#!/bin/bash
# Mole - Clean command.
# Runs cleanup modules with optional sudo.
# Supports dry-run and whitelist.

set -euo pipefail

export LC_ALL=C
export LANG=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/core/common.sh"
source "$SCRIPT_DIR/../lib/core/machine_output.sh"

source "$SCRIPT_DIR/../lib/core/sudo.sh"
source "$SCRIPT_DIR/../lib/clean/brew.sh"
source "$SCRIPT_DIR/../lib/clean/caches.sh"
source "$SCRIPT_DIR/../lib/clean/apps.sh"
source "$SCRIPT_DIR/../lib/clean/dev.sh"
source "$SCRIPT_DIR/../lib/clean/app_caches.sh"
source "$SCRIPT_DIR/../lib/clean/hints.sh"
source "$SCRIPT_DIR/../lib/clean/registry.sh"
source "$SCRIPT_DIR/../lib/clean/step_helpers.sh"
source "$SCRIPT_DIR/../lib/clean/system.sh"
source "$SCRIPT_DIR/../lib/clean/user.sh"

SYSTEM_CLEAN=false
DRY_RUN=false
PROTECT_FINDER_METADATA=false
EXTERNAL_VOLUME_TARGET=""
IS_M_SERIES=$([[ "$(uname -m)" == "arm64" ]] && echo "true" || echo "false")
MOLE_CLI_VERSION=$(sed -n 's/^VERSION="\(.*\)"$/\1/p' "$SCRIPT_DIR/../mole" | head -1)
MOLE_INTERFACE="human"
MOLE_OUTPUT_MODE="execute"
MOLE_SCOPE="all"
MOLE_SCOPE_EFFECTIVE="all"
MOLE_SELECTED_STEPS_CSV=""
MOLE_BLOCKING_POLICY="skip"
MOLE_EVENTS_FILE=""
MOLE_SUMMARY_FILE=""
MOLE_PLAN_FILE=""
MOLE_RUN_ID=""
MOLE_ITEM_EVENTS="grouped"
MOLE_MACHINE_SILENT_STDIO=0
declare -a MOLE_SELECTED_STEP_RECORDS=()
declare -a MOLE_SELECTED_SECTION_IDS=()
declare -a MOLE_REQUIRED_CAPABILITY_ERRORS=()

EXPORT_LIST_FILE="$HOME/.config/mole/clean-list.txt"
CURRENT_SECTION=""
readonly PROTECTED_SW_DOMAINS=(
    # Web editors
    "capcut.com"
    "photopea.com"
    "pixlr.com"
    # Google Workspace (offline mode)
    "docs.google.com"
    "sheets.google.com"
    "slides.google.com"
    "drive.google.com"
    "mail.google.com"
    # Code platforms (offline/PWA)
    "github.com"
    "gitlab.com"
    "codepen.io"
    "codesandbox.io"
    "replit.com"
    "stackblitz.com"
    # Collaboration tools (offline/PWA)
    "notion.so"
    "figma.com"
    "linear.app"
    "excalidraw.com"
)

