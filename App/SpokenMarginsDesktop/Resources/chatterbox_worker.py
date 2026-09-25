"""Local, line-delimited Chatterbox worker. No model downloads or network calls."""

import argparse
import inspect
import json
import os
import sys
import threading
import time
from pathlib import Path

PROTOCOL_OUTPUT = sys.stdout
sys.stdout = sys.stderr
PARENT_PID = os.getppid()


def exit_if_parent_disappears():
    while True:
        time.sleep(1)
        if os.getppid() != PARENT_PID:
            os._exit(1)


def reply(**values):
    PROTOCOL_OUTPUT.write(json.dumps(values) + "\n")
    PROTOCOL_OUTPUT.flush()


def protocol_tqdm(iterable, total=None, **_kwargs):
    """Report bounded progress updates to the parent without a noisy tqdm log."""
    if total is None:
        try:
            total = len(iterable)
        except TypeError:
            total = None

    last_bucket = -1
    for index, item in enumerate(iterable, start=1):
        if total:
            fraction = min(1.0, index / total)
            bucket = int(fraction * 20)
            if bucket > last_bucket or index == total:
                reply(progress=fraction, phase="Generating speech")
                last_bucket = bucket
        yield item


def main():
    threading.Thread(target=exit_if_parent_disappears, daemon=True).start()
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", required=True)
    parser.add_argument("--variant", choices=("nano", "turbo"), required=True)
    args = parser.parse_args()
    model_dir = Path(args.model)
    model_name = "Nano" if args.variant == "nano" else "Turbo"
    required = (
        "t3_nano_v1.safetensors" if args.variant == "nano" else "t3_turbo_v1.safetensors",
        "s3gen_meanflow.safetensors",
        "ve.safetensors",
        "conds.pt",
    )
    for name in required:
        if not (model_dir / name).is_file():
            reply(error=f"Chatterbox {model_name} model is missing {name}")
            return 2

    if not (model_dir / "tokenizer.json").is_file() and not (
        (model_dir / "vocab.json").is_file() and (model_dir / "merges.txt").is_file()
    ):
        reply(error=f"Chatterbox {model_name} tokenizer files are missing")
        return 2

    try:
        import torch
        import soundfile as sf
        from chatterbox.tts_turbo import ChatterboxTurboTTS
        from chatterbox.models.t3 import t3 as t3_module

        # The Turbo starter that ships with some local installs predates Nano
        # support. Fail before loading large weights instead of surfacing a
        # Python TypeError after the user waits for model startup.
        if args.variant == "nano" and "nano" not in inspect.signature(ChatterboxTurboTTS.from_local).parameters:
            reply(error="This Chatterbox Python runtime does not support Nano. Choose a Nano-compatible local runtime and model folder.")
            return 2

        t3_module.tqdm = protocol_tqdm

        device = "mps" if torch.backends.mps.is_available() else "cpu"
        if args.variant == "nano":
            model = ChatterboxTurboTTS.from_local(model_dir, device=device, nano=True)
        else:
            try:
                model = ChatterboxTurboTTS.from_local(model_dir, device=device, nano=False)
            except TypeError as error:
                if "nano" not in str(error):
                    raise
                model = ChatterboxTurboTTS.from_local(model_dir, device=device)
        reply(ready=True, device=device)
        for line in sys.stdin:
            try:
                request = json.loads(line)
                text = request["text"]
                output = Path(request["output"])
                if not text or len(text) > 240:
                    raise ValueError("Chatterbox input must contain 1–240 characters")
                output.parent.mkdir(parents=True, exist_ok=True)
                reply(progress=0.0, phase="Generating speech")
                with torch.inference_mode():
                    waveform = model.generate(text)
                reply(progress=None, phase="Finalizing audio")
                samples = waveform.squeeze().detach().cpu().numpy()
                sf.write(str(output), samples, model.sr, format="WAV", subtype="PCM_16")
                reply(ok=True, output=str(output))
                del waveform
                del samples
            except Exception as error:
                reply(error=str(error))
    except Exception as error:
        reply(error=f"Chatterbox {model_name} could not start: {error}")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
