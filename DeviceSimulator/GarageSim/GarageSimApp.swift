import AppKit
import CoreImage.CIFilterBuiltins
import GarageProtocol
import SwiftUI

@main
struct GarageSimApp: App {
    @StateObject private var host = BluetoothDeviceHost()

    init() {
        // Two copies would publish the same GATT service on one radio and share one state file;
        // phones then hit a mix of both. Hand off to the running copy instead.
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if let running = others.first {
            running.activate(options: [])
            exit(0)
        }
    }

    var body: some Scene {
        WindowGroup("GarageSim") {
            DeviceFaceplateView()
                .environmentObject(host)
                .frame(minWidth: 720, minHeight: 520)
        }
        .windowResizability(.contentMinSize)
    }
}

/// The simulated controller's "hardware": label, LCD, buttons and a serial-console style log.
struct DeviceFaceplateView: View {
    @EnvironmentObject private var host: BluetoothDeviceHost

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 16) {
                header
                lcd
                controls
                Spacer(minLength: 0)
                pairingLabel
            }
            .padding(20)
            .frame(minWidth: 340, idealWidth: 360)

            console
                .frame(minWidth: 320)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(host.isAdvertising ? Color.green : Color.red)
                .frame(width: 10, height: 10)
                .shadow(color: host.isAdvertising ? .green : .red, radius: 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(host.advertisedName).font(.system(.title3, design: .monospaced).bold())
                Text(host.isAdvertising ? "Advertising · \(host.connectedPhones) phone\(host.connectedPhones == 1 ? "" : "s") connected" : host.radio)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
        }
    }

    private var lcd: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(host.status.door.label.uppercased())
                Spacer()
                Text("\(host.status.position)%")
            }
            .font(.system(size: 28, weight: .bold, design: .monospaced))

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Color.green.opacity(0.15))
                    Rectangle()
                        .fill(Color.green.opacity(0.8))
                        .frame(width: proxy.size.width * CGFloat(host.status.position) / 100)
                }
            }
            .frame(height: 8)

            HStack {
                Label(host.status.pairingMode ? "PAIRING \(host.pairingSecondsLeft)s" : "PAIRING OFF", systemImage: "link")
                    .opacity(host.status.pairingMode ? 1 : 0.45)
                Spacer()
                Label("\(host.status.pairedClients) PHONES", systemImage: "iphone")
                Spacer()
                Label(host.status.obstructed ? "BLOCKED" : "SENSOR OK", systemImage: host.status.obstructed ? "exclamationmark.triangle.fill" : "checkmark.circle")
                    .foregroundStyle(host.status.obstructed ? Color.orange : Color.green)
            }
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
        }
        .foregroundStyle(Color.green)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.black))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.gray.opacity(0.4)))
    }

    private var controls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Button { host.pressPairButton() } label: {
                    Label("PAIR", systemImage: "dot.radiowaves.left.and.right").frame(maxWidth: .infinity)
                }
                .tint(.blue)
                Button { host.pressWallButton() } label: {
                    Label("Wall button", systemImage: "button.programmable").frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Toggle(isOn: Binding(get: { host.status.obstructed }, set: { host.setObstruction($0) })) {
                Text("Safety beam blocked")
            }
            .toggleStyle(.switch)
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack {
                Button("Forget all phones", role: .destructive) { host.forgetAllPhones() }
                Spacer()
            }
        }
    }

    private var pairingLabel: some View {
        HStack(alignment: .top, spacing: 14) {
            if let qr = QRCode.image(for: host.core.pairingURL) {
                Image(nsImage: qr)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 150, height: 150)
                    // Wide quiet zone: phone cameras read screen-displayed codes far more reliably.
                    .padding(14)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("SETUP CODE").font(.caption2.bold()).foregroundStyle(.secondary)
                Text("\(host.core.setupCode.prefix(3)) \(host.core.setupCode.suffix(3))")
                    .font(.system(size: 26, weight: .bold, design: .monospaced))
                    .textSelection(.enabled)
                Text("Scan with the iPhone Camera, or enter the code in GarageLink.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Copy pairing link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(host.core.pairingURL, forType: .string)
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
    }

    private var console: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Device log").font(.headline)
                Spacer()
                Text(host.core.deviceID.hex).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            }
            .padding(12)
            Divider()
            List(host.log) { line in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(line.date, format: .dateTime.hour().minute().second())
                        .foregroundStyle(.secondary)
                    Text(line.text)
                        .foregroundStyle(color(for: line.kind))
                }
                .font(.system(size: 12, design: .monospaced))
            }
            .listStyle(.plain)
        }
    }

    private func color(for kind: BluetoothDeviceHost.LogLine.Kind) -> Color {
        switch kind {
        case .device: return .primary
        case .radio: return .blue
        case .error: return .red
        }
    }
}

enum QRCode {
    static func image(for string: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage,
              let cgImage = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}
