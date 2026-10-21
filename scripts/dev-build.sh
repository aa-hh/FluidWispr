#!/bin/bash

# Build the latest main for development and launch it, as fast as a warm
# incremental Debug build allows. The build happens in its own git worktree
# with its own DerivedData, so your checkout is never touched and the second
# build only recompiles the files the new commits changed.
#
# Usage:
#   scripts/dev-build.sh                  build origin/main and launch it
#   scripts/dev-build.sh --ref <branch>   build origin/<branch> or a commit instead
#   scripts/dev-build.sh --no-launch      build only
#   scripts/dev-build.sh --if-changed     skip the build when that commit is already built
#   scripts/dev-build.sh --remote [host]  build on another Mac over ssh, copy the app here, launch it
#   scripts/dev-build.sh --adhoc          sign ad hoc even when an Apple Development certificate exists
#
# Environment:
#   FLUIDWISPR_DEV_HOME     worktree, DerivedData and timing log (default ~/Library/Developer/FluidWispr-dev)
#   FLUIDWISPR_REPO         the FluidWispr clone to fetch into (default: the clone holding this script)
#   FLUIDWISPR_REMOTE_REPO  the FluidWispr clone on the other Mac (default $HOME/FluidWispr there)
#
# The default host for --remote comes from this clone's own git config, so it
# never lands in a commit:  git config --local fluidwispr.remoteHost <host>
#
# Signing: with an Apple Development certificate the app is signed with it, so
# macOS keeps microphone and Accessibility permission across rebuilds. Without
# one the build is signed ad hoc, and macOS asks for those permissions again
# after each build.

set -euo pipefail

DEV_HOME="${FLUIDWISPR_DEV_HOME:-${HOME}/Library/Developer/FluidWispr-dev}"
SRC_DIR="${DEV_HOME}/src"
DERIVED_DATA="${DEV_HOME}/DerivedData"
APP_NAME="FluidVoice Debug.app"
DEBUG_BUNDLE_ID="com.FluidApp.app.debug"
RELEASE_BUNDLE_ID="com.FluidApp.app"

ref="main"
launch=1
if_changed=0
force_adhoc=0
remote_host=""
use_remote=0
print_app=0

usage() {
    sed -n '3,25p' "$0" | sed 's/^# \{0,1\}//'
}

die() {
    echo "dev-build: $*" >&2
    exit 1
}

while [ $# -gt 0 ]; do
    case "$1" in
        --ref) [ $# -ge 2 ] || die "--ref needs a branch or commit"; ref="$2"; shift 2 ;;
        --no-launch) launch=0; shift ;;
        --if-changed) if_changed=1; shift ;;
        --adhoc) force_adhoc=1; shift ;;
        --remote)
            use_remote=1
            if [ $# -ge 2 ] && [ "${2#-}" = "$2" ]; then remote_host="$2"; shift; fi
            shift ;;
        # Used by --remote: the last line of output is the built app's path.
        --print-app) print_app=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown option $1 (see --help)" ;;
    esac
done

if [ -n "${FLUIDWISPR_REPO:-}" ]; then
    repo="${FLUIDWISPR_REPO}"
else
    repo="$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null)" \
        || die "run this from inside a FluidWispr clone, or set FLUIDWISPR_REPO"
fi

if [ ${use_remote} -eq 1 ] && [ -z "${remote_host}" ]; then
    remote_host="$(git -C "${repo}" config --get fluidwispr.remoteHost || true)"
    [ -n "${remote_host}" ] \
        || die "--remote needs a host, or set one with: git config --local fluidwispr.remoteHost <host>"
fi

started_at=${SECONDS}
mark=${SECONDS}
timings=""
lap() {
    timings="${timings}${timings:+, }$1 $((SECONDS - mark))s"
    mark=${SECONDS}
}

resolve_commit() {
    git -C "${repo}" fetch --quiet origin
    git -C "${repo}" rev-parse --verify --quiet "origin/${ref}^{commit}" \
        || git -C "${repo}" rev-parse --verify --quiet "${ref}^{commit}" \
        || die "no branch or commit called ${ref}"
}

# Quit the running debug build, then open the new one. The release app has a
# different bundle id, so it keeps running, but both listen for the same hotkey.
launch_app() {
    local app="$1"
    if pgrep -f "${APP_NAME}/Contents/MacOS/" >/dev/null; then
        osascript -e "tell application id \"${DEBUG_BUNDLE_ID}\" to quit" >/dev/null 2>&1 || true
        local tries=0
        while pgrep -f "${APP_NAME}/Contents/MacOS/" >/dev/null && [ ${tries} -lt 25 ]; do
            sleep 0.2
            tries=$((tries + 1))
        done
        pkill -f "${APP_NAME}/Contents/MacOS/" 2>/dev/null || true
    fi
    if osascript -e "application id \"${RELEASE_BUNDLE_ID}\" is running" 2>/dev/null | grep -q true; then
        echo "Note: the installed FluidVoice is also running and uses the same hotkey. Quit it to test this build."
    fi
    open "${app}"
}

local_signing_identity() {
    security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.* \([[:xdigit:]]\{40\}\) "Apple Development:[^"]*".*/\1/p' \
        | head -n 1
}

