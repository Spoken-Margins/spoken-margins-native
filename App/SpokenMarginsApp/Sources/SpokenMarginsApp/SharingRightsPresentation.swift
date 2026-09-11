import Foundation
import SessionKit
import SessionKitSharing

enum SharingRightsPresentation {
    static let rightsNotice = "Source material may be protected by copyright. Share only material you have permission or another lawful basis to share. Attribution, a short excerpt, or a private recipient does not by itself grant permission."
    static let recipientCopiesNotice = "Recipients can keep or forward this file. Deleting your local copy cannot revoke their copies. Review the source excerpts, matching evidence, and voice or generated content before sharing."

    /// Values come from the successfully verified archive, never mutable drafts.
    static func disclosures(for package: VerifiedSpokenMarginsPackage) -> [String] {
        let manifest = package.manifest
        let item = manifest.item
        var lines = [rightsNotice, recipientCopiesNotice,
            "Private sharing notes, unrelated sessions, credentials, device paths, and raw diagnostics are not included.",
            "Source audio and full generated podcast transcripts are not included.",
            "Sender identity is labeled but not cryptographically verified."]
        let attribution: [(String, String?)] = [
            ("Title", item.title), ("Author", item.author), ("Publisher", item.publisher),
            ("Show", item.showTitle), ("Published", item.publishedAt),
            ("Source reference", item.canonicalURL), ("Original reference", item.originalURL),
            ("Episode reference", item.episodeGUID), ("Media reference", item.enclosureURL),
            ("Feed reference", item.source?.canonicalURL), ("Feed title", item.source?.title),
            ("Feed publisher", item.source?.publisher), ("Language", item.languageCode)
        ]
        lines += attribution.compactMap { label, value in
            guard let value, !value.isEmpty else { return nil }
            return "\(label): \(value)"
        }
        if let duration = item.durationMs { lines.append("Source duration: \(duration / 1_000) seconds.") }
        if item.exactEditionSHA256 != nil || item.normalizedContentSHA256 != nil {
            lines.append("Source-content fingerprints are included to identify the supplied edition.")
        }
        switch manifest.itemTransport.kind {
        case .reference: lines.append("The recipient acquires the referenced source separately.")
        case .recipientSupplied: lines.append("The source is omitted; the recipient must supply a matching item.")
        case .embeddedText:
            for text in package.embeddedTextItems {
                lines.append("Complete source text included: \(text.text.count) characters. This is the full listened-to text, not just the anchor excerpts.")
            }
        }
        for (index, record) in package.commentaryLayers.flatMap(\.interjections).enumerated() {
            let anchor = record.anchor
            lines.append("Margin \(index + 1) includes its creation time and reviewed representation provenance.")
            for (label, value) in [("Context before", anchor.prefix), ("Exact excerpt", anchor.exactText),
                                   ("Context after", anchor.suffix), ("Chapter", anchor.chapterTitle)] {
                if let value, !value.isEmpty { lines.append("Margin \(index + 1) — \(label): \(value)") }
            }
            for representation in record.representations {
                switch representation.kind {
                case .originalAudioAndText: lines.append("Margin \(index + 1): sender-approved original voice and text.")
                case .cleanedAudioAndText: lines.append("Margin \(index + 1): sender-approved edited voice and text; the private original is unchanged.")
                case .textOnly: lines.append("Margin \(index + 1): sender-approved text only; no recording.")
                case .summaryText: lines.append("Margin \(index + 1): sender-approved summary text, a derivative of the original note.")
                case .summaryAudioAndText: lines.append("Margin \(index + 1): sender-approved summary voice and text, a derivative of the original note.")
                case .ttsAudioAndText: lines.append("Margin \(index + 1): synthetic voice reading sender-approved text; not an authentic recording of the speaker.")
                }
            }
        }
        lines.append("Matching evidence: \(manifest.assets.filter { $0.role == SpokenMarginsAssetRole.acousticSignature }.count) acoustic signatures and \(package.editionFingerprintSpines.count) edition maps. These are matching evidence, not playable source audio or proof of permission.")
        lines.append("Text-derived matching evidence: \(package.transcriptPhraseSketches.count) phrase sketches. Acoustic opt-out is separate from this text-derived evidence.")
        for proposal in package.listeningMapProposals {
            for scene in proposal.scenes {
                lines.append("Listening Map — \(scene.title ?? "Scene"): \(scene.summaryText ?? "No summary") (\(scene.summaryProvenance?.rawValue.replacingOccurrences(of: "_", with: " ") ?? "provenance unavailable")).")
            }
        }
        let generatedVoiceCount = manifest.assets.filter {
            [SpokenMarginsAssetRole.summaryVoice, SpokenMarginsAssetRole.ttsVoice].contains($0.role)
        }.count
        if generatedVoiceCount > 0 { lines.append("Generated or summary voice assets included: \(generatedVoiceCount).") }
        return lines
    }
}
