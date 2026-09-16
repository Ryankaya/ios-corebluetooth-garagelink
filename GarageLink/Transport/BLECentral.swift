import CoreBluetooth
import GarageProtocol

extension GarageCharacteristic {
    var cbuuid: CBUUID { CBUUID(string: rawValue) }
    init?(cbuuid: CBUUID) { self.init(rawValue: cbuuid.uuidString.uppercased()) }
}

extension GarageGATT {
    static let serviceCBUUID = CBUUID(string: serviceUUID)
}

extension LinkError {
    /// Maps CoreBluetooth errors; ATT application errors from the device become `.att`.
    /// Anything else keeps the failing step and raw code so field reports are actionable.
    init(coreBluetooth error: Error, operation: String) {
        let nsError = error as NSError
        if nsError.domain == CBATTErrorDomain, let att = GarageATTError(rawValue: UInt8(clamping: nsError.code)) {
            self = .att(att)
        } else if nsError.domain == CBErrorDomain, nsError.code == CBError.Code.peripheralDisconnected.rawValue || nsError.code == CBError.Code.notConnected.rawValue {
            self = .disconnected
        } else if nsError.domain == CBATTErrorDomain {
            self = .gatt("\(operation) failed: ATT error 0x\(String(format: "%02X", nsError.code)) (\(error.localizedDescription))")
        } else {
            self = .gatt("\(operation) failed: \(error.localizedDescription) [\(nsError.domain) \(nsError.code)]")
        }
    }
}

/// CoreBluetooth central. Created lazily so the Bluetooth permission prompt appears when the user
/// first scans, not at launch. Delegate callbacks are delivered on the main queue.
@MainActor
final class BLECentral: NSObject, ObservableObject, PeripheralScanner {
    enum Availability: Equatable {
        case notStarted, unknown, ready, poweredOff, unauthorized, unsupported, resetting

        var problem: String? {
            switch self {
            case .poweredOff: return "Bluetooth is turned off."
            case .unauthorized: return "GarageLink doesn't have Bluetooth permission. Enable it in Settings."
            case .unsupported: return "This device doesn't support Bluetooth LE."
            case .notStarted, .unknown, .ready, .resetting: return nil
            }
        }
    }

    static let restoreIdentifier = "com.ryankaya.garagelink.central"

    @Published private(set) var availability: Availability = .notStarted

    private var manager: CBCentralManager?
    /// CoreBluetooth only keeps a peripheral alive while we hold a strong reference.
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var scanConsumers: [UUID: AsyncStream<DiscoveredPeripheral>.Continuation] = [:]
    private var poweredOnWaiters: [Pending<Void>] = []
    private var connecting: [UUID: Pending<CBPeripheral>] = [:]
    private var connections: [UUID: BLEConnection] = [:]

    private func startManager() -> CBCentralManager {
        if let manager { return manager }
        availability = .unknown
        let manager = CBCentralManager(delegate: self, queue: .main, options: [
            CBCentralManagerOptionShowPowerAlertKey: true,
            // State restoration: if iOS terminates us while connected, it relaunches us in the background.
            CBCentralManagerOptionRestoreIdentifierKey: Self.restoreIdentifier,
        ])
        self.manager = manager
        return manager
    }

    private func waitUntilReady() async throws -> CBCentralManager {
        let manager = startManager()
        switch availability {
        case .ready:
            return manager
        case .poweredOff, .unauthorized, .unsupported:
            throw LinkError.bluetoothUnavailable(availability.problem ?? "Bluetooth unavailable.")
        case .notStarted, .unknown, .resetting:
            try await awaitCallback(timeout: 5, operation: "Starting Bluetooth") { poweredOnWaiters.append($0) }
            return manager
        }
    }

    // MARK: Scanning

