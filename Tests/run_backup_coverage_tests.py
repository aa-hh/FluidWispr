#!/usr/bin/env python3
"""Checks the backup table against SettingsStore.Keys and SettingsBackupPayload.

A new setting must either get a SettingsBackupPayload field (same name as the
Keys entry, or mapped in BACKED_UP_AS) or an entry in NOT_BACKED_UP saying why.
Every payload field needs exactly one entry in the table in
SettingsStore+Backup.swift, and an entry that names a payload key path must
use that field's name. Reads source only; needs no Xcode.
"""

from pathlib import Path
import re
import sys

# Keys whose backup field has a different name.
BACKED_UP_AS = {
    "pressToTalkShortcuts": "primaryDictationShortcuts",
    "dictationPromptProfiles": "promptProfiles (AppBackupDocument)",
    "appPromptBindings": "appPromptBindings (AppBackupDocument)",
}

NOT_BACKED_UP = {
    # Secrets and machine-bound verification stay on this Mac.
    "providerAPIKeys": "secret",
    "providerAPIKeyIdentifiers": "keychain references",
    "verifiedProviderFingerprints": "derived from the API key on this Mac",
    "verifiedPrivateAIModelFingerprints": "derived from local model files",
    "externalCoreMLArtifactsDirectories": "local folder paths",
    # One-time migrations and onboarding progress.
    "privateAIContextDefaultMigratedTo4K": "migration marker",
    "microphoneSelectionMigrationVersion": "migration marker",
    "reliablePasteMigrationV1": "migration marker",
    "overlayBottomOffsetMigratedTo50": "migration marker",
    "secondaryPromptShortcutRemoved": "migration marker",
    "legacySecondaryPromptShortcutRetired": "migration marker",
    "enableTranscriptionSounds": "legacy key, migrated to transcriptionStartSound",
    "playgroundUsed": "onboarding progress",
    "onboardingCompleted": "onboarding progress",
    "onboardingGeneration": "onboarding progress",
    "manualOnboardingResetRequested": "onboarding progress",
    "manualOnboardingResetRequestedAt": "onboarding progress",
    "onboardingCurrentStep": "onboarding progress",
    "onboardingAISkipped": "onboarding progress",
    "onboardingPlaygroundValidated": "onboarding progress",
    "onboardingPlaygroundSkipped": "onboarding progress",
    "onboardingSelectedLanguageID": "onboarding progress",
    "privateAIInterestCaptured": "analytics marker",
    "historyNextRecordNumber": "record counter, kept with history",
    "customDictionaryNextNumber": "record counter, kept with the dictionary",
    # Caches and legacy settings superseded by backed-up ones.
    "availableAIModels": "model list cache",
    "availableModelsByProvider": "model list cache",
    "enableAIProcessing": "legacy, replaced by prompt selection",
    "selectedAIModel": "legacy, replaced by selectedModelByProvider",
    "selectedTranscriptionProvider": "legacy, replaced by selectedSpeechModel",
    "whisperModelSize": "legacy, replaced by selectedSpeechModel",
    "customDictationPrompt": "legacy, replaced by prompt profiles",
    "sendCustomPromptOnly": "legacy, replaced by prompt profiles",
    "selectedWritePromptID": "legacy, replaced by selectedEditPromptID",
    "selectedRewritePromptID": "legacy, replaced by selectedEditPromptID",
    "legacyPrimaryDictationShortcuts": "legacy, migrated to pressToTalkShortcuts or holdToTalkShortcuts",
    "legacyHotkeyShortcut": "legacy, migrated to pressToTalkShortcuts or holdToTalkShortcuts",
    "legacyHotkeyMode": "legacy, migrated to pressToTalkEnabled and holdToTalkEnabled",
    "legacyPressAndHoldMode": "legacy, migrated to pressToTalkEnabled and holdToTalkEnabled",
    "fluidServeOtherAgentsShared": "device-local",
    "intendedDockVisibility": "device-local",
    "defaultWritePromptOverride": "legacy, replaced by defaultEditPromptOverride",
    "defaultRewritePromptOverride": "legacy, replaced by defaultEditPromptOverride",
    "privateAIIdleUnloadMinutes": "stored inside privateAIIdleUnload",
    "privateAIIdleUnloadTestSeconds": "debug override",
    "notchPresentationMode": "legacy overlay mode",
    # System state owned by macOS.
    "showInDock": "mirrors hideFromDockAndAppSwitcher",
}


def main() -> None:
    repo = Path(__file__).resolve().parent.parent
    settings = (repo / "Sources/Fluid/Persistence/SettingsStore.swift").read_text()
    backup = (repo / "Sources/Fluid/Persistence/BackupService.swift").read_text()
    table = (repo / "Sources/Fluid/Persistence/SettingsStore+Backup.swift").read_text()

    keys_start = settings.index("enum Keys")
    keys_body = settings[keys_start:settings.index("\n    }\n", keys_start)]
    keys = re.findall(r'static let (\w+)\s*=\s*"', keys_body)

    payload_start = backup.index("struct SettingsBackupPayload")
    payload = backup[payload_start:backup.index("\n}\n", payload_start)]
    fields = set(re.findall(r"^\s*(?:let|var) (\w+)", payload, re.M))

    names = re.findall(r'\.(?:value|keepIfAbsent|orDefault|custom)\(\s*"(\w+)"', table)
    named_paths = re.findall(r'\.(?:value|keepIfAbsent|orDefault)\(\s*"(\w+)",\s*\\\.(\w+)', table)

    missing = [k for k in keys if k not in fields and k not in BACKED_UP_AS and k not in NOT_BACKED_UP]
    stale = sorted(set(NOT_BACKED_UP) - set(keys)) + sorted(set(BACKED_UP_AS) - set(keys))
    both = sorted(k for k in NOT_BACKED_UP if k in fields)

    errors = []
    if missing:
        errors.append("Not backed up and not listed in NOT_BACKED_UP: " + ", ".join(missing))
    if stale:
        errors.append("Listed here but no longer in SettingsStore.Keys: " + ", ".join(stale))
    if both:
        errors.append("Backed up but also listed in NOT_BACKED_UP: " + ", ".join(both))
    no_entry = sorted(fields - set(names))
    if no_entry:
        errors.append("Payload fields with no entry in the backup table: " + ", ".join(no_entry))
    unknown = sorted(set(names) - fields)
    if unknown:
        errors.append("Backup table entries with no payload field: " + ", ".join(unknown))
    repeated = sorted({n for n in names if names.count(n) > 1})
    if repeated:
        errors.append("Backup table entries listed twice: " + ", ".join(repeated))
    mismatched = [f"{n} reads \\.{p}" for n, p in named_paths if n != p]
    if mismatched:
        errors.append("Backup table entries whose key path is another field: " + ", ".join(mismatched))
    if errors:
        sys.exit("\n".join(errors))
    if not keys or not fields or not names:
        sys.exit("Could not read SettingsStore.Keys, SettingsBackupPayload or the backup table")


if __name__ == "__main__":
    main()
