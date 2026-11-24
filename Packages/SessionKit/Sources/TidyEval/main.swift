// Runs spoken Margins through Apple's on-device model with the tidy prompt and scores them against the app's guard (#4339).
// Mac only, with Apple Intelligence on. The app never links it. See fixtures/margin-tidy/README.md.
import Foundation
import SessionKit

#if canImport(FoundationModels)
import FoundationModels

struct EvalCase: Decodable {
    let id: String
    let kind: String
    let before: String
    let after: String
    let transcript: String
}

struct CaseFile: Decodable { let cases: [EvalCase] }

/// A prompt under test. `instructions` and `prompt` use {before}, {after} and {note}. `contextCharacters` is the passage
/// kept on each side. `app` runs the shipped `MarginTidyPrompt` instead of the text here.
struct Variant: Decodable {
    let id: String
    var app: Bool? = nil
    var instructions: String? = nil
    var prompt: String? = nil
    var contextCharacters: Int? = nil
    var contextBefore: Int? = nil
    var contextAfter: Int? = nil
    var permissive: Bool? = nil
    var maximumResponseTokens: Int? = nil
}

struct VariantFile: Decodable { let variants: [Variant] }

struct Row: Encodable {
    let variant: String
    let caseId: String
    let kind: String
    let transcript: String
    let fillerOnly: String
    let reply: String?
    let error: String?
    let guardRejection: String?
    let promptTokens: Int?
    let contextSize: Int
    let seconds: Double
    let contextBefore: Int
    let contextAfter: Int
}

func fill(_ template: String, before: String, after: String, note: String) -> String {
    template.replacingOccurrences(of: "{before}", with: before)
        .replacingOccurrences(of: "{after}", with: after)
        .replacingOccurrences(of: "{note}", with: note)
}

@available(macOS 26.4, *)
func describe(_ error: Error) -> String {
    if let error = error as? LanguageModelSession.GenerationError {
        switch error {
        case .exceededContextWindowSize: return "exceededContextWindowSize"
        case .guardrailViolation: return "guardrailViolation"
        case .refusal: return "refusal"
        case .unsupportedLanguageOrLocale: return "unsupportedLanguageOrLocale"
        default: return "generationError: \(error)"
        }
    }
    return String(describing: error)
}

func value(_ flag: String, _ args: [String]) -> String? {
    guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
    return args[index + 1]
}

@main
struct TidyEval {
    static func main() async throws {
        guard #available(macOS 26.4, *) else {
            print("tidy-eval needs macOS 26.4 or later.")
            exit(1)
        }
        try await Runner.main()
    }
}

@available(macOS 26.4, *)
enum Runner {
    static func main() async throws {
        let args = CommandLine.arguments
        guard let casesPath = value("--cases", args), let variantsPath = value("--variants", args), let outPath = value("--out", args) else {
            FileHandle.standardError.write("usage: tidy-eval --cases eval-cases.json --variants variants.json --out results.jsonl [--only v1,v2] [--case id1,id2]\n".data(using: .utf8)!)
            exit(2)
        }
        let cases = try JSONDecoder().decode(CaseFile.self, from: Data(contentsOf: URL(fileURLWithPath: casesPath))).cases
        var variants = try JSONDecoder().decode(VariantFile.self, from: Data(contentsOf: URL(fileURLWithPath: variantsPath))).variants
        if let only = value("--only", args)?.split(separator: ",").map(String.init) { variants = variants.filter { only.contains($0.id) } }
        let caseFilter = value("--case", args)?.split(separator: ",").map(String.init)

        let model = SystemLanguageModel.default
        guard case .available = model.availability else {
            FileHandle.standardError.write("Apple's on-device model is unavailable: \(model.availability)\n".data(using: .utf8)!)
            exit(1)
        }
        FileManager.default.createFile(atPath: outPath, contents: nil)
        let out = try FileHandle(forWritingTo: URL(fileURLWithPath: outPath))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

        for variant in variants {
            for item in cases where caseFilter?.contains(item.id) ?? true {
                let row = await run(variant: variant, item: item, model: model)
                out.write(try encoder.encode(row))
                out.write("\n".data(using: .utf8)!)
                let status = row.error ?? row.guardRejection.map { "guard: \($0)" } ?? "ok"
                print("\(variant.id)\t\(item.id)\t\(String(format: "%.1f", row.seconds))s\t\(row.promptTokens ?? -1)tok\t\(status)")
            }
        }
        try out.close()
    }

    static func run(variant: Variant, item: EvalCase, model: SystemLanguageModel) async -> Row {
        let instructions: String
        let prompt: String
        let context: (before: String, after: String)
        let permissive: Bool
        let maximumTokens: Int
        if variant.app == true {
            let request = MarginTidyPrompt.request(transcript: item.transcript, before: item.before, after: item.after)
            instructions = request.instructions
            prompt = request.prompt
            context = (request.context.before, request.context.after)
            permissive = true
            maximumTokens = request.maximumResponseTokens
        } else {
            let side = variant.contextCharacters ?? 500
            context = (
                BoundedAnchorContext.select(before: item.before, after: "", maximumCharactersPerSide: variant.contextBefore ?? side).before,
                BoundedAnchorContext.select(before: "", after: item.after, maximumCharactersPerSide: variant.contextAfter ?? side).after
            )
            instructions = fill(variant.instructions ?? "", before: context.before, after: context.after, note: item.transcript)
            prompt = fill(variant.prompt ?? "", before: context.before, after: context.after, note: item.transcript)
            permissive = variant.permissive ?? false
            maximumTokens = variant.maximumResponseTokens ?? 1_500
        }
        let tokens: Int?
        do {
            tokens = try await model.tokenCount(for: Instructions(instructions)) + model.tokenCount(for: Prompt(prompt))
        } catch {
            tokens = nil
        }
        let session = LanguageModelSession(
            model: SystemLanguageModel(useCase: .general, guardrails: permissive ? .permissiveContentTransformations : .default),
            instructions: instructions
        )
        let start = Date()
        var reply: String?
        var failure: String?
        do {
            let response = try await session.respond(
                to: prompt,
                options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: maximumTokens)
            )
            reply = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            failure = describe(error)
        }
        let seconds = Date().timeIntervalSince(start)
        let passage = [context.before, context.after].filter { !$0.isEmpty }.joined(separator: " ")
        let rejection = reply.flatMap { MarginTidyGuard.rejection(original: item.transcript, proposal: $0, passage: passage) }
        return Row(
            variant: variant.id, caseId: item.id, kind: item.kind, transcript: item.transcript,
            fillerOnly: MarginTidy.fillerOnly(item.transcript), reply: reply, error: failure,
            guardRejection: rejection.map { String(describing: $0) }, promptTokens: tokens, contextSize: model.contextSize,
            seconds: seconds, contextBefore: context.before.count, contextAfter: context.after.count
        )
    }
}
#else
@main
struct TidyEval {
    static func main() {
        print("tidy-eval needs Apple's FoundationModels (macOS 26.4 or later with Apple Intelligence).")
    }
}
#endif
