#!/usr/bin/env python3
"""Run the #4673 trial prompts against local assistant CLIs and save raw answers.

Maintainer tool: it needs the Claude Code CLI and the Codex CLI signed in on this Mac.
Raw answers go to artifacts/episode-link-trial/raw/ (git-ignored); nothing is posted.

    scripts/episode-link-trial/run_assistants.py [--only claude-search-plain] [--jobs 4]
"""
import argparse
import concurrent.futures
import json
import os
import pathlib
import subprocess
import time

ROOT = pathlib.Path(__file__).resolve().parents[2]
HERE = pathlib.Path(__file__).resolve().parent
OUT = ROOT / "artifacts" / "episode-link-trial"
CODEX = os.environ.get("CODEX_BIN", "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex")
CLAUDE = os.environ.get("CLAUDE_BIN", str(pathlib.Path.home() / ".local/bin/claude"))

# condition -> (assistant, web search on, wording)
CONDITIONS = {
    "claude-search-plain": ("claude", True, "plain"),
    "claude-search-verify": ("claude", True, "verify"),
    "claude-memory-plain": ("claude", False, "plain"),
    "codex-search-plain": ("codex", True, "plain"),
    "codex-search-verify": ("codex", True, "verify"),
    "codex-memory-plain": ("codex", False, "plain"),
}


def run_claude(prompt: str, search: bool, workdir: pathlib.Path) -> tuple[str, dict]:
    tools = "WebSearch,WebFetch" if search else ""
    cmd = [CLAUDE, "-p", "-", "--output-format", "json", "--model", "sonnet",
           "--permission-mode", "dontAsk", "--tools", tools, "--allowedTools", tools, "--strict-mcp-config",
           "--setting-sources", "project", "--no-session-persistence", "--max-budget-usd", "3"]
    proc = subprocess.run(cmd, input=prompt, capture_output=True, text=True, cwd=workdir, timeout=900)
    try:
        payload = json.loads(proc.stdout)
    except json.JSONDecodeError:
        return proc.stdout + proc.stderr, {"error": "non-json", "returncode": proc.returncode}
    return payload.get("result", ""), {"cost_usd": payload.get("total_cost_usd"), "returncode": proc.returncode,
                                        "is_error": payload.get("is_error")}


def run_codex(prompt: str, search: bool, workdir: pathlib.Path, answer: pathlib.Path) -> tuple[str, dict]:
    cmd = [CODEX, "exec", "--skip-git-repo-check", "-s", "read-only", "-C", str(workdir),
           "-c", f'web_search="{"live" if search else "disabled"}"',
           "-c", 'model_reasoning_effort="medium"', "-o", str(answer), "-"]
    proc = subprocess.run(cmd, input=prompt, capture_output=True, text=True, timeout=900)
    text = answer.read_text() if answer.exists() else ""
    tokens = None
    lines = proc.stdout.splitlines() + proc.stderr.splitlines()
    for i, line in enumerate(lines):
        if line.strip() == "tokens used" and i + 1 < len(lines):
            tokens = lines[i + 1].strip()
    searches = sum(1 for line in lines if line.startswith("web search:"))
    return text, {"tokens": tokens, "returncode": proc.returncode, "web_search_lines": searches}


def one(condition: str, persona: dict, wordings: dict) -> dict:
    assistant, search, wording = CONDITIONS[condition]
    prompt = wordings[wording].format(**persona)
    raw = OUT / "raw"
    raw.mkdir(parents=True, exist_ok=True)
    stem = f"{condition}-{persona['id']}"
    answer = raw / f"{stem}.txt"
    if answer.exists() and answer.read_text().strip():
        return {"condition": condition, "persona": persona["id"], "skipped": True}
    workdir = OUT / "empty-cwd"
    workdir.mkdir(parents=True, exist_ok=True)
    started = time.time()
    if assistant == "claude":
        text, meta = run_claude(prompt, search, workdir)
        answer.write_text(text)
    else:
        text, meta = run_codex(prompt, search, workdir, answer)
    meta.update({"condition": condition, "persona": persona["id"], "seconds": round(time.time() - started)})
    (raw / f"{stem}.meta.json").write_text(json.dumps(meta, indent=2))
    (raw / f"{stem}.prompt.txt").write_text(prompt)
    return meta


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--only", action="append", choices=sorted(CONDITIONS))
    parser.add_argument("--persona", action="append")
    parser.add_argument("--jobs", type=int, default=4)
    args = parser.parse_args()
    spec = json.loads((HERE / "personas.json").read_text())
    personas = [p for p in spec["personas"] if not args.persona or p["id"] in args.persona]
    jobs = [(c, p) for c in (args.only or CONDITIONS) for p in personas]
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as pool:
        for result in pool.map(lambda job: one(job[0], job[1], spec["wordings"]), jobs):
            print(json.dumps(result), flush=True)


if __name__ == "__main__":
    main()
