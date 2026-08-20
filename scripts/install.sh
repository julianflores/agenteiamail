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

# The installer must not write into the tree it is converging.
#
# Several helpers here are Python that imports repository-local modules, and the
# install root is now the clone — so CPython dropped __pycache__/*.pyc into
# harness/ and harness/adapters/ as a side effect of running the installer. The
# ownership model says the repository is preserved, not managed, and an install
# that quietly modifies it contradicts that.
#
# It also hid itself: the caches are gitignored, so `git status` stayed clean,
# and once they existed a rerun looked inert. Only a clean clone shows it, which
# is why the regression test builds one.
export PYTHONDONTWRITEBYTECODE=1

usage() {
    cat <<'EOF'
Usage:
  scripts/install.sh --runtime openclaw [--upgrade|--migrate|--uninstall] [--dry-run]
  scripts/install.sh --runtime hermes [--deliver TARGET --chat-id ID | --profile PROFILE]
                     [--upgrade|--migrate|--uninstall] [--non-interactive]
                     [--notify-secret-file PATH --roster-secret-file PATH]
                     [--dry-run]

Modes:
  (default)          Install or converge the selected runtime
  --upgrade          Upgrade/converge artifacts owned by this installer
  --migrate          Move a pre-single-root install into the clone, then converge
  --uninstall        Remove only artifacts owned by this installer

Options:
  --runtime RUNTIME          Required: openclaw or hermes
  --deliver TARGET          Guidance label for an operator-managed Hermes target
  --chat-id ID               Guidance label for that target's chat ID
  --profile PROFILE          Guidance label for an existing operator-managed profile
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

FR7 boundary status: OpenClaw filesystem artifacts converge atomically;
service enablement and Hermes mutation remain deferred.
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

validate_hermes_route_environment() {
    local name value
    for name in HERMES_NOTIFY_URL HERMES_ROSTER_URL HERMES_HEALTH_URL; do
        value=${!name:-}
        [[ -n "$value" ]] || {
            printf '%s is required; supply the full operator-approved URL' "$name"
            return 1
        }
        [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || {
            printf '%s must be a single-line URL' "$name"
            return 1
        }
    done
    if [[ "${HERMES_SIGNATURE_MODE:-v2}" != v2 ]]; then
        printf 'HERMES_SIGNATURE_MODE must be v2 for installer route verification'
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
            systemctl_bin=""
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
        if [[ "$runtime" == hermes ]]; then
            local route_error=""
            if ! route_error=$(validate_hermes_route_environment); then
                prereq_error "$route_error"
            fi

        fi
    fi

    logrotate_bin=$(resolve_command logrotate || true)
    printf 'discovery runtime=%s\n' "$runtime"
    printf 'repo_root=%s\n' "$ROOT"
    [[ -n "$python" ]] && printf 'python=%s\n' "$python"
    [[ -n "$runtime_cli" ]] && printf 'runtime_cli=%s\n' "$runtime_cli"
    printf 'service_path=%s\n' "${service_path:-not-reported}"
    if ((dry_run)); then
        printf 'runtime_probe=deferred (dry-run never executes runtime code)\n'
    else
        printf 'runtime_probe=deferred (filesystem-only convergence never executes runtime code)\n'
    fi
    printf 'systemd_user=%s\n' "$systemd_state"
    printf 'linger=%s\n' "$linger"
    if [[ -n "$logrotate_bin" ]]; then
        printf 'logrotate=%s\n' "$logrotate_bin"
    else
        printf 'logrotate=absent (managed Python rotation will be used)\n'
    fi
    if [[ -n "${XDG_CONFIG_HOME:-}${XDG_STATE_HOME:-}" ]]; then
        printf 'xdg_overrides=ignored (the install root is the clone)\n'
    fi

    if ((${#prerequisite_errors[@]})); then
        printf 'prerequisite failures (%d):\n' "${#prerequisite_errors[@]}" >&2
        local error
        for error in "${prerequisite_errors[@]}"; do
            printf -- '- %s\n' "$error" >&2
        done
        return 1
    fi
    discovered_python=$python
    discovered_systemctl=$systemctl_bin
    discovered_runtime_cli=$runtime_cli
}

# One rule, and it is not written here. harness/paths.py has it, scripts/
# envpath.sh is the shell half, and scripts/test_paths.sh asserts the two agree.
# A fourth copy in the installer is how the units end up pointing at a file the
# listener never reads.
# shellcheck source=envpath.sh
. "$ROOT/scripts/envpath.sh"

resolve_credentials_path() {
    agenteiamail_env_file
}

validate_container_chain() {
    local target=$1 anchor current relative component owner mode mode_value
    local -a components=()

    # Two anchors, because the install root is wherever the clone is and that is
    # not necessarily under $HOME. Whichever anchor is used, it is validated
    # itself before anything beneath it: the loop's first iteration checks
    # `current` before appending a component.
    if [[ "$target" == "$HOME" || "$target" == "$HOME"/* ]]; then
        anchor=$HOME
    elif [[ "$target" == "$install_root" || "$target" == "$install_root"/* ]]; then
        anchor=$install_root
    else
        printf 'inventory conflict-container=%s reason=outside-home-and-install-root\n' "$target"
        inventory_conflicts=1
        inventory_blocked_details+=("$target"$'\t'outside-home-and-install-root)
        return 1
    fi

    current=$anchor
    relative=${target#"$anchor"}
    relative=${relative#/}
    if [[ -n "$relative" ]]; then
        IFS='/' read -r -a components <<<"$relative"
    fi
    for component in "" "${components[@]}"; do
        if [[ -n "$component" ]]; then
            current="$current/$component"
        fi
        if [[ -L "$current" ]]; then
            printf 'inventory conflict-container=%s reason=symlink\n' "$current"
            inventory_conflicts=1
            inventory_blocked_details+=("$current"$'\t'symlink)
            return 1
        fi
        if [[ -e "$current" ]]; then
            if [[ ! -d "$current" ]]; then
                printf 'inventory conflict-container=%s reason=not-directory\n' "$current"
                inventory_conflicts=1
                inventory_blocked_details+=("$current"$'\t'not-directory)
                return 1
            fi
            owner=$(stat -Lc '%u' -- "$current" 2>/dev/null || true)
            mode=$(stat -Lc '%a' -- "$current" 2>/dev/null || true)
            if [[ "$owner" != "$EUID" || -z "$mode" ]]; then
                printf 'inventory conflict-container=%s reason=unsafe-owner-or-metadata\n' \
                    "$current"
                inventory_conflicts=1
                inventory_blocked_details+=("$current"$'\t'unsafe-owner-or-metadata)
                return 1
            fi
            mode_value=$((8#$mode))
            if ((mode_value & 18)); then
                printf 'inventory conflict-container=%s reason=group-or-world-writable\n' \
                    "$current"
                inventory_conflicts=1
                inventory_blocked_details+=("$current"$'\t'group-or-world-writable)
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

set_managed_paths() {
    # The clone is the install: config, state, credentials, secrets and roster
    # all hang off it. A legacy install that was never migrated keeps its split
    # layout instead, and the resolver — not this function — is what decides
    # which of those two a host is in.
    install_root=$(agenteiamail_root)
    config_dir=$(agenteiamail_config_dir)
    state_dir=$(agenteiamail_state_dir)
    unit_dir="$HOME/.config/systemd/user"
    hermes_dir="$config_dir/hermes"
    manifest="$config_dir/install.manifest"
    credentials=$(resolve_credentials_path)
    managed_paths=(
        "$unit_dir/agenteiamail-idle.service"
        "$unit_dir/agenteiamail-dispatch.service"
        "$unit_dir/agenteiamail-logrotate.service"
        "$unit_dir/agenteiamail-logrotate.timer"
        "$config_dir/runtime.env"
        # Generated Hermes secrets remain installer-owned across an explicit
        # runtime migration so rollback can reuse them and uninstall can still
        # account for them. Fresh OpenClaw installs never record these paths.
        "$hermes_dir/notify.secret"
        "$hermes_dir/roster.secret"
    )
}

manifest_arguments() {
    local manifest_runtime_value=${1:-$runtime} path
    printf '%s\0' --manifest "$manifest" --runtime "$manifest_runtime_value"
    for path in "${managed_paths[@]}"; do
        printf '%s\0' --allowed "$path"
    done
}

load_ownership_manifest() {
    local output kind path digest previous_runtime
    declare -gA owned_digests=()
    manifest_runtime=$runtime
    [[ -e "$manifest" || -L "$manifest" ]] || return 0
    local -a arguments=()
    mapfile -d '' -t arguments < <(manifest_arguments)
    if ! output=$(python3 "$ROOT/scripts/install_manifest.py" read "${arguments[@]}" 2>&1); then
        if [[ "$mode" != upgrade ]]; then
            printf '%s\n' "$output" >&2
            exit "$EX_CONFIG"
        fi
        if [[ "$runtime" == openclaw ]]; then
            previous_runtime=hermes
        else
            previous_runtime=openclaw
        fi
        mapfile -d '' -t arguments < <(manifest_arguments "$previous_runtime")
        if ! output=$(python3 "$ROOT/scripts/install_manifest.py" read "${arguments[@]}" 2>&1); then
            printf '%s\n' "$output" >&2
            exit "$EX_CONFIG"
        fi
        manifest_runtime=$previous_runtime
    fi
    while IFS=$'\t' read -r kind path digest; do
        [[ -n "$kind" ]] || continue
        owned_digests["$path"]=$digest
    done <<<"$output"
}

migrate_ownership_manifest() {
    local output path
    [[ "$manifest_runtime" != "$runtime" ]] || return 0
    local -a arguments=(
        --manifest "$manifest"
        --from-runtime "$manifest_runtime"
        --runtime "$runtime"
    )
    for path in "${managed_paths[@]}"; do
        arguments+=(--allowed "$path")
    done
    if ! output=$(python3 "$ROOT/scripts/install_manifest.py" migrate-runtime \
        "${arguments[@]}" 2>&1); then
        printf '%s\n' "$output" >&2
        exit "$EX_CONFIG"
    fi
    printf 'runtime_migration=%s-to-%s state=ownership-transferred\n' \
        "$manifest_runtime" "$runtime"
    manifest_runtime=$runtime
    changes_made=1
}

render_artifact() {
    local destination=$1 source=$2
    if [[ "$source" == generated-runtime-config ]]; then
        if [[ "$runtime" == openclaw ]]; then
            printf 'AGENTEIAMAIL_RUNTIME=openclaw\n'
            return
        fi
        python3 - "$notify_secret_file" "$roster_secret_file" <<'PYINNER'
import os
import sys

values = {
    "AGENTEIAMAIL_RUNTIME": "hermes",
    "HERMES_NOTIFY_URL": os.environ["HERMES_NOTIFY_URL"],
    "HERMES_NOTIFY_SECRET_FILE": sys.argv[1],
    "HERMES_ROSTER_URL": os.environ["HERMES_ROSTER_URL"],
    "HERMES_ROSTER_SECRET_FILE": sys.argv[2],
    "HERMES_HEALTH_URL": os.environ["HERMES_HEALTH_URL"],
    "HERMES_SIGNATURE_MODE": "v2",
}
if os.environ.get("HERMES_ALLOW_REMOTE", "").lower() in ("1", "true", "yes"):
    values["HERMES_ALLOW_REMOTE"] = "1"
for name, value in values.items():
    if "\n" in value or "\r" in value or "\0" in value:
        raise SystemExit(f"invalid multiline or NUL value for {name}")
    escaped = value.replace("\\", "\\\\").replace('"', '\\"')
    print(f'{name}="{escaped}"')
PYINNER
        return
    fi
    python3 - "$source" "$ROOT" "$credentials" "$config_dir" "$state_dir" <<'PYINNER'
import sys
from pathlib import Path

# Order matters only in that every placeholder is distinct; none is a prefix of
# another, so a single pass is enough. config and state are separate from the
# root because a legacy install keeps them outside the clone, and rendering them
# from the root would point a still-working install at empty directories.
text = Path(sys.argv[1]).read_text()
text = text.replace("/path/to/agenteiamail", sys.argv[2])
text = text.replace("/path/to/env", sys.argv[3])
text = text.replace("/path/to/config", sys.argv[4])
text = text.replace("/path/to/state", sys.argv[5])
sys.stdout.write(text)
PYINNER
}

sha256_file() {
    sha256sum -- "$1" | cut -d ' ' -f1
}

sha256_desired() {
    render_artifact "$1" "$2" | sha256sum | cut -d ' ' -f1
}

classify_planned_artifact() {
    local kind=$1 destination=$2 source=$3 actual desired
    if [[ -e "$destination" || -L "$destination" ]]; then
        if [[ -n "${owned_digests[$destination]+present}" ]]; then
            if [[ -L "$destination" || ! -f "$destination" ]]; then
                printf 'inventory conflict-owned-%s=%s reason=unsafe-artifact-type\n' \
                    "$kind" "$destination"
                inventory_conflicts=1
                return
            fi
            actual=$(sha256_file "$destination")
            if [[ "$actual" != "${owned_digests[$destination]}" ]]; then
                printf 'inventory conflict-owned-%s=%s reason=changed-outside-installer\n' \
                    "$kind" "$destination"
                inventory_conflicts=1
                return
            fi
            desired=$(sha256_desired "$destination" "$source")
            if [[ "$actual" == "$desired" ]]; then
                printf 'inventory existing-managed-%s=%s state=converged\n' \
                    "$kind" "$destination"
            else
                printf 'inventory planned-update-%s=%s source=%s\n' \
                    "$kind" "$destination" "$source"
                inventory_changes=1
            fi
        else
            # A process can stop after the atomic artifact link but before the
            # manifest record. Exact generated bytes are safe to adopt; any
            # differing, linked, non-regular, or foreign-owned path remains an
            # unproven conflict. write-artifact revalidates this at mutation.
            if [[ "$source" != generated-once-interactively &&
                  ! -L "$destination" && -f "$destination" && -O "$destination" ]]; then
                actual=$(sha256_file "$destination")
                desired=$(sha256_desired "$destination" "$source")
            else
                actual=""
                desired=""
            fi
            if [[ -n "$actual" && "$actual" == "$desired" ]]; then
                printf 'inventory planned-adopt-%s=%s reason=generated-content-match\n' \
                    "$kind" "$destination"
                inventory_changes=1
            else
                printf 'inventory conflict-preserve-%s=%s reason=unproven-ownership\n' \
                    "$kind" "$destination"
                inventory_conflicts=1
                inventory_unproven_conflicts=1
            fi
        fi
    else
        printf 'inventory planned-managed-%s=%s source=%s\n' \
            "$kind" "$destination" "$source"
        inventory_changes=1
    fi
}

classify_planned_secret() {
    local destination=$1 actual expected
    if [[ ! -e "$destination" && ! -L "$destination" ]]; then
        printf 'inventory planned-managed-secret=%s source=generated-once-interactively\n' \
            "$destination"
        inventory_changes=1
        return
    fi
    expected=${owned_digests[$destination]:-}
    if [[ -z "$expected" ]]; then
        printf 'inventory conflict-preserve-secret=%s reason=unproven-ownership\n' \
            "$destination"
        inventory_conflicts=1
        inventory_unproven_conflicts=1
        return
    fi
    if [[ -L "$destination" || ! -f "$destination" || ! -O "$destination" ||
          "$(stat -Lc '%a' -- "$destination" 2>/dev/null || true)" != 600 ]]; then
        printf 'inventory conflict-owned-secret=%s reason=unsafe-artifact-metadata\n' \
            "$destination"
        inventory_conflicts=1
        return
    fi
    actual=$(sha256_file "$destination")
    if [[ "$actual" != "$expected" ]]; then
        printf 'inventory conflict-owned-secret=%s reason=changed-outside-installer\n' \
            "$destination"
        inventory_conflicts=1
        return
    fi
    printf 'inventory existing-managed-secret=%s state=converged\n' "$destination"
}

print_managed_inventory() {
    local unit
    local unit_container_safe=1 config_container_safe=1 hermes_container_safe=1
    # These paths deliberately follow the resolver rather than XDG overrides.
    # Everything the install owns hangs off the clone, and the units are
    # rendered with the same answers; honoring XDG_CONFIG_HOME here would place
    # secrets where the unit never reads them and surface later as a 401.
    set_managed_paths
    inventory_conflicts=0
    inventory_unproven_conflicts=0
    inventory_blocked=0
    inventory_changes=0
    inventory_blocked_details=()

    printf 'inventory root=%s mode=%s runtime=%s\n' "$ROOT" "$mode" "$runtime"
    validate_container_chain "$unit_dir" || unit_container_safe=0
    validate_container_chain "$config_dir" || config_container_safe=0
    if ((config_container_safe)); then
        load_ownership_manifest
        if [[ "$manifest_runtime" != "$runtime" ]]; then
            printf 'inventory planned-runtime-migration=%s-to-%s mode=upgrade\n' \
                "$manifest_runtime" "$runtime"
            inventory_changes=1
        fi
    fi

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
        if [[ -e "$manifest" && ! -L "$manifest" ]]; then
            printf 'inventory ownership-manifest=%s state=secure
' "$manifest"
        else
            printf 'inventory planned-ownership-manifest=%s
' "$manifest"
            inventory_changes=1
        fi
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
                classify_planned_secret "$hermes_dir/notify.secret"
                classify_planned_secret "$hermes_dir/roster.secret"
            else
                inventory_blocked=1
                printf 'inventory blocked-managed-secret=%s/notify.secret reason=unsafe-container\n' \
                    "$hermes_dir"
                printf 'inventory blocked-managed-secret=%s/roster.secret reason=unsafe-container\n' \
                    "$hermes_dir"
            fi
        fi
    fi
    check_git_hygiene
    if ((inventory_blocked)); then
        printf 'inventory result=blocked configuration-refusal=true\n'
    fi
}

# Every runtime-owned path is ignored by git, and none of them is tracked.
#
# The install lives inside the working tree now, so an ignore rule is all that
# stands between a mail password and `git add -A`. This runs in the inventory
# phase, before anything is written: refusing to write a secret beats writing it
# and printing a warning nobody reads.
#
# A deployment with no .git — a tarball, an export — cannot be checked and is
# not refused for it. It is reported, so the difference between "checked and
# clean" and "could not check" stays visible.
check_git_hygiene() {
    local relative tracked=() exposed=()
    git_hygiene=violated

    if ! git -C "$install_root" rev-parse --git-dir >/dev/null 2>&1; then
        git_hygiene=unverifiable
        printf 'inventory git-hygiene=unverifiable reason=not-a-git-checkout root=%s\n' \
            "$install_root"
        return 0
    fi

    # `state/` and `hermes/` keep their trailing slash: .gitignore matches them
    # as directories, and `git check-ignore state` answers "not ignored" for a
    # directory that does not exist yet — which is exactly when this runs.
    for relative in .env runtime.env install.manifest roster.txt \
        hermes/notify.secret hermes/roster.secret hermes/ state/; do
        if git -C "$install_root" ls-files --error-unmatch -- "$relative" >/dev/null 2>&1; then
            tracked+=("$relative")
        elif ! git -C "$install_root" check-ignore -q -- "$relative"; then
            exposed+=("$relative")
        fi
    done

    if ((${#tracked[@]})); then
        for relative in "${tracked[@]}"; do
            printf 'inventory conflict-git-tracked=%s reason=runtime-path-is-tracked\n' "$relative"
        done
        inventory_conflicts=1
        inventory_blocked=1
    fi
    if ((${#exposed[@]})); then
        for relative in "${exposed[@]}"; do
            printf 'inventory conflict-git-exposed=%s reason=not-ignored\n' "$relative"
        done
        inventory_conflicts=1
        inventory_blocked=1
    fi
    if ((${#tracked[@]} == 0 && ${#exposed[@]} == 0)); then
        git_hygiene=clean
        printf 'inventory git-hygiene=clean root=%s\n' "$install_root"
    fi
}

# Move a pre-single-root install into the clone.
#
# Explicit and opt-in, because an upgrade that moved a running install on its
# own would be exactly the half-migration the resolver exists to prevent. What
# makes this safe is that it refuses far more readily than it acts: anything it
# cannot move cleanly stops the whole thing before the first rename, so a
# refusal leaves a working install rather than half of one.
#
# The UID baseline is the reason the state tree moves in one piece. Lose it and
# the listener either replays the mailbox or skips everything already delivered,
# and neither is visible from the outside.
plan_legacy_migration() {
    local legacy_config="$HOME/.config/agenteiamail"
    local legacy_state="$HOME/.local/state/agenteiamail"
    local source destination owner refusals=0

    migration_moves=()

    if ! agenteiamail_legacy_layout; then
        printf 'migrate result=nothing-to-do reason=already-single-root root=%s\n' "$install_root"
        return 0
    fi

    # Credentials first, and by their resolved name: an OpenClaw install from
    # before ~/.config existed keeps its file in the workspace, and it still has
    # to land at <clone>/.env.
    source=$(agenteiamail_env_file)
    [[ -e "$source" || -L "$source" ]] && migration_moves+=("$source"$'\t'"$install_root/.env")

    for source in "$legacy_config/runtime.env" "$legacy_config/install.manifest" \
        "$legacy_config/hermes"; do
        [[ -e "$source" || -L "$source" ]] || continue
        migration_moves+=("$source"$'\t'"$install_root/${source##*/}")
    done

    [[ -e "$legacy_state" || -L "$legacy_state" ]] && \
        migration_moves+=("$legacy_state"$'\t'"$install_root/state")

    if ((${#migration_moves[@]} == 0)); then
        printf 'migrate result=nothing-to-do reason=no-legacy-artifacts\n'
        return 0
    fi

    local entry
    for entry in "${migration_moves[@]}"; do
        IFS=$'\t' read -r source destination <<<"$entry"

        # A symlink is somebody's deliberate arrangement, and moving the link
        # rather than the file it points at silently changes what the install
        # reads. The operator resolves it; this does not guess.
        if [[ -L "$source" ]]; then
            printf 'migrate conflict-source=%s reason=symlink\n' "$source" >&2
            refusals=1
            continue
        fi
        owner=$(stat -Lc '%u' -- "$source" 2>/dev/null || true)
        if [[ "$owner" != "$EUID" ]]; then
            printf 'migrate conflict-source=%s reason=not-owned-by-caller\n' "$source" >&2
            refusals=1
            continue
        fi
        if [[ -e "$destination" || -L "$destination" ]]; then
            printf 'migrate conflict-destination=%s reason=already-exists\n' "$destination" >&2
            refusals=1
            continue
        fi
        printf 'migrate planned-move=%s to=%s\n' "$source" "$destination"
    done

    if ((refusals)); then
        return 1
    fi
    return 0
}

# The migration transaction.
#
# The first version moved each artifact with its own `mv` and, on a failure
# partway, exited saying the install was now split and had to be repaired by
# hand. On a live host that is credentials in one place and the UID baseline in
# another — the state that makes a mailbox go quiet without erroring anywhere.
#
# A reverse-`mv` rollback does not fix it: if the forward move failed because
# the filesystem was full or the rename crossed devices, the rollback fails for
# the same reason, at the same moment, with less of the install left.
#
# So nothing is moved. Everything is *copied* into a staging directory on the
# destination filesystem, validated there, and recorded in a durable manifest
# before anything is committed. The sources stay intact throughout, which makes
# the rollback a delete rather than a move — an operation that does not need
# space, and does not cross devices.
#
# There are exactly two states this can be interrupted in, and both are
# recoverable by rerunning --migrate:
#
#   before the first commit  the complete legacy install is still there; the
#                            transaction rolls back by deleting staging
#   after the first commit   every artifact exists in staging, so the remaining
#                            commits are replayed forward
#
# There is deliberately no third state, and no state in which a human is told to
# repair it themselves.
migration_staging() { printf '%s/.migrate-staging' "$install_root"; }
migration_transaction() { printf '%s/.migrate-transaction' "$install_root"; }

# The ordering lives in scripts/durable.py, with the reason for each step, and
# scripts/test_durable.py pins the sequence of calls. A rename is not durable
# because it returned: until the directory holding the new name is fsynced the
# kernel may persist a later unlink while losing the rename, which produces the
# split install by the one route the transaction did not model.
durable() {
    python3 "$ROOT/scripts/durable.py" "$@" || \
        die_config "could not make $2 durable; refusing to continue a migration that cannot survive a reboot"
}

# A test hook, in the same shape as AGENTEIAMAIL_TEST_INTERRUPT_AFTER. Failure
# has to be injectable at every commit boundary or the recovery paths are
# assertions about code nobody has run.
migration_fail_here() {
    [[ "${AGENTEIAMAIL_TEST_MIGRATE_FAIL_AT:-}" == "$1" ]] || return 1
    printf 'migrate test-injected-failure=%s\n' "$1" >&2
    return 0
}

# Slugs, so a staging directory holding `env` from the config dir and `env` from
# somewhere else cannot collide.
migration_slug() {
    printf '%s' "$1" | sed 's|^/||; s|/|__|g'
}

stage_legacy_migration() {
    local entry source destination staging slug staged index=0
    staging=$(migration_staging)

    rm -rf -- "$staging"
    mkdir -p -- "$staging"
    chmod 700 -- "$staging"

    for entry in "${migration_moves[@]}"; do
        IFS=$'\t' read -r source destination <<<"$entry"
        slug=$(migration_slug "$source")
        staged="$staging/$slug"

        if migration_fail_here "stage:$index"; then
            rm -rf -- "$staging"
            die_config "staging failed for $source; nothing was moved and the install is unchanged"
        fi

        # -a keeps mode, times and links. The copy lands on the destination
        # filesystem, so the commit below is a rename within one filesystem
        # rather than a copy that can run out of space halfway.
        if ! cp -a -- "$source" "$staged"; then
            rm -rf -- "$staging"
            die_config "could not stage $source; nothing was moved and the install is unchanged"
        fi

        # Validated before it is trusted. A short read or a truncated copy that
        # nobody compared is exactly the silent loss this is meant to prevent.
        if ! diff -r --no-dereference -- "$source" "$staged" >/dev/null 2>&1; then
            rm -rf -- "$staging"
            die_config "staged copy of $source does not match the original; nothing was moved"
        fi

        printf 'migrate staged=%s at=%s\n' "$source" "$staged"
        migration_staged+=("$source"$'\t'"$staged"$'\t'"$destination"$'\t'"$(migration_digest "$staged")")
        index=$((index + 1))
    done

    # Data before any name is trusted to refer to it.
    durable tree "$staging"
    durable dir "$install_root"
}

# Evidence, so a resume can revalidate rather than infer.
#
# Existence used to be treated as proof that a destination held the artifact
# committed there. It is not: a truncated copy, a stale staging tree, or a
# destination that merely exists all pass an existence check. This is a
# consistency check and not an authentication boundary — whoever can rewrite the
# destination can rewrite the digest beside it — but accidental corruption is the
# case that actually happens.
#
# Computed by scripts/tree_digest.py rather than here. The first version was a
# `find | xargs -I{} sh -c` pipeline, which substitutes each pathname into shell
# program text: a file named `"; touch PWNED; #` inside the state tree executed a
# command, and the state tree is a directory this migration copies wholesale.
# Filenames are data.
migration_digest() {
    python3 "$ROOT/scripts/tree_digest.py" "$1"
}

write_migration_transaction() {
    local phase=$1 entry unit transaction
    transaction=$(migration_transaction)
    {
        printf 'version\t2\n'
        printf 'phase\t%s\n' "$phase"
        printf 'root\t%s\n' "$install_root"
        # The set of units that were running before anything was stopped. It is
        # recorded here rather than held in a variable because the process that
        # has to put them back may not be the process that stopped them: an
        # interrupted run is resumed by a new one, and a variable does not
        # survive that. Restoring "whatever was running" is not good enough
        # either — a unit the operator had deliberately stopped must stay
        # stopped.
        for unit in "${migration_active_before[@]}"; do
            printf 'active\t%s\n' "$unit"
        done
        for entry in "${migration_staged[@]}"; do
            printf 'entry\t%s\n' "$entry"
        done
    } >"$transaction.tmp"
    chmod 600 -- "$transaction.tmp"
    durable file "$transaction.tmp"
    mv -- "$transaction.tmp" "$transaction"
    # The rename, not just the bytes. A manifest describing a commit that has
    # already started, which did not survive the crash that interrupted it, is
    # worse than no manifest — and this is why it happens before the services
    # are stopped rather than after.
    durable dir "$install_root"
}

read_migration_transaction() {
    local transaction line kind rest
    transaction=$(migration_transaction)
    migration_staged=()
    migration_active_before=()
    migration_phase=""
    [[ -f "$transaction" ]] || return 1
    while IFS= read -r line; do
        kind=${line%%$'\t'*}
        rest=${line#*$'\t'}
        case "$kind" in
            phase) migration_phase=$rest ;;
            active) migration_active_before+=("$rest") ;;
            entry) migration_staged+=("$rest") ;;
        esac
    done <"$transaction"
    return 0
}

# What is running right now, before anything stops it.
#
# Recorded rather than assumed, because the restore has to put back exactly this
# set and no more: a unit the operator had deliberately stopped must still be
# stopped afterwards, and "start everything" would quietly undo their decision.
record_active_units_before_stop() {
    local unit

    # Only ever recorded once, by the run that stops the services first.
    #
    # A resume reads this set back out of the transaction, and re-recording it
    # would ask a host whose services are *already stopped* what is running and
    # get the honest answer: nothing. The set would become empty, the resumed
    # commit would complete without restarting anything, and the migration would
    # report success over a silent mailbox — which is the state the whole
    # transaction exists to make unreachable. The EXIT trap cannot save this
    # either: after a real crash or power loss there was no trap to run.
    if ((${#migration_active_before[@]})); then
        for unit in "${migration_active_before[@]}"; do
            printf 'migrate active-before-stop=%s source=transaction\n' "$unit"
        done
        return 0
    fi

    migration_active_before=()
    [[ -n "$discovered_systemctl" ]] || return 0
    for unit in agenteiamail-idle.service agenteiamail-dispatch.service; do
        if "$discovered_systemctl" --user is-active --quiet "$unit" 2>/dev/null; then
            migration_active_before+=("$unit")
            printf 'migrate active-before-stop=%s\n' "$unit"
        else
            printf 'migrate inactive-before-stop=%s\n' "$unit"
        fi
    done
}

stop_services_for_migration() {
    local unit attempt active
    [[ -n "$discovered_systemctl" ]] || {
        printf 'migrate services=not-managed reason=no-systemctl\n'
        return 0
    }

    # From here on, any exit owes the operator their services back. The trap is
    # how that promise is kept on paths nobody remembered to write: a refusal
    # three functions deep still unwinds through it.
    migration_services_stopped=1

    for unit in agenteiamail-idle.service agenteiamail-dispatch.service; do
        "$discovered_systemctl" --user stop "$unit" >/dev/null 2>&1 || true
    done

    # The stop used to be `|| true` with nothing after it, under a comment
    # claiming the stop was what protected the move. It did not: a stop that
    # failed was indistinguishable from one that worked, and state was then
    # moved out from under a running listener holding it open. Ask.
    for unit in agenteiamail-idle.service agenteiamail-dispatch.service; do
        active=yes
        for attempt in 1 2 3 4 5 6 7 8 9 10; do
            if ! "$discovered_systemctl" --user is-active --quiet "$unit" 2>/dev/null; then
                active=no
                break
            fi
            sleep 1
        done
        if [[ "$active" == yes ]]; then
            # Says only what it knows. The services have already been asked to
            # stop by this point, so whether the install is "unchanged" is not
            # this line's to claim — the restore runs on the way out and reports
            # its own outcome, including when it fails.
            die_config "refusing to migrate: $unit is still active after stop; no artifact was moved"
        fi
        printf 'migrate stopped=%s state=inactive\n' "$unit"
    done
}

# Put back exactly what was running, and say so when it cannot.
#
# The previous version restored services on the success path only — where it was
# redundant, because converge_required_services already verifies is-active and
# dies otherwise — and was absent from every failure path, where it was the only
# thing that could have helped. A rollback left the listener and the dispatcher
# stopped while printing "the install is unchanged". The files were indeed
# unchanged. The mail had stopped, and the tool had just told the operator
# everything was fine.
restore_pre_stop_services() {
    local unit attempt active
    local -a unrestored=()

    ((migration_services_stopped)) || return 0
    [[ -n "$discovered_systemctl" ]] || return 0
    migration_services_stopped=0

    "$discovered_systemctl" --user daemon-reload >/dev/null 2>&1 || true

    for unit in "${migration_active_before[@]}"; do
        "$discovered_systemctl" --user start "$unit" >/dev/null 2>&1 || true
        active=no
        for attempt in 1 2 3 4 5; do
            if "$discovered_systemctl" --user is-active --quiet "$unit" 2>/dev/null; then
                active=yes
                break
            fi
            sleep 1
        done
        if [[ "$active" == yes ]]; then
            printf 'migrate restored=%s state=active\n' "$unit"
        else
            printf 'migrate restore-failed=%s state=inactive\n' "$unit" >&2
            unrestored+=("$unit")
        fi
    done

    if ((${#unrestored[@]})); then
        # Loud, and never folded into a success. The transaction is kept on
        # purpose: it is what a retry needs, and a host with mail stopped must
        # not read as finished.
        for unit in "${unrestored[@]}"; do
            printf 'install: %s could not be restarted and remains inactive; no mail is being detected\n' \
                "$unit" >&2
        done
        printf 'install: the migration transaction was kept so this can be retried; rerun --migrate\n' >&2
        return 1
    fi
    return 0
}

# Every exit after a stop attempt unwinds through here, including the ones
# nobody remembered to write.
migration_exit_restore() {
    local status=$?
    if ((migration_services_stopped)); then
        if ! restore_pre_stop_services; then
            ((status)) || status=1
        fi
    fi
    exit "$status"
}

commit_legacy_migration() {
    local entry source staged destination digest index=0

    for entry in "${migration_staged[@]}"; do
        IFS=$'\t' read -r source staged destination digest <<<"$entry"

        if [[ -e "$destination" || -L "$destination" ]]; then
            # Committed by an interrupted run. Replaying forward is the point of
            # the manifest — but existence is not proof it is the right artifact,
            # so it is checked rather than assumed.
            printf 'migrate already-committed=%s\n' "$destination"
        else
            if migration_fail_here "commit:$index"; then
                die_config "commit interrupted at $destination; rerun --migrate to finish, every artifact is still staged"
            fi
            mv -- "$staged" "$destination" || \
                die_config "commit failed at $destination; rerun --migrate to finish, every artifact is still staged"
            # The destination's parent, before any source is unlinked below. If
            # the unlink outlives the rename across a reboot, the artifact is
            # gone from both places.
            durable dir "$(dirname -- "$destination")"
            printf 'migrate committed=%s\n' "$destination"
        fi
        index=$((index + 1))
    done

    # Sources go last, and only once every destination exists and has been
    # proven. Until this loop the host holds two complete copies, which is what
    # makes both recovery directions possible.
    index=0
    for entry in "${migration_staged[@]}"; do
        IFS=$'\t' read -r source staged destination digest <<<"$entry"
        if migration_fail_here "cleanup:$index"; then
            die_config "cleanup interrupted at $source; rerun --migrate to finish, the new install is complete"
        fi
        if [[ -e "$source" || -L "$source" ]]; then
            rm -rf -- "$source"
            # After the unlink, so a reboot cannot resurrect a legacy entry that
            # was deleted and leave the host reading as legacy again.
            durable dir "$(dirname -- "$source")"
        fi
        index=$((index + 1))
    done

    rmdir -- "$HOME/.config/agenteiamail" 2>/dev/null || true
    rmdir -- "$HOME/.local/state/agenteiamail" 2>/dev/null || true
    rm -rf -- "$(migration_staging)"
    rm -f -- "$(migration_transaction)"
    # Last, before success is reported: a reboot must not resurrect a
    # transaction that already finished, because a manifest describing a
    # completed migration sends the next run back into resume.
    durable dir "$install_root"
}

rollback_legacy_migration() {
    # Only ever called before the first commit, where the sources are untouched
    # and staging is a copy. Deleting a copy needs no space and crosses no
    # device, which is why the transaction is built this way round.
    rm -rf -- "$(migration_staging)"
    rm -f -- "$(migration_transaction)"
    durable dir "$install_root"
    printf 'migrate result=rolled-back reason=no-artifact-was-committed\n'
}

# Every committed destination and every surviving staged copy is what the
# transaction says it is.
#
# Resume used to treat a destination's existence as proof it held the committed
# artifact. It does not: a truncated copy, a stale staging tree, or a
# destination that merely exists all pass an existence check. This is a
# consistency check rather than an authentication boundary — whoever can rewrite
# the destination can rewrite the digest beside it — but accidental corruption
# is the case that actually happens, and it fails closed.
validate_migration_evidence() {
    local entry source staged destination digest actual index=0 mismatches=0

    for entry in "${migration_staged[@]}"; do
        IFS=$'\t' read -r source staged destination digest <<<"$entry"

        if [[ -e "$destination" || -L "$destination" ]]; then
            actual=$(migration_digest "$destination")
            if [[ "$actual" != "$digest" ]]; then
                printf 'migrate conflict-destination=%s reason=does-not-match-committed-artifact\n' \
                    "$destination" >&2
                mismatches=1
            else
                printf 'migrate revalidated=%s state=committed\n' "$destination"
            fi
        elif [[ -e "$staged" || -L "$staged" ]]; then
            actual=$(migration_digest "$staged")
            if [[ "$actual" != "$digest" ]]; then
                printf 'migrate conflict-staged=%s reason=staged-copy-changed-since-it-was-recorded\n' \
                    "$staged" >&2
                mismatches=1
            else
                printf 'migrate revalidated=%s state=staged\n' "$staged"
            fi
        else
            printf 'migrate conflict-missing=%s reason=neither-destination-nor-staged-copy-exists\n' \
                "$destination" >&2
            mismatches=1
        fi
        index=$((index + 1))
    done

    if ((mismatches)); then
        # Nothing is deleted and the manifest is kept. A host that cannot be
        # proven consistent is one a human should look at, not one this should
        # tidy up.
        die_config 'refusing to continue: the migration transaction no longer matches what is on disk; every copy and the transaction manifest have been left in place'
    fi
}

# Rerunning --migrate on a host with a transaction manifest. Decides forward or
# back by looking at what is actually on disk, not at what the manifest hoped.
resume_legacy_migration() {
    local entry source staged destination digest committed=0

    for entry in "${migration_staged[@]}"; do
        IFS=$'\t' read -r source staged destination digest <<<"$entry"
        if [[ -e "$destination" || -L "$destination" ]]; then
            committed=1
            break
        fi
    done

    if ((committed == 0)); then
        printf 'migrate resume=rollback reason=nothing-committed\n'
        rollback_legacy_migration
        return 1
    fi

    printf 'migrate resume=forward reason=partially-committed\n'
    # Before the stop, so a refusal here does not have to put services back.
    validate_migration_evidence
    # read_migration_transaction already populated migration_active_before from
    # the manifest. record_active_units_before_stop keeps it rather than asking
    # a host whose services this migration already stopped.
    record_active_units_before_stop
    write_migration_transaction committing
    stop_services_for_migration
    commit_legacy_migration
    return 0
}

perform_legacy_migration() {
    ((${#migration_staged[@]})) || return 0

    # Recorded before the manifest is written, so the set of units to put back
    # is durable before anything is stopped rather than after.
    record_active_units_before_stop
    write_migration_transaction staged
    stop_services_for_migration
    commit_legacy_migration

    if agenteiamail_legacy_layout; then
        die_config 'migration committed every artifact but the host still resolves as a legacy install; refusing to converge a split install'
    fi

    # The resolver answers differently now, so every derived path is stale.
    set_managed_paths
    printf 'migrate result=moved root=%s\n' "$install_root"
    changes_made=1
}

plan_has_changes() {
    if [[ "$mode" == uninstall ]]; then
        [[ -e "$manifest" || -L "$manifest" ]]
        return
    fi
    ((inventory_changes))
}

create_secure_containers() {
    umask 077
    # The state tree is created here rather than left to the services. systemd
    # does not create the parent of a StandardOutput=append: path — it fails the
    # unit — so an install that converged the units and enabled them would leave
    # both services dead on a host where nobody had run mkdir by hand.
    mkdir -p -- "$unit_dir" "$config_dir" "$state_dir"
    validate_container_chain "$unit_dir" >/dev/null || die_config "unsafe unit container after creation: $unit_dir"
    validate_container_chain "$config_dir" >/dev/null || die_config "unsafe config container after creation: $config_dir"
    validate_container_chain "$state_dir" >/dev/null || die_config "unsafe state container after creation: $state_dir"
    if [[ "$runtime" == hermes && -z "$notify_secret_file" ]]; then
        mkdir -p -- "$hermes_dir"
        validate_container_chain "$hermes_dir" >/dev/null || \
            die_config "unsafe Hermes secret container after creation: $hermes_dir"
    fi
}

converge_artifact() {
    local kind=$1 destination=$2 source=$3 file_mode=$4 expected="" actual desired digest output current_mode
    expected=${owned_digests[$destination]:-}
    desired=$(sha256_desired "$destination" "$source")
    if [[ -e "$destination" && -n "$expected" ]]; then
        actual=$(sha256_file "$destination")
        current_mode=$(stat -Lc '%a' -- "$destination" 2>/dev/null || true)
        if [[ "$actual" == "$desired" && "$actual" == "$expected" &&
              "$current_mode" == "${file_mode#0}" ]]; then
            return
        fi
    fi
    if ! output=$(render_artifact "$destination" "$source" | python3         "$ROOT/scripts/install_manifest.py" write-artifact --path "$destination"         --mode "$file_mode" --expected-digest "$expected" 2>&1); then
        printf '%s
' "$output" >&2
        exit "$EX_CONFIG"
    fi
    digest=${output##*$'
'}
    write_count=$((write_count + 1))
    if [[ "${AGENTEIAMAIL_TEST_INTERRUPT_AFTER_WRITE:-}" == "$write_count" ]]; then
        printf 'install: test interruption after artifact creation before ownership record %d\n' \
            "$write_count" >&2
        exit 99
    fi
    local -a arguments=()
    mapfile -d '' -t arguments < <(manifest_arguments)
    if ! output=$(python3 "$ROOT/scripts/install_manifest.py" record "${arguments[@]}"         --kind "$kind" --path "$destination" --digest "$digest" 2>&1); then
        printf '%s
' "$output" >&2
        exit "$EX_CONFIG"
    fi
    owned_digests["$destination"]=$digest
    changes_made=1
    runtime_filesystem_changed=1
    mutation_count=$((mutation_count + 1))
    if [[ "${AGENTEIAMAIL_TEST_INTERRUPT_AFTER:-}" == "$mutation_count" ]]; then
        printf 'install: test interruption after artifact %d
' "$mutation_count" >&2
        exit 99
    fi
}

deactivate_owned_services() {
    local unit unit_path changed=0
    if [[ -z "$discovered_systemctl" ]]; then
        printf 'install: warning: systemd user manager unavailable; service deactivation unconfirmed.\n' >&2
        return 0
    fi
    for unit in agenteiamail-idle.service agenteiamail-dispatch.service \
        agenteiamail-logrotate.timer; do
        unit_path="$unit_dir/$unit"
        [[ -n "${owned_digests[$unit_path]+present}" ]] || continue
        if "$discovered_systemctl" --user is-enabled --quiet "$unit" 2>/dev/null ||
           "$discovered_systemctl" --user is-active --quiet "$unit" 2>/dev/null; then
            "$discovered_systemctl" --user disable --now "$unit" || \
                die_config "failed to disable owned user unit $unit; filesystem preserved"
            changed=1
        fi
        if "$discovered_systemctl" --user is-enabled --quiet "$unit" 2>/dev/null ||
           "$discovered_systemctl" --user is-active --quiet "$unit" 2>/dev/null; then
            die_config "owned user unit $unit remained enabled or active; filesystem preserved"
        fi
    done
    ((changed == 0)) || changes_made=1
}

uninstall_owned_filesystem() {
    local destination output
    local -a arguments=()
    set_managed_paths
    validate_container_chain "$config_dir" >/dev/null || \
        die_config "unsafe config container during uninstall: $config_dir"
    if [[ ! -e "$manifest" && ! -L "$manifest" ]]; then
        return
    fi
    load_ownership_manifest
    # Validate every durable ownership record before the first service or
    # filesystem mutation. A late modified artifact must not leave a half-
    # uninstalled runtime boundary.
    for destination in "${managed_paths[@]}"; do
        [[ -n "${owned_digests[$destination]+present}" ]] || continue
        validate_container_chain "${destination%/*}" >/dev/null || \
            die_config "unsafe artifact container during uninstall: ${destination%/*}"
        if [[ -d "${destination%/*}" ]]; then
            if ! output=$(python3 "$ROOT/scripts/install_manifest.py" verify-artifact \
                --path "$destination" --expected-digest "${owned_digests[$destination]}" 2>&1); then
                printf '%s\n' "$output" >&2
                exit "$EX_CONFIG"
            fi
        fi
    done
    deactivate_owned_services
    for destination in "${managed_paths[@]}"; do
        [[ -n "${owned_digests[$destination]+present}" ]] || continue
        validate_container_chain "${destination%/*}" >/dev/null || \
            die_config "unsafe artifact container during uninstall: ${destination%/*}"
        if [[ -d "${destination%/*}" ]]; then
            if ! output=$(python3 "$ROOT/scripts/install_manifest.py" remove-artifact \
                --path "$destination" --expected-digest "${owned_digests[$destination]}" 2>&1); then
                printf '%s\n' "$output" >&2
                exit "$EX_CONFIG"
            fi
        fi
        mapfile -d '' -t arguments < <(manifest_arguments)
        if ! output=$(python3 "$ROOT/scripts/install_manifest.py" forget "${arguments[@]}" \
            --path "$destination" 2>&1); then
            printf '%s\n' "$output" >&2
            exit "$EX_CONFIG"
        fi
        unset 'owned_digests[$destination]'
        changes_made=1
    done
    mapfile -d '' -t arguments < <(manifest_arguments)
    if ! output=$(python3 "$ROOT/scripts/install_manifest.py" finalize "${arguments[@]}" 2>&1); then
        printf '%s\n' "$output" >&2
        exit "$EX_CONFIG"
    fi
    changes_made=1
    if [[ -n "$discovered_systemctl" ]]; then
        "$discovered_systemctl" --user daemon-reload || \
            die_config 'filesystem removed, but systemctl --user daemon-reload failed; rerun daemon-reload manually'
    fi
}

initialize_ownership_manifest() {
    local output
    create_secure_containers
    local -a arguments=()
    mapfile -d '' -t arguments < <(manifest_arguments)
    if ! output=$(python3 "$ROOT/scripts/install_manifest.py" init "${arguments[@]}" 2>&1); then
        printf '%s
' "$output" >&2
        exit "$EX_CONFIG"
    fi
    load_ownership_manifest
}

converge_runtime_filesystem() {
    local unit
    for unit in agenteiamail-idle.service agenteiamail-dispatch.service         agenteiamail-logrotate.service agenteiamail-logrotate.timer; do
        converge_artifact file "$unit_dir/$unit" "$ROOT/systemd/$unit" 0644
    done
    converge_artifact file "$config_dir/runtime.env" generated-runtime-config 0600
}

converge_generated_secret() {
    local label=$1 destination=$2 expected actual secret_value output digest
    expected=${owned_digests[$destination]:-}
    if [[ -e "$destination" && -n "$expected" ]]; then
        actual=$(sha256_file "$destination")
        if [[ "$actual" == "$expected" ]]; then
            return
        fi
        die_config "owned Hermes $label secret changed outside the installer: $destination"
    fi
    [[ ! -e "$destination" && ! -L "$destination" ]] || \
        die_config "unowned Hermes $label secret is preserved; move it aside before retrying: $destination"
    secret_value=$("$discovered_python" -c 'import secrets; print(secrets.token_urlsafe(32))')
    if ! output=$(printf '%s\n' "$secret_value" | \
        "$discovered_python" "$ROOT/scripts/install_manifest.py" write-artifact \
        --path "$destination" --mode 0600 --expected-digest '' 2>&1); then
        printf '%s\n' "$output" >&2
        exit "$EX_CONFIG"
    fi
    digest=${output##*$'\n'}
    write_count=$((write_count + 1))
    local -a arguments=()
    mapfile -d '' -t arguments < <(manifest_arguments)
    if ! output=$("$discovered_python" "$ROOT/scripts/install_manifest.py" record \
        "${arguments[@]}" --kind secret --path "$destination" --digest "$digest" 2>&1); then
        printf '%s\n' "$output" >&2
        exit "$EX_CONFIG"
    fi
    owned_digests["$destination"]=$digest
    changes_made=1
    mutation_count=$((mutation_count + 1))
    generated_secrets=1
    printf 'hermes_%s_secret=%s\n' "$label" "$secret_value"
    secret_value=''
}

print_hermes_route_guidance() {
    local quoted
    if [[ -n "$profile" ]]; then
        printf -v quoted '%q' "$profile"
        printf 'hermes_route_guidance=existing-profile profile=%s edits_hermes_config=false\n' \
            "$quoted"
    elif [[ -n "$deliver" ]]; then
        local quoted_deliver quoted_chat
        printf -v quoted_deliver '%q' "$deliver"
        printf -v quoted_chat '%q' "$chat_id"
        printf 'hermes_route_guidance=guided-only delivery_target=%s chat_id=%s edits_hermes_config=false\n' \
            "$quoted_deliver" "$quoted_chat"
    else
        printf 'hermes_route_guidance=operator-selection-required edits_hermes_config=false\n'
    fi
}

prepare_hermes_secrets() {
    generated_secrets=0
    print_hermes_route_guidance
    if [[ -n "$notify_secret_file" ]]; then
        return
    fi
    converge_generated_secret notify "$hermes_dir/notify.secret"
    converge_generated_secret roster "$hermes_dir/roster.secret"
    notify_secret_file="$hermes_dir/notify.secret"
    roster_secret_file="$hermes_dir/roster.secret"
    if ((generated_secrets)); then
        printf '%s\n' \
            'install: configure the two Hermes routes with the newly shown secrets, then rerun the installer; services were not activated' >&2
        exit "$EX_CONFIG"
    fi
}

probe_hermes_webhook_support() {
    local output
    if ! output=$("$discovered_runtime_cli" webhook --help 2>&1); then
        printf '%s\n' "$output" >&2
        die_config 'Hermes webhook support is unavailable; install a V2-capable Hermes release'
    fi
    printf 'hermes_webhook_probe=accepted executable=%s\n' "$discovered_runtime_cli"
}

probe_hermes_routes() {
    HERMES_NOTIFY_SECRET_FILE="$notify_secret_file" \
    HERMES_ROSTER_SECRET_FILE="$roster_secret_file" \
    HERMES_SIGNATURE_MODE=v2 \
    "$discovered_python" "$ROOT/scripts/hermes_smoke.py"
}

verify_installed_units() {
    local systemd_analyze output
    systemd_analyze=$(resolve_command systemd-analyze || true)
    [[ -n "$systemd_analyze" ]] || \
        die_config 'systemd-analyze executable not found; installed units were not activated'
    if ! output=$("$systemd_analyze" verify \
        "$unit_dir/agenteiamail-idle.service" \
        "$unit_dir/agenteiamail-dispatch.service" \
        "$unit_dir/agenteiamail-logrotate.service" \
        "$unit_dir/agenteiamail-logrotate.timer" 2>&1); then
        printf '%s\n' "$output" >&2
        die_config 'systemd-analyze verify rejected the installed units; no service state was changed'
    fi
}

probe_openclaw_service_environment() {
    local systemd_run output
    systemd_run=$(resolve_command systemd-run || true)
    [[ -n "$systemd_run" ]] || \
        die_config 'systemd-run executable not found; cannot execute OpenClaw in the systemd user environment'
    if ! output=$("$systemd_run" --user --pipe --quiet --wait \
        "$discovered_runtime_cli" --version 2>&1); then
        printf '%s\n' "$output" >&2
        die_config 'OpenClaw is present but cannot run in the systemd user service environment'
    fi
    printf 'openclaw_service_probe=accepted executable=%s\n' "$discovered_runtime_cli"
}

print_final_verification_report() {
    local unit label secret_path secret_mode
    printf 'verification_report_begin\n'
    printf 'verification_runtime=%s\n' "$runtime"
    for unit in agenteiamail-idle.service agenteiamail-dispatch.service \
        agenteiamail-logrotate.service agenteiamail-logrotate.timer; do
        printf 'verification_unit=%s/%s validated=true\n' "$unit_dir" "$unit"
    done
    if [[ "$runtime" == hermes ]]; then
        for label in notify roster; do
            if [[ "$label" == notify ]]; then
                secret_path=$notify_secret_file
            else
                secret_path=$roster_secret_file
            fi
            [[ -f "$secret_path" && ! -L "$secret_path" && -O "$secret_path" ]] || \
                die_config "final verification rejected unsafe $label secret path: $secret_path"
            secret_mode=$(stat -Lc '%a' -- "$secret_path" 2>/dev/null || true)
            [[ "$secret_mode" == 600 ]] || \
                die_config "final verification requires mode 0600 for $label secret: $secret_path"
            printf 'verification_secret=%s path=%s mode=0600 validated=true\n' \
                "$label" "$secret_path"
        done
        printf 'verification_smoke=health result=accepted scope=reachability-only\n'
        printf 'verification_smoke=notify-email.received result=delivered\n'
        printf 'verification_smoke=notify-listener.error result=delivered\n'
        printf 'verification_smoke=roster-email.received result=accepted completion=unconfirmed\n'
    else
        printf 'verification_secret=not-applicable runtime=openclaw\n'
        printf 'verification_smoke=openclaw-service-environment result=accepted\n'
    fi
    # The hygiene state reaches the final report, not only the inventory stream.
    # It used to be printed once, mid-inventory, while the report still ended
    # `result=passed` — so "could not check" and "checked and clean" were
    # distinguishable to a human reading every line and to nothing else: not the
    # caller, not the exit status, not the report. A control nobody verified is
    # not a control that passed.
    printf 'verification_git_hygiene=%s root=%s\n' "$git_hygiene" "$install_root"
    case "$git_hygiene" in
        clean)
            printf 'verification_report_end result=passed\n'
            ;;
        unverifiable)
            printf 'verification_report_end result=passed-with-unverified-control control=git-hygiene\n'
            ;;
        *)
            die_config 'final verification reached an install whose git hygiene was never established'
            ;;
    esac
}

converge_required_services() {
    local unit
    "$discovered_systemctl" --user daemon-reload || \
        die_config 'systemctl --user daemon-reload failed; no service was enabled'
    for unit in agenteiamail-idle.service agenteiamail-dispatch.service \
        agenteiamail-logrotate.timer; do
        if "$discovered_systemctl" --user is-enabled --quiet "$unit" && \
           "$discovered_systemctl" --user is-active --quiet "$unit"; then
            if ((runtime_filesystem_changed)); then
                "$discovered_systemctl" --user restart "$unit" || \
                    die_config "failed to restart changed required user unit: $unit"
                if ! "$discovered_systemctl" --user is-active --quiet "$unit"; then
                    die_config "restarted required user unit did not remain active: $unit"
                fi
                printf 'service=%s state=enabled-active restarted=true\n' "$unit"
                continue
            fi
            printf 'service=%s state=enabled-active\n' "$unit"
            continue
        fi
        "$discovered_systemctl" --user enable --now "$unit" || \
            die_config "failed to enable and start required user unit: $unit"
        if ! "$discovered_systemctl" --user is-enabled --quiet "$unit" || \
           ! "$discovered_systemctl" --user is-active --quiet "$unit"; then
            die_config "required user unit did not become enabled and active: $unit"
        fi
        printf 'service=%s state=enabled-active changed=true\n' "$unit"
        changes_made=1
    done
}

runtime=""
deliver=""
chat_id=""
profile=""
notify_secret_file=""
roster_secret_file=""
mode="install"
# Tri-state, defaulting to the pessimistic end: `violated` until something
# actually checks. An unset-or-empty variable read as "fine" is the failure this
# whole tri-state exists to remove.
git_hygiene=violated
upgrade=0
uninstall=0
migrate=0
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
        --migrate)
            mark_option_once "$1"
            migrate=1
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

if ((upgrade + uninstall + migrate > 1)); then
    die_usage '--upgrade, --migrate and --uninstall are mutually exclusive'
elif ((upgrade)); then
    mode="upgrade"
elif ((uninstall)); then
    mode="uninstall"
elif ((migrate)); then
    mode="migrate"
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
for value in "$deliver" "$chat_id" "$profile"; do
    [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || \
        die_usage 'Hermes delivery and profile labels must be single-line values'
done
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

if ! discover_prerequisites; then
    exit "$EX_CONFIG"
fi

# Before the ordinary inventory, because a migration changes what every path in
# that inventory resolves to. Placed ahead of the dry-run branch so
# `--migrate --dry-run` reports the moves rather than the convergence plan.
changes_made=0
migration_moves=()
migration_staged=()
migration_active_before=()
migration_phase=""
migration_services_stopped=0

# Armed before anything can stop a service. Every exit after a stop attempt
# unwinds through this, which is what makes the restore cover the refusal paths
# nobody remembered to write rather than only the ones somebody did.
trap migration_exit_restore EXIT

set_managed_paths
# An outstanding transaction means the host is mid-migration. Every path this
# installer would resolve is a guess until it finishes, so nothing else runs:
# converging units against a half-committed layout is how the units and the
# session hook end up disagreeing, which reads as a quiet mailbox.
if [[ -f "$(migration_transaction)" && "$mode" != migrate ]]; then
    printf 'install: an unfinished migration transaction exists at %s\n' \
        "$(migration_transaction)" >&2
    printf 'install: rerun with --migrate to finish or roll it back; no other mode is safe until then\n' >&2
    exit "$EX_CONFIG"
fi

if [[ "$mode" == migrate ]]; then
    if read_migration_transaction; then
        printf 'migrate transaction=found phase=%s entries=%d\n' \
            "$migration_phase" "${#migration_staged[@]}"
        # A transaction recording an active set means an earlier run stopped
        # those units. That run may have died without its trap running — power
        # loss, SIGKILL — so this one owes the restore, on the rollback path as
        # much as the forward one. Starting a unit that is already running is a
        # no-op, so arming this unconditionally is safe and forgetting to arm it
        # is not.
        if ((${#migration_active_before[@]})); then
            migration_services_stopped=1
        fi
        if ((dry_run)); then
            printf 'dry-run: an unfinished migration transaction exists; rerun without --dry-run to resolve it.\n'
            exit "$EX_CHANGED"
        fi
        if resume_legacy_migration; then
            set_managed_paths
            changes_made=1
            mode=upgrade
        else
            # "Unchanged" was a lie in the way that matters: the files were
            # unchanged and the services were still stopped, so the mailbox had
            # gone quiet while this line said everything was fine. The restore
            # runs on the way out, and says so itself if it cannot.
            printf 'install: migration rolled back; no artifact was committed and the previous layout is intact.\n'
            exit "$EX_CHANGED"
        fi
    else
        if ! plan_legacy_migration; then
            die_config 'migration refused; nothing was moved'
        fi
        if ((dry_run)); then
            if ((${#migration_moves[@]})); then
                printf 'dry-run: migration plan contains move actions; no changes made.\n'
                exit "$EX_CHANGED"
            fi
            printf 'dry-run: nothing to migrate.\n'
            exit "$EX_OK"
        fi
        if ((${#migration_moves[@]})); then
            stage_legacy_migration
            perform_legacy_migration
        fi
        # Converge from here on as an upgrade: the artifacts exist and are
        # owned, they are just in a new place and the units still name the old
        # one.
        mode=upgrade
    fi
fi

if ((dry_run)); then
    print_managed_inventory
    if ((inventory_conflicts || inventory_blocked)); then
        if ((inventory_unproven_conflicts)); then
            printf 'install: unproven pre-existing artifacts are preserved; ownership manifest support is required before mutation\n' >&2
        fi
        if ((inventory_blocked)); then
            for blocked_detail in "${inventory_blocked_details[@]}"; do
                IFS=$'\t' read -r blocked_container blocked_reason <<<"$blocked_detail"
                case "$blocked_reason" in
                    group-or-world-writable)
                        printf 'install: unsafe managed container %s reason=%s; run: chmod go-w -- %q\n' \
                            "$blocked_container" "$blocked_reason" "$blocked_container" >&2
                        ;;
                    symlink)
                        printf 'install: unsafe managed container %s reason=%s; replace the symlink with a user-owned directory before retrying\n' \
                            "$blocked_container" "$blocked_reason" >&2
                        ;;
                    not-directory)
                        printf 'install: unsafe managed container %s reason=%s; replace it with a user-owned directory before retrying\n' \
                            "$blocked_container" "$blocked_reason" >&2
                        ;;
                    unsafe-owner-or-metadata)
                        printf 'install: unsafe managed container %s reason=%s; verify user ownership and readable metadata before retrying\n' \
                            "$blocked_container" "$blocked_reason" >&2
                        ;;
                    *)
                        printf 'install: unsafe managed container %s reason=%s; correct the container path before retrying\n' \
                            "$blocked_container" "$blocked_reason" >&2
                        ;;
                esac
            done
        fi
        exit "$EX_CONFIG"
    fi
    if plan_has_changes; then
        printf 'dry-run: plan contains create, modify, or remove actions; no changes made.\n'
        exit "$EX_CHANGED"
    fi
    printf 'dry-run: system is converged; no changes needed.\n'
    exit "$EX_OK"
fi

if [[ "$mode" == uninstall ]]; then
    changes_made=0
    uninstall_owned_filesystem
    if ((changes_made)); then
        printf 'install: owned services deactivated when reachable and recorded artifacts removed; credentials and state preserved.\n'
        exit "$EX_CHANGED"
    fi
    printf 'install: no ownership manifest; no filesystem artifacts removed.\n'
    exit "$EX_OK"
fi

print_managed_inventory
if ((inventory_conflicts || inventory_blocked)); then
    die_config 'filesystem convergence refused because managed inventory is unsafe or unowned'
fi
mutation_count=0
write_count=0
runtime_filesystem_changed=0
if [[ "$runtime" == hermes ]]; then
    probe_hermes_webhook_support
fi
migrate_ownership_manifest
initialize_ownership_manifest
if [[ "$runtime" == hermes ]]; then
    prepare_hermes_secrets
fi
converge_runtime_filesystem
verify_installed_units
if [[ "$runtime" == openclaw ]]; then
    probe_openclaw_service_environment
else
    probe_hermes_routes
fi
converge_required_services
print_final_verification_report
if ((changes_made)); then
    printf 'install: %s artifacts and required user services converged.\n' "$runtime"
    exit "$EX_CHANGED"
fi
printf 'install: %s artifacts and required user services already converged.\n' "$runtime"
exit "$EX_OK"