record_timing() {
    local commit="$1" profile="$2"
    mkdir -p "${DEV_HOME}"
    printf '%s\t%s\t%s\t%s\ttotal %ss\t%s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(hostname -s)" "${commit:0:7}" "${profile}" \
        "$((SECONDS - started_at))" "${timings}" >> "${DEV_HOME}/timings.log"
}

build_on_remote() {
    local commit app_dir remote_out remote_app identity
    commit="$(resolve_commit)"
    lap fetch
    app_dir="${DEV_HOME}/remote"
    remote_out="$(mktemp -t fluidwispr-remote)"
    # shellcheck disable=SC2064 # expand now: remote_out is local to this function
    trap "rm -f '${remote_out}'" EXIT

    # Send this script over ssh so the other Mac runs the same version as here. It
    # is saved to a file first, because a build step that reads standard input
    # would swallow the rest of a script piped into bash.
    # Ad hoc there: over ssh its login keychain is usually locked.
    echo "Building ${commit:0:7} on ${remote_host}..."
    # shellcheck disable=SC2029
    ssh "${remote_host}" "f=\$(mktemp) && cat > \"\$f\" && FLUIDWISPR_REPO=${FLUIDWISPR_REMOTE_REPO:-\$HOME/FluidWispr} bash \"\$f\" --ref ${commit} --no-launch --if-changed --adhoc --print-app < /dev/null; rc=\$?; rm -f \"\$f\"; exit \$rc" \
        < "${BASH_SOURCE[0]}" | tee "${remote_out}"
    remote_app="$(tail -n 1 "${remote_out}")"
    case "${remote_app}" in
        */"${APP_NAME}") ;;
        *) die "the other Mac did not report a built app" ;;
    esac
    lap "remote build"

    mkdir -p "${app_dir}"
    rsync -a --delete "${remote_host}:${remote_app}/" "${app_dir}/${APP_NAME}/"
    lap copy

    # Re-sign with this Mac's certificate, when there is one, so macOS keeps
    # this build's permissions the same way it does for a local build.
    identity="$(local_signing_identity)"
    if [ -n "${identity}" ]; then
        codesign --force --deep --sign "${identity}" --options runtime --timestamp=none \
            --preserve-metadata=identifier,entitlements,flags "${app_dir}/${APP_NAME}"
        codesign --verify --deep --strict "${app_dir}/${APP_NAME}"
        lap re-sign
    fi

    if [ ${launch} -eq 1 ]; then
        launch_app "${app_dir}/${APP_NAME}"
        lap launch
    fi
    record_timing "${commit}" "remote"
    echo "Done in $((SECONDS - started_at))s (${timings})."
}

build_here() {
    local commit profile app built_file log_file
    commit="$(resolve_commit)"
    app="${DERIVED_DATA}/Build/Products/Debug/${APP_NAME}"
    built_file="${DEV_HOME}/last-built"

    if [ ${if_changed} -eq 1 ] && [ -d "${app}" ] && [ -f "${built_file}" ] \
        && [ "$(cat "${built_file}")" = "${commit}" ]; then
        echo "${commit:0:7} is already built."
        lap fetch
    else
        mkdir -p "${DEV_HOME}"
        if [ -e "${SRC_DIR}" ]; then
            [ "$(git -C "${SRC_DIR}" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" \
                = "$(git -C "${repo}" rev-parse --path-format=absolute --git-common-dir)" ] \
                || die "${SRC_DIR} exists but is not a worktree of ${repo}; move it or set FLUIDWISPR_DEV_HOME"
            # This worktree belongs to the script, so local edits in it are discarded.
            # Checkout keeps unchanged files' timestamps, which keeps the build incremental.
            git -C "${SRC_DIR}" checkout --quiet --force --detach "${commit}"
            git -C "${SRC_DIR}" clean --quiet -fd
        else
            git -C "${repo}" worktree add --quiet --detach "${SRC_DIR}" "${commit}"
        fi
        lap fetch

        if [ ${force_adhoc} -eq 0 ] && [ -n "$(local_signing_identity)" ]; then
            profile="public"
        elif grep -q '^    adhoc)' "${SRC_DIR}/build.sh"; then
            profile="adhoc"
        else
            die "no Apple Development certificate, and this commit's build.sh has no adhoc profile"
        fi

        log_file="${DEV_HOME}/last-build.log"
        echo "Building ${commit:0:7} (${profile}), log: ${log_file}"
        # No index store: Xcode's editor index is not needed for a build you only run.
        if ! FLUIDVOICE_DERIVED_DATA_PATH="${DERIVED_DATA}" \
            FLUIDVOICE_XCODEBUILD_EXTRA_ARGS="-onlyUsePackageVersionsFromResolvedFile COMPILER_INDEX_STORE_ENABLE=NO" \
            bash "${SRC_DIR}/build.sh" "${profile}" > "${log_file}" 2>&1; then
            grep -E 'error:|BUILD FAILED' "${log_file}" | head -n 40 >&2 || true
            die "build failed, full log: ${log_file}"
        fi
        printf '%s\n' "${commit}" > "${built_file}"
        lap build
        record_timing "${commit}" "${profile}"
    fi

    if [ ${launch} -eq 1 ]; then
        launch_app "${app}"
        lap launch
    fi
    echo "Done in $((SECONDS - started_at))s (${timings})."
    if [ ${print_app} -eq 1 ]; then
        echo "${app}"
    fi
}

if [ ${use_remote} -eq 1 ]; then
    build_on_remote
else
    build_here
fi
