#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_HOME="$(mktemp -d)"
trap 'rm -rf "$TMP_HOME"' EXIT

mkdir -p "$TMP_HOME/Library/Caches/TestApp"
printf 'cache data' > "$TMP_HOME/Library/Caches/TestApp/cache.tmp"

run_preflight() {
    local events="$TMP_HOME/preflight-events.jsonl"
    local summary="$TMP_HOME/preflight-summary.json"

    HOME="$TMP_HOME" MOLE_TEST_MODE=1 "$ROOT_DIR/mole" clean \
        --interface jsonl --preflight --scope all \
        --events-file "$events" --summary-file "$summary" > /dev/null

    python3 - <<'PY' "$events" "$summary"
import json, pathlib, sys
events = [json.loads(line) for line in pathlib.Path(sys.argv[1]).read_text().splitlines() if line.strip()]
summary = json.loads(pathlib.Path(sys.argv[2]).read_text())
assert events[0]["event"] == "run.started"
assert events[-1]["event"] == "result"
assert summary["mode"] == "preflight"
PY
}

run_plan() {
    local events="$TMP_HOME/plan-events.jsonl"
    local plan="$TMP_HOME/plan-summary.json"

    HOME="$TMP_HOME" MOLE_TEST_MODE=1 "$ROOT_DIR/mole" clean \
        --interface jsonl --dry-run --scope user \
        --events-file "$events" --plan-file "$plan" > /dev/null

    python3 - <<'PY' "$events" "$plan"
import json, pathlib, sys
events = [json.loads(line) for line in pathlib.Path(sys.argv[1]).read_text().splitlines() if line.strip()]
plan = json.loads(pathlib.Path(sys.argv[2]).read_text())
assert any(event["event"] == "candidate.found" for event in events)
assert plan["mode"] == "plan"
assert len(plan["candidates"]) >= 1
PY
}

run_execute() {
    local events="$TMP_HOME/execute-events.jsonl"
    local summary="$TMP_HOME/execute-summary.json"

    HOME="$TMP_HOME" MOLE_TEST_MODE=1 "$ROOT_DIR/mole" clean \
        --interface jsonl --scope user \
        --events-file "$events" --summary-file "$summary" > /dev/null

    python3 - <<'PY' "$events" "$summary" "$TMP_HOME/Library/Caches/TestApp/cache.tmp"
import json, pathlib, sys
events = [json.loads(line) for line in pathlib.Path(sys.argv[1]).read_text().splitlines() if line.strip()]
summary = json.loads(pathlib.Path(sys.argv[2]).read_text())
assert events[-1]["event"] == "result"
assert summary["mode"] == "execute"
assert summary["totals"]["items_deleted"] >= 1
assert not pathlib.Path(sys.argv[3]).exists()
PY
}

run_preflight
run_plan
run_execute

printf 'clean jsonl smoke checks passed\n'