    func scan() -> AsyncStream<DiscoveredPeripheral> {
        let (stream, continuation) = AsyncStream.makeStream(of: DiscoveredPeripheral.self, bufferingPolicy: .bufferingNewest(32))
        let token = UUID()
        scanConsumers[token] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in
                self?.scanConsumers[token] = nil
                self?.updateScanning()
            }
        }
        Task {
            do {
                _ = try await waitUntilReady()
                updateScanning()
            } catch {
                continuation.finish()
            }
        }
        return stream
    }

    private func updateScanning() {
        guard let manager, availability == .ready else { return }
        if scanConsumers.isEmpty {
            if manager.isScanning { manager.stopScan() }
        } else if !manager.isScanning {
            // Duplicates on: live RSSI while the scan sheet is open (foreground only).
            manager.scanForPeripherals(withServices: [GarageGATT.serviceCBUUID], options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        }
    }

    // MARK: Connecting

    func connect(to id: UUID, timeout: TimeInterval) async throws -> GATTConnection {
        let manager = try await waitUntilReady()
        if let existing = connections[id], existing.isConnected { return existing }

        guard let peripheral = peripherals[id] ?? manager.retrievePeripherals(withIdentifiers: [id]).first else {
            throw LinkError.notFound
        }
        peripherals[id] = peripheral

        do {
            // CoreBluetooth's connect never times out on its own; we impose one.
            _ = try await awaitCallback(timeout: timeout, operation: "Connecting") { (pending: Pending<CBPeripheral>) in
                connecting[id]?.resume(.failure(LinkError.cancelled))
                connecting[id] = pending
                manager.connect(peripheral, options: nil)
            }
        } catch {
            connecting[id] = nil
            manager.cancelPeripheralConnection(peripheral)
            throw error
        }

        let connection = BLEConnection(peripheral: peripheral) { [weak self] in
            self?.manager?.cancelPeripheralConnection(peripheral)
        }
        connections[id] = connection
        do {
            try await connection.discoverGATT()
        } catch {
            connection.disconnect()
            throw error
        }
        return connection
    }
}

extension BLECentral: @preconcurrency CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn: availability = .ready
        case .poweredOff: availability = .poweredOff
        case .unauthorized: availability = .unauthorized
        case .unsupported: availability = .unsupported
        case .resetting: availability = .resetting
        case .unknown: availability = .unknown
        @unknown default: availability = .unknown
        }

        if availability == .ready {
            poweredOnWaiters.forEach { $0.resume(.success(())) }
            poweredOnWaiters.removeAll()
            updateScanning()
            return
        }

        // Radio went away: every link is dead.
        let reason = LinkError.bluetoothUnavailable(availability.problem ?? "Bluetooth was reset.")
        for connection in connections.values { connection.handleDisconnect(reason) }
        connections.removeAll()
        for pending in connecting.values { pending.resume(.failure(reason)) }
        connecting.removeAll()
        if let problem = availability.problem {
            poweredOnWaiters.forEach { $0.resume(.failure(LinkError.bluetoothUnavailable(problem))) }
            poweredOnWaiters.removeAll()
        }
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        for peripheral in dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? [] {
            peripherals[peripheral.identifier] = peripheral
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let rssi = RSSI.intValue
        guard rssi != 127 else { return } // 127 = "RSSI unavailable"
        peripherals[peripheral.identifier] = peripheral
        // Prefer the advertised local name: `peripheral.name` can be a stale GAP name (e.g. the Mac's hostname).
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? "Unnamed device"
        let discovery = DiscoveredPeripheral(id: peripheral.identifier, name: name, rssi: rssi, lastSeen: Date())
        for consumer in scanConsumers.values { consumer.yield(discovery) }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connecting.removeValue(forKey: peripheral.identifier)?.resume(.success(peripheral))
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        let failure = error.map { LinkError(coreBluetooth: $0, operation: "Connecting") } ?? .gatt("Failed to connect.")
        connecting.removeValue(forKey: peripheral.identifier)?.resume(.failure(failure))
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        if let connection = connections.removeValue(forKey: peripheral.identifier) {
            // The callback is about an established link. A reconnect may already be in flight
            // (disconnect → quick reconnect); don't let this late callback fail it.
            connection.handleDisconnect(error)
        } else {
            connecting.removeValue(forKey: peripheral.identifier)?.resume(.failure(LinkError.disconnected))
        }
    }
}

