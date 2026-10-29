import Foundation
import SessionKit

public struct FixtureAIProvider: AIProviderClient {
    public let providerType = "fixture"
    public let model = "gate1-fixture"

    public init() {}
}
