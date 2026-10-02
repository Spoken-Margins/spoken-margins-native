import Foundation
import SafariServices

final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    #if SPOKEN_MARGINS_LEGACY
    private static let appGroupIdentifier = "group.com.spokenmargins.native.legacy"
    private static let appURLScheme = "spokenmargins-legacy"
    #else
    private static let appGroupIdentifier = "group.com.spokenmargins.native"
    private static let appURLScheme = "spokenmargins"
    #endif
    private static let payloadDirectoryName = "BrowserTextHandoffs"

    func beginRequest(with context: NSExtensionContext) {
        let response = NSExtensionItem()
        response.userInfo = [SFExtensionMessageKey: responseMessage(for: context)]
        context.completeRequest(returningItems: [response], completionHandler: nil)
    }

    private func responseMessage(for context: NSExtensionContext) -> [String: Any] {
        guard let item = context.inputItems.first as? NSExtensionItem,
              let message = item.userInfo?[SFExtensionMessageKey] as? [String: Any] else {
            return errorResponse("Unsupported browser text extension message.")
        }
        if message["action"] as? String == "storeRemotePDFHandoff" {
            return storeRemotePDFHandoff(urlString: message["url"] as? String)
        }
        guard message["action"] as? String == "storeBrowserTextPayload",
              var payload = message["payload"] as? [String: Any] else {
            return errorResponse("Unsupported browser text extension message.")
        }

        let payloadID = sanitizedPayloadID(payload["id"] as? String)
        payload["id"] = payloadID
        payload["schemaVersion"] = payload["schemaVersion"] as? String ?? "browser-text-handoff.v1"
        payload["createdAt"] = payload["createdAt"] as? String ?? ISO8601DateFormatter().string(from: Date())

        do {
            guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupIdentifier) else {
                return errorResponse("App Group container is unavailable.")
            }
            let directoryURL = containerURL.appendingPathComponent(Self.payloadDirectoryName, isDirectory: true)
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let payloadURL = directoryURL.appendingPathComponent(payloadID).appendingPathExtension("json")
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: payloadURL, options: [.atomic])
            return [
                "ok": true,
                "payloadId": payloadID,
                "openURL": "\(Self.appURLScheme)://browser-text?payloadId=\(payloadID)"
            ]
        } catch {
            return errorResponse("Unable to store browser text payload: \(error.localizedDescription)")
        }
    }

    /// A PDF tab is handed to the app's remote-PDF import, the same route the
    /// share sheet uses, instead of capturing the PDF viewer's page text (#658).
    private func storeRemotePDFHandoff(urlString: String?) -> [String: Any] {
        guard let urlString,
              let url = URL(string: urlString),
              url.scheme?.lowercased() == "https",
              url.host != nil else {
            return errorResponse("Only PDFs on an https:// address can be sent to Spoken Margins.")
        }
        let handoff = SourceLinkHandoff(
            id: "source-link-\(UUID().uuidString)",
            inputURL: url.absoluteString,
            sourceSurface: SourceLinkHandoff.safariExtensionPDFSurface,
            startSession: true
        )
        do {
            let payloadID = try SourceLinkHandoffStore.appGroup().save(handoff)
            return [
                "ok": true,
                "payloadId": payloadID,
                "openURL": SourceLinkHandoffURL.url(forPayloadID: payloadID).absoluteString
            ]
        } catch {
            return errorResponse("Unable to send this PDF to Spoken Margins: \(error.localizedDescription)")
        }
    }

    private func sanitizedPayloadID(_ rawID: String?) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        let cleaned = rawID?
            .unicodeScalars
            .filter { allowed.contains($0) }
            .map(String.init)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return cleaned.isEmpty ? UUID().uuidString : cleaned
    }

    private func errorResponse(_ message: String) -> [String: Any] {
        [
            "ok": false,
            "error": message
        ]
    }
}
