import CoreBluetooth
import Foundation
import GarageProtocol

extension GarageCharacteristic {
    var cbuuid: CBUUID { CBUUID(string: rawValue) }
    init?(cbuuid: CBUUID) { self.init(rawValue: cbuuid.uuidString.uppercased()) }
}

/// Exposes a `GarageDeviceCore` as a real BLE GATT peripheral using the Mac's Bluetooth radio.
/// Everything (CoreBluetooth callbacks, motor timer, UI updates) runs on the main queue.
final class BluetoothDeviceHost: NSObject, ObservableObject, CBPeripheralManagerDelegate {
    struct LogLine: Identifiable {
        enum Kind { case device, radio, error }
        let id = UUID()
        let date = Date()
        let kind: Kind
        let text: String
    }

    @Published private(set) var status: DoorStatus
    @Published private(set) var radio = "Starting Bluetooth…"
    @Published private(set) var isAdvertising = false
    @Published private(set) var connectedPhones = 0
    @Published private(set) var pairingSecondsLeft = 0
    @Published private(set) var log: [LogLine] = []

    let core: GarageDeviceCore
    private let store = SnapshotStore.default()
    private var manager: CBPeripheralManager!
    private var characteristics: [GarageCharacteristic: CBMutableCharacteristic] = [:]
    private var backlog: [(characteristic: CBMutableCharacteristic, value: Data, centrals: [CBCentral]?)] = []
    private var subscribers: [UUID: Set<GarageCharacteristic>] = [:]
    private var motorTimer: Timer?
    private var lastTick = Date()

