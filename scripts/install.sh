#!/usr/bin/env bash
# Idempotent agenteiamail installer — FR7 implementation skeleton.
#
# This first pushed shape is deliberately inert. It validates the public CLI,
# then exits before prerequisite discovery or any host modification. Each phase
# below will be filled in and regression-tested without changing that boundary.

set -euo pipefail

readonly EX_USAGE=64
readonly EX_CONFIG=78

usage() {
    cat <<'EOF'
Usage:
  scripts/install.sh --runtime openclaw
  scripts/install.sh --runtime hermes [--deliver telegram --chat-id ID]
  scripts/install.sh --runtime hermes [--profile PROFILE]

Options:
  --runtime RUNTIME  Required: openclaw or hermes
  --deliver TARGET  Hermes user-facing delivery target (for example telegram)
  --chat-id ID       Hermes target chat ID
  --profile PROFILE  Operator-selected Hermes profile
  -h, --help         Show this help

FR7 skeleton status: argument validation only; no files or services are changed.
EOF
}

die_usage() {
    printf 'install: %s
' "$1" >&2
    printf "Try 'scripts/install.sh --help'.
" >&2
    exit "$EX_USAGE"
}

runtime=""
deliver=""
chat_id=""
profile=""

while (($#)); do
    case "$1" in
        --runtime|--deliver|--chat-id|--profile)
            (($# >= 2)) || die_usage "$1 requires a value"
            value=$2
            [[ -n "$value" && "$value" != --* ]] || die_usage "$1 requires a value"
            case "$1" in
                --runtime) runtime=$value ;;
                --deliver) deliver=$value ;;
                --chat-id) chat_id=$value ;;
                --profile) profile=$value ;;
            esac
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die_usage "unknown argument: $1"
            ;;
    esac
done

[[ -n "$runtime" ]] || die_usage '--runtime is required'
case "$runtime" in
    openclaw|hermes) ;;
    *) die_usage "unsupported runtime: $runtime" ;;
esac

if [[ "$runtime" != hermes && ( -n "$deliver" || -n "$chat_id" || -n "$profile" ) ]]; then
    die_usage '--deliver, --chat-id, and --profile are Hermes-only options'
fi
if [[ -n "$deliver" && -z "$chat_id" ]]; then
    die_usage '--deliver currently requires --chat-id'
fi
if [[ -n "$chat_id" && -z "$deliver" ]]; then
    die_usage '--chat-id currently requires --deliver'
fi

printf 'FR7 installer skeleton validated runtime=%s; no changes made.
' "$runtime" >&2
exit "$EX_CONFIG"
