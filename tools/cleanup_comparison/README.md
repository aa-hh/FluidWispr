# Cleanup model comparison

Runs the same recorded dictations through each cleanup model and writes one report: speed per model, then the cleaned text side by side under shuffled letters so you can tick every version that reads well without knowing which model wrote it. Each tick is one point. This is the test behind AA-207. A model becomes the default only if it is no slower at the slowest 10% and wins on most samples.

Run it on your Mac. The speed numbers only mean something from the network and hardware you dictate on.

## One-time setup

For the local models, install Ollama and pull the candidates:
`ollama pull qwen3:4b-instruct`, `ollama pull qwen3:1.7b`, `ollama pull llama3.2:3b`, `ollama pull gemma3:4b`.
A model you have not pulled is skipped.

## Record the samples

Dictate the 30 sample prompts with FluidWispr into any text field, one dictation each, in one sitting. The app keeps each dictation's raw Parakeet text in its history whether or not cleanup ran. Then export a backup (Settings, Backup & Restore, Export).

## Run

```
python3 tools/cleanup_comparison/compare_cleanup_models.py --backup ~/Downloads/FluidVoice_Backup_<date>.json --last 30
```

`--last 30` takes the 30 newest dictations, so record the samples last, or raise the number and ignore extras. A Debug build (the dev build or the Test build download) can transcribe a folder of recordings instead with `--audio DIR`, after `defaults write com.FluidApp.app.debug LocalAPIEnabled -bool true` and a restart of the app. Release builds leave the local API out (AA-188).

The script asks for `CEREBRAS_API_KEY` and `GROQ_API_KEY` without showing what you type (or reads them from the environment). Leave one blank to skip that provider. It writes to `~/FluidWispr-comparisons/<timestamp>/`:

- `report.html`, the page to open and judge
- `transcripts.json`, the Parakeet text, so a rerun can use `--transcripts` instead
- `results.json`, every attempt with its time and text

Useful flags: `--runs 5` (attempts per sample), `--only "Cerebras gpt-oss-120b"` (repeatable), `--candidates FILE` (a different model list; the default is `candidates.json` here).

The system prompt is read from `SettingsStore.swift`, so the test always uses the prompt the app ships. A custom prompt set in the app is not used.

## Tests

`python3 tools/cleanup_comparison/test_compare_cleanup_models.py`
