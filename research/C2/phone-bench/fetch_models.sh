#!/bin/sh
# Download the two KittenTTS nano 0.8 models VoiceBench bundles into VoiceBench/Models/
# (git-ignored), pinned to Hugging Face revisions and checked against their sha256.
# Idempotent. Run once before building VoiceBench; the build fails if a model is missing.
set -eu
cd "$(dirname "$0")"
mkdir -p VoiceBench/Models

fetch() {
    name=$1 url=$2 sha=$3
    out="VoiceBench/Models/$name.onnx"
    if [ ! -s "$out" ]; then
        curl -fL --retry 3 -o "$out.part" "$url"
        mv "$out.part" "$out"
    fi
    actual=$(shasum -a 256 "$out" | cut -d' ' -f1)
    if [ "$actual" != "$sha" ]; then
        echo "error: $out has sha256 $actual, expected $sha" >&2
        rm -f "$out"
        exit 1
    fi
    echo "ok  $out"
}

fetch kitten-nano-0.8-fp32 \
    https://huggingface.co/KittenML/kitten-tts-nano-0.8-fp32/resolve/7a1db645b1f3ab9420761d87428e042b9cec3f26/kitten_tts_nano_v0_8.onnx \
    320564d2615f235de972ca27a7f39551c94185cfa24ca85b07a29084135f1e5e
fetch kitten-nano-0.8-int8 \
    https://huggingface.co/KittenML/kitten-tts-nano-0.8-int8/resolve/84781d74e29ee25217551556398b42f80593a813/kitten_tts_nano_v0_8.onnx \
    f7b0afcbee92870b32b8e0276d855b954dc25470c9f051b376ac7eee537c76fc
