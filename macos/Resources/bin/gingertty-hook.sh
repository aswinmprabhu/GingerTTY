#!/usr/bin/env bash
# GingerTTY hook handler — updates tab status via AppleScript.
# Called by Claude Code hooks with the event name as $1.

set -euo pipefail

EVENT="${1:-}"
TERMINAL_ID="${GINGERTTY_TERMINAL_ID:-}"

echo "[$(date)] Hook called: EVENT=$EVENT TERMINAL_ID=$TERMINAL_ID" >> /tmp/gingertty-hook.log

[[ -z "$TERMINAL_ID" ]] && { echo "[$(date)] No TERMINAL_ID, exiting" >> /tmp/gingertty-hook.log; exit 0; }

read_hook_payload() {
    cat
}

permission_request_timeout_seconds() {
    local timeout="${GINGERTTY_PERMISSION_REQUEST_TIMEOUT_SECONDS:-30}"
    if [[ "$timeout" =~ ^[0-9]+$ ]] && [[ "$timeout" -gt 0 ]]; then
        printf '%s\n' "$timeout"
    else
        printf '30\n'
    fi
}

set_status() {
    osascript -e "tell application \"GingerTTY\" to set agent status \"$1\" on terminal id \"$TERMINAL_ID\"" &>/dev/null
}

clear_status() {
    osascript -e "tell application \"GingerTTY\" to set agent status \"\" on terminal id \"$TERMINAL_ID\"" &>/dev/null
}

prepare_permission_request_files() {
    local payload="$1"

    /usr/bin/python3 - "$TERMINAL_ID" "$payload" <<'PY'
import hashlib
import json
import pathlib
import shlex
import sys
import time


def truncate(value: str, limit: int = 180) -> str:
    value = " ".join(value.split())
    if len(value) <= limit:
        return value
    if limit <= 3:
        return value[:limit]
    return value[: limit - 3] + "..."


def summarize_tool_input(tool_name: str, tool_input) -> str:
    if not isinstance(tool_input, dict):
        return truncate(str(tool_input or tool_name))

    if tool_name == "Bash":
        description = str(tool_input.get("description") or "").strip()
        command = str(tool_input.get("command") or "").strip()
        if description and command:
            return truncate(f"{description} - {command}")
        if description:
            return truncate(description)
        if command:
            return truncate(command)

    if tool_name in {"Read", "Write", "Edit", "MultiEdit"}:
        path = str(tool_input.get("file_path") or tool_input.get("path") or "").strip()
        if path:
            return truncate(path)

    try:
        return truncate(json.dumps(tool_input, sort_keys=True, separators=(",", ": ")))
    except TypeError:
        return truncate(str(tool_input))


terminal_id = sys.argv[1]

try:
    payload = json.loads(sys.argv[2])
except json.JSONDecodeError:
    raise SystemExit(0)

if payload.get("hook_event_name") != "PermissionRequest":
    raise SystemExit(0)

tool_name = str(payload.get("tool_name") or "").strip()
if not tool_name:
    raise SystemExit(0)

tool_input = payload.get("tool_input") or {}
session_id = str(payload.get("session_id") or "session").strip() or "session"
agent_id = str(payload.get("agent_id") or "main").strip() or "main"
suggestions = payload.get("permission_suggestions")
summary = summarize_tool_input(tool_name, tool_input)

base = pathlib.Path.home() / "Library" / "Application Support" / "GingerTTY" / "PermissionRequests" / terminal_id
base.mkdir(parents=True, exist_ok=True)

digest_source = json.dumps(
    {
        "tool_name": tool_name,
        "tool_input": tool_input,
        "session_id": session_id,
        "agent_id": agent_id,
    },
    sort_keys=True,
    separators=(",", ":"),
)
signature = hashlib.sha256(digest_source.encode("utf-8")).hexdigest()[:12]
stem = f"{session_id}-{agent_id}-{int(time.time())}-{signature}"
response_path = base / f"{stem}.json"
if response_path.exists():
    response_path.unlink()

suggestions_json = ""
if suggestions:
    suggestions_json = json.dumps(suggestions, sort_keys=True, separators=(",", ":"))

print(f"RESPONSE_PATH={shlex.quote(str(response_path))}")
print(f"SESSION_ID={shlex.quote(session_id)}")
print(f"AGENT_ID={shlex.quote(agent_id)}")
print(f"TOOL_NAME={shlex.quote(tool_name)}")
print(f"INPUT_SUMMARY={shlex.quote(summary)}")
print(f"SUGGESTIONS_JSON={shlex.quote(suggestions_json)}")
PY
}