// MARK: - Connection

/// One connected peripheral. Serializes nothing itself — CoreBluetooth queues GATT operations —
/// but matches each callback to the oldest live waiter for that characteristic.
@MainActor
final class BLEConnection: NSObject, GATTConnection {
    let events: AsyncStream<LinkEvent>
    private(set) var isConnected = true

    private let peripheral: CBPeripheral
    private let cancel: () -> Void
    private let eventSink: AsyncStream<LinkEvent>.Continuation
    private var characteristics: [GarageCharacteristic: CBCharacteristic] = [:]
    private var serviceDiscovery: Pending<[CBService]>?
    private var characteristicDiscovery: Pending<Void>?
    private var reads: [GarageCharacteristic: [Pending<Data>]] = [:]
    private var writes: [GarageCharacteristic: [Pending<Void>]] = [:]
    private var notifyChanges: [GarageCharacteristic: [Pending<Void>]] = [:]
    private var rssiReads: [Pending<Int>] = []

    init(peripheral: CBPeripheral, cancel: @escaping () -> Void) {
        self.peripheral = peripheral
        self.cancel = cancel
        (events, eventSink) = AsyncStream.makeStream(of: LinkEvent.self)
        super.init()
        peripheral.delegate = self
    }

    func discoverGATT() async throws {
        let services = try await awaitCallback(timeout: 10, operation: "Service discovery") { (pending: Pending<[CBService]>) in
            serviceDiscovery = pending
            peripheral.discoverServices([GarageGATT.serviceCBUUID])
        }
        // Normally one. iOS caches the GATT database of bonded devices (e.g. a Mac on the same Apple ID),
        // so a stale copy of the service can linger next to the live one. Use the first copy that answers.
        var lastError: Error = LinkError.serviceMissing
        for service in services {
            do {
                try await awaitCallback(timeout: 10, operation: "Characteristic discovery") { (pending: Pending<Void>) in
                    characteristicDiscovery = pending
                    peripheral.discoverCharacteristics(GarageCharacteristic.allCases.map(\.cbuuid), for: service)
                }
                if services.count > 1 { _ = try await read(.info) }
                return
            } catch {
                lastError = error
            }
        }
        if services.count > 1 {
            throw LinkError.gatt("\(lastError.localizedDescription) Tried \(services.count) copies of the GarageLink service.")
        }
        throw lastError
    }

    private func characteristic(_ c: GarageCharacteristic) throws -> CBCharacteristic {
        guard isConnected else { throw LinkError.disconnected }
        guard let characteristic = characteristics[c] else { throw LinkError.characteristicMissing(c) }
        return characteristic
    }

    func read(_ c: GarageCharacteristic) async throws -> Data {
        let characteristic = try characteristic(c)
        return try await awaitCallback(timeout: 5, operation: "Reading \(c.label)") { (pending: Pending<Data>) in
            reads[c, default: []].append(pending)
            peripheral.readValue(for: characteristic)
        }
    }

    func write(_ c: GarageCharacteristic, _ value: Data) async throws {
        let characteristic = try characteristic(c)
        let maximum = peripheral.maximumWriteValueLength(for: .withResponse)
        guard value.count <= maximum else {
            throw LinkError.gatt("\(c.label) frame is \(value.count) bytes; link allows \(maximum).")
        }
        try await awaitCallback(timeout: 5, operation: "Writing \(c.label)") { (pending: Pending<Void>) in
            writes[c, default: []].append(pending)
            // With response: the device's ATT result (e.g. "bad setup code") comes back on this write.
            peripheral.writeValue(value, for: characteristic, type: .withResponse)
        }
    }

