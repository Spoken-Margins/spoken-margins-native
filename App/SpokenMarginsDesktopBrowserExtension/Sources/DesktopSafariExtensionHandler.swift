import Foundation
import SafariServices

final class DesktopSafariExtensionHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        let result = NSExtensionItem()
        result.userInfo = [SFExtensionMessageKey: handle(context)]
        context.completeRequest(returningItems: [result], completionHandler: nil)
    }

    private func handle(_ context: NSExtensionContext) -> [String: Any] {
        guard let item = context.inputItems.first as? NSExtensionItem,
              let message = item.userInfo?[SFExtensionMessageKey] as? [String: Any],
              message["action"] as? String == "storeBrowserTextPayload",
              let payload = message["payload"] as? [String: Any],
              payload["schemaVersion"] as? String == "browser-text-handoff.v1",
              let source = payload["source"] as? [String: Any],
              let sourceString = source["url"] as? String,
              let sourceURL = URL(string: sourceString),
              ["http", "https"].contains(sourceURL.scheme?.lowercased() ?? ""),
              let text = payload["text"] as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.count <= 100_000,
              let data = try? JSONSerialization.data(withJSONObject: payload),
              data.count <= 1_000_000 else {
            return ["ok": false, "error": "Invalid or oversized webpage capture."]
        }
        guard let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.spokenmargins.desktop") else {
            return ["ok": false, "error": "Desktop App Group is unavailable. Check signing and Safari extension setup."]
        }
        do {
            let directory = group.appendingPathComponent("BrowserTextHandoffs", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let id = UUID().uuidString
            try data.write(to: directory.appendingPathComponent(id).appendingPathExtension("json"), options: [.atomic])
            return ["ok": true, "openURL": "spokenmargins-desktop://browser-text?payloadId=\(id)"]
        } catch {
            return ["ok": false, "error": "Could not save webpage capture: \(error.localizedDescription)"]
        }
    }
}
