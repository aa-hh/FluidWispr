# Cleanup model comparison

Runs the same recorded dictations through each cleanup model and writes one report: speed per model, then the cleaned text side by side under shuffled letters so you can pick the best version without knowing which model wrote it. This is the test behind AA-207. A model becomes the default only if it is no slower at the slowest 10% and wins on most samples.

Run it on your Mac. The speed numbers only mean something from the network and hardware you dictate on.

## One-time setup

1. Turn on FluidWispr's local API, which the script uses to transcribe recordings with Parakeet:
   `defaults write com.FluidApp.app.debug LocalAPIEnabled -bool true` for the test build from GitHub (`FluidVoice Debug.app`), or `com.FluidApp.app` for a release build, then quit and reopen it.
2. For the local models, install Ollama and pull the candidates:
   `ollama pull qwen3:4b-instruct`, `ollama pull llama3.2:3b`, `ollama pull gemma3:4b`.
   A model you have not pulled is skipped.

## Run

```
python3 tools/cleanup_comparison/compare_cleanup_models.py --audio ~/Desktop/samples
```

The script asks for `CEREBRAS_API_KEY` and `GROQ_API_KEY` without showing what you type (or reads them from the environment). Leave one blank to skip that provider. It writes to `~/FluidWispr-comparisons/<timestamp>/`:

- `report.html`, the page to open and judge
- `transcripts.json`, the Parakeet text, so a rerun can skip transcription with `--transcripts`
- `results.json`, every attempt with its time and text

Useful flags: `--runs 5` (attempts per sample), `--only "Cerebras gpt-oss-120b"` (repeatable), `--candidates FILE` (a different model list; the default is `candidates.json` here).

The system prompt is read from `SettingsStore.swift`, so the test always uses the prompt the app ships. A custom prompt set in the app is not used.

## Tests

`python3 tools/cleanup_comparison/test_compare_cleanup_models.py`
