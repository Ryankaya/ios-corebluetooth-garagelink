import Foundation
import GarageProtocol

/// An in-app garage controller running the same `GarageDeviceCore` firmware logic as the Mac
/// simulator. It lets the full app — discovery, ECDH pairing, signed commands, notifications,
/// disconnects — run in the iOS Simulator, and gives a demo without any hardware nearby.
@MainActor
final class VirtualGarage: ObservableObject {
    static let peripheralID = UUID(uuidString: "6E4A0000-0000-4000-8000-00000000C0DE")!

    @Published private(set) var status: DoorStatus
    @Published private(set) var pairingSecondsLeft = 0
    @Published private(set) var activity: [String] = []
    @Published private(set) var connectionCount = 0

    private(set) var core: GarageDeviceCore
    private var connections: [ObjectIdentifier: WeakConnection] = [:]
    private var timer: Timer?
    private var lastTick = Date()
    private let defaultsKey = "virtualGarage.snapshot"

    private struct WeakConnection { weak var value: VirtualConnection? }

    init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let snapshot = try? JSONDecoder().decode(GarageDeviceCore.Snapshot.self, from: data) {
            core = GarageDeviceCore(snapshot: snapshot)
        } else {
            core = GarageDeviceCore.makeNew(name: "Demo Garage")
        }
        if core.pairedClientCount == 0 { core.pressPairButton() }
        status = core.status
        configureCore()
        persist()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func configureCore() {
        core.log = { [weak self] message in
            self?.activity.insert(message, at: 0)
            if (self?.activity.count ?? 0) > 50 { self?.activity.removeLast() }
        }
    }

    var info: DeviceInfo { core.info }
    var advertisedName: String { GarageGATT.advertisedName(for: core.deviceID) }

    // MARK: Physical controls (the "device panel" sheet)

    func pressPairButton() { core.pressPairButton(); changed() }
    func pressWallButton() { core.pressWallButton(); changed() }
    func setObstruction(_ blocked: Bool) { core.setObstruction(blocked); changed() }

    /// New identity and setup code; every phone must pair again.
    func factoryReset() {
        for connection in connections.values.compactMap(\.value) { connection.dropLink() }
        core = GarageDeviceCore.makeNew(name: "Demo Garage")
        configureCore()
        core.pressPairButton()
        activity = ["Factory reset"]
        changed()
    }

    private func tick() {
        let now = Date()
        let didChange = core.tick(now.timeIntervalSince(lastTick))
        lastTick = now
        let seconds = Int(core.pairingModeRemaining.rounded(.up))
        if seconds != pairingSecondsLeft { pairingSecondsLeft = seconds }
        if didChange { changed(persist: false) }
    }

    private func changed(persist shouldPersist: Bool = true) {
        if shouldPersist { persist() }
        status = core.status
        broadcast(.state, core.status.encoded)
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(core.snapshot) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }

    private func broadcast(_ c: GarageCharacteristic, _ value: Data) {
        for connection in connections.values.compactMap(\.value) { connection.deliver(c, value) }
    }

    // MARK: GATT server

    fileprivate func attach(_ connection: VirtualConnection) {
        connections[ObjectIdentifier(connection)] = WeakConnection(value: connection)
        connectionCount = connections.values.filter { $0.value != nil }.count
    }

    fileprivate func detach(_ connection: VirtualConnection) {
        connections[ObjectIdentifier(connection)] = nil
        connectionCount = connections.values.filter { $0.value != nil }.count
    }

    fileprivate func handleRead(_ c: GarageCharacteristic) -> Data {
        switch c {
        case .info: return core.info.encoded
        case .state: return core.status.encoded
        case .challenge: return core.challenge
        case .command, .pairing: return Data()
        }
    }

    /// Returns notifications to deliver to the writer after the write response.
    fileprivate func handleWrite(_ c: GarageCharacteristic, _ value: Data) -> Result<[(GarageCharacteristic, Data)], GarageATTError> {
        defer { changed() }
        switch c {
        case .command:
            return core.handleCommand(value).map { _ in [] }
        case .pairing:
            return core.handlePairing(value).map { reply in reply.map { [(.pairing, $0.encoded)] } ?? [] }
        case .info, .state, .challenge:
            return .failure(.malformed)
        }
    }
}

@MainActor
final class VirtualScanner: PeripheralScanner {
    private let device: VirtualGarage

    init(device: VirtualGarage) {
        self.device = device
    }

    func scan() -> AsyncStream<DiscoveredPeripheral> {
        let (stream, continuation) = AsyncStream.makeStream(of: DiscoveredPeripheral.self)
        let task = Task { [device] in
            while !Task.isCancelled {
                continuation.yield(DiscoveredPeripheral(
                    id: VirtualGarage.peripheralID,
                    name: device.advertisedName,
                    rssi: Int.random(in: -52 ... -44),
                    lastSeen: Date()
                ))
                try? await Task.sleep(nanoseconds: 700_000_000)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    func connect(to id: UUID, timeout: TimeInterval) async throws -> GATTConnection {
        guard id == VirtualGarage.peripheralID else { throw LinkError.notFound }
        try await Task.sleep(nanoseconds: 350_000_000)
        return VirtualConnection(device: device)
    }
}

@MainActor
final class VirtualConnection: GATTConnection {
    let events: AsyncStream<LinkEvent>
    private(set) var isConnected = true
    private let eventSink: AsyncStream<LinkEvent>.Continuation
    private let device: VirtualGarage
    private var subscribed: Set<GarageCharacteristic> = []

    init(device: VirtualGarage) {
        self.device = device
        (events, eventSink) = AsyncStream.makeStream(of: LinkEvent.self)
        device.attach(self)
    }

    /// Simulated air time, so UI states (spinners, disabled buttons) behave as they do over BLE.
    private func airtime() async throws {
        try await Task.sleep(nanoseconds: UInt64.random(in: 25_000_000...70_000_000))
        guard isConnected else { throw LinkError.disconnected }
    }

    func read(_ c: GarageCharacteristic) async throws -> Data {
        try await airtime()
        return device.handleRead(c)
    }

    func write(_ c: GarageCharacteristic, _ value: Data) async throws {
        try await airtime()
        switch device.handleWrite(c, value) {
        case let .failure(error):
            throw LinkError.att(error)
        case let .success(notifications):
            // Like a real peripheral: write response first, notifications after.
            Task {
                try? await Task.sleep(nanoseconds: 20_000_000)
                for (characteristic, data) in notifications { deliver(characteristic, data) }
            }
        }
    }

    func setNotifications(_ enabled: Bool, for c: GarageCharacteristic) async throws {
        try await airtime()
        if enabled { subscribed.insert(c) } else { subscribed.remove(c) }
    }

    func readRSSI() async throws -> Int {
        try await airtime()
        return Int.random(in: -52 ... -44)
    }

    func deliver(_ c: GarageCharacteristic, _ value: Data) {
        guard isConnected, subscribed.contains(c) else { return }
        eventSink.yield(.notification(c, value))
    }

    func disconnect() {
        guard isConnected else { return }
        isConnected = false
        device.detach(self)
        eventSink.finish()
    }

    /// Device-initiated drop (factory reset), surfaced to the app as a link loss.
    func dropLink() {
        guard isConnected else { return }
        isConnected = false
        device.detach(self)
        eventSink.yield(.disconnected(LinkError.disconnected))
        eventSink.finish()
    }
}
