import SwiftUI

/// Every frame on the wire: what was written, what came back, and what the device rejected.
struct TrafficLogView: View {
    @EnvironmentObject private var log: TrafficLog

    var body: some View {
        List {
            if log.entries.isEmpty {
                Text("No traffic yet. Connect to a device to see GATT reads, writes and notifications.")
                    .foregroundStyle(.secondary)
            }
            ForEach(log.entries) { entry in
                HStack(alignment: .top, spacing: 10) {
                    icon(for: entry.direction)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            if let characteristic = entry.characteristic {
                                Text(characteristic.label).font(.caption.bold())
                            }
                            Text(entry.repeats > 1 ? "\(entry.note) ×\(entry.repeats)" : entry.note).font(.caption)
                            Spacer()
                            Text(entry.date, format: .dateTime.hour().minute().second())
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        if let bytes = entry.bytes, !bytes.isEmpty {
                            Text("\(bytes.count)B  \(bytes.hexDump)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .listStyle(.plain)
        .navigationTitle("Protocol inspector")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Clear") { log.clear() }
                    .disabled(log.entries.isEmpty)
            }
        }
    }

    @ViewBuilder
    private func icon(for direction: TrafficLog.Direction) -> some View {
        switch direction {
        case .tx:
            Image(systemName: "arrow.up.circle.fill").foregroundStyle(.orange)
        case .rx:
            Image(systemName: "arrow.down.circle.fill").foregroundStyle(.blue)
        case .event:
            Image(systemName: "circle.fill").font(.caption2).foregroundStyle(.secondary)
        case .error:
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        }
    }
}