open_permission_request() {
    RESPONSE_PATH="$1" \
    SESSION_ID="$2" \
    AGENT_ID="$3" \
    TOOL_NAME="$4" \
    INPUT_SUMMARY="$5" \
    SUGGESTIONS_JSON="$6" \
    TERMINAL_ID="$TERMINAL_ID" \
    osascript <<'APPLESCRIPT' &>/dev/null
set responsePath to system attribute "RESPONSE_PATH"
set sessionID to system attribute "SESSION_ID"
set agentID to system attribute "AGENT_ID"
set toolName to system attribute "TOOL_NAME"
set inputSummary to system attribute "INPUT_SUMMARY"
set suggestionsJSON to system attribute "SUGGESTIONS_JSON"
set terminalID to system attribute "TERMINAL_ID"

tell application "GingerTTY"
    present permission request inputSummary response path responsePath session id sessionID agent id agentID tool name toolName suggestions json suggestionsJSON on terminal id terminalID
end tell
APPLESCRIPT
}

wait_for_permission_request_response() {
    local response_path="$1"
    local timeout="$2"
    local waited=0

    while [[ $waited -lt $timeout ]]; do
        if [[ -s "$response_path" ]]; then
            return 0
        fi
        sleep 1
        waited=$((waited + 1))
    done

    return 1
}

emit_permission_request_decision() {
    local response_path="$1"
    cat "$response_path"
}

prepare_plan_review_files() {
    local payload="$1"

    /usr/bin/python3 - "$TERMINAL_ID" "$payload" <<'PY'
import json
import hashlib
import pathlib
import shlex
import sys

terminal_id = sys.argv[1]
payload = json.loads(sys.argv[2])

tool_name = payload.get("tool_name")
if tool_name != "ExitPlanMode":
    raise SystemExit(0)

tool_input = payload.get("tool_input") or {}
plan_file_path = tool_input.get("planFilePath")
if not plan_file_path:
    raise SystemExit(0)

scratch_path = pathlib.Path(plan_file_path).expanduser()
if not scratch_path.exists():
    raise SystemExit(0)

plan = scratch_path.read_text(encoding="utf-8")
if not plan.strip():
    raise SystemExit(0)

session_id = payload.get("session_id") or "session"
agent_id = payload.get("agent_id") or "main"

base = pathlib.Path.home() / "Library" / "Application Support" / "GingerTTY" / "PlanReviews" / terminal_id
base.mkdir(parents=True, exist_ok=True)
stem = f"{session_id}-{agent_id}"

signature_source = f"path:{scratch_path.resolve()}:{hashlib.sha256(plan.encode('utf-8')).hexdigest()}"

dedupe_path = base / f"{session_id}.last-review"
if dedupe_path.exists() and dedupe_path.read_text(encoding="utf-8") == signature_source:
    raise SystemExit(0)
dedupe_path.write_text(signature_source, encoding="utf-8")

response_path = base / f"{stem}.json"
if response_path.exists():
    response_path.unlink()

print(f"SCRATCH_PATH={shlex.quote(str(scratch_path))}")
print(f"RESPONSE_PATH={shlex.quote(str(response_path))}")
print(f"SESSION_ID={shlex.quote(session_id)}")
print(f"AGENT_ID={shlex.quote(agent_id)}")
PY
}

open_plan_review() {
    SCRATCH_PATH="$1" \
    RESPONSE_PATH="$2" \
    SESSION_ID="$3" \
    AGENT_ID="$4" \
    TERMINAL_ID="$TERMINAL_ID" \
    osascript <<'APPLESCRIPT' &>/dev/null
set scratchPath to system attribute "SCRATCH_PATH"
set responsePath to system attribute "RESPONSE_PATH"
set sessionID to system attribute "SESSION_ID"
set agentID to system attribute "AGENT_ID"
set terminalID to system attribute "TERMINAL_ID"

tell application "GingerTTY"
    activate
    open plan review scratchPath response path responsePath session id sessionID agent id agentID on terminal id terminalID
end tell
APPLESCRIPT
}

wait_for_plan_review_response() {
    local response_path="$1"
    local waited=0
    local timeout=900

    while [[ $waited -lt $timeout ]]; do
        if [[ -s "$response_path" ]]; then
            return 0
        fi
        sleep 1
        waited=$((waited + 1))
    done

    return 1
}

emit_plan_review_decision() {
    local response_path="$1"

    /usr/bin/python3 - "$response_path" <<'PY'
import json
import sys

response_path = sys.argv[1]
with open(response_path, "r", encoding="utf-8") as handle:
    response = json.load(handle)

decision = response.get("decision")

if decision == "approve":
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PermissionRequest",
            "decision": {
                "behavior": "allow"
            }
        }
    }))
    raise SystemExit(0)

