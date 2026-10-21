#!/usr/bin/env python3
"""Compare dictation cleanup models on the same recorded samples.

Usage:
  python3 tools/cleanup_comparison/compare_cleanup_models.py --audio DIR
  python3 tools/cleanup_comparison/compare_cleanup_models.py --transcripts FILE

--audio sends each recording to FluidWispr's local API for a Parakeet
transcript (the app must be running with LocalAPIEnabled set) and caches the
transcripts next to the report, so later runs can use --transcripts instead.

Every candidate in candidates.json gets every transcript --runs times, with
the same system prompt the app sends, built from SettingsStore.swift. The
report lists speed per model and the cleaned text side by side under letters
that are shuffled per sample, so the writing can be judged without names.

Standard library only. API keys come from the environment, or a hidden prompt.
"""

import argparse
import getpass
import html
import json
import math
import os
import random
import re
import statistics
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path


HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
SETTINGS_STORE = REPO / "Sources/Fluid/Persistence/SettingsStore.swift"
AUDIO_EXTENSIONS = {".m4a", ".wav", ".mp3", ".aac", ".caf", ".aiff", ".flac"}
LOCAL_API = "http://127.0.0.1:47733"
# Matches LatencyBudget.defaultCloudMilliseconds, the app's default cloud budget; used only for reporting.
CLOUD_BUDGET_MS = 400


def swift_string_function(source, name):
    """Return the multi-line string literal a `static func name() -> String` returns."""
    pattern = re.compile(
        r"static func " + re.escape(name) + r"\(\) -> String \{\s*\"\"\"\n(.*?)\n\s*\"\"\"",
        re.DOTALL,
    )
    match = pattern.search(source)
    if not match:
        raise ValueError(f"{name} not found in SettingsStore.swift")
    lines = match.group(1).split("\n")
    indent = min(len(line) - len(line.lstrip()) for line in lines if line.strip())
    return "\n".join(line[indent:] for line in lines)


def default_dictation_prompt(source):
    """Mirror SettingsStore.combineBasePrompt(for: .dictate, with: body)."""
    base = swift_string_function(source, "baseDictationPromptText").strip()
    body = swift_string_function(source, "defaultDictationPromptBodyText").strip()
    return f"{base}\n\n{body}"


def transcript_user_content(transcript):
    """Mirror DictationPromptRequest: JSONEncoder output, which escapes slashes."""
    return json.dumps({"transcript": transcript}, ensure_ascii=False, separators=(",", ":")).replace("/", "\\/")


def percentile(values, fraction):
    if not values:
        return None
    ordered = sorted(values)
    index = max(0, math.ceil(fraction * len(ordered)) - 1)
    return ordered[index]


