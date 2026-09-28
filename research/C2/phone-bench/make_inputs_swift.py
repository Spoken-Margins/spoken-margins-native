"""Regenerate VoiceBench/VoiceBenchInputs.swift from inputs.json (run from this folder)."""
import json

d = json.load(open("inputs.json"))
kit, sup = d["kitten"], d["supertonic"]
order = ["p1-narrative", "p2-scientific", "p3-conversational"]
sw = lambda s: json.dumps(s, ensure_ascii=False)
L = ["// Generated from research/C2/phone-bench/inputs.json by make_inputs_swift.py. Don't edit by hand.",
     "import Foundation", "",
     "struct VoiceBenchInputs: Sendable {",
     "    struct KittenChunk: Sendable { let text: String; let inputIds: [Int64]; let style: [Float] }",
     "    struct Kitten: Sendable { let speed: Float; let passages: [String: [KittenChunk]] }",
     "    struct Supertonic: Sendable { let passages: [String: [String]] }",
     "    let passageOrder: [String]", "    let kitten: Kitten", "    let supertonic: Supertonic", "",
     "    static let bundled = VoiceBenchInputs(",
     f"        passageOrder: {sw(order)},",
     f"        kitten: Kitten(speed: {kit['speed']}, passages: ["]
for pid in order:
    L.append(f"            {sw(pid)}: [")
    for c in kit["passages"][pid]:
        L.append(f"                KittenChunk(text: {sw(c['text'])}, inputIds: {c['input_ids']}, style: {c['style']}),")
    L.append("            ],")
L += ["        ]),", "        supertonic: Supertonic(passages: ["]
L += [f"            {sw(pid)}: {sw(sup['passages'][pid])}," for pid in order]
L += ["        ])", "    )", "}"]
open("VoiceBench/VoiceBenchInputs.swift", "w").write("\n".join(L) + "\n")
