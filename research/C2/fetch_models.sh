#!/bin/sh
# Download every candidate model into models/ (git-ignored). Idempotent.
# Sources: GitHub release assets and Hugging Face. Checksums are printed so a
# run on another machine can be compared with the one in the README.
set -e
cd "$(dirname "$0")"
mkdir -p models/piper
PY=.venv/bin/python
get() { [ -s "$2" ] || curl -fsSL -o "$2" "$1"; }
get https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/sherpa-onnx-supertonic-3-tts-int8-2026-05-11.tar.bz2 models/st3.tar.bz2
[ -d models/sherpa-onnx-supertonic-3-tts-int8-2026-05-11 ] || (cd models && tar xjf st3.tar.bz2)
for f in kokoro-v1.0.int8.onnx kokoro-v1.0.onnx voices-v1.0.bin; do
  get https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/$f models/$f
done
for r in kitten-tts-nano-0.8-int8 kitten-tts-nano-0.8-fp32; do
  $PY -c "from huggingface_hub import snapshot_download as s; s('KittenML/$r', local_dir='models/$r')" >/dev/null
done
for v in en/en_US/ljspeech/high/en_US-ljspeech-high en/en_US/lessac/medium/en_US-lessac-medium; do
  for e in onnx onnx.json; do get https://huggingface.co/rhasspy/piper-voices/resolve/main/$v.$e models/piper/$(basename $v).$e; done
done
# Pocket TTS downloads its own weights (ungated, no voice cloning) on first load.
shasum -a 256 models/st3.tar.bz2 models/*.onnx models/*/*.onnx 2>/dev/null || sha256sum models/st3.tar.bz2 models/*.onnx models/*/*.onnx
