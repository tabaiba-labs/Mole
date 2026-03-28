#!/bin/bash
# Mole - Machine-readable output helpers.

set -euo pipefail

if [[ -n "${MOLE_MACHINE_OUTPUT_LOADED:-}" ]]; then
    return 0
fi
readonly MOLE_MACHINE_OUTPUT_LOADED=1

MOLE_MACHINE_EVENT_SEQ=0
MOLE_MACHINE_EVENT_SINK=""
MOLE_MACHINE_RUN_STARTED_AT=""
MOLE_MACHINE_RUN_CONTEXT_JSON=""
declare -a MOLE_MACHINE_CAPABILITIES_JSON=()
declare -a MOLE_MACHINE_SECTION_RESULTS_JSON=()
declare -a MOLE_MACHINE_STEP_RESULTS_JSON=()
declare -a MOLE_MACHINE_PLAN_CANDIDATES_JSON=()
declare -a MOLE_MACHINE_NEXT_ACTIONS_JSON=()

mole_machine_is_jsonl() {
    [[ "${MOLE_INTERFACE:-human}" == "jsonl" ]]
}

mole_machine_is_silent() {
    [[ "${MOLE_MACHINE_SILENT_STDIO:-0}" == "1" ]]
}

mole_machine_json_escape() {
    local value="${1:-}"
    value=${value//\\/\\\\}
    value=${value//"/\\"}
    value=${value//$'\n'/\\n}
    value=${value//$'\r'/\\r}
    value=${value//$'\t'/\\t}
    printf '%s' "$value"
}

mole_machine_json_string() {
    printf '"%s"' "$(mole_machine_json_escape "${1:-}")"
}

mole_machine_json_bool() {
    if [[ "${1:-false}" == "true" ]]; then
        printf 'true'
    else
        printf 'false'
    fi
}

mole_machine_json_number() {
    local value="${1:-0}"
    if [[ "$value" =~ ^-?[0-9]+([.][0-9]+)?$ ]]; then
        printf '%s' "$value"
    else
        printf '0'
    fi
}

mole_machine_json_array_from_csv() {
    local csv="${1:-}"
    local result="["
    local first=true
    local item

    if [[ -n "$csv" ]]; then
        local old_ifs="$IFS"
        IFS=','
        for item in $csv; do
            [[ -z "$item" ]] && continue
            if [[ "$first" == "true" ]]; then
                first=false
            else
                result+=","
            fi
            result+=$(mole_machine_json_string "$item")
        done
        IFS="$old_ifs"
    fi

    result+="]"
    printf '%s' "$result"
}

mole_machine_json_array_from_lines() {
    local result="["
    local first=true
    local item
    for item in "$@"; do
        [[ -z "$item" ]] && continue
        if [[ "$first" == "true" ]]; then
            first=false
        else
            result+=","
        fi
        result+="$item"
    done
    result+="]"
    printf '%s' "$result"
}

mole_machine_now_utc() {
    date -u '+%Y-%m-%dT%H:%M:%SZ'
}

mole_machine_candidate_id_for_path() {
    local path="$1"
    local identity
    identity=$(mole_path_identity "$path")
    printf 'fs:%s\n' "${identity//[^a-zA-Z0-9._:-]/_}"
}

mole_machine_candidate_id_for_logical() {
    local slug="$1"
    printf 'logical:%s:%s\n' "${MOLE_CLEAN_CURRENT_STEP_ID:-unknown}" "$slug"
}

mole_machine_init_output() {
    mole_machine_is_jsonl || return 0

    if [[ -z "${MOLE_RUN_ID:-}" ]]; then
        local epoch random_part pid_part
        epoch=$(date +%s 2> /dev/null || echo "0")
        random_part=${RANDOM:-0}
        pid_part=$$
        MOLE_RUN_ID="mole-${epoch}-${pid_part}-${random_part}"
        export MOLE_RUN_ID
    fi

    MOLE_MACHINE_RUN_STARTED_AT=$(mole_machine_now_utc)

    if [[ -n "${MOLE_EVENTS_FILE:-}" ]]; then
        ensure_user_file "$MOLE_EVENTS_FILE"
        : > "$MOLE_EVENTS_FILE"
        MOLE_MACHINE_EVENT_SINK="$MOLE_EVENTS_FILE"
    else
        MOLE_MACHINE_EVENT_SINK=""
    fi
}

mole_machine_emit() {
    mole_machine_is_jsonl || return 0

    local event_name="$1"
    local data_json="${2-}"
    [[ -z "$data_json" ]] && data_json='{}'
    MOLE_MACHINE_EVENT_SEQ=$((MOLE_MACHINE_EVENT_SEQ + 1))

    local line
    line=$(printf '{"v":1,"run_id":%s,"seq":%s,"ts":%s,"command":"clean","mode":%s,"event":%s,"data":%s}' \
        "$(mole_machine_json_string "${MOLE_RUN_ID:-}")" \
        "$(mole_machine_json_number "$MOLE_MACHINE_EVENT_SEQ")" \
        "$(mole_machine_json_string "$(mole_machine_now_utc)")" \
        "$(mole_machine_json_string "${MOLE_OUTPUT_MODE:-execute}")" \
        "$(mole_machine_json_string "$event_name")" \
        "$data_json")

    if [[ -n "$MOLE_MACHINE_EVENT_SINK" ]]; then
        printf '%s\n' "$line" >> "$MOLE_MACHINE_EVENT_SINK"
    elif [[ -n "${MOLE_MACHINE_STDOUT_FD:-}" ]]; then
        printf '%s\n' "$line" >&${MOLE_MACHINE_STDOUT_FD}
    else
        printf '%s\n' "$line"
    fi
}

mole_machine_record_capability() {
    mole_machine_is_jsonl || return 0
    local capability_id="$1"
    local state="$2"
    local severity="$3"
    local affects_csv="${4:-}"
    local message="${5:-}"
    local remediation_kind="${6:-none}"

    local json
    json=$(printf '{"capability_id":%s,"state":%s,"severity":%s,"affects_steps":%s,"message":%s,"remediation":{"kind":%s}}' \
        "$(mole_machine_json_string "$capability_id")" \
        "$(mole_machine_json_string "$state")" \
        "$(mole_machine_json_string "$severity")" \
        "$(mole_machine_json_array_from_csv "$affects_csv")" \
        "$(mole_machine_json_string "$message")" \
        "$(mole_machine_json_string "$remediation_kind")")

    MOLE_MACHINE_CAPABILITIES_JSON+=("$json")
    mole_machine_emit "capability.state" "$json"
}

mole_machine_notice() {
    mole_machine_is_jsonl || return 0
    local level="$1"
    local code="$2"
    local message="$3"
    local section_id="${4:-}"
    local step_id="${5:-}"

    local json
    json=$(printf '{"level":%s,"code":%s,"section_id":%s,"step_id":%s,"message":%s}' \
        "$(mole_machine_json_string "$level")" \
        "$(mole_machine_json_string "$code")" \
        "$(mole_machine_json_string "$section_id")" \
        "$(mole_machine_json_string "$step_id")" \
        "$(mole_machine_json_string "$message")")
    mole_machine_emit "notice" "$json"
}

mole_machine_candidate_found() {
    mole_machine_is_jsonl || return 0
    local candidate_id="$1"
    local label="$2"
    local target_kind="$3"
    local action_kind="$4"
    local path="$5"
    local display_path="$6"
    local item_kind="$7"
    local estimated_bytes="${8:-0}"
    local estimated_items="${9:-0}"
    local requires_csv="${10:-}"
    local metadata_json="${11-}"
    [[ -z "$metadata_json" ]] && metadata_json='{}'

    local json
    json=$(printf '{"candidate_id":%s,"step_id":%s,"section_id":%s,"label":%s,"target_kind":%s,"action_kind":%s,"path":%s,"display_path":%s,"item_kind":%s,"estimated_bytes":%s,"estimated_items":%s,"requires_capabilities":%s,"selected_default":true,"metadata":%s}' \
        "$(mole_machine_json_string "$candidate_id")" \
        "$(mole_machine_json_string "${MOLE_CLEAN_CURRENT_STEP_ID:-}")" \
        "$(mole_machine_json_string "${MOLE_CLEAN_CURRENT_SECTION_ID:-}")" \
        "$(mole_machine_json_string "$label")" \
        "$(mole_machine_json_string "$target_kind")" \
        "$(mole_machine_json_string "$action_kind")" \
        "$(mole_machine_json_string "$path")" \
        "$(mole_machine_json_string "$display_path")" \
        "$(mole_machine_json_string "$item_kind")" \
        "$(mole_machine_json_number "$estimated_bytes")" \
        "$(mole_machine_json_number "$estimated_items")" \
        "$(mole_machine_json_array_from_csv "$requires_csv")" \
        "$metadata_json")
    MOLE_MACHINE_PLAN_CANDIDATES_JSON+=("$json")
    mole_machine_emit "candidate.found" "$json"
}

mole_machine_candidate_skipped() {
    mole_machine_is_jsonl || return 0
    local candidate_id="$1"
    local label="$2"
    local reason_code="$3"
    local message="$4"

    local json
    json=$(printf '{"candidate_id":%s,"step_id":%s,"section_id":%s,"label":%s,"reason_code":%s,"message":%s}' \
        "$(mole_machine_json_string "$candidate_id")" \
        "$(mole_machine_json_string "${MOLE_CLEAN_CURRENT_STEP_ID:-}")" \
        "$(mole_machine_json_string "${MOLE_CLEAN_CURRENT_SECTION_ID:-}")" \
        "$(mole_machine_json_string "$label")" \
        "$(mole_machine_json_string "$reason_code")" \
        "$(mole_machine_json_string "$message")")
    mole_machine_emit "candidate.skipped" "$json"
}

mole_machine_item_result() {
    mole_machine_is_jsonl || return 0
    local candidate_id="$1"
    local label="$2"
    local outcome="$3"
    local actual_bytes="${4:-0}"
    local actual_items="${5:-0}"
    local reason_code="${6:-}"
    local duration_ms="${7:-0}"

    local reason_json="null"
    if [[ -n "$reason_code" ]]; then
        reason_json=$(mole_machine_json_string "$reason_code")
    fi

    local json
    json=$(printf '{"candidate_id":%s,"step_id":%s,"label":%s,"outcome":%s,"actual_bytes":%s,"actual_items":%s,"reason_code":%s,"duration_ms":%s}' \
        "$(mole_machine_json_string "$candidate_id")" \
        "$(mole_machine_json_string "${MOLE_CLEAN_CURRENT_STEP_ID:-}")" \
        "$(mole_machine_json_string "$label")" \
        "$(mole_machine_json_string "$outcome")" \
        "$(mole_machine_json_number "$actual_bytes")" \
        "$(mole_machine_json_number "$actual_items")" \
        "$reason_json" \
        "$(mole_machine_json_number "$duration_ms")")
    mole_machine_emit "item.result" "$json"
}

mole_machine_record_step_result() {
    mole_machine_is_jsonl || return 0
    local step_id="$1"
    local section_id="$2"
    local status="$3"
    local bytes="$4"
    local items="$5"
    local skipped="$6"
    local failed="$7"
    local duration_ms="$8"
    local reason_code="${9:-}"

    local reason_field='null'
    if [[ -n "$reason_code" ]]; then
        reason_field=$(mole_machine_json_string "$reason_code")
    fi

    local json
    json=$(printf '{"step_id":%s,"section_id":%s,"status":%s,"freed_bytes":%s,"items":%s,"skipped":%s,"failed":%s,"duration_ms":%s,"reason_code":%s}' \
        "$(mole_machine_json_string "$step_id")" \
        "$(mole_machine_json_string "$section_id")" \
        "$(mole_machine_json_string "$status")" \
        "$(mole_machine_json_number "$bytes")" \
        "$(mole_machine_json_number "$items")" \
        "$(mole_machine_json_number "$skipped")" \
        "$(mole_machine_json_number "$failed")" \
        "$(mole_machine_json_number "$duration_ms")" \
        "$reason_field")
    MOLE_MACHINE_STEP_RESULTS_JSON+=("$json")
}

mole_machine_record_section_result() {
    mole_machine_is_jsonl || return 0
    local section_id="$1"
    local status="$2"
    local bytes="$3"
    local items="$4"
    local skipped="$5"
    local failed="$6"
    local duration_ms="$7"

    local json
    json=$(printf '{"section_id":%s,"status":%s,"freed_bytes":%s,"items":%s,"skipped":%s,"failed":%s,"duration_ms":%s}' \
        "$(mole_machine_json_string "$section_id")" \
        "$(mole_machine_json_string "$status")" \
        "$(mole_machine_json_number "$bytes")" \
        "$(mole_machine_json_number "$items")" \
        "$(mole_machine_json_number "$skipped")" \
        "$(mole_machine_json_number "$failed")" \
        "$(mole_machine_json_number "$duration_ms")")
    MOLE_MACHINE_SECTION_RESULTS_JSON+=("$json")
}

mole_machine_write_json_file() {
    local target_file="$1"
    local json_payload="$2"
    [[ -z "$target_file" ]] && return 0

    local parent_dir
    parent_dir=$(dirname "$target_file")
    mkdir -p "$parent_dir"

    local tmp_file
    tmp_file=$(mktemp "$parent_dir/.mole-machine.XXXXXX")
    printf '%s\n' "$json_payload" > "$tmp_file"
    mv -f "$tmp_file" "$target_file"
}

mole_machine_capabilities_object_json() {
    local result="{"
    local first=true
    local entry capability_id capability_state

    for entry in "${MOLE_MACHINE_CAPABILITIES_JSON[@]-}"; do
        capability_id=$(printf '%s' "$entry" | sed -n 's/.*"capability_id":"\([^"]*\)".*/\1/p')
        capability_state=$(printf '%s' "$entry" | sed -n 's/.*"state":"\([^"]*\)".*/\1/p')
        [[ -z "$capability_id" ]] && continue
        if [[ "$first" == "true" ]]; then
            first=false
        else
            result+=","
        fi
        result+=$(mole_machine_json_string "$capability_id")
        result+=":"
        result+=$(mole_machine_json_string "$capability_state")
    done

    result+="}"
    printf '%s' "$result"
}

mole_machine_build_final_result_json() {
    local status="$1"
    local total_bytes="$2"
    local total_items="$3"
    local total_skipped="$4"
    local total_failed="$5"
    local steps_ok="$6"
    local steps_blocked="$7"
    local steps_failed="$8"
    local plan_mode_candidates_json="${9:-[]}"
    local finished_at duration_ms outputs_json

    finished_at=$(mole_machine_now_utc)
    duration_ms=0
    outputs_json=$(printf '{"events_file":%s,"summary_file":%s,"plan_file":%s,"operations_log":%s,"debug_log":%s}' \
        "$(mole_machine_json_string "${MOLE_EVENTS_FILE:-}")" \
        "$(mole_machine_json_string "${MOLE_SUMMARY_FILE:-}")" \
        "$(mole_machine_json_string "${MOLE_PLAN_FILE:-}")" \
        "$(mole_machine_json_string "${OPERATIONS_LOG_FILE:-}")" \
        "$(mole_machine_json_string "${DEBUG_LOG_FILE:-}")")

    printf '{"status":%s,"mode":%s,"scope_effective":%s,"started_at":%s,"finished_at":%s,"duration_ms":%s,"totals":{"estimated_bytes":%s,"freed_bytes":%s,"candidates_found":%s,"items_deleted":%s,"items_skipped":%s,"items_failed":%s,"steps_ok":%s,"steps_blocked":%s,"steps_failed":%s},"capabilities":%s,"sections":%s,"steps":%s,"candidates":%s,"outputs":%s,"next_actions":%s}' \
        "$(mole_machine_json_string "$status")" \
        "$(mole_machine_json_string "${MOLE_OUTPUT_MODE:-execute}")" \
        "$(mole_machine_json_string "${MOLE_SCOPE_EFFECTIVE:-all}")" \
        "$(mole_machine_json_string "${MOLE_MACHINE_RUN_STARTED_AT:-}")" \
        "$(mole_machine_json_string "$finished_at")" \
        "$(mole_machine_json_number "$duration_ms")" \
        "$(mole_machine_json_number "$total_bytes")" \
        "$(mole_machine_json_number "$total_bytes")" \
        "$(mole_machine_json_number "$total_items")" \
        "$(mole_machine_json_number "$total_items")" \
        "$(mole_machine_json_number "$total_skipped")" \
        "$(mole_machine_json_number "$total_failed")" \
        "$(mole_machine_json_number "$steps_ok")" \
        "$(mole_machine_json_number "$steps_blocked")" \
        "$(mole_machine_json_number "$steps_failed")" \
        "$(mole_machine_capabilities_object_json)" \
        "$(mole_machine_json_array_from_lines "${MOLE_MACHINE_SECTION_RESULTS_JSON[@]-}")" \
        "$(mole_machine_json_array_from_lines "${MOLE_MACHINE_STEP_RESULTS_JSON[@]-}")" \
        "$plan_mode_candidates_json" \
        "$outputs_json" \
        "$(mole_machine_json_array_from_lines "${MOLE_MACHINE_NEXT_ACTIONS_JSON[@]-}")"
}
