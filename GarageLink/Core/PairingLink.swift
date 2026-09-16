import CoreNFC
import Foundation
import GarageProtocol

/// `garagelink://pair?d=<device id hex>&c=<6-digit setup code>` — printed on the device as a QR
/// code and written to its NFC sticker. Opens the app from the Camera, from iOS background tag
/// reading, or from the in-app NFC scanner.
struct PairingLink: Equatable {
    let deviceID: ShortID
    let setupCode: String

    init?(url: URL) {
        guard url.scheme == "garagelink", url.host == "pair",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let idHex = items.first(where: { $0.name == "d" })?.value,
              let deviceID = ShortID(hex: idHex),
              let code = items.first(where: { $0.name == "c" })?.value,
              GarageCrypto.isValidSetupCode(code)
        else { return nil }
        self.deviceID = deviceID
        self.setupCode = code
    }

    var advertisedName: String { GarageGATT.advertisedName(for: deviceID) }
}

/// "Tap to pair": reads the pairing link from the device's NFC tag.
@MainActor
final class NFCPairingReader: NSObject {
    enum ReaderError: LocalizedError {
        case unavailable
        case noPairingLink

        var errorDescription: String? {
            switch self {
            case .unavailable: return "NFC isn't available on this device."
            case .noPairingLink: return "That tag doesn't contain a GarageLink pairing link."
            }
        }
    }

    static var isAvailable: Bool { NFCNDEFReaderSession.readingAvailable }

    private var session: NFCNDEFReaderSession?
    private var continuation: CheckedContinuation<PairingLink, Error>?

    func read() async throws -> PairingLink {
        guard Self.isAvailable else { throw ReaderError.unavailable }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let session = NFCNDEFReaderSession(delegate: self, queue: .main, invalidateAfterFirstRead: false)
            session.alertMessage = "Hold your iPhone near the GarageLink tag on the device."
            session.begin()
            self.session = session
        }
    }

    private func finish(_ result: Result<PairingLink, Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }
}

extension NFCPairingReader: @preconcurrency NFCNDEFReaderSessionDelegate {
    func readerSession(_ session: NFCNDEFReaderSession, didDetectNDEFs messages: [NFCNDEFMessage]) {
        let link = messages
            .flatMap(\.records)
            .compactMap { $0.wellKnownTypeURIPayload() }
            .lazy
            .compactMap(PairingLink.init(url:))
            .first
        if let link {
            session.alertMessage = "Found \(link.advertisedName)"
            session.invalidate()
            finish(.success(link))
        } else {
            session.invalidate(errorMessage: ReaderError.noPairingLink.localizedDescription)
            finish(.failure(ReaderError.noPairingLink))
        }
    }

    func readerSession(_ session: NFCNDEFReaderSession, didInvalidateWithError error: Error) {
        self.session = nil
        let code = (error as? NFCReaderError)?.code
        if code == .readerSessionInvalidationErrorUserCanceled {
            finish(.failure(CancellationError()))
        } else if code != .readerSessionInvalidationErrorFirstNDEFTagRead {
            finish(.failure(error))
        }
    }
}
