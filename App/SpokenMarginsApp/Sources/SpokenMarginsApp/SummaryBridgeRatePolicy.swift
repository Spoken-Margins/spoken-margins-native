import Foundation

enum SummaryBridgeRatePolicy {
    // Keep pronunciation independent of listening speed. Version generated assets
    // so summaries synthesized with the former accelerated policy are not reused.
    static let synthesisSpeed: Float = 1
    static let systemSynthesisRate: Float = 0.5
    static let cacheVersion = "natural-rate-v2"
    static func transportRate(_ listeningRate: Double) -> Float { Float(listeningRate) }
}