def post_json(url, payload, headers=None, timeout=30):
    request = urllib.request.Request(
        url,
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json", **(headers or {})},
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return json.loads(response.read().decode("utf-8"))


def transcribe_audio(audio_dir, api=LOCAL_API):
    files = sorted(p for p in Path(audio_dir).iterdir() if p.suffix.lower() in AUDIO_EXTENSIONS)
    if not files:
        raise SystemExit(f"No audio files in {audio_dir}")
    samples = []
    for path in files:
        try:
            result = post_json(f"{api}/v1/transcribe", {"path": str(path.resolve())}, timeout=120)
        except urllib.error.HTTPError as error:
            raise SystemExit(f"FluidWispr could not transcribe {path.name}: {error.read().decode('utf-8', 'replace')}")
        except urllib.error.URLError as error:
            raise SystemExit(
                f"FluidWispr's local API did not answer ({error}). Open the app, run\n"
                "  defaults write com.FluidApp.app.debug LocalAPIEnabled -bool true\n"
                "then quit and reopen FluidWispr."
            )
        samples.append({"id": path.name, "transcript": result["text"].strip()})
        print(f"  transcribed {path.name}: {len(result['text'].split())} words", file=sys.stderr)
    return samples


def api_key(candidate, cache):
    env = candidate.get("key_env")
    if not env:
        return ""
    if env not in cache:
        cache[env] = os.environ.get(env) or getpass.getpass(f"{env} (blank skips {candidate['name']}): ").strip()
    return cache[env]


def run_candidate(candidate, prompt, samples, runs, key, send=post_json):
    body = {
        "model": candidate["model"],
        "temperature": candidate.get("temperature", 0.2),
        "stream": False,
        **candidate.get("extra", {}),
    }
    headers = {"Authorization": f"Bearer {key}"} if key else {}
    url = candidate["base_url"].rstrip("/") + "/chat/completions"
    results = []
    # One untimed call first: the app keeps the local model loaded (AA-177),
    # so a cold load is not part of what a dictation waits for.
    if samples:
        try:
            send(url, {**body, "messages": [{"role": "system", "content": prompt},
                                            {"role": "user", "content": transcript_user_content(samples[0]["transcript"])}]}, headers, 120)
        except Exception:
            pass
    for sample in samples:
        messages = [
            {"role": "system", "content": prompt},
            {"role": "user", "content": transcript_user_content(sample["transcript"])},
        ]
        attempts = []
        for _ in range(runs):
            started = time.perf_counter()
            try:
                response = send(url, {**body, "messages": messages}, headers, 30)
                text = response["choices"][0]["message"]["content"] or ""
                attempts.append({"ms": round((time.perf_counter() - started) * 1000), "text": text.strip()})
            except Exception as error:
                attempts.append({"ms": None, "error": f"{type(error).__name__}: {error}"})
        results.append({"id": sample["id"], "attempts": attempts})
    return results


def summarize(candidate_results):
    timings = [a["ms"] for sample in candidate_results for a in sample["attempts"] if a["ms"] is not None]
    total = sum(len(sample["attempts"]) for sample in candidate_results)
    return {
        "median_ms": round(statistics.median(timings)) if timings else None,
        "p90_ms": percentile(timings, 0.9),
        "within_budget": (sum(1 for t in timings if t <= CLOUD_BUDGET_MS) / total) if total else 0,
        "errors": total - len(timings),
        "attempts": total,
    }


def first_text(sample_result):
    for attempt in sample_result["attempts"]:
        if "text" in attempt:
            return attempt["text"]
    return None


def blind_order(model_names, sample_id, seed):
    order = list(model_names)
    random.Random(f"{seed}:{sample_id}").shuffle(order)
    return order


def render_report(samples, results, seed, runs):
    names = list(results)
    speed_rows = []
    for name in sorted(names, key=lambda n: results[n]["summary"]["p90_ms"] or math.inf):
        s = results[name]["summary"]
        fmt = lambda v: "n/a" if v is None else f"{v:,} ms"
        speed_rows.append(
            f"<tr><td>{html.escape(name)}</td><td>{fmt(s['median_ms'])}</td><td>{fmt(s['p90_ms'])}</td>"
            f"<td>{s['within_budget']:.0%}</td><td>{s['errors']} of {s['attempts']}</td></tr>"
        )

    sample_blocks, key_rows, key_map = [], [], {}
    for sample in samples:
        order = [n for n in blind_order(names, sample["id"], seed) if results[n].get("by_id", {}).get(sample["id"])]
        letters = [chr(ord("A") + i) for i in range(len(order))]
        key_map[sample["id"]] = dict(zip(letters, order))
        options = []
        for letter, name in zip(letters, order):
            text = first_text(results[name]["by_id"][sample["id"]])
            shown = html.escape(text) if text is not None else "<em>no answer</em>"
            options.append(
                f'<label class="option"><input type="radio" name="{html.escape(sample["id"])}" value="{letter}">'
                f"<b>{letter}</b><p>{shown}</p></label>"
            )
        key_rows.append(
            f"<tr><td>{html.escape(sample['id'])}</td>"
            + "".join(f"<td>{l}: {html.escape(n)}</td>" for l, n in zip(letters, order))
            + "</tr>"
        )
        sample_blocks.append(
            f'<section><h3>{html.escape(sample["id"])}</h3><p class="raw">{html.escape(sample["transcript"])}</p>'
            + "".join(options)
            + "</section>"
        )

    key_json = json.dumps(key_map)
    return f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Cleanup model comparison</title>
<style>
:root {{ --bg: #fff; --fg: #1a1a1a; --muted: #666; --line: #ddd; --pick: #e8f0ff; }}
@media (prefers-color-scheme: dark) {{ :root {{ --bg: #161616; --fg: #eee; --muted: #999; --line: #333; --pick: #1e2a40; }} }}
body {{ background: var(--bg); color: var(--fg); font: 15px/1.5 -apple-system, system-ui, sans-serif; max-width: 860px; margin: 0 auto; padding: 24px 16px; }}
table {{ border-collapse: collapse; width: 100%; }} td, th {{ border-bottom: 1px solid var(--line); padding: 6px 8px; text-align: left; }}
.raw {{ color: var(--muted); }} .option {{ display: block; border: 1px solid var(--line); border-radius: 8px; padding: 8px 12px; margin: 8px 0; cursor: pointer; }}
.option:has(input:checked) {{ background: var(--pick); }} .option p {{ margin: 4px 0 0; white-space: pre-wrap; }}
section {{ margin: 28px 0; }} #tally {{ position: sticky; bottom: 0; background: var(--bg); border-top: 1px solid var(--line); padding: 10px 0; }}
</style></head><body>
<h1>Cleanup model comparison</h1>
<p>{len(samples)} samples, {runs} runs each. Speed is the full answer time from this Mac. "Within {CLOUD_BUDGET_MS} ms" counts the share of attempts that would beat the cloud budget.</p>
<h2>Speed</h2>
<table><tr><th>Model</th><th>Typical</th><th>Slowest 10%</th><th>Within {CLOUD_BUDGET_MS} ms</th><th>Failed</th></tr>{''.join(speed_rows)}</table>
<h2>Writing, blind</h2>
<p>Grey text is the raw transcript. Pick the best version of each. Letters are shuffled per sample.</p>
{''.join(sample_blocks)}
<div id="tally"><button id="reveal">Reveal which model is which</button> <span id="score"></span></div>
<details id="key" hidden><summary>Key</summary><table>{''.join(key_rows)}</table></details>
<script>
const key = {key_json};
document.getElementById("reveal").onclick = () => {{
  const wins = {{}};
  document.querySelectorAll("input:checked").forEach(i => {{ const m = key[i.name][i.value]; wins[m] = (wins[m] || 0) + 1; }});
  document.getElementById("score").textContent = Object.entries(wins).sort((a, b) => b[1] - a[1]).map(([m, n]) => m + ": " + n).join(" · ") || "No picks yet.";
  const k = document.getElementById("key"); k.hidden = false; k.open = true;
}};
</script>
</body></html>
"""


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--audio", help="folder of recordings to transcribe through FluidWispr")
    source.add_argument("--transcripts", help="JSON list of {id, transcript} from an earlier run")
    parser.add_argument("--candidates", default=str(HERE / "candidates.json"))
    parser.add_argument("--only", action="append", help="run only the named candidate (repeatable)")
    parser.add_argument("--runs", type=int, default=5)
    parser.add_argument("--out", default=str(Path.home() / "FluidWispr-comparisons"))
    parser.add_argument("--seed", default=time.strftime("%Y%m%d%H%M%S"))
    args = parser.parse_args(argv)

    out = Path(args.out) / args.seed
    out.mkdir(parents=True, exist_ok=True)
    if args.audio:
        samples = transcribe_audio(args.audio)
        (out / "transcripts.json").write_text(json.dumps(samples, indent=2, ensure_ascii=False))
    else:
        samples = json.loads(Path(args.transcripts).read_text())
    if not samples:
        raise SystemExit("No samples to compare.")

    prompt = default_dictation_prompt(SETTINGS_STORE.read_text())
    candidates = json.loads(Path(args.candidates).read_text())
    if args.only:
        unknown = set(args.only) - {c["name"] for c in candidates}
        if unknown:
            raise SystemExit(f"Not in {args.candidates}: {', '.join(sorted(unknown))}")
        candidates = [c for c in candidates if c["name"] in args.only]

    results, keys = {}, {}
    for candidate in candidates:
        key = api_key(candidate, keys)
        if candidate.get("key_env") and not key:
            print(f"skipped {candidate['name']}: no {candidate['key_env']}", file=sys.stderr)
            continue
        print(f"running {candidate['name']}", file=sys.stderr)
        per_sample = run_candidate(candidate, prompt, samples, args.runs, key)
        summary = summarize(per_sample)
        if summary["errors"] == summary["attempts"]:
            print(f"skipped {candidate['name']}: every attempt failed, first error: "
                  f"{per_sample[0]['attempts'][0].get('error')}", file=sys.stderr)
            continue
        results[candidate["name"]] = {"summary": summary, "by_id": {r["id"]: r for r in per_sample}}

    if not results:
        raise SystemExit("No candidate answered; nothing to report.")
    (out / "results.json").write_text(json.dumps(results, indent=2, ensure_ascii=False))
    report = out / "report.html"
    report.write_text(render_report(samples, results, args.seed, args.runs))
    print(report)


if __name__ == "__main__":
    main()
