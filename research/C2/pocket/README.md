# Pocket TTS on onnxruntime (#459, stream C2)

The app's own code can render Kyutai Pocket TTS (voice alba) with the onnxruntime it already links for Supertonic. Nothing in the app calls it yet; the target is `SessionKitPocket` in `Packages/SessionKit`.

| File | What it is |
| --- | --- |
| `fetch_weights.sh` | Downloads the int8 networks, tokenizer, bundle description and alba's voice state into `../models/pocket/` (git-ignored) at pinned revisions, checking each sha256. Run it once before the weights tests. `POCKET_TTS_MODEL_DIR` moves the folder. |
| `wer.py` | Whisper word error for rendered clips, scored like `../intelligibility.py`. |
| `make_golden.py` | Regenerates the tokenizer and text-splitting fixture the Swift tests compare against. |

**License.** Both sources are CC BY 4.0 (the ONNX export `KevinAHM/pocket-tts-onnx` at 58a6d00, and the ungated `kyutai/pocket-tts-without-voice-cloning` at 575d143 for alba's voice state), so MLX isn't needed. The app must carry an attribution line before it ships this voice. `LICENSE.txt` is fetched next to the weights.

**Run the tests** (from `Packages/SessionKit`; the word-error test needs a Python with `faster-whisper` and `jiwer`, named in `POCKET_TTS_PYTHON` or at `research/C2/.venv`; if faster-whisper fails to open files, `pip install 'av<16'`):

```sh
../../research/C2/pocket/fetch_weights.sh
POCKET_TTS_PYTHON=/path/to/python swift test --filter PocketRendererTests
```

Without the weights the tests that need them say "skipped: weights not fetched".
