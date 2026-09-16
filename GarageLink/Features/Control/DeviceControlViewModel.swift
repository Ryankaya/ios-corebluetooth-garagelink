import GarageProtocol
import SwiftUI

@MainActor
final class DeviceControlViewModel: ObservableObject {
    enum Link: Equatable {
        case disconnected
        case connecting
        case connected
        case retrying(in: Int, reason: String)
    }

    @Published private(set) var link: Link = .disconnected
    @Published private(set) var status: DoorStatus?
    @Published private(set) var rssi: Int?
    @Published private(set) var sending: Opcode?
    @Published var alert: String?
    @Published private(set) var isUnpaired = false

    let device: PairedDevice
    private let env: AppEnvironment
    private var client: GarageClient?
    private var connectTask: Task<Void, Never>?
    private var rssiTask: Task<Void, Never>?
    private var isActive = false
    private var attempt = 0

    init(device: PairedDevice, env: AppEnvironment) {
        self.device = device
        self.env = env
    }

    // MARK: Lifecycle — connected only while the screen is visible and the app is active

    func activate() {
        guard !isActive else { return }
        isActive = true
        attempt = 0
        connect()
    }

    func deactivate() {
        isActive = false
        connectTask?.cancel()
        connectTask = nil
        rssiTask?.cancel()
        rssiTask = nil
        client?.disconnect()
        client = nil
        link = .disconnected
    }

    private func connect() {
        guard isActive, client == nil, link != .connecting else { return }
        connectTask?.cancel()
        link = .connecting
        connectTask = Task { [weak self] in
            guard let self else { return }
            do {
                let connection = try await env.connect(to: device)
                let client = GarageClient(connection: connection, log: env.log)
                client.onStatus = { [weak self] status in
                    withAnimation(.easeInOut(duration: 0.15)) { self?.status = status }
                }
                client.onDisconnect = { [weak self] error in
                    self?.connectionLost(error)
                }
                self.client = client
                try await client.prepare(expecting: device.deviceID)
                let status = try await client.readStatus()
                try Task.checkCancellation()
                self.status = status
                link = .connected
                attempt = 0
                startRSSIUpdates()
            } catch is CancellationError {
                return
            } catch LinkError.cancelled {
                return
            } catch {
                client?.disconnect()
                client = nil
                scheduleRetry(reason: error.localizedDescription)
            }
        }
    }

    private func connectionLost(_ error: Error?) {
        client = nil
        rssiTask?.cancel()
        rssi = nil
        link = .disconnected
        scheduleRetry(reason: error?.localizedDescription ?? "Connection lost")
    }

    /// Exponential backoff: 1, 2, 4, 8, then every 10 seconds.
    private func scheduleRetry(reason: String) {
        guard isActive else { return }
        let delay = min(1 << min(attempt, 4), 10)
        attempt += 1
        link = .retrying(in: delay, reason: reason)
        connectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
            guard !Task.isCancelled, let self else { return }
            self.link = .disconnected
            self.connect()
        }
    }

    func retryNow() {
        connectTask?.cancel()
        link = .disconnected
        attempt = 0
        connect()
    }

    private func startRSSIUpdates() {
        rssiTask?.cancel()
        rssiTask = Task { [weak self] in
            while !Task.isCancelled {
                if let client = self?.client, let value = try? await client.readRSSI() {
                    self?.rssi = value
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    // MARK: Commands

    func send(_ opcode: Opcode) async {
        guard let client, sending == nil else { return }
        guard let key = env.registry.key(for: device) else {
            alert = "The pairing key for this device is missing. Forget the device and pair again."
            return
        }
        sending = opcode
        defer { sending = nil }
        do {
            try await client.send(opcode, key: key, clientID: env.registry.clientID)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        } catch LinkError.att(.unauthorized) {
            isUnpaired = true
            alert = "The device no longer recognizes this iPhone (it may have been reset). Forget it and pair again."
        } catch {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            alert = error.localizedDescription
        }
    }

    /// Asks the device to delete this phone's key (best effort), then deletes it locally.
    func forget() async {
        if let client, let key = env.registry.key(for: device), !isUnpaired {
            try? await client.send(.unpair, key: key, clientID: env.registry.clientID)
        }
        deactivate()
        env.registry.remove(device)
    }

    // MARK: Presentation

    var primaryAction: Opcode {
        switch status?.door {
        case .opening?, .closing?: return .stop
        case .open?: return .close
        case .stopped?, .closed?, nil: return .open
        }
    }

    var headline: String {
        guard let status else { return "—" }
        switch status.door {
        case .opening, .closing: return "\(status.door.label)… \(status.position)%"
        case .stopped: return "Stopped at \(status.position)%"
        case .open, .closed: return status.door.label
        }
    }
}
