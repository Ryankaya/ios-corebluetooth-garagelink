import Foundation
import GarageProtocol

@MainActor
final class AppEnvironment: ObservableObject {
    let registry = DeviceRegistry()
    let log = TrafficLog()
    let ble = BLECentral()
    lazy var virtualGarage = VirtualGarage()
    lazy var virtualScanner = VirtualScanner(device: virtualGarage)

    /// Set when the app is opened from a pairing QR code / NFC tag.
    @Published var pendingLink: PairingLink?

    func scanner(for kind: TransportKind) -> PeripheralScanner {
        switch kind {
        case .bluetooth: return ble
        case .virtual: return virtualScanner
        }
    }

    /// Reconnects to a paired device: try the remembered CoreBluetooth identifier first, then scan
    /// for the advertised name (identifiers change when a device rotates its Bluetooth address).
    func connect(to device: PairedDevice) async throws -> GATTConnection {
        switch device.transport {
        case .virtual:
            return try await virtualScanner.connect(to: VirtualGarage.peripheralID, timeout: 5)
        case .bluetooth:
            do {
                return try await ble.connect(to: device.peripheralID, timeout: 6)
            } catch let error as LinkError where error == .notFound || error.isTimeout {
                // The caller verifies the device ID from the Info characteristic after connecting.
                let found = try await discover(deviceID: device.deviceID, timeout: 8)
                registry.updatePeripheralID(found.id, for: device.deviceID)
                return try await ble.connect(to: found.id, timeout: 8)
            }
        }
    }

    /// Scans for the device: returns at once on an exact advertised-name match, otherwise after
    /// `timeout` falls back to the strongest GarageLink device whose name isn't visible.
    func discover(deviceID: ShortID, timeout: TimeInterval) async throws -> DiscoveredPeripheral {
        let name = GarageGATT.advertisedName(for: deviceID)
        let stream = ble.scan()
        var seen: [UUID: DiscoveredPeripheral] = [:]
        let exact: DiscoveredPeripheral? = try await withThrowingTaskGroup(of: DiscoveredPeripheral?.self) { group in
            group.addTask { @MainActor in
                for await discovery in stream {
                    if discovery.name == name { return discovery }
                    seen[discovery.id] = discovery
                }
                return nil
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }
            defer { group.cancelAll() }
            return try await group.next() ?? nil
        }
        guard let found = exact ?? Array(seen.values).bestCandidate(for: deviceID) else {
            throw LinkError.notFound
        }
        return found
    }
}

extension LinkError {
    var isTimeout: Bool {
        if case .timeout = self { return true }
        return false
    }
}
