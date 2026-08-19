#!/usr/bin/env bash
# Idempotent agenteiamail installer — FR7 implementation skeleton.
#
# The public CLI contract, inert discovery, and fail-closed ownership inventory
# land before any host mutation phase. Every valid non-help, non-dry invocation
# remains deliberately inert.

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
  --dry-run                  Discover and plan without executing runtimes or changing host
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

resolve_in_path() {
    local name=$1 search_path=$2
    PATH="$search_path" command -v "$name" 2>/dev/null || return 1
}

systemd_service_path() {
    local systemctl_bin=$1 environment line
    environment=$("$systemctl_bin" --user show-environment 2>/dev/null) || return 1
    while IFS= read -r line; do
        if [[ "$line" == PATH=* ]]; then
            printf '%s' "${line#PATH=}"
            return 0
        fi
    done <<<"$environment"
    return 2
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
    local python="" systemctl_bin="" loginctl_bin="" linger="unknown" user_name=""
    local runtime_cli="" logrotate_bin="" service_path=""
    local systemd_state="unavailable" quoted_user path_status
    local service_path_error_reported=0
    prerequisite_errors=()

    if [[ -z "${HOME:-}" || "$HOME" != /* ]]; then
        prereq_error 'HOME must be set to an absolute path'
    fi

    python=$(resolve_command python3 || true)
    [[ -n "$python" ]] || prereq_error 'python3 executable not found'

    systemctl_bin=$(resolve_command systemctl || true)
    if [[ -z "$systemctl_bin" ]]; then
        if [[ "$mode" == uninstall ]]; then
            systemd_state="unavailable (filesystem inventory continues)"
        else
            prereq_error 'systemctl executable not found; a systemd user session is required'
        fi
    elif service_path=$(systemd_service_path "$systemctl_bin"); then
        systemd_state="available"
    else
        path_status=$?
        if ((path_status == 2)); then
            systemd_state="available (PATH not reported)"
            if [[ "$mode" != uninstall && "$runtime" == openclaw ]]; then
                prereq_error 'systemd user environment does not report PATH; cannot verify OpenClaw'
                service_path_error_reported=1
            fi
        elif [[ "$mode" == uninstall ]]; then
            systemd_state="unavailable (filesystem inventory continues)"
        else
            prereq_error 'systemctl --user is unavailable; use a host with a systemd user session'
        fi
    fi

    user_name=$(id -un 2>/dev/null || true)
    if [[ -z "$user_name" || ! "$user_name" =~ ^[A-Za-z0-9_.-]+$ ]]; then
        prereq_error 'cannot derive a safe service account name from id -un'
    fi
    loginctl_bin=$(resolve_command loginctl || true)
    if [[ -z "$loginctl_bin" ]]; then
        if [[ "$mode" == uninstall ]]; then
            linger="unknown (informational; uninstall continues)"
        else
            prereq_error 'loginctl executable not found; cannot verify user lingering'
        fi
    elif [[ -n "$user_name" ]]; then
        linger=$("$loginctl_bin" show-user "$user_name" -p Linger --value 2>/dev/null || true)
        if [[ "$linger" != yes ]]; then
            if [[ "$mode" == uninstall ]]; then
                linger="disabled (informational; uninstall continues)"
            else
                printf -v quoted_user '%q' "$user_name"
                prereq_error "user lingering is disabled; run: sudo loginctl enable-linger $quoted_user"
            fi
        else
            linger="enabled"
        fi
    fi

    if [[ "$mode" == uninstall ]]; then
        runtime_cli="not-required-for-uninstall"
    else
        if [[ "$runtime" == openclaw ]]; then
            if [[ -z "$service_path" ]]; then
                if ((service_path_error_reported == 0)); then
                    prereq_error 'openclaw executable cannot be verified because the systemd user PATH is unavailable'
                fi
            else
                runtime_cli=$(resolve_in_path "$runtime" "$service_path" || true)
                if [[ -z "$runtime_cli" ]]; then
                    prereq_error 'openclaw executable not found in the systemd user PATH'
                fi
            fi
        else
            runtime_cli=$(resolve_command hermes || true)
            if [[ -z "$runtime_cli" ]]; then
                prereq_error 'hermes executable not found in the installer PATH'
            fi
        fi
        if [[ "$runtime" == hermes && -n "$notify_secret_file" && -n "$python" ]]; then
            local secret_error=""
            if ! secret_error=$(validate_hermes_secret_files "$python"); then
                prereq_error "$secret_error"
            fi
        fi
    fi

    logrotate_bin=$(resolve_command logrotate || true)
    printf 'discovery runtime=%s\n' "$runtime"
    printf 'repo_root=%s\n' "$ROOT"
    [[ -n "$python" ]] && printf 'python=%s\n' "$python"
    [[ -n "$runtime_cli" ]] && printf 'runtime_cli=%s\n' "$runtime_cli"
    printf 'service_path=%s\n' "${service_path:-not-reported}"
    printf 'runtime_probe=deferred (dry-run never executes runtime code)\n'
    printf 'systemd_user=%s\n' "$systemd_state"
    printf 'linger=%s\n' "$linger"
    if [[ -n "$logrotate_bin" ]]; then
        printf 'logrotate=%s\n' "$logrotate_bin"
    else
        printf 'logrotate=absent (managed Python rotation will be used)\n'
    fi
    if [[ -n "${XDG_CONFIG_HOME:-}${XDG_STATE_HOME:-}" ]]; then
        printf 'xdg_overrides=ignored (application paths are fixed under HOME)\n'
    fi

    if ((${#prerequisite_errors[@]})); then
        printf 'prerequisite failures (%d):\n' "${#prerequisite_errors[@]}" >&2
        local error
        for error in "${prerequisite_errors[@]}"; do
            printf -- '- %s\n' "$error" >&2
        done
        return 1
    fi
}

resolve_credentials_path() {
    local neutral legacy
    if [[ -n "${AGENTEIAMAIL_ENV:-}" ]]; then
        printf '%s' "$AGENTEIAMAIL_ENV"
        return
    fi
    neutral="$HOME/.config/agenteiamail/env"
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

validate_container_chain() {
    local target=$1 current relative component owner mode mode_value
    local -a components=()

    [[ "$target" == "$HOME"/* ]] || {
        printf 'inventory conflict-container=%s reason=outside-home\n' "$target"
        inventory_conflicts=1
        return 1
    }

    current=$HOME
    relative=${target#"$HOME"/}
    IFS='/' read -r -a components <<<"$relative"
    for component in "" "${components[@]}"; do
        if [[ -n "$component" ]]; then
            current="$current/$component"
        fi
        if [[ -L "$current" ]]; then
            printf 'inventory conflict-container=%s reason=symlink\n' "$current"
            inventory_conflicts=1
            return 1
        fi
        if [[ -e "$current" ]]; then
            if [[ ! -d "$current" ]]; then
                printf 'inventory conflict-container=%s reason=not-directory\n' "$current"
                inventory_conflicts=1
                return 1
            fi
            owner=$(stat -Lc '%u' -- "$current" 2>/dev/null || true)
            mode=$(stat -Lc '%a' -- "$current" 2>/dev/null || true)
            if [[ "$owner" != "$EUID" || -z "$mode" ]]; then
                printf 'inventory conflict-container=%s reason=unsafe-owner-or-metadata\n' \
                    "$current"
                inventory_conflicts=1
                return 1
            fi
            mode_value=$((8#$mode))
            if ((mode_value & 18)); then
                printf 'inventory conflict-container=%s reason=group-or-world-writable\n' \
                    "$current"
                inventory_conflicts=1
                return 1
            fi
        else
            printf 'inventory planned-container=%s policy=create-securely-and-revalidate\n' \
                "$target"
            return 0
        fi
    done
    printf 'inventory existing-container=%s policy=revalidate-before-write\n' "$target"
}

classify_planned_artifact() {
    local kind=$1 destination=$2 source=$3
    if [[ -e "$destination" || -L "$destination" ]]; then
        printf 'inventory conflict-preserve-%s=%s reason=unproven-ownership\n' \
            "$kind" "$destination"
        inventory_conflicts=1
    else
        printf 'inventory planned-managed-%s=%s source=%s\n' \
            "$kind" "$destination" "$source"
    fi
}

print_managed_inventory() {
    local config_dir state_dir unit_dir hermes_dir credentials unit
    local unit_container_safe=1 config_container_safe=1 hermes_container_safe=1
    # These paths deliberately follow the runtime and systemd contracts rather
    # than XDG overrides: the Hermes adapter defaults state via expanduser(),
    # while the shipped units read %h paths. Honoring XDG_CONFIG_HOME here would
    # place secrets where the unit never reads them and surface later as a 401.
    config_dir="$HOME/.config/agenteiamail"
    state_dir="$HOME/.local/state/agenteiamail"
    unit_dir="$HOME/.config/systemd/user"
    hermes_dir="$config_dir/hermes"
    credentials=$(resolve_credentials_path)
    inventory_conflicts=0
    inventory_blocked=0

    printf 'inventory root=%s mode=%s runtime=%s\n' "$ROOT" "$mode" "$runtime"
    validate_container_chain "$unit_dir" || unit_container_safe=0
    validate_container_chain "$config_dir" || config_container_safe=0

    for unit in agenteiamail-idle.service agenteiamail-dispatch.service \
        agenteiamail-logrotate.service agenteiamail-logrotate.timer; do
        if ((unit_container_safe)); then
            classify_planned_artifact file "$unit_dir/$unit" "$ROOT/systemd/$unit"
        else
            inventory_blocked=1
            printf 'inventory blocked-managed-file=%s/%s reason=unsafe-container\n' \
                "$unit_dir" "$unit"
        fi
    done
    if ((config_container_safe)); then
        classify_planned_artifact file "$config_dir/runtime.env" generated-runtime-config
        classify_planned_artifact file "$config_dir/install.manifest" \
            generated-ownership-record
    else
        inventory_blocked=1
        printf 'inventory blocked-managed-file=%s/runtime.env reason=unsafe-container\n' \
            "$config_dir"
        printf 'inventory blocked-managed-file=%s/install.manifest reason=unsafe-container\n' \
            "$config_dir"
    fi
    printf 'inventory container-directory=%s policy=never-own-directory\n' "$unit_dir"
    printf 'inventory container-directory=%s policy=never-own-directory\n' "$config_dir"

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
            if ((config_container_safe)); then
                validate_container_chain "$hermes_dir" || hermes_container_safe=0
            else
                hermes_container_safe=0
            fi
            printf 'inventory container-directory=%s policy=never-own-directory\n' \
                "$hermes_dir"
            if ((hermes_container_safe)); then
                classify_planned_artifact secret "$hermes_dir/notify.secret" \
                    generated-once-interactively
                classify_planned_artifact secret "$hermes_dir/roster.secret" \
                    generated-once-interactively
            else
                inventory_blocked=1
                printf 'inventory blocked-managed-secret=%s/notify.secret reason=unsafe-container\n' \
                    "$hermes_dir"
                printf 'inventory blocked-managed-secret=%s/roster.secret reason=unsafe-container\n' \
                    "$hermes_dir"
            fi
        fi
    fi
    if ((inventory_blocked)); then
        printf 'inventory result=blocked configuration-refusal=true\n'
    fi
}

plan_has_changes() {
    local manifest="$HOME/.config/agenteiamail/install.manifest"
    if [[ "$mode" == uninstall ]]; then
        [[ -e "$manifest" || -L "$manifest" ]]
        return
    fi
    # With no ownership manifest reader in this structural boundary, every
    # conflict has already failed closed and every remaining candidate is absent.
    return 0
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
declare -A seen_options=()

mark_option_once() {
    local option=$1
    [[ -z "${seen_options[$option]+present}" ]] || die_usage "duplicate option: $option"
    seen_options[$option]=1
}

while (($#)); do
    case "$1" in
        --runtime|--deliver|--chat-id|--profile|--notify-secret-file|--roster-secret-file)
            mark_option_once "$1"
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
            mark_option_once "$1"
            upgrade=1
            shift
            ;;
        --uninstall)
            mark_option_once "$1"
            uninstall=1
            shift
            ;;
        --non-interactive)
            mark_option_once "$1"
            non_interactive=1
            shift
            ;;
        --dry-run)
            mark_option_once "$1"
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

if [[ "$runtime" != hermes ]]; then
    if [[ -n "$deliver" || -n "$chat_id" || -n "$profile" ||
          -n "$notify_secret_file" || -n "$roster_secret_file" ]] ||
       ((non_interactive)); then
        die_usage 'delivery, profile, non-interactive, and route-secret options are Hermes-only'
    fi
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
    if ((inventory_conflicts || inventory_blocked)); then
        printf 'install: unproven pre-existing artifacts are preserved; ownership manifest support is required before mutation\n' >&2
        exit "$EX_CONFIG"
    fi
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
