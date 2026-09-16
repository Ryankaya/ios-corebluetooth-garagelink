import Foundation
import GarageProtocol

/// Records every GATT frame the app sends and receives, for the in-app protocol inspector.
@MainActor
final class TrafficLog: ObservableObject {
    enum Direction {
        case tx, rx, event, error
    }

    struct Entry: Identifiable {
        let id = UUID()
        var date = Date()
        let direction: Direction
        let characteristic: GarageCharacteristic?
        var bytes: Data?
        let note: String
        /// Consecutive identical-kind notifications folded into this row (door travel sends ~100).
        var repeats = 1
    }

    @Published private(set) var entries: [Entry] = []
    private let limit = 400

    func record(_ direction: Direction, _ characteristic: GarageCharacteristic? = nil, _ bytes: Data? = nil, note: String) {
        if direction == .rx, characteristic == .state, var latest = entries.first,
           latest.direction == .rx, latest.characteristic == .state, latest.note == note {
            latest.bytes = bytes
            latest.date = Date()
            latest.repeats += 1
            entries[0] = latest
            return
        }
        entries.insert(Entry(direction: direction, characteristic: characteristic, bytes: bytes, note: note), at: 0)
        if entries.count > limit { entries.removeLast(entries.count - limit) }
    }

    func clear() {
        entries.removeAll()
    }
}
