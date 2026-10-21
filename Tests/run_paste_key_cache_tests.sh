#!/bin/sh
set -eu

task_developer_dir="${DEVELOPER_DIR:-$(xcode-select -p)}"
case "$task_developer_dir" in
    */Xcode*.app/Contents/Developer) ;;
    *) echo "Set DEVELOPER_DIR to an installed full Xcode before running tests." >&2; exit 1 ;;
esac
export DEVELOPER_DIR="$task_developer_dir"
task_repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
task_test_dir=$(mktemp -d /tmp/fluidvoice-paste-cache-tests.XXXXXX)
# The regular paste key tests run in FluidDictationIntegrationTests (PasteTests).
# This script keeps only the live keyboard layout check, which switches input sources.
if [ "${1:-}" = "--live" ]; then
    xcrun swiftc -O \
        "$task_repo_dir/Sources/Fluid/Services/PasteKeyCodeCache.swift" \
        "$task_repo_dir/Sources/Fluid/Services/PasteKeyCodeResolver.swift" \
        "$task_repo_dir/Tests/PasteKeyCodeCacheLiveLayoutTests.swift" \
        -o "$task_test_dir/paste-live-tests"
    "$task_test_dir/paste-live-tests"
fi
