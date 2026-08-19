#!/usr/bin/env bash
# Idempotent agenteiamail installer — FR7 implementation skeleton.
#
# The public CLI contract is established here before host mutation phases land.
# Until prerequisite discovery and the managed-artifact inventory are complete,
# every valid non-help invocation remains deliberately inert.

set -euo pipefail

readonly EX_OK=0
readonly EX_CHANGED=10
readonly EX_USAGE=64
readonly EX_CONFIG=78
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
readonly ROOT

usage() {
    cat <<'EOF'
Usage:
  scripts/install.sh --runtime openclaw [--upgrade|--uninstall] [--dry-run]
  scripts/install.sh --runtime hermes [--deliver TARGET --chat-id ID | --profile PROFILE]
                     [--upgrade|--uninstall] [--non-interactive]
                     [--notify-secret-file PATH --roster-secret-file PATH]
                     [--dry-run]

Modes:
  (default)          Install or converge the selected runtime
  --upgrade          Upgrade/converge artifacts owned by this installer
  --uninstall        Remove only artifacts owned by this installer

Options:
  --runtime RUNTIME          Required: openclaw or hermes
  --deliver TARGET          Hermes user-facing delivery target (for example telegram)
  --chat-id ID               Hermes target chat ID
  --profile PROFILE          Select an existing operator-managed Hermes profile
  --non-interactive          Never create or print route secrets
  --notify-secret-file PATH  Pre-provisioned Hermes notification-route secret
  --roster-secret-file PATH  Pre-provisioned Hermes roster-route secret
  --dry-run                  Discover prerequisites and print the plan without changes
  -h, --help                 Show this help

Exit status:
  0   Success: converged and no changes were needed
  10  Success: converged and changes were made
  64  Usage error
  78  Configuration, prerequisite, or not-yet-implemented phase error

Exit status 10 is success. Shell wrappers, CI, and configuration-management
callers must accept both 0 and 10 as successful convergence.

FR7 boundary status: dry-run discovery and inventory only; non-dry runs are inert.
EOF
}

die_usage() {
    printf 'install: %s\n' "$1" >&2
    printf "Try 'scripts/install.sh --help'.\n" >&2
    exit "$EX_USAGE"
}

die_config() {
    printf 'install: %s\n' "$1" >&2
    exit "$EX_CONFIG"
}

resolve_command() {
    command -v "$1" 2>/dev/null || return 1
}

validate_hermes_secret_files() {
    local python=$1 output
    if ! output=$(PYTHONPATH="$ROOT/harness" "$python" - \
        "$notify_secret_file" "$roster_secret_file" <<'PYINNER'
import hmac
import sys

# Installer validation deliberately shares the adapter contract. A regression
# test pins this import and its mode-0600 rejection behavior.
from adapters.hermes import _load_secret

loaded = []
for label, path in (("notify", sys.argv[1]), ("roster", sys.argv[2])):
    secret, error = _load_secret(path)
    if error:
        print(f"{label} secret: {error}")
        raise SystemExit(1)
    loaded.append(secret)
if hmac.compare_digest(loaded[0], loaded[1]):
    print("Hermes notify and roster route secrets must differ")
    raise SystemExit(1)
PYINNER
    ); then
        printf '%s' "$output"
        return 1
    fi
}

prereq_error() {
    if ((dry_run)); then
        prerequisite_errors+=("$1")
    else
        die_config "$1"
    fi
}

