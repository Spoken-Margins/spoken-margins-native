import Foundation
import SessionKit

public struct OpenAICompatibleProvider: AIProviderClient {
    public let providerType: String
    public let model: String
    public let baseURL: URL
    public let apiKeyReference: String?

    public init(baseURL: URL, model: String, apiKeyReference: String?) {
        self.providerType = "openai_compatible"
        self.baseURL = baseURL
        self.model = model
        self.apiKeyReference = apiKeyReference
    }
}

public struct FixtureAIProvider: AIProviderClient {
    public let providerType = "fixture"
    public let model = "gate1-fixture"

    public init() {}
}
