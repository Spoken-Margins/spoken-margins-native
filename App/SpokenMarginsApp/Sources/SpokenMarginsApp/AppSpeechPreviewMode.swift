import Foundation

enum AppSpeechPreviewMode {
    case spokenContent
    case appVoice(voiceIdentifier: String?, rate: Float)
    case assistiveTechnology
}