discover_prerequisites() {
    local python="" systemctl_bin="" loginctl_bin="" linger="unknown" user_name
    local runtime_cli="" logrotate_bin=""
    prerequisite_errors=()

    if [[ -z "${HOME:-}" || "$HOME" != /* ]]; then
        prereq_error 'HOME must be set to an absolute path'
    fi

    python=$(resolve_command python3 || true)
    [[ -n "$python" ]] || prereq_error 'python3 executable not found'

    systemctl_bin=$(resolve_command systemctl || true)
    if [[ -z "$systemctl_bin" ]]; then
        prereq_error 'systemctl executable not found; a systemd user session is required'
    elif ! "$systemctl_bin" --user show-environment >/dev/null 2>&1; then
        prereq_error 'systemctl --user is unavailable; use a host with a systemd user session'
    fi

    user_name=${USER:-}
    [[ -n "$user_name" ]] || user_name=$(id -un)
    loginctl_bin=$(resolve_command loginctl || true)
    if [[ -z "$loginctl_bin" ]]; then
        if [[ "$mode" == uninstall ]]; then
            linger="unknown (informational; uninstall continues)"
        else
            prereq_error 'loginctl executable not found; cannot verify user lingering'
        fi
    else
        linger=$("$loginctl_bin" show-user "$user_name" -p Linger --value 2>/dev/null || true)
        if [[ "$linger" != yes ]]; then
            if [[ "$mode" == uninstall ]]; then
                linger="disabled (informational; uninstall continues)"
            else
                prereq_error "user lingering is disabled; run: sudo loginctl enable-linger $user_name"
            fi
        else
            linger="enabled"
        fi
    fi

    if [[ "$mode" == uninstall ]]; then
        runtime_cli="not-required-for-uninstall"
    else
        runtime_cli=$(resolve_command "$runtime" || true)
        if [[ -z "$runtime_cli" ]]; then
            prereq_error "$runtime executable not found in the service-safe PATH"
        elif [[ "$runtime" == openclaw ]]; then
            "$runtime_cli" --version >/dev/null 2>&1 || \
                prereq_error 'openclaw executable exists but cannot run --version'
        else
            "$runtime_cli" webhook --help >/dev/null 2>&1 || \
                prereq_error 'hermes executable does not expose webhook support'
            if [[ -n "$notify_secret_file" && -n "$python" ]]; then
                local secret_error=""
                if ! secret_error=$(validate_hermes_secret_files "$python"); then
                    prereq_error "$secret_error"
                fi
            fi
        fi
    fi

    logrotate_bin=$(resolve_command logrotate || true)
    printf 'discovery runtime=%s\n' "$runtime"
    printf 'repo_root=%s\n' "$ROOT"
    [[ -n "$python" ]] && printf 'python=%s\n' "$python"
    [[ -n "$runtime_cli" ]] && printf 'runtime_cli=%s\n' "$runtime_cli"
    [[ -n "$systemctl_bin" ]] && printf 'systemd_user=checked\n'
    printf 'linger=%s\n' "$linger"
    if [[ -n "$logrotate_bin" ]]; then
        printf 'logrotate=%s\n' "$logrotate_bin"
    else
        printf 'logrotate=absent (managed Python rotation will be used)\n'
    fi

    if ((${#prerequisite_errors[@]})); then
        printf 'prerequisite failures (%d):\n' "${#prerequisite_errors[@]}" >&2
        local error
        for error in "${prerequisite_errors[@]}"; do
            printf -- '- %s\n' "$error" >&2
        done
        return 1
    fi
    printf 'systemd_user=available\n'
}

resolve_credentials_path() {
    local neutral legacy
    if [[ -n "${AGENTEIAMAIL_ENV:-}" ]]; then
        printf '%s' "$AGENTEIAMAIL_ENV"
        return
    fi
    neutral="${XDG_CONFIG_HOME:-$HOME/.config}/agenteiamail/env"
    if [[ -e "$neutral" || -L "$neutral" ]]; then
        printf '%s' "$neutral"
        return
    fi
    # Legacy-migration probe only: this path is read-only discovery input.
    # It is never a write target, a new-install default, or an owned artifact.
    legacy="$HOME/.openclaw/workspace/.env"
    if [[ -e "$legacy" || -L "$legacy" ]]; then
        printf '%s' "$legacy"
        return
    fi
    printf '%s' "$neutral"
}

print_managed_inventory() {
    local config_home state_home config_dir state_dir unit_dir credentials unit
    config_home=${XDG_CONFIG_HOME:-$HOME/.config}
    state_home=${XDG_STATE_HOME:-$HOME/.local/state}
    config_dir="$config_home/agenteiamail"
    state_dir="$state_home/agenteiamail"
    unit_dir="$config_home/systemd/user"
    credentials=$(resolve_credentials_path)

    printf 'inventory root=%s mode=%s runtime=%s\n' "$ROOT" "$mode" "$runtime"
    for unit in agenteiamail-idle.service agenteiamail-dispatch.service \
        agenteiamail-logrotate.service agenteiamail-logrotate.timer; do
        printf 'inventory managed-file=%s/%s source=%s/systemd/%s\n' \
            "$unit_dir" "$unit" "$ROOT" "$unit"
    done
    printf 'inventory managed-file=%s/runtime.env source=generated-runtime-config\n' \
        "$config_dir"
    printf 'inventory managed-file=%s/install.manifest source=generated-ownership-record\n' \
        "$config_dir"
    printf 'inventory managed-directory=%s policy=remove-if-empty\n' "$unit_dir"
    printf 'inventory managed-directory=%s policy=remove-if-empty\n' "$config_dir"

    printf 'inventory preserve-file=%s role=mailbox-credentials\n' "$credentials"
    printf 'inventory preserve-file=%s/roster.txt role=recipient-roster\n' "$ROOT"
    printf 'inventory preserve-tree=%s role=uid-journal-cursor-and-logs\n' "$state_dir"
    printf 'inventory preserve-repository=%s\n' "$ROOT"

    if [[ "$runtime" == hermes ]]; then
        if [[ -n "$notify_secret_file" ]]; then
            printf 'inventory external-secret=%s role=notify validate-only=true\n' \
                "$notify_secret_file"
            printf 'inventory external-secret=%s role=roster validate-only=true\n' \
                "$roster_secret_file"
        else
            printf 'inventory conditional-managed-secret=%s/hermes/notify.secret role=notify\n' \
                "$config_dir"
            printf 'inventory conditional-managed-secret=%s/hermes/roster.secret role=roster\n' \
                "$config_dir"
        fi
    fi
}

plan_has_changes() {
    local config_home config_dir unit_dir unit source destination
    config_home=${XDG_CONFIG_HOME:-$HOME/.config}
    config_dir="$config_home/agenteiamail"
    unit_dir="$config_home/systemd/user"

    if [[ "$mode" == uninstall ]]; then
        [[ -e "$config_dir/install.manifest" || -L "$config_dir/install.manifest" ]]
        return
    fi

    for unit in agenteiamail-idle.service agenteiamail-dispatch.service \
        agenteiamail-logrotate.service agenteiamail-logrotate.timer; do
        source="$ROOT/systemd/$unit"
        destination="$unit_dir/$unit"
        if [[ ! -e "$destination" && ! -L "$destination" ]] || \
           ! cmp -s "$source" "$destination"; then
            return 0
        fi
    done
    for destination in "$config_dir/runtime.env" "$config_dir/install.manifest"; do
        [[ -e "$destination" || -L "$destination" ]] || return 0
    done
    if [[ "$runtime" == hermes && -z "$notify_secret_file" ]]; then
        for destination in "$config_dir/hermes/notify.secret" \
            "$config_dir/hermes/roster.secret"; do
            [[ -e "$destination" || -L "$destination" ]] || return 0
        done
    fi
    return 1
}

runtime=""
deliver=""
chat_id=""
profile=""
notify_secret_file=""
roster_secret_file=""
mode="install"
upgrade=0
uninstall=0
non_interactive=0
dry_run=0

while (($#)); do
    case "$1" in
        --runtime|--deliver|--chat-id|--profile|--notify-secret-file|--roster-secret-file)
            (($# >= 2)) || die_usage "$1 requires a value"
            value=$2
            [[ -n "$value" && "$value" != --* ]] || die_usage "$1 requires a value"
            case "$1" in
                --runtime) runtime=$value ;;
                --deliver) deliver=$value ;;
                --chat-id) chat_id=$value ;;
                --profile) profile=$value ;;
                --notify-secret-file) notify_secret_file=$value ;;
                --roster-secret-file) roster_secret_file=$value ;;
            esac
            shift 2
            ;;
        --upgrade)
            upgrade=1
            shift
            ;;
        --uninstall)
            uninstall=1
            shift
            ;;
        --non-interactive)
            non_interactive=1
            shift
            ;;
        --dry-run)
            dry_run=1
            shift
            ;;
        -h|--help)
            usage
            exit "$EX_OK"
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

if ((upgrade && uninstall)); then
    die_usage '--upgrade and --uninstall are mutually exclusive'
elif ((upgrade)); then
    mode="upgrade"
elif ((uninstall)); then
    mode="uninstall"
fi

if [[ "$runtime" != hermes ]] &&
   [[ -n "$deliver" || -n "$chat_id" || -n "$profile" ||
      -n "$notify_secret_file" || -n "$roster_secret_file" ]]; then
    die_usage 'delivery, profile, and route-secret options are Hermes-only'
fi
if [[ -n "$deliver" && -z "$chat_id" ]]; then
    die_usage '--deliver requires --chat-id'
fi
if [[ -n "$chat_id" && -z "$deliver" ]]; then
    die_usage '--chat-id requires --deliver'
fi
if [[ -n "$profile" && ( -n "$deliver" || -n "$chat_id" ) ]]; then
    die_usage '--profile is mutually exclusive with --deliver and --chat-id'
fi
if [[ -n "$notify_secret_file" && -z "$roster_secret_file" ]] ||
   [[ -n "$roster_secret_file" && -z "$notify_secret_file" ]]; then
    die_usage '--notify-secret-file and --roster-secret-file must be supplied together'
fi
if [[ -n "$notify_secret_file" && "$notify_secret_file" == "$roster_secret_file" ]]; then
    die_usage 'notify and roster secret files must be different'
fi
if [[ "$runtime" == hermes && "$mode" != uninstall ]] && ((non_interactive)) &&
   [[ -z "$notify_secret_file" || -z "$roster_secret_file" ]]; then
    die_usage '--non-interactive requires --notify-secret-file and --roster-secret-file for Hermes'
fi

if ((dry_run)); then
    if ! discover_prerequisites; then
        exit "$EX_CONFIG"
    fi
    print_managed_inventory
    if plan_has_changes; then
        printf 'dry-run: plan contains create, modify, or remove actions; no changes made.\n'
        exit "$EX_CHANGED"
    fi
    printf 'dry-run: system is converged; no changes needed.\n'
    exit "$EX_OK"
fi

printf 'FR7 installer skeleton validated runtime=%s mode=%s; no changes made.\n' \
    "$runtime" "$mode" >&2
exit "$EX_CONFIG"