    func setNotifications(_ enabled: Bool, for c: GarageCharacteristic) async throws {
        let characteristic = try characteristic(c)
        guard characteristic.isNotifying != enabled else { return }
        try await awaitCallback(timeout: 5, operation: "Subscribing to \(c.label)") { (pending: Pending<Void>) in
            notifyChanges[c, default: []].append(pending)
            peripheral.setNotifyValue(enabled, for: characteristic)
        }
    }

    func readRSSI() async throws -> Int {
        guard isConnected else { throw LinkError.disconnected }
        return try await awaitCallback(timeout: 3, operation: "Reading signal strength") { (pending: Pending<Int>) in
            rssiReads.append(pending)
            peripheral.readRSSI()
        }
    }

    func disconnect() {
        guard isConnected else { return }
        cancel()
        handleDisconnect(nil)
    }

    func handleDisconnect(_ error: Error?) {
        guard isConnected else { return }
        isConnected = false
        let failure = LinkError.disconnected
        serviceDiscovery?.resume(.failure(failure))
        characteristicDiscovery?.resume(.failure(failure))
        reads.values.flatMap { $0 }.forEach { $0.resume(.failure(failure)) }
        writes.values.flatMap { $0 }.forEach { $0.resume(.failure(failure)) }
        notifyChanges.values.flatMap { $0 }.forEach { $0.resume(.failure(failure)) }
        rssiReads.forEach { $0.resume(.failure(failure)) }
        reads.removeAll(); writes.removeAll(); notifyChanges.removeAll(); rssiReads.removeAll()
        eventSink.yield(.disconnected(error))
        eventSink.finish()
    }
}

extension BLEConnection: @preconcurrency CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            serviceDiscovery?.resume(.failure(LinkError(coreBluetooth: error, operation: "Service discovery")))
            return
        }
        let services = peripheral.services?.filter { $0.uuid == GarageGATT.serviceCBUUID } ?? []
        serviceDiscovery?.resume(services.isEmpty ? .failure(LinkError.serviceMissing) : .success(services))
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error {
            characteristicDiscovery?.resume(.failure(LinkError(coreBluetooth: error, operation: "Characteristic discovery")))
            return
        }
        characteristics = [:]
        for characteristic in service.characteristics ?? [] {
            if let c = GarageCharacteristic(cbuuid: characteristic.uuid) { characteristics[c] = characteristic }
        }
        if let missing = GarageCharacteristic.allCases.first(where: { characteristics[$0] == nil }) {
            characteristicDiscovery?.resume(.failure(LinkError.characteristicMissing(missing)))
        } else {
            characteristicDiscovery?.resume(.success(()))
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let c = GarageCharacteristic(cbuuid: characteristic.uuid) else { return }
        if let error {
            reads[c]?.popLive()?.resume(.failure(LinkError(coreBluetooth: error, operation: "Reading \(c.label)")))
            return
        }
        let value = characteristic.value ?? Data()
        // The same callback delivers read responses and notifications. A waiting read claims it;
        // otherwise it's an unsolicited notification.
        if let read = reads[c]?.popLive() {
            read.resume(.success(value))
        } else if characteristic.isNotifying {
            eventSink.yield(.notification(c, value))
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let c = GarageCharacteristic(cbuuid: characteristic.uuid) else { return }
        writes[c]?.popLive()?.resume(error.map { .failure(LinkError(coreBluetooth: $0, operation: "Writing \(c.label)")) } ?? .success(()))
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard let c = GarageCharacteristic(cbuuid: characteristic.uuid) else { return }
        notifyChanges[c]?.popLive()?.resume(error.map { .failure(LinkError(coreBluetooth: $0, operation: "Subscribing to \(c.label)")) } ?? .success(()))
    }

    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        rssiReads.popLive()?.resume(error.map { .failure(LinkError(coreBluetooth: $0, operation: "Reading signal strength")) } ?? .success(RSSI.intValue))
    }

    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        // The device changed its GATT table (e.g. firmware update): our handles are stale.
        if invalidatedServices.contains(where: { $0.uuid == GarageGATT.serviceCBUUID }) {
            disconnect()
        }
    }
}
