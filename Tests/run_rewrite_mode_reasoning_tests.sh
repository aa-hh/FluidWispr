#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
task_developer_dir="${DEVELOPER_DIR:-$(xcode-select -p)}"
test -d "$task_developer_dir/Platforms/MacOSX.platform"
export DEVELOPER_DIR="$task_developer_dir"
task_test_dir=$(mktemp -d /tmp/fluidvoice-rewrite-reasoning.XXXXXX)
trap 'rm -rf "$task_test_dir"' EXIT
# Exercise the exact production lookup and provider-key methods.
{ echo 'extension RewriteModeService {'
  sed -n '/^    private func reasoningConfig(forModel model: String, providerID: String)/,/^    }$/p' Sources/Fluid/Services/RewriteModeService.swift
  sed -n '/^    private func providerKey(for providerID: String) -> String {/,/^    }$/p' Sources/Fluid/Services/RewriteModeService.swift
  echo '}'
} | sed 's/^    private func/    func/' > "$task_test_dir/Lookup.swift"
xcrun swiftc -parse-as-library "$task_test_dir/Lookup.swift" Tests/RewriteModeReasoningTests.swift -o "$task_test_dir/tests"
"$task_test_dir/tests"
