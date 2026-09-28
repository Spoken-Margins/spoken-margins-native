#!/bin/sh
# Render the blind-listening set (4 threads, WAVs kept) and the 1-thread timing pass.
set -e
cd "$(dirname "$0")"
PY=.venv/bin/python
SET="supertonic supertonic:steps=4 kokoro:quant=fp32 kokoro:quant=int8 kitten:size=nano-fp32 kitten:size=nano piper:voice=en_US-ljspeech-high piper:voice=en_US-lessac-medium pocket"
for e in $SET; do $PY bench.py "$e" --threads 4 --repeats 2; done
for e in $SET; do $PY bench.py "$e" --threads 1 --repeats 1 --no-audio; done
