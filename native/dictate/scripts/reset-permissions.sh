#!/usr/bin/env bash

set -euo pipefail

BUNDLE_ID="${BUNDLE_ID:-dev.subset.dictate}"
APP_PROCESS_NAME="${APP_PROCESS_NAME:-Dictate}"
KILL_APP=1
OPEN_SETTINGS=0
DRY_RUN=0

usage() {
    cat <<EOF
Reset macOS permissions for Dictate.

Usage:
  ./scripts/reset-permissions.sh [options]

Options:
  --bundle-id <id>     Override the app bundle identifier.
  --process-name <n>   Override the process name to stop before resetting.
  --no-kill            Do not stop running app instances first.
  --open-settings      Open relevant System Settings panes after reset.
  --dry-run            Print commands without executing them.
  -h, --help           Show this help.

Environment overrides:
  BUNDLE_ID
  APP_PROCESS_NAME
EOF
}

run_cmd() {
    if [[ "${DRY_RUN}" == "1" ]]; then
        printf '[dry-run] %q' "$1"
        shift
        for arg in "$@"; do
            printf ' %q' "${arg}"
        done
        printf '\n'
        return 0
    fi

    "$@"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --bundle-id|--process-name)
            if [[ $# -lt 2 || -z "$2" ]]; then
                echo "$1 needs a non-empty value" >&2
                usage >&2
                exit 1
            fi
            if [[ "$1" == "--bundle-id" ]]; then BUNDLE_ID="$2"; else APP_PROCESS_NAME="$2"; fi
            shift 2
            ;;
        --no-kill)
            KILL_APP=0
            shift
            ;;
        --open-settings)
            OPEN_SETTINGS=1
            shift
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

require_tool() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "Missing required tool: $1" >&2
        exit 1
    fi
}

require_tool tccutil

if [[ "${KILL_APP}" == "1" ]]; then
    # Match the exact process name, not any command line that mentions it.
    if pgrep -x "${APP_PROCESS_NAME}" >/dev/null 2>&1; then
        echo "Stopping running ${APP_PROCESS_NAME} instances"
        run_cmd pkill -x "${APP_PROCESS_NAME}"
    else
        echo "No running ${APP_PROCESS_NAME} instances found"
    fi
fi

for service in Microphone Accessibility AppleEvents; do
    echo "Resetting ${service} for ${BUNDLE_ID}"
    run_cmd tccutil reset "${service}" "${BUNDLE_ID}"
done

if [[ "${OPEN_SETTINGS}" == "1" ]]; then
    echo "Opening System Settings privacy panes"
    run_cmd open "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
    run_cmd open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    run_cmd open "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
fi

cat <<EOF

Done.

Next:
1. Launch ${APP_PROCESS_NAME} again.
2. Re-approve Microphone, Accessibility, and Automation/System Events when prompted.
3. If prompts do not appear, revisit the relevant panes in System Settings.
EOF
