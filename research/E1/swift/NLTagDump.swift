// Records Apple NaturalLanguage tags for every string the portable baseline reads, so the
// cloud-built portable rules can be re-scored with the real on-device tagger (E1 M2, Mac).
//
//   python3 scripts/export_nl_inputs.py > /tmp/e1-inputs.json
//   swift swift/NLTagDump.swift /tmp/e1-inputs.json > /tmp/e1-nl-tags.json
//   python scripts/run_eval.py --nl-tags /tmp/e1-nl-tags.json
//
// Output: { text: [[token, lemma|null, lexicalClass, nameType|null, utf16Offset], ...] }
import Foundation
import NaturalLanguage

let inputs = try JSONDecoder().decode([String].self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
let names: [NLTag: String] = [.personalName: "person", .placeName: "place", .organizationName: "org"]
var table: [String: [[Any]]] = [:]
for text in inputs {
    let tagger = NLTagger(tagSchemes: [.lexicalClass, .lemma, .nameType])
    tagger.string = text
    var rows: [[Any]] = []
    tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .lexicalClass,
                         options: [.omitWhitespace, .joinNames]) { tag, range in
        let lemma = tagger.tag(at: range.lowerBound, unit: .word, scheme: .lemma).0?.rawValue
        let name = tagger.tag(at: range.lowerBound, unit: .word, scheme: .nameType).0.flatMap { names[$0] }
        let offset = text.utf16.distance(from: text.startIndex, to: range.lowerBound)
        rows.append([String(text[range]), lemma ?? NSNull(), tag?.rawValue ?? "OtherWord", name ?? NSNull(), offset])
        return true
    }
    table[text] = rows
}
let out = try JSONSerialization.data(withJSONObject: table, options: [.sortedKeys])
FileHandle.standardOutput.write(out)