    override init() {
        if let snapshot = store.load() {
            core = GarageDeviceCore(snapshot: snapshot)
        } else {
            core = GarageDeviceCore.makeNew(name: "Garage")
        }
        if core.pairedClientCount == 0 { core.pressPairButton() }
        status = core.status
        super.init()
        store.save(core.snapshot)
        core.log = { [weak self] in self?.append(.device, $0) }
        if core.pairingMode { append(.device, "Pairing mode on — no phones paired yet") }

        manager = CBPeripheralManager(delegate: self, queue: .main)
        motorTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in self?.tick() }
    }

    var advertisedName: String { GarageGATT.advertisedName(for: core.deviceID) }
    var stateFilePath: String { store.url.path }

    // MARK: Physical controls

    func pressPairButton() { core.pressPairButton(); deviceStateChanged() }
    func pressWallButton() { core.pressWallButton(); deviceStateChanged() }
    func setObstruction(_ blocked: Bool) { core.setObstruction(blocked); deviceStateChanged() }
    func forgetAllPhones() { core.forgetAllPhones(); deviceStateChanged() }

    private func deviceStateChanged() {
        store.save(core.snapshot)
        publish(notify: true)
    }

    private func tick() {
        let now = Date()
        let changed = core.tick(now.timeIntervalSince(lastTick))
        lastTick = now
        let seconds = Int(core.pairingModeRemaining.rounded(.up))
        if seconds != pairingSecondsLeft { pairingSecondsLeft = seconds }
        if changed { publish(notify: true) }
    }

    private func publish(notify: Bool) {
        status = core.status
        if notify { self.notify(.state, core.status.encoded, to: nil) }
    }

    private func append(_ kind: LogLine.Kind, _ text: String) {
        log.insert(LogLine(kind: kind, text: text), at: 0)
        if log.count > 200 { log.removeLast() }
        fileLog.write(text)
    }

    /// Mirrors the device log to ~/Library/Application Support/GarageLinkSim/gatt.log for debugging.
    private let fileLog = FileLog(url: SnapshotStore.default().url.deletingLastPathComponent().appendingPathComponent("gatt.log"))

    // MARK: Setup

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        switch peripheral.state {
        case .poweredOn:
            radio = "Bluetooth on"
            publishService()
        case .poweredOff:
            radio = "Bluetooth is off"
            isAdvertising = false
        case .unauthorized:
            radio = "Bluetooth permission denied — allow GarageSim in System Settings › Privacy & Security › Bluetooth"
            isAdvertising = false
        case .unsupported:
            radio = "This Mac can't act as a Bluetooth LE peripheral"
        default:
            radio = "Bluetooth unavailable"
            isAdvertising = false
        }
        if peripheral.state != .poweredOn {
            subscribers.removeAll()
            connectedPhones = 0
            append(.error, radio)
        }
    }

    private func publishService() {
        manager.removeAllServices()
        func make(_ c: GarageCharacteristic, _ properties: CBCharacteristicProperties, _ permissions: CBAttributePermissions) -> CBMutableCharacteristic {
            let characteristic = CBMutableCharacteristic(type: c.cbuuid, properties: properties, value: nil, permissions: permissions)
            characteristics[c] = characteristic
            return characteristic
        }
        let service = CBMutableService(type: CBUUID(string: GarageGATT.serviceUUID), primary: true)
        service.characteristics = [
            make(.info, [.read], [.readable]),
            make(.state, [.read, .notify], [.readable]),
            make(.challenge, [.read], [.readable]),
            make(.command, [.write], [.writeable]),
            make(.pairing, [.write, .notify], [.writeable]),
        ]
        manager.add(service)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let error {
            append(.error, "Couldn't publish GATT service: \(error.localizedDescription)")
            return
        }
        append(.radio, "GATT service published (pid \(ProcessInfo.processInfo.processIdentifier))")
        manager.startAdvertising([
            CBAdvertisementDataLocalNameKey: advertisedName,
            CBAdvertisementDataServiceUUIDsKey: [CBUUID(string: GarageGATT.serviceUUID)],
        ])
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        if let error {
            append(.error, "Advertising failed: \(error.localizedDescription)")
        } else {
            isAdvertising = true
            append(.radio, "Advertising as \(advertisedName)")
        }
    }

    // MARK: Subscriptions — the best "a phone connected" signal a peripheral gets

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        guard let c = GarageCharacteristic(cbuuid: characteristic.uuid) else { return }
        if subscribers[central.identifier] == nil {
            append(.radio, "Phone connected · max notify \(central.maximumUpdateValueLength) bytes")
        }
        subscribers[central.identifier, default: []].insert(c)
        connectedPhones = subscribers.count
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        guard let c = GarageCharacteristic(cbuuid: characteristic.uuid) else { return }
        subscribers[central.identifier]?.remove(c)
        if subscribers[central.identifier]?.isEmpty == true {
            subscribers[central.identifier] = nil
            append(.radio, "Phone disconnected")
        }
        connectedPhones = subscribers.count
    }

    // MARK: Reads

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        append(.radio, "Read request \(GarageCharacteristic(cbuuid: request.characteristic.uuid)?.label ?? request.characteristic.uuid.uuidString) offset \(request.offset)")
        guard let c = GarageCharacteristic(cbuuid: request.characteristic.uuid) else {
            peripheral.respond(to: request, withResult: .attributeNotFound)
            return
        }
        let value: Data
        switch c {
        case .info: value = core.info.encoded
        case .state: value = core.status.encoded
        case .challenge: value = core.challenge
        case .command, .pairing:
            peripheral.respond(to: request, withResult: .readNotPermitted)
            return
        }
        guard request.offset <= value.count else {
            peripheral.respond(to: request, withResult: .invalidOffset)
            return
        }
        request.value = value.subdata(in: request.offset..<value.count)
        peripheral.respond(to: request, withResult: .success)
    }

    // MARK: Writes

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        // CoreBluetooth contract: respond exactly once, to the first request, for the whole batch.
        guard let first = requests.first else { return }
        for request in requests {
            append(.radio, "Write request \(GarageCharacteristic(cbuuid: request.characteristic.uuid)?.label ?? "?") \(request.value?.count ?? 0) bytes")
        }
        var result: CBATTError.Code = .success
        var replies: [(GarageCharacteristic, Data)] = []

        for request in requests {
            guard request.offset == 0 else { result = .invalidOffset; break }
            guard let c = GarageCharacteristic(cbuuid: request.characteristic.uuid), let value = request.value else {
                result = .unlikelyError
                break
            }
            switch c {
            case .command:
                if case let .failure(error) = core.handleCommand(value) { result = Self.attCode(error) }
            case .pairing:
                switch core.handlePairing(value) {
                case let .success(reply):
                    if let reply { replies.append((.pairing, reply.encoded)) }
                case let .failure(error):
                    result = Self.attCode(error)
                }
            case .info, .state, .challenge:
                result = .writeNotPermitted
            }
            if result != .success { break }
        }

        peripheral.respond(to: first, withResult: result)
        if result != .success {
            append(.error, "Write rejected with ATT error 0x\(String(result.rawValue, radix: 16))")
        }
        for (characteristic, value) in replies {
            notify(characteristic, value, to: [first.central])
        }
        deviceStateChanged()
    }

    private static func attCode(_ error: GarageATTError) -> CBATTError.Code {
        CBATTError.Code(rawValue: Int(error.rawValue)) ?? .unlikelyError
    }

    // MARK: Notifications

    private func notify(_ c: GarageCharacteristic, _ value: Data, to centrals: [CBCentral]?) {
        guard let characteristic = characteristics[c], manager.state == .poweredOn else { return }
        if c == .state {
            // Only the latest door state matters; drop stale queued ones.
            backlog.removeAll { $0.characteristic === characteristic }
        }
        if !backlog.isEmpty || !manager.updateValue(value, for: characteristic, onSubscribedCentrals: centrals) {
            backlog.append((characteristic, value, centrals))
        }
    }

    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        while let next = backlog.first {
            guard peripheral.updateValue(next.value, for: next.characteristic, onSubscribedCentrals: next.centrals) else { return }
            backlog.removeFirst()
        }
    }
}

/// Persists the device identity, setup code and paired phone keys between runs — like device flash.
struct SnapshotStore {
    let url: URL

    static func `default`() -> SnapshotStore {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return SnapshotStore(url: support.appendingPathComponent("GarageLinkSim/device.json"))
    }

    func load() -> GarageDeviceCore.Snapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(GarageDeviceCore.Snapshot.self, from: data)
    }

    func save(_ snapshot: GarageDeviceCore.Snapshot) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(snapshot).write(to: url, options: [.atomic])
            // Holds pairing keys: owner read/write only.
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            NSLog("GarageSim: couldn't save device state: \(error)")
        }
    }
}

final class FileLog {
    private let handle: FileHandle?
    private let formatter = ISO8601DateFormatter()

    init(url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        handle?.seekToEndOfFile()
    }

    func write(_ line: String) {
        handle?.write(Data("\(formatter.string(from: Date())) \(line)\n".utf8))
    }
}