declare -a WHITELIST_PATTERNS=()
WHITELIST_WARNINGS=()
if [[ -f "$HOME/.config/mole/whitelist" ]]; then
    while IFS= read -r line; do
        # shellcheck disable=SC2295
        line="${line#"${line%%[![:space:]]*}"}"
        # shellcheck disable=SC2295
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" || "$line" =~ ^# ]] && continue

        [[ "$line" == ~* ]] && line="${line/#~/$HOME}"
        line="${line//\$HOME/$HOME}"
        line="${line//\$\{HOME\}/$HOME}"
        if [[ "$line" =~ \.\. ]]; then
            WHITELIST_WARNINGS+=("Path traversal not allowed: $line")
            continue
        fi

        if [[ "$line" != "$FINDER_METADATA_SENTINEL" ]]; then
            if [[ ! "$line" =~ ^[a-zA-Z0-9/_.@\ *-]+$ ]]; then
                WHITELIST_WARNINGS+=("Invalid path format: $line")
                continue
            fi

            if [[ "$line" != /* ]]; then
                WHITELIST_WARNINGS+=("Must be absolute path: $line")
                continue
            fi
        fi

        if [[ "$line" =~ // ]]; then
            WHITELIST_WARNINGS+=("Consecutive slashes: $line")
            continue
        fi

        case "$line" in
            / | /System | /System/* | /bin | /bin/* | /sbin | /sbin/* | /usr/bin | /usr/bin/* | /usr/sbin | /usr/sbin/* | /etc | /etc/* | /var/db | /var/db/*)
                WHITELIST_WARNINGS+=("Protected system path: $line")
                continue
                ;;
        esac

        duplicate="false"
        if [[ ${#WHITELIST_PATTERNS[@]} -gt 0 ]]; then
            for existing in "${WHITELIST_PATTERNS[@]}"; do
                if [[ "$line" == "$existing" ]]; then
                    duplicate="true"
                    break
                fi
            done
        fi
        [[ "$duplicate" == "true" ]] && continue
        WHITELIST_PATTERNS+=("$line")
    done < "$HOME/.config/mole/whitelist"
else
    WHITELIST_PATTERNS=("${DEFAULT_WHITELIST_PATTERNS[@]}")
fi

# Expand whitelist patterns once to avoid repeated tilde expansion in hot loops.
expand_whitelist_patterns() {
    if [[ ${#WHITELIST_PATTERNS[@]} -gt 0 ]]; then
        local -a EXPANDED_PATTERNS
        EXPANDED_PATTERNS=()
        for pattern in "${WHITELIST_PATTERNS[@]}"; do
            local expanded="${pattern/#\~/$HOME}"
            EXPANDED_PATTERNS+=("$expanded")
        done
        WHITELIST_PATTERNS=("${EXPANDED_PATTERNS[@]}")
    fi
}
expand_whitelist_patterns

if [[ ${#WHITELIST_PATTERNS[@]} -gt 0 ]]; then
    for entry in "${WHITELIST_PATTERNS[@]}"; do
        if [[ "$entry" == "$FINDER_METADATA_SENTINEL" ]]; then
            PROTECT_FINDER_METADATA=true
            break
        fi
    done
fi

# Section tracking and summary counters.
total_items=0
TRACK_SECTION=0
SECTION_ACTIVITY=0
files_cleaned=0
total_size_cleaned=0
whitelist_skipped_count=0
PROJECT_ARTIFACT_HINT_DETECTED=false
PROJECT_ARTIFACT_HINT_COUNT=0
PROJECT_ARTIFACT_HINT_TRUNCATED=false
PROJECT_ARTIFACT_HINT_EXAMPLES=()
PROJECT_ARTIFACT_HINT_ESTIMATED_KB=0
PROJECT_ARTIFACT_HINT_ESTIMATE_SAMPLES=0
PROJECT_ARTIFACT_HINT_ESTIMATE_PARTIAL=false
declare -a DRY_RUN_SEEN_IDENTITIES=()

# shellcheck disable=SC2329
note_activity() {
    if [[ "${TRACK_SECTION:-0}" == "1" ]]; then
        SECTION_ACTIVITY=1
    fi
}

# shellcheck disable=SC2329
register_dry_run_cleanup_target() {
    local path="$1"
    local identity
    identity=$(mole_path_identity "$path")

    if [[ ${#DRY_RUN_SEEN_IDENTITIES[@]} -gt 0 ]] && mole_identity_in_list "$identity" "${DRY_RUN_SEEN_IDENTITIES[@]}"; then
        return 1
    fi

    DRY_RUN_SEEN_IDENTITIES+=("$identity")
    return 0
}

CLEANUP_DONE=false
# shellcheck disable=SC2329
cleanup() {
    local signal="${1:-EXIT}"
    local exit_code="${2:-$?}"

    if [[ "$CLEANUP_DONE" == "true" ]]; then
        return 0
    fi
    CLEANUP_DONE=true

    stop_inline_spinner 2> /dev/null || true

    cleanup_temp_files

    stop_sudo_session

    show_cursor
}

trap 'cleanup EXIT $?' EXIT
trap 'cleanup INT 130; exit 130' INT
trap 'cleanup TERM 143; exit 143' TERM

start_section() {
    TRACK_SECTION=1
    SECTION_ACTIVITY=0
    CURRENT_SECTION="$1"
    echo ""
    echo -e "${PURPLE_BOLD}${ICON_ARROW} $1${NC}"

    if [[ "$DRY_RUN" == "true" ]]; then
        ensure_user_file "$EXPORT_LIST_FILE"
        echo "" >> "$EXPORT_LIST_FILE"
        echo "=== $1 ===" >> "$EXPORT_LIST_FILE"
    fi
}

end_section() {
    stop_section_spinner

    if [[ "${TRACK_SECTION:-0}" == "1" && "${SECTION_ACTIVITY:-0}" == "0" ]]; then
        echo -e "  ${GREEN}${ICON_SUCCESS}${NC} Nothing to clean"
    fi
    TRACK_SECTION=0
}

clean_machine_mode_enabled() {
    mole_machine_is_jsonl
}

clean_selected_section_count() {
    local count=0
    local item
    for item in "${MOLE_SELECTED_SECTION_IDS[@]-}"; do
        [[ -n "$item" ]] && count=$((count + 1))
    done
    printf '%s\n' "$count"
}

clean_selected_step_count() {
    local count=0
    local item
    for item in "${MOLE_SELECTED_STEP_RECORDS[@]-}"; do
        [[ -n "$item" ]] && count=$((count + 1))
    done
    printf '%s\n' "$count"
}

clean_step_requires_capability() {
    local capability_id="$1"
    local csv="$2"
    [[ -z "$csv" ]] && return 1
    local item
    local old_ifs="$IFS"
    IFS=','
    for item in $csv; do
        if [[ "$item" == "$capability_id" ]]; then
            IFS="$old_ifs"
            return 0
        fi
    done
    IFS="$old_ifs"
    return 1
}

clean_selected_step_ids_csv_for_capability() {
    local capability_id="$1"
    local include_recommended="${2:-false}"
    local result=""
    local entry

    for entry in "${MOLE_SELECTED_STEP_RECORDS[@]-}"; do
        local step_id section_id label function_name kind required_caps recommended_caps scope
        IFS='|' read -r step_id section_id label function_name kind required_caps recommended_caps scope <<< "$entry"
        if clean_step_requires_capability "$capability_id" "$required_caps" || { [[ "$include_recommended" == "true" ]] && clean_step_requires_capability "$capability_id" "$recommended_caps"; }; then
            if [[ -n "$result" ]]; then
                result+="," 
            fi
            result+="$step_id"
        fi
    done

    result=${result//, /,}
    printf '%s\n' "$result"
}

clean_capability_state() {
    local capability_id="$1"
    case "$capability_id" in
        sudo.session)
            if [[ -z "$(clean_selected_step_ids_csv_for_capability "$capability_id")" ]]; then
                echo "not_applicable"
            elif has_sudo_session; then
                echo "granted"
            else
                echo "missing"
            fi
            ;;
        full_disk_access)
            if has_full_disk_access; then
                echo "granted"
            else
                case $? in
                    1) echo "missing" ;;
                    2) echo "unknown" ;;
                    *) echo "unknown" ;;
                esac
            fi
            ;;
        automation.finder)
            if command -v osascript > /dev/null 2>&1; then
                echo "unknown"
            else
                echo "unavailable"
            fi
            ;;
        access.user_library)
            if [[ -d "$HOME/Library" ]] && ls "$HOME/Library" > /dev/null 2>&1; then
                echo "granted"
            else
                echo "missing"
            fi
            ;;
        access.application_support)
            if [[ ! -d "$HOME/Library/Application Support" ]]; then
                echo "not_applicable"
            elif ls "$HOME/Library/Application Support" > /dev/null 2>&1; then
                echo "granted"
            else
                echo "missing"
            fi
            ;;
        access.containers)
            if [[ ! -d "$HOME/Library/Containers" ]]; then
                echo "not_applicable"
            elif ls "$HOME/Library/Containers" > /dev/null 2>&1; then
                echo "granted"
            else
                echo "missing"
            fi
            ;;
        access.group_containers)
            if [[ ! -d "$HOME/Library/Group Containers" ]]; then
                echo "not_applicable"
            elif ls "$HOME/Library/Group Containers" > /dev/null 2>&1; then
                echo "granted"
            else
                echo "missing"
            fi
            ;;
        access.browser_profiles)
            if [[ -d "$HOME/Library/Application Support" ]] && ls "$HOME/Library/Application Support" > /dev/null 2>&1; then
                echo "granted"
            else
                echo "missing"
            fi
            ;;
        access.external_volume)
            if [[ -n "$EXTERNAL_VOLUME_TARGET" && -e "$EXTERNAL_VOLUME_TARGET" ]]; then
                echo "granted"
            else
                echo "missing"
            fi
            ;;
        tool.tmutil)
            command -v tmutil > /dev/null 2>&1 && echo "granted" || echo "unavailable"
            ;;
        tool.diskutil)
            command -v diskutil > /dev/null 2>&1 && echo "granted" || echo "unavailable"
            ;;
        tool.mdfind)
            command -v mdfind > /dev/null 2>&1 && echo "granted" || echo "unavailable"
            ;;
        *)
            echo "unknown"
            ;;
    esac
}

clean_capability_message() {
    local capability_id="$1"
    case "$capability_id" in
        sudo.session) echo "Administrative access is required for selected cleanup steps." ;;
        full_disk_access) echo "Full Disk Access may be required to inspect and clean all selected locations." ;;
        automation.finder) echo "Finder automation may improve Trash handling." ;;
        access.application_support) echo "Application Support is not fully accessible." ;;
        access.containers) echo "Containers are not fully accessible." ;;
        access.group_containers) echo "Group Containers are not fully accessible." ;;
        access.external_volume) echo "The selected external volume is not accessible." ;;
        tool.tmutil) echo "tmutil is unavailable for selected Time Machine steps." ;;
        tool.diskutil) echo "diskutil is unavailable for external volume cleanup." ;;
        tool.mdfind) echo "mdfind is unavailable for orphaned system service detection." ;;
        *) echo "$capability_id state changed." ;;
    esac
}

clean_resolve_selected_steps() {
    clean_registry_init
    MOLE_SELECTED_STEP_RECORDS=()
    MOLE_SELECTED_SECTION_IDS=()

    if [[ -n "$EXTERNAL_VOLUME_TARGET" ]]; then
        MOLE_SCOPE="external"
    fi
    MOLE_SCOPE_EFFECTIVE="$MOLE_SCOPE"

    local entry
    while IFS= read -r entry; do
        [[ -z "$entry" ]] && continue
        MOLE_SELECTED_STEP_RECORDS+=("$entry")
        local step_id section_id label function_name kind required_caps recommended_caps scope
        IFS='|' read -r step_id section_id label function_name kind required_caps recommended_caps scope <<< "$entry"
        local seen=false
        local existing
        for existing in "${MOLE_SELECTED_SECTION_IDS[@]-}"; do
            if [[ "$existing" == "$section_id" ]]; then
                seen=true
                break
            fi
        done
        [[ "$seen" == "true" ]] || MOLE_SELECTED_SECTION_IDS+=("$section_id")
    done < <(clean_selected_step_records)
}

clean_emit_run_context() {
    clean_machine_mode_enabled || return 0

    local argv_json="["
    local first=true
    local arg
    for arg in "$@"; do
        if [[ "$first" == "true" ]]; then
            first=false
        else
            argv_json+="," 
        fi
        argv_json+=$(mole_machine_json_string "$arg")
    done
    argv_json=${argv_json//, /,}
    argv_json+="]"

    mole_machine_emit "run.started" "$(printf '{"argv":%s,"interface":%s,"mode":%s,"scope_requested":%s,"steps_requested":%s,"external_target":%s,"blocking_policy":%s}' \
        "$argv_json" \
        "$(mole_machine_json_string "$MOLE_INTERFACE")" \
        "$(mole_machine_json_string "$MOLE_OUTPUT_MODE")" \
        "$(mole_machine_json_string "$MOLE_SCOPE")" \
        "$(mole_machine_json_array_from_csv "$MOLE_SELECTED_STEPS_CSV")" \
        "$(mole_machine_json_string "$EXTERNAL_VOLUME_TARGET")" \
        "$(mole_machine_json_string "$MOLE_BLOCKING_POLICY")")"

    mole_machine_emit "run.context" "$(printf '{"mole_version":%s,"os_version":%s,"arch":%s,"uid":%s,"euid":%s,"home":%s,"cwd":%s,"log_dir":%s}' \
        "$(mole_machine_json_string "${MOLE_CLI_VERSION:-unknown}")" \
        "$(mole_machine_json_string "$(sw_vers -productVersion 2> /dev/null || echo unknown)")" \
        "$(mole_machine_json_string "$(uname -m)")" \
        "$(mole_machine_json_number "$(id -u)")" \
        "$(mole_machine_json_number "$(id -u)")" \
        "$(mole_machine_json_string "$HOME")" \
        "$(mole_machine_json_string "$PWD")" \
        "$(mole_machine_json_string "$HOME/Library/Logs/mole")")"

    local section_json="["
    local section_first=true
    local section_id
    for section_id in "${MOLE_SELECTED_SECTION_IDS[@]-}"; do
        if [[ "$section_first" == "true" ]]; then
            section_first=false
        else
            section_json+="," 
        fi
        section_json+=$(mole_machine_json_string "$section_id")
    done
    section_json=${section_json//, /,}
    section_json+="]"

    local step_json="["
    local step_first=true
    local step_entry
    for step_entry in "${MOLE_SELECTED_STEP_RECORDS[@]-}"; do
        local step_id
        IFS='|' read -r step_id _rest <<< "$step_entry"
        if [[ "$step_first" == "true" ]]; then
            step_first=false
        else
            step_json+="," 
        fi
        step_json+=$(mole_machine_json_string "$step_id")
    done
    step_json=${step_json//, /,}
    step_json+="]"

    mole_machine_emit "scope.resolved" "$(printf '{"scope_effective":%s,"section_ids":%s,"step_ids":%s}' \
        "$(mole_machine_json_string "$MOLE_SCOPE_EFFECTIVE")" \
        "$section_json" \
        "$step_json")"
}

clean_emit_capabilities() {
    clean_machine_mode_enabled || return 0

    local known_capabilities=(
        "sudo.session"
        "full_disk_access"
        "automation.finder"
        "access.user_library"
        "access.application_support"
        "access.containers"
        "access.group_containers"
        "access.browser_profiles"
        "access.external_volume"
        "tool.tmutil"
        "tool.diskutil"
        "tool.mdfind"
    )
    local capability_id
    for capability_id in "${known_capabilities[@]}"; do
        local required_steps recommended_steps severity state remediation
        required_steps=$(clean_selected_step_ids_csv_for_capability "$capability_id")
        recommended_steps=$(clean_selected_step_ids_csv_for_capability "$capability_id" true)
        [[ -z "$recommended_steps" ]] && continue
        severity="recommended"
        [[ -n "$required_steps" ]] && severity="required"
        state=$(clean_capability_state "$capability_id")
        remediation="review"
        if [[ "$capability_id" == "sudo.session" ]]; then
            remediation="elevate_and_retry"
        elif [[ "$capability_id" == "full_disk_access" ]]; then
            remediation="open_system_settings"
        fi
        mole_machine_record_capability "$capability_id" "$state" "$severity" "$recommended_steps" "$(clean_capability_message "$capability_id")" "$remediation"
        if [[ "$severity" == "required" && "$state" != "granted" && "$state" != "not_applicable" ]]; then
            MOLE_REQUIRED_CAPABILITY_ERRORS+=("$capability_id")
        fi
    done
}

clean_required_capability_missing_for_step() {
    local required_csv="$1"
    local item
    local old_ifs="$IFS"
    IFS=','
    for item in $required_csv; do
        [[ -z "$item" ]] && continue
        local state
        state=$(clean_capability_state "$item")
        if [[ "$state" != "granted" && "$state" != "not_applicable" ]]; then
            IFS="$old_ifs"
            printf '%s\n' "$item"
            return 0
        fi
    done
    IFS="$old_ifs"
    return 1
}

clean_run_step_record() {
    local entry="$1"
    local step_id section_id label function_name kind required_caps recommended_caps scope
    IFS='|' read -r step_id section_id label function_name kind required_caps recommended_caps scope <<< "$entry"

    local step_index="$2"
    local step_total="$3"
    local missing_capability=""
    missing_capability=$(clean_required_capability_missing_for_step "$required_caps" || true)

    MOLE_CLEAN_CURRENT_STEP_ID="$step_id"
    MOLE_CLEAN_CURRENT_STEP_LABEL="$label"
    MOLE_CLEAN_CURRENT_SECTION_ID="$section_id"

    clean_machine_mode_enabled && mole_machine_emit "step.started" "$(printf '{"step_id":%s,"section_id":%s,"label":%s,"kind":%s,"capabilities_required":%s,"capabilities_recommended":%s,"destructive":%s,"index":%s,"count":%s}' \
        "$(mole_machine_json_string "$step_id")" \
        "$(mole_machine_json_string "$section_id")" \
        "$(mole_machine_json_string "$label")" \
        "$(mole_machine_json_string "$kind")" \
        "$(mole_machine_json_array_from_csv "$required_caps")" \
        "$(mole_machine_json_array_from_csv "$recommended_caps")" \
        "$(mole_machine_json_bool "$([[ "$kind" == "hint" || "$kind" == "check" || "$kind" == "scan" ]] && echo false || echo true)")" \
        "$(mole_machine_json_number "$step_index")" \
        "$(mole_machine_json_number "$step_total")")"

    if [[ -n "$missing_capability" ]]; then
        clean_machine_mode_enabled && mole_machine_notice "warning" "capability_missing" "$label skipped: $missing_capability is unavailable." "$section_id" "$step_id"
        clean_machine_mode_enabled && mole_machine_emit "step.completed" "$(printf '{"step_id":%s,"status":%s,"reason_code":%s,"capability_id":%s}' \
            "$(mole_machine_json_string "$step_id")" \
            "$(mole_machine_json_string "blocked")" \
            "$(mole_machine_json_string "capability_missing")" \
            "$(mole_machine_json_string "$missing_capability")")"
        mole_machine_record_step_result "$step_id" "$section_id" "blocked" 0 0 0 0 0 "capability_missing"
        [[ "$MOLE_BLOCKING_POLICY" == "fail" ]] && return 4
        return 0
    fi

    if [[ "$MOLE_OUTPUT_MODE" == "preflight" ]]; then
        clean_machine_mode_enabled && mole_machine_emit "step.completed" "$(printf '{"step_id":%s,"status":%s,"freed_bytes":0,"items":0,"skipped":0,"failed":0,"duration_ms":0}' \
            "$(mole_machine_json_string "$step_id")" \
            "$(mole_machine_json_string "ok")")"
        mole_machine_record_step_result "$step_id" "$section_id" "ok" 0 0 0 0 0 ""
        return 0
    fi

    local bytes_before items_before skip_before failed_before started_at rc duration_ms bytes_delta items_delta
    bytes_before=$total_size_cleaned
    items_before=$files_cleaned
    skip_before=$whitelist_skipped_count
    failed_before=${MOLE_PERMISSION_DENIED_COUNT:-0}
    started_at=$(date +%s)
    rc=0
    if clean_machine_mode_enabled; then
        "$function_name" > /dev/null 2>&1 || rc=$?
    else
        "$function_name" || rc=$?
    fi
    duration_ms=$(( ( $(date +%s) - started_at ) * 1000 ))
    bytes_delta=$(((total_size_cleaned - bytes_before) * 1024))
    items_delta=$((files_cleaned - items_before))
    local skipped_delta=$((whitelist_skipped_count - skip_before))
    local failed_delta=$(( ${MOLE_PERMISSION_DENIED_COUNT:-0} - failed_before ))
    local step_status="ok"
    local reason_code=""
    if [[ $rc -ne 0 ]]; then
        step_status="failed"
        reason_code="internal_error"
    fi

    clean_machine_mode_enabled && mole_machine_emit "step.completed" "$(printf '{"step_id":%s,"status":%s,"freed_bytes":%s,"items":%s,"skipped":%s,"failed":%s,"duration_ms":%s}' \
        "$(mole_machine_json_string "$step_id")" \
        "$(mole_machine_json_string "$step_status")" \
        "$(mole_machine_json_number "$bytes_delta")" \
        "$(mole_machine_json_number "$items_delta")" \
        "$(mole_machine_json_number "$skipped_delta")" \
        "$(mole_machine_json_number "$failed_delta")" \
        "$(mole_machine_json_number "$duration_ms")")"
    mole_machine_record_step_result "$step_id" "$section_id" "$step_status" "$bytes_delta" "$items_delta" "$skipped_delta" "$failed_delta" "$duration_ms" "$reason_code"
    return $rc
}

clean_run_section() {
    local section_id="$1"
    local section_label
    section_label=$(clean_section_label "$section_id")
    local section_steps=()
    local entry
    for entry in "${MOLE_SELECTED_STEP_RECORDS[@]-}"; do
        local step_id current_section label function_name kind required_caps recommended_caps scope
        IFS='|' read -r step_id current_section label function_name kind required_caps recommended_caps scope <<< "$entry"
        [[ "$current_section" == "$section_id" ]] && section_steps+=("$entry")
    done
    [[ ${#section_steps[@]} -eq 0 ]] && return 0

    local section_index=1
    local idx lookup_section
    local selected_sections=("${MOLE_SELECTED_SECTION_IDS[@]-}")
    for idx in "${!selected_sections[@]}"; do
        lookup_section="${selected_sections[$idx]}"
        if [[ "$lookup_section" == "$section_id" ]]; then
            section_index=$((idx + 1))
            break
        fi
    done

    if clean_machine_mode_enabled; then
        mole_machine_emit "section.started" "$(printf '{"section_id":%s,"label":%s,"index":%s,"count":%s}' \
            "$(mole_machine_json_string "$section_id")" \
            "$(mole_machine_json_string "$section_label")" \
            "$(mole_machine_json_number "$section_index")" \
            "$(mole_machine_json_number "$(clean_selected_section_count)")")"
    else
        start_section "$section_label"
    fi

    local bytes_before=$total_size_cleaned
    local items_before=$files_cleaned
    local skip_before=$whitelist_skipped_count
    local failed_before=${MOLE_PERMISSION_DENIED_COUNT:-0}
    local started_at
    started_at=$(date +%s)
    local rc=0
    local step_total=${#section_steps[@]}
    for idx in "${!section_steps[@]}"; do
        clean_run_step_record "${section_steps[$idx]}" "$((idx + 1))" "$step_total" || rc=$?
        if [[ $rc -eq 4 && "$MOLE_BLOCKING_POLICY" == "fail" ]]; then
            break
        fi
    done

    local duration_ms=$(( ( $(date +%s) - started_at ) * 1000 ))
    local bytes_delta=$(((total_size_cleaned - bytes_before) * 1024))
    local items_delta=$((files_cleaned - items_before))
    local skipped_delta=$((whitelist_skipped_count - skip_before))
    local failed_delta=$(( ${MOLE_PERMISSION_DENIED_COUNT:-0} - failed_before ))
    local section_status="ok"
    [[ $rc -ne 0 && $rc -ne 4 ]] && section_status="failed"
    [[ $rc -eq 4 ]] && section_status="blocked"

    if clean_machine_mode_enabled; then
        mole_machine_emit "section.completed" "$(printf '{"section_id":%s,"status":%s,"duration_ms":%s,"totals":{"estimated_bytes":%s,"freed_bytes":%s,"candidates_found":%s,"items_deleted":%s,"items_skipped":%s,"items_failed":%s}}' \
            "$(mole_machine_json_string "$section_id")" \
            "$(mole_machine_json_string "$section_status")" \
            "$(mole_machine_json_number "$duration_ms")" \
            "$(mole_machine_json_number "$bytes_delta")" \
            "$(mole_machine_json_number "$bytes_delta")" \
            "$(mole_machine_json_number "$items_delta")" \
            "$(mole_machine_json_number "$items_delta")" \
            "$(mole_machine_json_number "$skipped_delta")" \
            "$(mole_machine_json_number "$failed_delta")")"
    else
        end_section
    fi

    mole_machine_record_section_result "$section_id" "$section_status" "$bytes_delta" "$items_delta" "$skipped_delta" "$failed_delta" "$duration_ms"
    return $rc
}

clean_run_selected_sections() {
    local section_id
    local rc=0
    for section_id in "${MOLE_SELECTED_SECTION_IDS[@]-}"; do
        clean_run_section "$section_id" || rc=$?
        if [[ $rc -eq 4 && "$MOLE_BLOCKING_POLICY" == "fail" ]]; then
            return 4
        fi
    done
    return $rc
}

# shellcheck disable=SC2329
normalize_paths_for_cleanup() {
    local -a input_paths=("$@")
    local -a unique_paths=()

    for path in "${input_paths[@]}"; do
        local normalized="${path%/}"
        [[ -z "$normalized" ]] && normalized="$path"
        local found=false
        if [[ ${#unique_paths[@]} -gt 0 ]]; then
            for existing in "${unique_paths[@]}"; do
                if [[ "$existing" == "$normalized" ]]; then
                    found=true
                    break
                fi
            done
        fi
        [[ "$found" == "true" ]] || unique_paths+=("$normalized")
    done

    local sorted_paths
    if [[ ${#unique_paths[@]} -gt 0 ]]; then
        sorted_paths=$(printf '%s\n' "${unique_paths[@]}" | awk '{print length "|" $0}' | LC_ALL=C sort -n | cut -d'|' -f2-)
    else
        sorted_paths=""
    fi

    local -a result_paths=()
    while IFS= read -r path; do
        [[ -z "$path" ]] && continue
        local is_child=false
        if [[ ${#result_paths[@]} -gt 0 ]]; then
            for kept in "${result_paths[@]}"; do
                if [[ "$path" == "$kept" || "$path" == "$kept"/* ]]; then
                    is_child=true
                    break
                fi
            done
        fi
        [[ "$is_child" == "true" ]] || result_paths+=("$path")
    done <<< "$sorted_paths"

    if [[ ${#result_paths[@]} -gt 0 ]]; then
        printf '%s\n' "${result_paths[@]}"
    fi
}

# shellcheck disable=SC2329
get_cleanup_path_size_kb() {
    local path="$1"

    if [[ -f "$path" && ! -L "$path" ]]; then
        if command -v stat > /dev/null 2>&1; then
            local bytes
            bytes=$(stat -f%z "$path" 2> /dev/null || echo "0")
            if [[ "$bytes" =~ ^[0-9]+$ && "$bytes" -gt 0 ]]; then
                echo $(((bytes + 1023) / 1024))
                return 0
            fi
        fi
    fi

    if [[ -L "$path" ]]; then
        if command -v stat > /dev/null 2>&1; then
            local bytes
            bytes=$(stat -f%z "$path" 2> /dev/null || echo "0")
            if [[ "$bytes" =~ ^[0-9]+$ && "$bytes" -gt 0 ]]; then
                echo $(((bytes + 1023) / 1024))
            else
                echo 0
            fi
            return 0
        fi
    fi

    get_path_size_kb "$path"
}

# Classification helper for cleanup risk levels
# shellcheck disable=SC2329
classify_cleanup_risk() {
    local description="$1"
    local path="${2:-}"

    # HIGH RISK: System files, preference files, require sudo
    if [[ "$description" =~ [Ss]ystem || "$description" =~ [Ss]udo || "$path" =~ ^/System || "$path" =~ ^/Library ]]; then
        echo "HIGH|System files or requires admin access"
        return
    fi

    # HIGH RISK: Preference files that might affect app functionality
    if [[ "$description" =~ [Pp]reference || "$path" =~ /Preferences/ ]]; then
        echo "HIGH|Preference files may affect app settings"
        return
    fi

    # MEDIUM RISK: Installers, large files, app bundles
    if [[ "$description" =~ [Ii]nstaller || "$description" =~ [Aa]pp.*[Bb]undle || "$description" =~ [Ll]arge ]]; then
        echo "MEDIUM|Installer packages or app data"
        return
    fi

    # MEDIUM RISK: Old backups, downloads
    if [[ "$description" =~ [Bb]ackup || "$description" =~ [Dd]ownload || "$description" =~ [Oo]rphan ]]; then
        echo "MEDIUM|Backup or downloaded files"
        return
    fi

    # LOW RISK: Caches, logs, temporary files (automatically regenerated)
    if [[ "$description" =~ [Cc]ache || "$description" =~ [Ll]og || "$description" =~ [Tt]emp || "$description" =~ [Tt]humbnail ]]; then
        echo "LOW|Cache/log files, automatically regenerated"
        return
    fi

    # DEFAULT: MEDIUM
    echo "MEDIUM|User data files"
}

# shellcheck disable=SC2329
safe_clean() {
    if [[ $# -eq 0 ]]; then
        return 0
    fi

    local description
    local -a targets

    if [[ $# -eq 1 ]]; then
        description="$1"
        targets=("$1")
    else
        description="${*: -1}"
        targets=("${@:1:$#-1}")
    fi

    local -a valid_targets=()
    for target in "${targets[@]}"; do
        # Optimization: If target is a glob literal and parent dir missing, skip it.
        if [[ "$target" == *"*"* && ! -e "$target" ]]; then
            local base_path="${target%%\**}"
            local parent_dir
            if [[ "$base_path" == */ ]]; then
                parent_dir="${base_path%/}"
            else
                parent_dir=$(dirname "$base_path")
            fi

            if [[ ! -d "$parent_dir" ]]; then
                # debug_log "Skipping nonexistent parent: $parent_dir for $target"
                continue
            fi
        fi
        valid_targets+=("$target")
    done

    if [[ ${#valid_targets[@]} -gt 0 ]]; then
        targets=("${valid_targets[@]}")
    else
        targets=()
    fi
    if [[ ${#targets[@]} -eq 0 ]]; then
        return 0
    fi

    local removed_any=0
    local total_size_kb=0
    local total_count=0
    local skipped_count=0
    local removal_failed_count=0
    local permission_start=${MOLE_PERMISSION_DENIED_COUNT:-0}

    local show_scan_feedback=false
    if [[ ${#targets[@]} -gt 20 && -t 1 ]]; then
        show_scan_feedback=true
        stop_section_spinner
        MOLE_SPINNER_PREFIX="  " start_inline_spinner "Scanning ${#targets[@]} items..."
    fi

    local -a existing_paths=()
    for path in "${targets[@]}"; do
        local skip=false

        if should_protect_path "$path"; then
            skip=true
            skipped_count=$((skipped_count + 1))
            log_operation "clean" "SKIPPED" "$path" "protected"
        fi

        [[ "$skip" == "true" ]] && continue

        if is_path_whitelisted "$path"; then
            skip=true
            skipped_count=$((skipped_count + 1))
            log_operation "clean" "SKIPPED" "$path" "whitelist"
        fi
        [[ "$skip" == "true" ]] && continue
        if [[ -e "$path" ]]; then
            if [[ "$DRY_RUN" == "true" ]]; then
                register_dry_run_cleanup_target "$path" || continue
            fi
            existing_paths+=("$path")
        fi
    done

    if [[ "$show_scan_feedback" == "true" ]]; then
        stop_section_spinner
    fi

    debug_log "Cleaning: $description, ${#existing_paths[@]} items"

    # Enhanced debug output with risk level and details
    if [[ "${MO_DEBUG:-}" == "1" && ${#existing_paths[@]} -gt 0 ]]; then
        # Determine risk level for this cleanup operation
        local risk_info
        risk_info=$(classify_cleanup_risk "$description" "${existing_paths[0]}")
        local risk_level="${risk_info%%|*}"
        local risk_reason="${risk_info#*|}"

        debug_operation_start "$description"
        debug_risk_level "$risk_level" "$risk_reason"
        debug_operation_detail "Item count" "${#existing_paths[@]}"

        # Log sample of files (first 10) with details
        if [[ ${#existing_paths[@]} -le 10 ]]; then
            debug_operation_detail "Files to be removed" "All files listed below"
        else
            debug_operation_detail "Files to be removed" "Showing first 10 of ${#existing_paths[@]} files"
        fi
    fi

    if [[ $skipped_count -gt 0 ]]; then
        whitelist_skipped_count=$((whitelist_skipped_count + skipped_count))
    fi

    if [[ ${#existing_paths[@]} -eq 0 ]]; then
        return 0
    fi

    if [[ ${#existing_paths[@]} -gt 1 ]]; then
        local -a normalized_paths=()
        while IFS= read -r path; do
            [[ -n "$path" ]] && normalized_paths+=("$path")
        done < <(normalize_paths_for_cleanup "${existing_paths[@]}")

        if [[ ${#normalized_paths[@]} -gt 0 ]]; then
            existing_paths=("${normalized_paths[@]}")
        else
            existing_paths=()
        fi
    fi

    local show_spinner=false
    if [[ ${#existing_paths[@]} -gt 10 ]]; then
        show_spinner=true
        local total_paths=${#existing_paths[@]}
        if [[ -t 1 ]]; then MOLE_SPINNER_PREFIX="  " start_inline_spinner "Scanning items..."; fi
    fi

    local cleaning_spinner_started=false

    # For larger batches, precompute sizes in parallel for better UX/stat accuracy.
    if [[ ${#existing_paths[@]} -gt 3 ]]; then
        local temp_dir
        temp_dir=$(create_temp_dir)

        local dir_count=0
        local sample_size=$((${#existing_paths[@]} > 20 ? 20 : ${#existing_paths[@]}))
        local max_sample=$((${#existing_paths[@]} * 20 / 100))
        [[ $max_sample -gt $sample_size ]] && sample_size=$max_sample

        for ((i = 0; i < sample_size && i < ${#existing_paths[@]}; i++)); do
            [[ -d "${existing_paths[i]}" ]] && ((dir_count++))
        done

        # Heuristic: mostly files -> sequential stat is faster than subshells.
        if [[ $dir_count -lt 5 && ${#existing_paths[@]} -gt 20 ]]; then
            if [[ -t 1 && "$show_spinner" == "false" ]]; then
                MOLE_SPINNER_PREFIX="  " start_inline_spinner "Scanning items..."
                show_spinner=true
            fi

            local idx=0
            local last_progress_update
            last_progress_update=$(get_epoch_seconds)
            for path in "${existing_paths[@]}"; do
                local size
                size=$(get_cleanup_path_size_kb "$path")
                [[ ! "$size" =~ ^[0-9]+$ ]] && size=0

                if [[ "$size" -gt 0 ]]; then
                    echo "$size 1" > "$temp_dir/result_${idx}"
                else
                    echo "0 0" > "$temp_dir/result_${idx}"
                fi

                idx=$((idx + 1))
                if [[ $((idx % 20)) -eq 0 && "$show_spinner" == "true" && -t 1 ]]; then
                    update_progress_if_needed "$idx" "${#existing_paths[@]}" last_progress_update 1 || true
                    last_progress_update=$(get_epoch_seconds)
                fi
            done
        else
            local -a pids=()
            local idx=0
            local completed=0
            local last_progress_update
            last_progress_update=$(get_epoch_seconds)
            local total_paths=${#existing_paths[@]}

            if [[ ${#existing_paths[@]} -gt 0 ]]; then
                for path in "${existing_paths[@]}"; do
                    (
                        local size
                        size=$(get_cleanup_path_size_kb "$path")
                        [[ ! "$size" =~ ^[0-9]+$ ]] && size=0
                        local tmp_file="$temp_dir/result_${idx}.$$"
                        if [[ "$size" -gt 0 ]]; then
                            echo "$size 1" > "$tmp_file"
                        else
                            echo "0 0" > "$tmp_file"
                        fi
                        mv "$tmp_file" "$temp_dir/result_${idx}" 2> /dev/null || true
                    ) &
                    pids+=($!)
                    idx=$((idx + 1))

                    if ((${#pids[@]} >= MOLE_MAX_PARALLEL_JOBS)); then
                        wait "${pids[0]}" 2> /dev/null || true
                        pids=("${pids[@]:1}")
                        completed=$((completed + 1))

                        if [[ "$show_spinner" == "true" && -t 1 ]]; then
                            update_progress_if_needed "$completed" "$total_paths" last_progress_update 2 || true
                        fi
                    fi
                done
            fi

            if [[ ${#pids[@]} -gt 0 ]]; then
                for pid in "${pids[@]}"; do
                    wait "$pid" 2> /dev/null || true
                    completed=$((completed + 1))

                    if [[ "$show_spinner" == "true" && -t 1 ]]; then
                        update_progress_if_needed "$completed" "$total_paths" last_progress_update 2 || true
                    fi
                done
            fi
        fi

        # Read results back in original order.
        # Start spinner for cleaning phase
        if [[ "$DRY_RUN" != "true" && ${#existing_paths[@]} -gt 0 && -t 1 ]]; then
            MOLE_SPINNER_PREFIX="  " start_inline_spinner "Cleaning..."
            cleaning_spinner_started=true
        fi
        idx=0
        if [[ ${#existing_paths[@]} -gt 0 ]]; then
            for path in "${existing_paths[@]}"; do
                local result_file="$temp_dir/result_${idx}"
                if [[ -f "$result_file" ]]; then
                    read -r size count < "$result_file" 2> /dev/null || true
                    local removed=0
                    if [[ "$DRY_RUN" != "true" ]]; then
                        if safe_remove "$path" true; then
                            removed=1
                        fi
                    else
                        removed=1
                    fi

                    if [[ $removed -eq 1 ]]; then
                        if [[ "$size" -gt 0 ]]; then
                            total_size_kb=$((total_size_kb + size))
                        fi
                        total_count=$((total_count + 1))
                        removed_any=1
                    else
                        if [[ -e "$path" && "$DRY_RUN" != "true" ]]; then
                            removal_failed_count=$((removal_failed_count + 1))
                        fi
                    fi
                fi
                idx=$((idx + 1))
            done
        fi

    else
        # Start spinner for cleaning phase (small batch)
        if [[ "$DRY_RUN" != "true" && ${#existing_paths[@]} -gt 0 && -t 1 ]]; then
            MOLE_SPINNER_PREFIX="  " start_inline_spinner "Cleaning..."
            cleaning_spinner_started=true
        fi
        local idx=0
        if [[ ${#existing_paths[@]} -gt 0 ]]; then
            for path in "${existing_paths[@]}"; do
                local size_kb
                size_kb=$(get_cleanup_path_size_kb "$path")
                [[ ! "$size_kb" =~ ^[0-9]+$ ]] && size_kb=0

                local removed=0
                if [[ "$DRY_RUN" != "true" ]]; then
                    if safe_remove "$path" true; then
                        removed=1
                    fi
                else
                    removed=1
                fi

                if [[ $removed -eq 1 ]]; then
                    if [[ "$size_kb" -gt 0 ]]; then
                        total_size_kb=$((total_size_kb + size_kb))
                    fi
                    total_count=$((total_count + 1))
                    removed_any=1
                else
                    if [[ -e "$path" && "$DRY_RUN" != "true" ]]; then
                        removal_failed_count=$((removal_failed_count + 1))
                    fi
                fi
                idx=$((idx + 1))
            done
        fi
    fi

    if [[ "$show_spinner" == "true" || "$cleaning_spinner_started" == "true" ]]; then
        stop_inline_spinner
    fi

    local permission_end=${MOLE_PERMISSION_DENIED_COUNT:-0}
    # Track permission failures in debug output (avoid noisy user warnings).
    if [[ $permission_end -gt $permission_start && $removed_any -eq 0 ]]; then
        debug_log "Permission denied while cleaning: $description"
    fi
    if [[ $removal_failed_count -gt 0 && "$DRY_RUN" != "true" ]]; then
        debug_log "Skipped $removal_failed_count items, permission denied or in use, for: $description"
    fi

    if [[ $removed_any -eq 1 ]]; then
        # Stop spinner before output
        stop_section_spinner

        local size_human
        size_human=$(bytes_to_human "$((total_size_kb * 1024))")

        local label="$description"
        if [[ ${#targets[@]} -gt 1 ]]; then
            label+=" ${#targets[@]} items"
        fi

        if clean_machine_mode_enabled && [[ "${MOLE_ITEM_EVENTS:-grouped}" == "grouped" ]]; then
            local candidate_path="${existing_paths[0]:-}"
            local candidate_display="$candidate_path"
            local candidate_kind="file"
            [[ -d "$candidate_path" ]] && candidate_kind="directory"
            [[ -z "$candidate_path" ]] && candidate_display="$label"
            local grouped_candidate_id
            grouped_candidate_id=$(mole_machine_candidate_id_for_logical "$(printf '%s' "$label" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-')")
            mole_machine_candidate_found "$grouped_candidate_id" "$label" "logical" "delete_path" "$candidate_path" "$candidate_display" "$candidate_kind" "$((total_size_kb * 1024))" "$total_count" "" '{}'
            if [[ "$DRY_RUN" == "true" ]]; then
                mole_machine_item_result "$grouped_candidate_id" "$label" "would_clean" "$((total_size_kb * 1024))" "$total_count" "" 0
            else
                mole_machine_item_result "$grouped_candidate_id" "$label" "cleaned" "$((total_size_kb * 1024))" "$total_count" "" 0
            fi
        fi

        if [[ "$DRY_RUN" == "true" ]]; then
            if ! clean_machine_mode_enabled; then
                echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} $label${NC}, ${YELLOW}$size_human dry${NC}"
            fi

            local paths_temp
            paths_temp=$(create_temp_file)

            idx=0
            if [[ ${#existing_paths[@]} -gt 0 ]]; then
                for path in "${existing_paths[@]}"; do
                    local size=0

                    if [[ -n "${temp_dir:-}" && -f "$temp_dir/result_${idx}" ]]; then
                        read -r size count < "$temp_dir/result_${idx}" 2> /dev/null || true
                    else
                        size=$(get_cleanup_path_size_kb "$path" 2> /dev/null || echo "0")
                    fi

                    [[ "$size" == "0" || -z "$size" ]] && {
                        idx=$((idx + 1))
                        continue
                    }

                    echo "$(dirname "$path")|$size|$path" >> "$paths_temp"
                    idx=$((idx + 1))
                done
            fi

            # Group dry-run paths by parent for a compact export list.
            if [[ -f "$paths_temp" && -s "$paths_temp" ]]; then
                sort -t'|' -k1,1 "$paths_temp" | awk -F'|' '
                {
                    parent = $1
                    size = $2
                    path = $3

                    parent_size[parent] += size
                    if (parent_count[parent] == 0) {
                        parent_first[parent] = path
                    }
                    parent_count[parent]++
                }
                END {
                    for (parent in parent_size) {
                        if (parent_count[parent] > 1) {
                            printf "%s|%d|%d\n", parent, parent_size[parent], parent_count[parent]
                        } else {
                            printf "%s|%d|1\n", parent_first[parent], parent_size[parent]
                        }
                    }
                }
                ' | while IFS='|' read -r display_path total_size child_count; do
                    local size_human
                    size_human=$(bytes_to_human "$((total_size * 1024))")
                    if [[ $child_count -gt 1 ]]; then
                        echo "$display_path  # $size_human, $child_count items" >> "$EXPORT_LIST_FILE"
                    else
                        echo "$display_path  # $size_human" >> "$EXPORT_LIST_FILE"
                    fi
                done
            fi
        else
            if ! clean_machine_mode_enabled; then
                local line_color
                line_color=$(cleanup_result_color_kb "$total_size_kb")
                echo -e "  ${line_color}${ICON_SUCCESS}${NC} $label${NC}, ${line_color}$size_human${NC}"
            fi
        fi
        files_cleaned=$((files_cleaned + total_count))
        total_size_cleaned=$((total_size_cleaned + total_size_kb))
        total_items=$((total_items + 1))
        note_activity
    fi

    return 0
}

start_cleanup() {
    # Set current command for operation logging
    export MOLE_CURRENT_COMMAND="clean"
    log_operation_session_start "clean"
    DRY_RUN_SEEN_IDENTITIES=()

    if clean_machine_mode_enabled; then
        export MOLE_SILENT_STDIO=1
        MOLE_MACHINE_SILENT_STDIO=1
        if [[ -n "$EXTERNAL_VOLUME_TARGET" ]]; then
            MOLE_SCOPE_EFFECTIVE="external"
        fi
        if [[ "$MOLE_SCOPE" == "system" ]]; then
            SYSTEM_CLEAN=true
        elif [[ "$MOLE_SCOPE" == "user" ]]; then
            SYSTEM_CLEAN=false
        elif [[ "$MOLE_SCOPE" == "all" ]]; then
            SYSTEM_CLEAN=true
        fi
        return 0
    fi

    if [[ -t 1 ]]; then
        printf '\033[2J\033[H'
    fi
    printf '\n'
    if [[ -n "$EXTERNAL_VOLUME_TARGET" ]]; then
        echo -e "${PURPLE_BOLD}Clean External Volume${NC}"
        echo -e "${GRAY}${EXTERNAL_VOLUME_TARGET}${NC}"
        echo ""

        if [[ "$DRY_RUN" == "true" ]]; then
            echo -e "${YELLOW}Dry Run Mode${NC}, Preview only, no deletions"
            echo ""
        fi
        SYSTEM_CLEAN=false
        return 0
    fi

    echo -e "${PURPLE_BOLD}Clean Your Mac${NC}"
    echo ""

    if [[ "$DRY_RUN" != "true" && -t 0 ]]; then
        echo -e "${GRAY}${ICON_WARNING} Use --dry-run to preview, --whitelist to manage protected paths${NC}"
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        echo -e "${YELLOW}Dry Run Mode${NC}, Preview only, no deletions"
        echo ""

        ensure_user_file "$EXPORT_LIST_FILE"
        cat > "$EXPORT_LIST_FILE" << EOF
# Mole Cleanup Preview - $(date '+%Y-%m-%d %H:%M:%S')
#
# How to protect files:
# 1. Copy any path below to ~/.config/mole/whitelist
# 2. Run: mo clean --whitelist
#
# Example:
#   /Users/*/Library/Caches/com.example.app
#

EOF

        # Preview system section when sudo is already cached (no password prompt).
        if has_sudo_session; then
            SYSTEM_CLEAN=true
            echo -e "${GREEN}${ICON_SUCCESS}${NC} Admin access available, system preview included"
            echo ""
        else
            SYSTEM_CLEAN=false
            echo -e "${GRAY}${ICON_WARNING} System caches need sudo, run ${NC}sudo -v && mo clean --dry-run${GRAY} for full preview${NC}"
            echo ""
        fi
        return
    fi

    if [[ -t 0 ]]; then
        if has_sudo_session; then
            SYSTEM_CLEAN=true
            echo -e "${GREEN}${ICON_SUCCESS}${NC} Admin access already available"
            echo ""
        else
            echo -ne "${PURPLE}${ICON_ARROW}${NC} System caches need sudo. ${GREEN}Enter${NC} continue, ${GRAY}Space${NC} skip: "

            local choice
            choice=$(read_key)

            # ESC/Q aborts, Space skips, Enter enables system cleanup.
            if [[ "$choice" == "QUIT" ]]; then
                echo -e " ${GRAY}Canceled${NC}"
                exit 0
            fi

            if [[ "$choice" == "SPACE" ]]; then
                echo -e " ${GRAY}Skipped${NC}"
                echo ""
                SYSTEM_CLEAN=false
            elif [[ "$choice" == "ENTER" ]]; then
                printf "\r\033[K" # Clear the prompt line
                if ensure_sudo_session "System cleanup requires admin access"; then
                    SYSTEM_CLEAN=true
                    echo -e "${GREEN}${ICON_SUCCESS}${NC} Admin access granted"
                    echo ""
                else
                    SYSTEM_CLEAN=false
                    echo ""
                    echo -e "${YELLOW}Authentication failed${NC}, continuing with user-level cleanup"
                fi
            else
                SYSTEM_CLEAN=false
                echo -e " ${GRAY}Skipped${NC}"
                echo ""
            fi
        fi
    else
        echo ""
        echo "Running in non-interactive mode"
        if has_sudo_session; then
            SYSTEM_CLEAN=true
            echo "  ${ICON_LIST} System-level cleanup enabled, sudo session active"
        else
            SYSTEM_CLEAN=false
            echo "  ${ICON_LIST} System-level cleanup skipped, requires sudo"
        fi
        echo "  ${ICON_LIST} User-level cleanup will proceed automatically"
        echo ""
    fi
}

perform_cleanup() {
    if [[ -n "$EXTERNAL_VOLUME_TARGET" ]]; then
        total_items=0
        files_cleaned=0
        total_size_cleaned=0
    fi

    # Test mode skips expensive scans and returns minimal output.
    local test_mode_enabled=false
    if [[ -z "$EXTERNAL_VOLUME_TARGET" && "${MOLE_TEST_MODE:-0}" == "1" && ! clean_machine_mode_enabled ]]; then
        test_mode_enabled=true
        if [[ "$DRY_RUN" == "true" ]]; then
            echo -e "${YELLOW}Dry Run Mode${NC}, Preview only, no deletions"
            echo ""
        fi
        echo -e "${GREEN}${ICON_LIST}${NC} User app cache"
        if [[ ${#WHITELIST_PATTERNS[@]} -gt 0 ]]; then
            local -a expanded_defaults
            expanded_defaults=()
            for default in "${DEFAULT_WHITELIST_PATTERNS[@]}"; do
                expanded_defaults+=("${default/#\~/$HOME}")
            done
            local has_custom=false
            for pattern in "${WHITELIST_PATTERNS[@]}"; do
                local is_default=false
                local normalized_pattern="${pattern%/}"
                for default in "${expanded_defaults[@]}"; do
                    local normalized_default="${default%/}"
                    [[ "$normalized_pattern" == "$normalized_default" ]] && is_default=true && break
                done
                [[ "$is_default" == "false" ]] && has_custom=true && break
            done
            [[ "$has_custom" == "true" ]] && echo -e "${GREEN}${ICON_SUCCESS}${NC} Protected items found"
        fi
        if [[ "$DRY_RUN" == "true" ]]; then
            echo ""
            echo "Potential space: 0.00GB"
        fi
        total_items=1
        files_cleaned=0
        total_size_cleaned=0
    fi

    if [[ "$test_mode_enabled" == "false" && -z "$EXTERNAL_VOLUME_TARGET" && ! clean_machine_mode_enabled ]]; then
        echo -e "${BLUE}${ICON_ADMIN}${NC} $(detect_architecture) | Free space: $(get_free_space)"
    fi

    if [[ "$test_mode_enabled" == "true" ]]; then
        local summary_heading="Test mode complete"
        local -a summary_details
        summary_details=()
        summary_details+=("Test mode - no actual cleanup performed")
        if ! clean_machine_mode_enabled; then
            print_summary_block "$summary_heading" "${summary_details[@]}"
            printf '\n'
        fi
        return 0
    fi

    # Pre-check TCC permissions to avoid mid-run prompts.
    if [[ -z "$EXTERNAL_VOLUME_TARGET" && "$MOLE_OUTPUT_MODE" != "preflight" ]]; then
        if ! clean_machine_mode_enabled; then
            check_tcc_permissions
        fi
    fi

    if [[ ${#WHITELIST_PATTERNS[@]} -gt 0 ]]; then
        local predefined_count=0
        local custom_count=0

        for pattern in "${WHITELIST_PATTERNS[@]}"; do
            local is_predefined=false
            for default in "${DEFAULT_WHITELIST_PATTERNS[@]}"; do
                local expanded_default="${default/#\~/$HOME}"
                if [[ "$pattern" == "$expanded_default" ]]; then
                    is_predefined=true
                    break
                fi
            done

            if [[ "$is_predefined" == "true" ]]; then
                predefined_count=$((predefined_count + 1))
            else
                custom_count=$((custom_count + 1))
            fi
        done

        if [[ $custom_count -gt 0 || $predefined_count -gt 0 ]]; then
            local summary=""
            [[ $predefined_count -gt 0 ]] && summary+="$predefined_count core"
            [[ $custom_count -gt 0 && $predefined_count -gt 0 ]] && summary+=" + "
            [[ $custom_count -gt 0 ]] && summary+="$custom_count custom"
            summary+=" patterns active"

            if ! clean_machine_mode_enabled; then
                echo -e "${BLUE}${ICON_SUCCESS}${NC} Whitelist: $summary"
            fi

            if [[ "$DRY_RUN" == "true" && ! clean_machine_mode_enabled ]]; then
                for pattern in "${WHITELIST_PATTERNS[@]}"; do
                    [[ "$pattern" == "$FINDER_METADATA_SENTINEL" ]] && continue
                    echo -e "  ${GRAY}${ICON_SUBLIST}${NC} ${GRAY}${pattern}${NC}"
                done
            fi
        fi
    fi

    if [[ -t 1 && "$DRY_RUN" != "true" && ! clean_machine_mode_enabled ]]; then
        local fda_status=0
        has_full_disk_access
        fda_status=$?
        if [[ $fda_status -eq 1 ]]; then
            echo ""
            echo -e "${GRAY}${ICON_REVIEW}${NC} ${GRAY}Grant Full Disk Access to your terminal in System Settings for best results${NC}"
        fi
    fi

    total_items=0
    files_cleaned=0
    total_size_cleaned=0

    local had_errexit=0
    [[ $- == *e* ]] && had_errexit=1

    # Allow per-section failures without aborting the full run.
    set +e

    if ! clean_machine_mode_enabled && [[ ${#WHITELIST_WARNINGS[@]} -gt 0 ]]; then
        echo ""
        local warning
        for warning in "${WHITELIST_WARNINGS[@]}"; do
            echo -e "  ${GRAY}${ICON_WARNING}${NC} Whitelist: $warning"
        done
    fi

    local run_rc=0
    clean_run_selected_sections || run_rc=$?

    # ===== Final summary =====
    if ! clean_machine_mode_enabled; then
        echo ""

        local summary_heading=""
        local summary_status="success"
        if [[ "$DRY_RUN" == "true" ]]; then
            summary_heading="Dry run complete - no changes made"
        else
            summary_heading="Cleanup complete"
        fi

        local -a summary_details=()

        if [[ $total_size_cleaned -gt 0 ]]; then
            local freed_size_human
            freed_size_human=$(bytes_to_human_kb "$total_size_cleaned")

            if [[ "$DRY_RUN" == "true" ]]; then
                local stats="Potential space: ${GREEN}${freed_size_human}${NC}"
                [[ $files_cleaned -gt 0 ]] && stats+=" | Items: $files_cleaned"
                [[ $total_items -gt 0 ]] && stats+=" | Categories: $total_items"
                summary_details+=("$stats")

                {
                    echo ""
                    echo "# ============================================"
                    echo "# Summary"
                    echo "# ============================================"
                    echo "# Potential cleanup: ${freed_size_human}"
                    echo "# Items: $files_cleaned"
                    echo "# Categories: $total_items"
                } >> "$EXPORT_LIST_FILE"

                summary_details+=("Detailed file list: ${GRAY}$EXPORT_LIST_FILE${NC}")
                summary_details+=("Use ${GRAY}mo clean --whitelist${NC} to add protection rules")
            else
                local summary_line="Space freed: ${GREEN}${freed_size_human}${NC}"

                if [[ $files_cleaned -gt 0 && $total_items -gt 0 ]]; then
                    summary_line+=" | Items cleaned: $files_cleaned | Categories: $total_items"
                elif [[ $files_cleaned -gt 0 ]]; then
                    summary_line+=" | Items cleaned: $files_cleaned"
                elif [[ $total_items -gt 0 ]]; then
                    summary_line+=" | Categories: $total_items"
                fi

                summary_details+=("$summary_line")

                if ((total_size_cleaned >= MOLE_ONE_GIB_KB)); then
                    local freed_gb=$((total_size_cleaned / MOLE_ONE_GIB_KB))
                    local movies=$((freed_gb * 10 / 45))

                    if [[ $movies -gt 0 ]]; then
                        if [[ $movies -eq 1 ]]; then
                            summary_details+=("Equivalent to ~$movies 4K movie of storage.")
                        else
                            summary_details+=("Equivalent to ~$movies 4K movies of storage.")
                        fi
                    fi
                fi

                local final_free_space
                final_free_space=$(get_free_space)
                summary_details+=("Free space now: $final_free_space")
            fi
        else
            summary_status="info"
            if [[ "$DRY_RUN" == "true" ]]; then
                summary_details+=("No significant reclaimable space detected, system already clean.")
            else
                summary_details+=("System was already clean; no additional space freed.")
            fi
            summary_details+=("Free space now: $(get_free_space)")
        fi

        print_summary_block "$summary_heading" "${summary_details[@]}"
        printf '\n'
    else
        local steps_ok=0
        local steps_blocked=0
        local steps_failed=0
        local step_json status_value
        for step_json in "${MOLE_MACHINE_STEP_RESULTS_JSON[@]-}"; do
            status_value=$(printf '%s' "$step_json" | sed -n 's/.*"status":"\([^"]*\)".*/\1/p')
            case "$status_value" in
                ok) steps_ok=$((steps_ok + 1)) ;;
                blocked) steps_blocked=$((steps_blocked + 1)) ;;
                failed) steps_failed=$((steps_failed + 1)) ;;
            esac
        done

        local final_status="ok"
        if [[ "$MOLE_OUTPUT_MODE" == "preflight" ]]; then
            [[ $steps_blocked -gt 0 ]] && final_status="blocked"
        elif [[ $run_rc -eq 4 ]]; then
            final_status="blocked"
        elif [[ $run_rc -ne 0 ]]; then
            final_status="failed"
        elif [[ $steps_failed -gt 0 || $steps_blocked -gt 0 ]]; then
            final_status="partial"
        fi

        local candidates_json='[]'
        local machine_candidate_count=0
        local candidate_entry
        for candidate_entry in "${MOLE_MACHINE_PLAN_CANDIDATES_JSON[@]-}"; do
            [[ -n "$candidate_entry" ]] && machine_candidate_count=$((machine_candidate_count + 1))
        done
        if [[ $machine_candidate_count -gt 0 ]]; then
            candidates_json=$(mole_machine_json_array_from_lines "${MOLE_MACHINE_PLAN_CANDIDATES_JSON[@]-}")
        fi

        local summary_json
        summary_json=$(mole_machine_build_final_result_json "$final_status" "$((total_size_cleaned * 1024))" "$files_cleaned" "$whitelist_skipped_count" "${MOLE_PERMISSION_DENIED_COUNT:-0}" "$steps_ok" "$steps_blocked" "$steps_failed" "$candidates_json")
        mole_machine_emit "result" "$summary_json"
        [[ -n "$MOLE_SUMMARY_FILE" ]] && mole_machine_write_json_file "$MOLE_SUMMARY_FILE" "$summary_json"
        [[ -n "$MOLE_PLAN_FILE" ]] && mole_machine_write_json_file "$MOLE_PLAN_FILE" "$summary_json"
    fi

    if [[ $had_errexit -eq 1 ]]; then
        set -e
    fi

    # Log session end with summary
    log_operation_session_end "clean" "$files_cleaned" "$total_size_cleaned"

    if clean_machine_mode_enabled; then
        return "$run_rc"
    fi
    return 0
}

main() {
    local original_args=("$@")
    while [[ $# -gt 0 ]]; do
        case "$1" in
            "--help" | "-h")
                show_clean_help
                exit 0
                ;;
            "--debug")
                export MO_DEBUG=1
                ;;
            "--dry-run" | "-n")
                DRY_RUN=true
                export MOLE_DRY_RUN=1
                ;;
            "--interface")
                shift
                [[ $# -eq 0 ]] && {
                    echo "Missing value for --interface" >&2
                    exit 2
                }
                MOLE_INTERFACE="$1"
                ;;
            "--preflight")
                MOLE_OUTPUT_MODE="preflight"
                ;;
            "--scope")
                shift
                [[ $# -eq 0 ]] && {
                    echo "Missing value for --scope" >&2
                    exit 2
                }
                MOLE_SCOPE="$1"
                ;;
            "--steps")
                shift
                [[ $# -eq 0 ]] && {
                    echo "Missing value for --steps" >&2
                    exit 2
                }
                MOLE_SELECTED_STEPS_CSV="$1"
                ;;
            "--blocking-policy")
                shift
                [[ $# -eq 0 ]] && {
                    echo "Missing value for --blocking-policy" >&2
                    exit 2
                }
                MOLE_BLOCKING_POLICY="$1"
                ;;
            "--events-file")
                shift
                [[ $# -eq 0 ]] && {
                    echo "Missing value for --events-file" >&2
                    exit 2
                }
                MOLE_EVENTS_FILE="$1"
                ;;
            "--summary-file")
                shift
                [[ $# -eq 0 ]] && {
                    echo "Missing value for --summary-file" >&2
                    exit 2
                }
                MOLE_SUMMARY_FILE="$1"
                ;;
            "--plan-file")
                shift
                [[ $# -eq 0 ]] && {
                    echo "Missing value for --plan-file" >&2
                    exit 2
                }
                MOLE_PLAN_FILE="$1"
                ;;
            "--run-id")
                shift
                [[ $# -eq 0 ]] && {
                    echo "Missing value for --run-id" >&2
                    exit 2
                }
                MOLE_RUN_ID="$1"
                export MOLE_RUN_ID
                ;;
            "--item-events")
                shift
                [[ $# -eq 0 ]] && {
                    echo "Missing value for --item-events" >&2
                    exit 2
                }
                MOLE_ITEM_EVENTS="$1"
                ;;
            "--non-interactive")
                :
                ;;
            "--no-color" | "--no-spinner")
                :
                ;;
            "--external")
                shift
                if [[ $# -eq 0 ]]; then
                    echo "Missing path for --external" >&2
                    exit 2
                fi
                EXTERNAL_VOLUME_TARGET=$(validate_external_volume_target "$1") || exit 1
                ;;
            "--whitelist")
                source "$SCRIPT_DIR/../lib/manage/whitelist.sh"
                manage_whitelist "clean"
                exit 0
                ;;
            *)
                echo "Unknown clean option: $1" >&2
                exit 2
                ;;
        esac
        shift
    done

    case "$MOLE_INTERFACE" in
        human | jsonl) ;;
        *)
            echo "Unsupported --interface: $MOLE_INTERFACE" >&2
            exit 2
            ;;
    esac

    case "$MOLE_SCOPE" in
        all | user | system | external) ;;
        *)
            echo "Unsupported --scope: $MOLE_SCOPE" >&2
            exit 2
            ;;
    esac

    case "$MOLE_BLOCKING_POLICY" in
        skip | fail) ;;
        *)
            echo "Unsupported --blocking-policy: $MOLE_BLOCKING_POLICY" >&2
            exit 2
            ;;
    esac

    case "$MOLE_ITEM_EVENTS" in
        none | grouped | all) ;;
        *)
            echo "Unsupported --item-events: $MOLE_ITEM_EVENTS" >&2
            exit 2
            ;;
    esac

    if [[ "$MOLE_OUTPUT_MODE" == "preflight" && "$DRY_RUN" == "true" ]]; then
        echo "--preflight cannot be combined with --dry-run" >&2
        exit 2
    fi

    if [[ "$DRY_RUN" == "true" && "$MOLE_OUTPUT_MODE" != "preflight" ]]; then
        MOLE_OUTPUT_MODE="plan"
    fi

    if [[ -n "$MOLE_PLAN_FILE" && "$DRY_RUN" != "true" ]]; then
        echo "--plan-file requires --dry-run" >&2
        exit 2
    fi

    if [[ "$MOLE_INTERFACE" == "jsonl" ]]; then
        export MOLE_SILENT_STDIO=1
        export MOLE_MACHINE_SILENT_STDIO=1
        export NO_COLOR=1
    fi

    clean_resolve_selected_steps
    if [[ $(clean_selected_step_count) -eq 0 ]]; then
        echo "No clean steps selected" >&2
        exit 2
    fi

    if clean_machine_mode_enabled; then
        mole_machine_init_output
        if [[ -z "$MOLE_EVENTS_FILE" ]]; then
            exec 3>&1
            MOLE_MACHINE_STDOUT_FD=3
        fi
        clean_emit_run_context "${original_args[@]}"
        clean_emit_capabilities
    fi

    start_cleanup
    if ! clean_machine_mode_enabled; then
        clean_resolve_selected_steps
    fi
    if ! clean_machine_mode_enabled; then
        hide_cursor
    fi
    local run_status=0
    perform_cleanup || run_status=$?
    if ! clean_machine_mode_enabled; then
        show_cursor
    fi
    exit "$run_status"
}

main "$@"
