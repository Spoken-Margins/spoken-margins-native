#!/bin/sh
# Download the Pocket TTS ONNX weights and the alba voice into research/C2/models/pocket/
# (git-ignored), pinned to Hugging Face revisions and checked against their sha256 (#459).
# Idempotent. Weights never go into git. Override the folder with POCKET_TTS_MODEL_DIR.
#
# Sources, both CC BY 4.0 (the app must carry an attribution line when it ships the voice):
#   KevinAHM/pocket-tts-onnx, revision 58a6d00: ONNX export of Kyutai's Pocket TTS.
#   kyutai/pocket-tts-without-voice-cloning, revision 575d143: the ungated weights; alba's
#   voice state (the model's cache after it has "heard" the voice) comes from here.
# int8 for the three big networks, as the export's own default; the text embedder stays fp32.
set -eu
dest=${POCKET_TTS_MODEL_DIR:-"$(cd "$(dirname "$0")/.." && pwd)/models/pocket"}
mkdir -p "$dest"

onnx_base=https://huggingface.co/KevinAHM/pocket-tts-onnx/resolve/58a6d00cf13d239b6748cb0769f35c580a8f606c
voice_base=https://huggingface.co/kyutai/pocket-tts-without-voice-cloning/resolve/575d14372df89a4534bcb989870a34e77544b09f

sha256_of() {
    if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1
    else sha256sum "$1" | cut -d' ' -f1; fi
}

fetch() {
    name=$1 url=$2 sha=$3
    out="$dest/$name"
    if [ ! -s "$out" ]; then
        curl -fL --retry 3 -o "$out.part" "$url"
        mv "$out.part" "$out"
    fi
    actual=$(sha256_of "$out")
    if [ "$actual" != "$sha" ]; then
        echo "error: $out has sha256 $actual, expected $sha" >&2
        rm -f "$out"
        exit 1
    fi
    echo "ok  $out"
}

fetch bundle.json "$onnx_base/onnx/english_2026-04/bundle.json" bab643150f437f37df080a710520ff39ed9ebd9a339f8ebdc739f7eddfc28b3f
fetch tokenizer.model "$onnx_base/onnx/english_2026-04/tokenizer.model" d461765ae179566678c93091c5fa6f2984c31bbe990bf1aa62d92c64d91bc3f6
fetch text_conditioner.onnx "$onnx_base/onnx/english_2026-04/text_conditioner.onnx" 4ecee995fb69f85c7a7493d11f7b5ee15d9950facc7ab3f5c9c49ef1e03847bb
fetch flow_lm_main_int8.onnx "$onnx_base/onnx/english_2026-04/flow_lm_main_int8.onnx" f9bd8106b79a0192c1c43399ab938fb24900a95c1c599870d75a884e99000116
fetch flow_lm_flow_int8.onnx "$onnx_base/onnx/english_2026-04/flow_lm_flow_int8.onnx" 3dd781ee5abee9e195320bf0106bebd6372a852b3b36352524ee78b40554635d
fetch mimi_decoder_int8.onnx "$onnx_base/onnx/english_2026-04/mimi_decoder_int8.onnx" 3630450a3297a101792a6ac66619ebc70ab916b265e6220c2afaef8b1673f925
fetch alba.safetensors "$voice_base/languages/english_2026-04/embeddings/alba.safetensors" 69c32db63ca56843d994f81f343f62e0bf2d73f7e4c9bc73e44bb1110b1d8845
fetch LICENSE.txt "$onnx_base/onnx/LICENSE" fe7b4ce83b8381cc5b216bbb4af73c570688d1b819c73bbaed8ca401f4677cd6