if decision == "request_changes":
    comments = sorted(
        response.get("comments", []),
        key=lambda item: (item.get("startLine", 0), item.get("endLine", 0)),
    )

    lines = ["Plan review requested changes."]
    if comments:
        lines.append("Reviewer comments:")
        for comment in comments:
            start = comment.get("startLine")
            end = comment.get("endLine")
            if start == end:
                label = f"L{start}"
            else:
                label = f"L{start}-L{end}"
            lines.append(f"- {label}: {comment.get('text', '').strip()}")

    if response.get("edited"):
        lines.append("The reviewer directly edited the plan markdown.")

    final_path = response.get("finalFilePath", "")
    if final_path:
        lines.append(f"Treat this reviewed markdown file as the source of truth: {final_path}")

    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PermissionRequest",
            "decision": {
                "behavior": "deny",
                "message": "\n".join(lines)
            }
        }
    }))
    raise SystemExit(0)

# Unknown decision - allow by default
print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "PermissionRequest",
        "decision": {
            "behavior": "allow"
        }
    }
}))
PY
}

case "$EVENT" in
    UserPromptSubmit)  set_status "Running" ;;
    PreToolUse)        set_status "Running" ;;
    Stop)              set_status "Done" ;;
    Notification)      set_status "Need input" ;;
    SessionEnd)        clear_status ;;
    PermissionRequest)
        PAYLOAD="$(read_hook_payload)"
        echo "[$(date)] PermissionRequest payload: $PAYLOAD" >> /tmp/gingertty-hook.log
        PREPARED_VARS="$(prepare_permission_request_files "$PAYLOAD")" || exit 0
        [[ -z "${PREPARED_VARS:-}" ]] && exit 0
        eval "$PREPARED_VARS"
        echo "[$(date)] Opening permission request: tool=$TOOL_NAME summary=$INPUT_SUMMARY response=$RESPONSE_PATH" >> /tmp/gingertty-hook.log
        if open_permission_request "$RESPONSE_PATH" "$SESSION_ID" "$AGENT_ID" "$TOOL_NAME" "$INPUT_SUMMARY" "$SUGGESTIONS_JSON"; then
            echo "[$(date)] Waiting for permission response at: $RESPONSE_PATH" >> /tmp/gingertty-hook.log
            if wait_for_permission_request_response "$RESPONSE_PATH" "$(permission_request_timeout_seconds)"; then
                echo "[$(date)] Permission response received" >> /tmp/gingertty-hook.log
                emit_permission_request_decision "$RESPONSE_PATH"
            else
                echo "[$(date)] Permission request timed out" >> /tmp/gingertty-hook.log
            fi
        else
            echo "[$(date)] open_permission_request failed" >> /tmp/gingertty-hook.log
        fi
        ;;
    ExitPlanMode)
        echo "[$(date)] ExitPlanMode hook started" >> /tmp/gingertty-hook.log
        PAYLOAD="$(read_hook_payload)"
        echo "[$(date)] Payload: $PAYLOAD" >> /tmp/gingertty-hook.log
        PREPARED_VARS="$(prepare_plan_review_files "$PAYLOAD")" || { echo "[$(date)] prepare_plan_review_files failed" >> /tmp/gingertty-hook.log; exit 0; }
        [[ -z "${PREPARED_VARS:-}" ]] && { echo "[$(date)] PREPARED_VARS empty" >> /tmp/gingertty-hook.log; exit 0; }
        eval "$PREPARED_VARS"
        echo "[$(date)] Opening plan review: $SCRATCH_PATH" >> /tmp/gingertty-hook.log
        if open_plan_review "$SCRATCH_PATH" "$RESPONSE_PATH" "$SESSION_ID" "$AGENT_ID"; then
            echo "[$(date)] Waiting for response at: $RESPONSE_PATH" >> /tmp/gingertty-hook.log
            if wait_for_plan_review_response "$RESPONSE_PATH"; then
                echo "[$(date)] Got response, emitting decision" >> /tmp/gingertty-hook.log
                DECISION="$(emit_plan_review_decision "$RESPONSE_PATH")"
                echo "[$(date)] Decision: $DECISION" >> /tmp/gingertty-hook.log
                echo "$DECISION"
            else
                echo "[$(date)] Timeout waiting for response" >> /tmp/gingertty-hook.log
            fi
        else
            echo "[$(date)] open_plan_review failed" >> /tmp/gingertty-hook.log
        fi
        echo "[$(date)] ExitPlanMode hook finished" >> /tmp/gingertty-hook.log
        ;;
esac
