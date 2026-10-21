"""Regression fixtures; no app, network, or API keys needed."""

import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from compare_cleanup_models import (
    SETTINGS_STORE,
    blind_order,
    default_dictation_prompt,
    main,
    percentile,
    render_report,
    run_candidate,
    summarize,
    transcript_user_content,
)


class PromptTests(unittest.TestCase):
    # Fails if SettingsStore's prompt functions are renamed or reshaped, which
    # would leave the comparison testing a prompt the app no longer sends.
    def test_prompt_matches_app_default(self):
        prompt = default_dictation_prompt(SETTINGS_STORE.read_text())
        self.assertTrue(prompt.startswith("Make the smallest edits needed"))
        self.assertIn("\n\nRead the value of the JSON transcript field only.", prompt)
        self.assertTrue(prompt.endswith("JSON wrapper."))
        self.assertNotIn('"""', prompt)

    # Fails if the user message stops matching Swift's JSONEncoder output.
    def test_transcript_encoding_matches_swift(self):
        self.assertEqual(transcript_user_content('say "hi" and/or café'), '{"transcript":"say \\"hi\\" and\\/or café"}')


class RunTests(unittest.TestCase):
    def test_timings_errors_and_payload(self):
        sent = []

        def fake_send(url, payload, headers, timeout):
            sent.append((url, payload, headers))
            if len(sent) == 3:
                raise TimeoutError("slow")
            return {"choices": [{"message": {"content": " Cleaned. "}}]}

        candidate = {"name": "x", "base_url": "https://example.test/v1/", "model": "m", "extra": {"reasoning_effort": "low"}}
        results = run_candidate(candidate, "PROMPT", [{"id": "01", "transcript": "um hi"}], 3, "k", send=fake_send)
        self.assertEqual(len(sent), 4)
        url, payload, headers = sent[1]
        self.assertEqual(url, "https://example.test/v1/chat/completions")
        self.assertEqual(payload["reasoning_effort"], "low")
        self.assertIs(payload["stream"], False)
        self.assertEqual(payload["messages"][0], {"role": "system", "content": "PROMPT"})
        self.assertEqual(headers, {"Authorization": "Bearer k"})
        attempts = results[0]["attempts"]
        self.assertEqual(attempts[0]["text"], "Cleaned.")
        self.assertIn("TimeoutError", attempts[1]["error"])
        summary = summarize(results)
        self.assertEqual((summary["errors"], summary["attempts"]), (1, 3))

    # Fails if a mistyped --only name runs nothing instead of saying which name is wrong.
    def test_unknown_only_name_exits_with_its_name(self):
        with tempfile.TemporaryDirectory() as folder:
            transcripts = Path(folder) / "t.json"
            transcripts.write_text("[]")
            with self.assertRaises(SystemExit) as raised:
                main(["--transcripts", str(transcripts), "--only", "Nope", "--out", folder])
        self.assertIn("Nope", str(raised.exception))

    def test_percentile_takes_upper_value(self):
        self.assertEqual(percentile([100, 200, 300, 400, 5000], 0.9), 5000)
        self.assertEqual(percentile(list(range(1, 11)), 0.9), 9)
        self.assertIsNone(percentile([], 0.9))


class ReportTests(unittest.TestCase):
    def test_names_appear_only_in_speed_table_and_key(self):
        samples = [{"id": f"{i:02}", "transcript": f"raw {i}"} for i in range(1, 6)]
        results = {}
        for name in ("Alpha model", "Beta model"):
            per_sample = [{"id": s["id"], "attempts": [{"ms": 120, "text": "same text"}]} for s in samples]
            results[name] = {"summary": summarize(per_sample), "by_id": {r["id"]: r for r in per_sample}}
        report = render_report(samples, results, "seed", 1)
        writing = report.split("<h2>Writing, blind</h2>")[1].split('<div id="tally">')[0]
        self.assertNotIn("Alpha", writing)
        key = json.loads(report.split("const key = ")[1].split(";\n")[0])
        self.assertEqual(set(key["01"].values()), {"Alpha model", "Beta model"})
        self.assertEqual(blind_order(["a", "b", "c"], "01", "s"), blind_order(["a", "b", "c"], "01", "s"))


if __name__ == "__main__":
    unittest.main()
