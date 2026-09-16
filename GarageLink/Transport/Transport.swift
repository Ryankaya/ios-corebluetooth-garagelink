import Foundation
import GarageProtocol

// The app talks to devices through these two protocols. `BLECentral` implements them with
// CoreBluetooth; `VirtualScanner` implements them in-process so the whole app (pairing,
// signed commands, reconnects) runs in the iOS Simulator, which has no Bluetooth radio.

enum TransportKind: String, Codable, CaseIterable, Identifiable {
    case bluetooth
    case virtual

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bluetooth: return "Bluetooth"
        case .virtual: return "Virtual device"
        }
    }

    static var preferred: TransportKind {
        #if targetEnvironment(simulator)
        return .virtual
        #else
        return .bluetooth
        #endif
    }
}

struct DiscoveredPeripheral: Identifiable, Equatable {
    let id: UUID
    var name: String
    var rssi: Int
    var lastSeen: Date

    /// "GL-A1B2C3" → "a1b2c3", used to match a pairing link's device ID before connecting.
    var deviceIDPrefix: String? {
        guard name.hasPrefix(GarageGATT.advertisedNamePrefix) else { return nil }
        return name.dropFirst(GarageGATT.advertisedNamePrefix.count).lowercased()
    }
}

enum LinkEvent {
    case notification(GarageCharacteristic, Data)
    case disconnected(Error?)
}

@MainActor
protocol GATTConnection: AnyObject {
    /// Single consumer: `GarageClient` owns the iteration.
    var events: AsyncStream<LinkEvent> { get }
    var isConnected: Bool { get }
    func read(_ characteristic: GarageCharacteristic) async throws -> Data
    func write(_ characteristic: GarageCharacteristic, _ value: Data) async throws
    func setNotifications(_ enabled: Bool, for characteristic: GarageCharacteristic) async throws
    func readRSSI() async throws -> Int
    func disconnect()
}

@MainActor
protocol PeripheralScanner: AnyObject {
    /// Scans while the stream is being consumed; cancelling the consuming task stops the scan.
    func scan() -> AsyncStream<DiscoveredPeripheral>
    func connect(to id: UUID, timeout: TimeInterval) async throws -> GATTConnection
}

enum LinkError: LocalizedError, Equatable {
    case bluetoothUnavailable(String)
    case timeout(String)
    case notFound
    case disconnected
    case cancelled
    case serviceMissing
    case characteristicMissing(GarageCharacteristic)
    case att(GarageATTError)
    case gatt(String)

    var errorDescription: String? {
        switch self {
        case let .bluetoothUnavailable(reason): return reason
        case let .timeout(operation): return "\(operation) timed out. Is the device nearby and powered?"
        case .notFound: return "Device not found nearby."
        case .disconnected: return "The device disconnected."
        case .cancelled: return "Cancelled."
        case .serviceMissing: return "This device doesn't expose the GarageLink service."
        case let .characteristicMissing(c): return "The device is missing the \(c.label) characteristic (firmware mismatch?)."
        case let .att(error): return error.message
        case let .gatt(message): return message
        }
    }
}

/// A callback-to-async bridge that resumes exactly once: from the delegate callback, a timeout,
/// cancellation, or a disconnect — whichever comes first.
@MainActor
final class Pending<Value> {
    private var continuation: CheckedContinuation<Value, Error>?
    private var timeoutTask: Task<Void, Never>?
    private(set) var isCompleted = false

    func resume(_ result: Result<Value, Error>) {
        guard !isCompleted, let continuation else { return }
        isCompleted = true
        self.continuation = nil
        timeoutTask?.cancel()
        continuation.resume(with: result)
    }

    fileprivate func install(_ continuation: CheckedContinuation<Value, Error>, timeout: TimeInterval, operation: String) {
        self.continuation = continuation
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.resume(.failure(LinkError.timeout(operation)))
        }
    }
}

/// Registers a `Pending` (via `start`, which typically stores it and kicks off a CoreBluetooth call)
/// and suspends until something resumes it.
@MainActor
func awaitCallback<Value>(
    timeout: TimeInterval,
    operation: String,
    start: (Pending<Value>) -> Void
) async throws -> Value {
    let pending = Pending<Value>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Value, Error>) in
            pending.install(continuation, timeout: timeout, operation: operation)
            start(pending)
        }
    } onCancel: {
        Task { @MainActor in pending.resume(.failure(LinkError.cancelled)) }
    }
}

extension Array {
    /// Pops the first element whose pending operation is still waiting (skips timed-out ones).
    @MainActor
    mutating func popLive<Value>() -> Pending<Value>? where Element == Pending<Value> {
        while let first = first {
            removeFirst()
            if !first.isCompleted { return first }
        }
        return nil
    }
}
