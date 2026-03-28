#!/usr/bin/env bats

setup_file() {
    PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    export PROJECT_ROOT

    ORIGINAL_HOME="${HOME:-}"
    export ORIGINAL_HOME

    HOME="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-clean-jsonl-home.XXXXXX")"
    export HOME

    mkdir -p "$HOME"
}

teardown_file() {
    rm -rf "$HOME"
    if [[ -n "${ORIGINAL_HOME:-}" ]]; then
        export HOME="$ORIGINAL_HOME"
    fi
}

setup() {
    rm -rf "$HOME/.config/mole" "$HOME/Library"
    mkdir -p "$HOME/.config/mole" "$HOME/Library/Caches"
}

@test "mo clean jsonl preflight writes summary and capability events" {
    local events_file="$HOME/events.jsonl"
    local summary_file="$HOME/summary.json"

    run env HOME="$HOME" MOLE_TEST_MODE=1 "$PROJECT_ROOT/mole" clean \
        --interface jsonl --preflight --scope all \
        --events-file "$events_file" --summary-file "$summary_file"

    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ -f "$events_file" ]
    [ -f "$summary_file" ]

    run python3 - <<'PY' "$events_file" "$summary_file"
import json, sys, pathlib
events = [json.loads(line) for line in pathlib.Path(sys.argv[1]).read_text().splitlines() if line.strip()]
summary = json.loads(pathlib.Path(sys.argv[2]).read_text())
assert events[0]["event"] == "run.started"
assert any(event["event"] == "capability.state" for event in events)
assert events[-1]["event"] == "result"
assert summary["mode"] == "preflight"
assert summary["status"] in {"blocked", "ok"}
PY

    [ "$status" -eq 0 ]
}

@test "mo clean jsonl dry-run writes plan with candidates" {
    mkdir -p "$HOME/Library/Caches/TestApp"
    echo "cache data" > "$HOME/Library/Caches/TestApp/cache.tmp"

    local events_file="$HOME/events.jsonl"
    local plan_file="$HOME/plan.json"

    run env HOME="$HOME" MOLE_TEST_MODE=1 "$PROJECT_ROOT/mole" clean \
        --interface jsonl --dry-run --scope user \
        --events-file "$events_file" --plan-file "$plan_file"

    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ -f "$events_file" ]
    [ -f "$plan_file" ]
    [ -f "$HOME/Library/Caches/TestApp/cache.tmp" ]

    run python3 - <<'PY' "$events_file" "$plan_file"
import json, sys, pathlib
events = [json.loads(line) for line in pathlib.Path(sys.argv[1]).read_text().splitlines() if line.strip()]
plan = json.loads(pathlib.Path(sys.argv[2]).read_text())
assert any(event["event"] == "candidate.found" for event in events)
assert plan["mode"] == "plan"
assert len(plan["candidates"]) >= 1
PY

    [ "$status" -eq 0 ]
}

@test "mo clean jsonl execute user scope deletes files and writes summary" {
    mkdir -p "$HOME/Library/Caches/TestApp"
    echo "cache data" > "$HOME/Library/Caches/TestApp/cache.tmp"

    local events_file="$HOME/events.jsonl"
    local summary_file="$HOME/summary.json"

    run env HOME="$HOME" MOLE_TEST_MODE=1 "$PROJECT_ROOT/mole" clean \
        --interface jsonl --scope user \
        --events-file "$events_file" --summary-file "$summary_file"

    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ -f "$events_file" ]
    [ -f "$summary_file" ]
    [ ! -f "$HOME/Library/Caches/TestApp/cache.tmp" ]

    run python3 - <<'PY' "$events_file" "$summary_file"
import json, sys, pathlib
events = [json.loads(line) for line in pathlib.Path(sys.argv[1]).read_text().splitlines() if line.strip()]
summary = json.loads(pathlib.Path(sys.argv[2]).read_text())
assert events[-1]["event"] == "result"
assert summary["mode"] == "execute"
assert summary["status"] in {"ok", "partial"}
assert summary["totals"]["items_deleted"] >= 1
PY

    [ "$status" -eq 0 ]
}

@test "mo clean jsonl system scope can fail fast on missing sudo" {
    local events_file="$HOME/events.jsonl"
    local summary_file="$HOME/summary.json"

    run env HOME="$HOME" MOLE_TEST_MODE=1 "$PROJECT_ROOT/mole" clean \
        --interface jsonl --preflight --scope system --blocking-policy fail \
        --events-file "$events_file" --summary-file "$summary_file"

    [ "$status" -eq 4 ]
    [ -f "$summary_file" ]

    run python3 - <<'PY' "$summary_file"
import json, sys, pathlib
summary = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert summary["status"] == "blocked"
PY

    [ "$status" -eq 0 ]
}
