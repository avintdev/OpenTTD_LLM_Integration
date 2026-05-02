"""Session-scoped logging, status, and summary persistence.

Each bridge run gets its own folder under ``web/sessions/``. The current run
is also mirrored into a few root-level JSON files for compatibility with the
existing static dashboard while the UI is being migrated.
"""

from __future__ import annotations

import json
import threading
import uuid
from copy import deepcopy
from datetime import datetime
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parent
APP_ROOT = ROOT.parent
WEB_ROOT = APP_ROOT / "web"
SESSIONS_ROOT = WEB_ROOT / "sessions"
INDEX_PATH = SESSIONS_ROOT / "index.json"
CURRENT_PATH = SESSIONS_ROOT / "current.json"

LEGACY_LOG_PATH = WEB_ROOT / "logs.json"
LEGACY_STATUS_PATH = WEB_ROOT / "status.json"
LEGACY_SUMMARY_PATH = WEB_ROOT / "summary.json"
LEGACY_CURRENT_PATH = WEB_ROOT / "current_session.json"

MAX_INTERACTIONS = 50
MAX_ERROR_EVENTS = 200

# Default in-code classifications for common error tokens. Keys are
# lower-cased substrings to look for in signatures or messages; values
# are the classification label to apply when matched.
DEFAULT_ERROR_CLASSIFICATIONS: dict[str, str] = {
    "no_funds": "llm",
}
_lock = threading.RLock()
_current_session: dict[str, Any] | None = None


def _utc_now() -> str:
    return datetime.utcnow().replace(microsecond=0).isoformat() + "Z"


def _json_default(obj: Any) -> Any:
    if isinstance(obj, bytes):
        try:
            return obj.decode("utf-8")
        except UnicodeDecodeError:
            return list(obj)
    if isinstance(obj, Path):
        return str(obj)
    return str(obj)


def _write_json(path: Path, payload: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, default=_json_default), encoding="utf-8")


def _read_json(path: Path, default: Any) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (FileNotFoundError, json.JSONDecodeError):
        return deepcopy(default)


def _append_jsonl(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(payload, default=_json_default) + "\n")


def _default_summary() -> dict[str, Any]:
    return {
        "llm_calls": 0,
        "llm_latency_total_ms": 0,
        "llm_latency_count": 0,
        "llm_latency_max_ms": 0,
        "commands_attempted": 0,
        "commands_succeeded": 0,
        "game_errors": 0,
        "provider_errors": 0,
        "timeouts": 0,
        "validation_skips": 0,
        "bridge_errors": 0,
        "admin_errors": 0,
        "command_errors": 0,
        "errors_total": 0,
        "llm_error_commands": 0,
        "events_total": 0,
        "last_command": None,
        "last_reply": None,
        "last_error": None,
    }


def _default_status() -> dict[str, Any]:
    return {
        "code": "starting",
        "label": "Starting",
        "detail": "Session created",
        "updated_at": _utc_now(),
        "session_id": None,
        "mode": None,
        "command": None,
        "reply": None,
        "model": None,
    }


def _slugify(value: Any) -> str:
    text = "".join(ch.lower() if ch.isalnum() else "-" for ch in str(value or "")).strip("-")
    while "--" in text:
        text = text.replace("--", "-")
    return text or "session"


def _make_session_id(mode: str, model: str | None = None) -> str:
    stamp = datetime.utcnow().strftime("%Y%m%dT%H%M%SZ")
    suffix = uuid.uuid4().hex[:8]
    mode_slug = _slugify(mode)
    model_slug = _slugify(model) if model else "nomodel"
    return f"{stamp}-{model_slug}-{mode_slug}-{suffix}"


def _error_signature(entry: dict[str, Any]) -> str:
    kind = str(entry.get("kind") or entry.get("type") or "error").strip().lower()
    if kind == "command_result":
        outcome = str(entry.get("outcome") or "unknown").strip().lower()
        reply = entry.get("reply")
        reply_type = str(entry.get("reply_type") or "UNKNOWN").strip().upper()
        reason = ""
        if isinstance(reply, dict):
            for key in ("msg", "message", "reason", "error", "detail"):
                value = reply.get(key)
                if isinstance(value, str) and value.strip():
                    reason = value.strip()
                    break
            if not reason:
                reason = json.dumps(reply, sort_keys=True, default=_json_default)
        else:
            reason = str(reply or "")
        return f"command:{outcome}:{reply_type}:{reason}"
    if kind == "validation_skip":
        return f"validation:{str(entry.get('error') or '').strip()}"
    category = str(entry.get("category") or "unknown").strip().lower()
    message = str(entry.get("message") or entry.get("error") or "").strip()
    return f"{kind}:{category}:{message}"


def _guess_error_source(entry: dict[str, Any]) -> str:
    kind = str(entry.get("kind") or entry.get("type") or "error").strip().lower()
    if kind == "command_result":
        outcome = str(entry.get("outcome") or "").strip().lower()
        if outcome in {"game_error", "timeout"}:
            return "game"
        return "command"
    if kind == "validation_skip":
        return "validation"
    category = str(entry.get("category") or "").strip().lower()
    if category == "provider_error":
        return "llm"
    if category == "admin_error":
        return "admin"
    if category == "bridge_error":
        return "bridge"
    return "unknown"


def _error_classification_default(entry: dict[str, Any]) -> str:
    # First, allow simple in-code defaults based on keywords/signature
    try:
        sig = str(_error_signature(entry) or "").lower()
    except Exception:
        sig = ""
    text = sig
    # also inspect common message/reply fields
    for key in ("message", "error", "detail"):
        val = entry.get(key)
        if isinstance(val, str) and val:
            text += " " + val.lower()
    # For command replies, try some nested fields too
    reply = entry.get("reply")
    if isinstance(reply, dict):
        for key in ("msg", "message", "reason", "error", "detail"):
            val = reply.get(key)
            if isinstance(val, str) and val:
                text += " " + val.lower()

    for kw, label in DEFAULT_ERROR_CLASSIFICATIONS.items():
        if kw in text:
            return label

    guess = _guess_error_source(entry)
    if guess in {"llm", "game", "bridge", "admin", "validation"}:
        return guess
    return "unknown"


def _record_error_event_locked(entry: dict[str, Any]) -> None:
    if _current_session is None:
        return
    payload = deepcopy(entry)
    payload.setdefault("timestamp", _utc_now())
    payload["session_id"] = _current_session["session_id"]
    payload["signature"] = _error_signature(payload)
    payload["source_guess"] = _guess_error_source(payload)
    payload["classification"] = _current_session["error_classifications"].get(payload["signature"], _error_classification_default(payload))
    _current_session["error_events"].append(payload)
    _current_session["error_events"] = _current_session["error_events"][-MAX_ERROR_EVENTS:]
    _append_jsonl(_current_session["paths"]["errors_log"], payload)


def _build_error_catalog_locked() -> list[dict[str, Any]]:
    catalog: dict[str, dict[str, Any]] = {}
    for entry in _current_session["error_events"]:
        signature = str(entry.get("signature") or _error_signature(entry))
        bucket = catalog.get(signature)
        if bucket is None:
            bucket = {
                "signature": signature,
                "classification": entry.get("classification") or _error_classification_default(entry),
                "source_guess": entry.get("source_guess") or _guess_error_source(entry),
                "kind": entry.get("kind") or entry.get("type") or "error",
                "category": entry.get("category"),
                "message": entry.get("message") or entry.get("error") or entry.get("detail"),
                "outcome": entry.get("outcome"),
                "reply_type": entry.get("reply_type"),
                "count": 0,
                "first_seen": entry.get("timestamp"),
                "last_seen": entry.get("timestamp"),
                "sample": deepcopy(entry),
            }
            catalog[signature] = bucket
        bucket["count"] += 1
        bucket["last_seen"] = entry.get("timestamp") or bucket["last_seen"]
        if bucket.get("message") in (None, ""):
            bucket["message"] = entry.get("message") or entry.get("error") or entry.get("detail")
        if bucket.get("classification") in (None, "unknown"):
            bucket["classification"] = entry.get("classification") or _error_classification_default(entry)
    return sorted(catalog.values(), key=lambda item: (str(item.get("last_seen") or ""), str(item.get("signature") or "")), reverse=True)


def _public_session_snapshot(session: dict[str, Any]) -> dict[str, Any]:
    summary = deepcopy(session["summary"])
    llm_latency_count = int(summary.get("llm_latency_count", 0) or 0)
    if llm_latency_count > 0:
        summary["llm_latency_avg_ms"] = round(
            float(summary.get("llm_latency_total_ms", 0)) / llm_latency_count,
            2,
        )
    else:
        summary["llm_latency_avg_ms"] = 0

    commands_attempted = int(summary.get("commands_attempted", 0) or 0)
    commands_succeeded = int(summary.get("commands_succeeded", 0) or 0)
    summary["success_rate"] = round(
        (commands_succeeded / commands_attempted) * 100.0,
        2,
    ) if commands_attempted else 0
    summary["commands_failed"] = max(0, commands_attempted - commands_succeeded)

    return {
        "session_id": session["session_id"],
        "mode": session["mode"],
        "started_at": session["started_at"],
        "ended_at": session.get("ended_at"),
        "last_updated": session.get("last_updated"),
        "status": deepcopy(session["status"]),
        "summary": summary,
        "metadata": deepcopy(session.get("metadata", {})),
    }


def _session_paths(session_dir: Path) -> dict[str, Path]:
    return {
        "dir": session_dir,
        "manifest": session_dir / "manifest.json",
        "events": session_dir / "events.jsonl",
        "interactions": session_dir / "interactions.json",
        "errors_log": session_dir / "errors.jsonl",
        "errors": session_dir / "errors.json",
        "error_classifications": session_dir / "error_classifications.json",
        "status": session_dir / "status.json",
        "summary": session_dir / "summary.json",
    }


def _refresh_indexes_locked() -> None:
    if _current_session is None:
        return

    index_payload = _read_json(INDEX_PATH, {"current_session_id": None, "sessions": []})
    sessions = index_payload.get("sessions", [])
    if not isinstance(sessions, list):
        sessions = []

    current_snapshot = _public_session_snapshot(_current_session)
    current_id = current_snapshot["session_id"]
    updated = False

    for idx, entry in enumerate(sessions):
        if not isinstance(entry, dict):
            continue
        if entry.get("session_id") != current_id:
            continue
        sessions[idx] = current_snapshot
        updated = True
        break

    if not updated:
        sessions.append(current_snapshot)

    index_payload = {
        "current_session_id": current_id,
        "sessions": sessions,
    }
    _write_json(INDEX_PATH, index_payload)
    _write_json(CURRENT_PATH, {
        "session_id": current_id,
        "session_dir": f"sessions/{current_id}",
    })
    _write_json(LEGACY_CURRENT_PATH, current_snapshot)


def _refresh_summary_locked() -> None:
    if _current_session is None:
        return
    snapshot = _public_session_snapshot(_current_session)
    _write_json(_current_session["paths"]["summary"], snapshot["summary"])
    _write_json(LEGACY_SUMMARY_PATH, snapshot["summary"])


def _refresh_status_locked() -> None:
    if _current_session is None:
        return
    _write_json(_current_session["paths"]["status"], _current_session["status"])
    _write_json(LEGACY_STATUS_PATH, _current_session["status"])


def _refresh_interactions_locked() -> None:
    if _current_session is None:
        return
    interactions = _current_session["interactions"][-MAX_INTERACTIONS:]
    _write_json(_current_session["paths"]["interactions"], interactions)
    _write_json(LEGACY_LOG_PATH, interactions)


def _refresh_errors_locked() -> None:
    if _current_session is None:
        return
    _write_json(_current_session["paths"]["errors"], _build_error_catalog_locked())


def _write_manifest_locked() -> None:
    if _current_session is None:
        return
    manifest = {
        "session_id": _current_session["session_id"],
        "mode": _current_session["mode"],
        "started_at": _current_session["started_at"],
        "ended_at": _current_session.get("ended_at"),
        "metadata": deepcopy(_current_session.get("metadata", {})),
    }
    _write_json(_current_session["paths"]["manifest"], manifest)


def _create_session_locked(mode: str, metadata: dict[str, Any] | None = None) -> dict[str, Any]:
    global _current_session
    metadata = deepcopy(metadata or {})
    session_id = _make_session_id(mode, metadata.get("model"))
    session_dir = SESSIONS_ROOT / session_id
    session_dir.mkdir(parents=True, exist_ok=True)
    paths = _session_paths(session_dir)
    now = _utc_now()
    session = {
        "session_id": session_id,
        "mode": mode,
        "started_at": now,
        "ended_at": None,
        "last_updated": now,
        "metadata": deepcopy(metadata or {}),
        "paths": paths,
        "summary": _default_summary(),
        "status": _default_status(),
        "interactions": [],
        "error_events": [],
        "error_classifications": _read_json(paths["error_classifications"], {}),
    }
    session["status"].update({
        "session_id": session_id,
        "mode": mode,
        "label": "Starting",
        "detail": "Session created",
    })

    # Seed global state before writing companion files that reference it.
    _current_session = session

    _write_manifest_locked()
    _refresh_status_locked()
    _refresh_summary_locked()
    _refresh_interactions_locked()
    _refresh_errors_locked()
    _write_json(paths["error_classifications"], session["error_classifications"])
    _refresh_indexes_locked()
    _append_jsonl(paths["events"], {
        "timestamp": now,
        "type": "session_start",
        "session_id": session_id,
        "mode": mode,
        "metadata": deepcopy(metadata or {}),
    })
    return session


def ensure_session(mode: str = "auto", metadata: dict[str, Any] | None = None) -> dict[str, Any]:
    """Return the active session snapshot, creating one when needed."""
    global _current_session
    with _lock:
        if _current_session is None or _current_session.get("ended_at") is not None:
            _current_session = _create_session_locked(mode=mode, metadata=metadata)
        elif metadata:
            _current_session["metadata"].update(metadata)
            _write_manifest_locked()
            _refresh_indexes_locked()
        return _public_session_snapshot(_current_session)


def start_session(mode: str, metadata: dict[str, Any] | None = None) -> dict[str, Any]:
    """Create a new session if one does not already exist."""
    global _current_session
    with _lock:
        if _current_session is not None and _current_session.get("ended_at") is None:
            if metadata:
                _current_session["metadata"].update(metadata)
                _write_manifest_locked()
                _refresh_indexes_locked()
            return _public_session_snapshot(_current_session)
        _current_session = _create_session_locked(mode=mode, metadata=metadata)
        return _public_session_snapshot(_current_session)


def get_session_snapshot() -> dict[str, Any] | None:
    with _lock:
        if _current_session is None:
            return None
        return _public_session_snapshot(_current_session)


def set_status(code: str, detail: Any = None, *, label: str | None = None, command: str | None = None, reply: Any = None, model: str | None = None, context: dict[str, Any] | None = None) -> dict[str, Any]:
    """Update the live status snapshot for the current session."""
    global _current_session
    with _lock:
        ensure_session()
        assert _current_session is not None
        status = {
            "code": code,
            "label": label or code.replace("_", " ").strip().title(),
            "detail": detail,
            "updated_at": _utc_now(),
            "session_id": _current_session["session_id"],
            "mode": _current_session["mode"],
            "command": command,
            "reply": reply,
            "model": model or _current_session["metadata"].get("model"),
        }
        if context:
            status["context"] = deepcopy(context)
        _current_session["status"] = status
        _current_session["last_updated"] = status["updated_at"]
        _append_jsonl(_current_session["paths"]["events"], {
            "timestamp": status["updated_at"],
            "type": "status",
            "session_id": _current_session["session_id"],
            "status": deepcopy(status),
        })
        _refresh_status_locked()
        _refresh_indexes_locked()
        return deepcopy(status)


def record_interaction(entry: dict[str, Any]) -> dict[str, Any]:
    """Persist one LLM prompt/response interaction."""
    global _current_session
    with _lock:
        ensure_session()
        assert _current_session is not None
        payload = deepcopy(entry)
        payload.setdefault("timestamp", _utc_now())
        payload["session_id"] = _current_session["session_id"]
        payload["kind"] = "llm_interaction"

        summary = _current_session["summary"]
        summary["llm_calls"] += 1
        latency = payload.get("latency_ms")
        if isinstance(latency, (int, float)):
            latency = int(latency)
            summary["llm_latency_total_ms"] += latency
            summary["llm_latency_count"] += 1
            summary["llm_latency_max_ms"] = max(summary["llm_latency_max_ms"], latency)

        usage = payload.get("usage")
        if isinstance(usage, dict):
            summary.setdefault("prompt_tokens_total", 0)
            summary.setdefault("completion_tokens_total", 0)
            summary.setdefault("total_tokens_total", 0)
            for key, summary_key in (
                ("prompt_tokens", "prompt_tokens_total"),
                ("completion_tokens", "completion_tokens_total"),
                ("total_tokens", "total_tokens_total"),
            ):
                value = usage.get(key)
                if isinstance(value, (int, float)):
                    summary[summary_key] += int(value)

        _current_session["interactions"].append(payload)
        _current_session["interactions"] = _current_session["interactions"][-MAX_INTERACTIONS:]
        _current_session["last_updated"] = payload["timestamp"]
        _current_session["summary"]["events_total"] += 1

        _append_jsonl(_current_session["paths"]["events"], {
            "timestamp": payload["timestamp"],
            "type": "llm_interaction",
            "session_id": _current_session["session_id"],
            "interaction": deepcopy(payload),
        })

        _refresh_interactions_locked()
        _refresh_summary_locked()
        _refresh_indexes_locked()
        return deepcopy(payload)


def get_error_catalog() -> list[dict[str, Any]]:
    with _lock:
        if _current_session is None:
            return []
        return deepcopy(_build_error_catalog_locked())


def set_error_classifications(classifications: dict[str, str]) -> dict[str, str]:
    global _current_session
    with _lock:
        ensure_session()
        assert _current_session is not None
        normalized = {
            str(signature): str(label).strip().lower() or "unknown"
            for signature, label in (classifications or {}).items()
            if str(signature).strip()
        }
        _current_session["error_classifications"] = normalized
        _write_json(_current_session["paths"]["error_classifications"], normalized)
        for entry in _current_session["error_events"]:
            signature = str(entry.get("signature") or _error_signature(entry))
            entry["classification"] = normalized.get(signature, _error_classification_default(entry))
        _refresh_errors_locked()
        return deepcopy(normalized)


def record_command_result(cmd: str, reply: Any, *, outcome: str | None = None, context: dict[str, Any] | None = None) -> dict[str, Any]:
    """Persist a dispatched command and its DONE/ERR/timeout reply."""
    global _current_session
    with _lock:
        ensure_session()
        assert _current_session is not None
        reply_type = "UNKNOWN"
        if isinstance(reply, dict):
            reply_type = str(reply.get("t", "")).upper() or "UNKNOWN"

        normalized_outcome = outcome
        if normalized_outcome is None:
            if reply_type == "DONE":
                normalized_outcome = "success"
            elif reply_type == "ERR":
                normalized_outcome = "game_error"
            elif reply_type == "TIMEOUT":
                normalized_outcome = "timeout"
            else:
                normalized_outcome = "unknown"

        summary = _current_session["summary"]
        summary["commands_attempted"] += 1
        if normalized_outcome == "success":
            summary["commands_succeeded"] += 1
        elif normalized_outcome == "game_error":
            summary["game_errors"] += 1
            summary["command_errors"] += 1
            summary["errors_total"] += 1
        elif normalized_outcome == "timeout":
            summary["timeouts"] += 1
            summary["command_errors"] += 1
            summary["errors_total"] += 1
        else:
            summary["errors_total"] += 1

        payload = {
            "timestamp": _utc_now(),
            "session_id": _current_session["session_id"],
            "cmd": cmd,
            "reply": deepcopy(reply),
            "reply_type": reply_type,
            "outcome": normalized_outcome,
        }
        if context:
            payload["context"] = deepcopy(context)

        summary["last_command"] = cmd
        summary["last_reply"] = deepcopy(reply)
        if normalized_outcome in {"game_error", "timeout"}:
            summary["last_error"] = deepcopy(reply)
        _current_session["last_updated"] = payload["timestamp"]
        _append_jsonl(_current_session["paths"]["events"], {
            "timestamp": payload["timestamp"],
            "type": "command_result",
            "session_id": _current_session["session_id"],
            "command": deepcopy(payload),
        })

        if normalized_outcome != "success":
            _record_error_event_locked({
                "kind": "command_result",
                "timestamp": payload["timestamp"],
                "cmd": cmd,
                "reply": deepcopy(reply),
                "reply_type": reply_type,
                "outcome": normalized_outcome,
                **({"context": deepcopy(context)} if context else {}),
            })

        if normalized_outcome == "game_error":
            _current_session["status"] = {
                "code": "command_error",
                "label": "Game Error",
                "detail": reply.get("msg") if isinstance(reply, dict) else "Game rejected the command",
                "updated_at": payload["timestamp"],
                "session_id": _current_session["session_id"],
                "mode": _current_session["mode"],
                "command": cmd,
                "reply": deepcopy(reply),
                "model": _current_session["metadata"].get("model"),
            }
            _current_session["summary"]["last_error"] = deepcopy(reply)
            _refresh_status_locked()
        elif normalized_outcome == "timeout":
            _current_session["status"] = {
                "code": "command_timeout",
                "label": "Game Timeout",
                "detail": f"No reply received for {cmd}",
                "updated_at": payload["timestamp"],
                "session_id": _current_session["session_id"],
                "mode": _current_session["mode"],
                "command": cmd,
                "reply": deepcopy(reply),
                "model": _current_session["metadata"].get("model"),
            }
            _current_session["summary"]["last_error"] = deepcopy(reply)
            _refresh_status_locked()

        _refresh_errors_locked()
        _refresh_summary_locked()
        _refresh_indexes_locked()
        return deepcopy(payload)


def record_validation_skip(decision: Any, error: str, *, context: dict[str, Any] | None = None) -> dict[str, Any]:
    """Persist a validation skip that prevented a command from dispatching."""
    global _current_session
    with _lock:
        ensure_session()
        assert _current_session is not None
        summary = _current_session["summary"]
        summary["validation_skips"] += 1
        summary["errors_total"] += 1
        summary["last_error"] = error
        payload = {
            "timestamp": _utc_now(),
            "session_id": _current_session["session_id"],
            "decision": repr(decision),
            "error": error,
        }
        if context:
            payload["context"] = deepcopy(context)

        _current_session["last_updated"] = payload["timestamp"]
        _record_error_event_locked({
            "kind": "validation_skip",
            "timestamp": payload["timestamp"],
            "decision": repr(decision),
            "error": error,
            **({"context": deepcopy(context)} if context else {}),
        })
        _append_jsonl(_current_session["paths"]["events"], {
            "timestamp": payload["timestamp"],
            "type": "validation_skip",
            "session_id": _current_session["session_id"],
            "validation": deepcopy(payload),
        })
        _refresh_errors_locked()
        _refresh_summary_locked()
        _refresh_indexes_locked()
        return deepcopy(payload)


def record_error(category: str, message: str, *, context: dict[str, Any] | None = None) -> dict[str, Any]:
    """Persist a non-command runtime error such as provider, bridge, or admin failures."""
    global _current_session
    with _lock:
        ensure_session()
        assert _current_session is not None
        summary = _current_session["summary"]
        summary["errors_total"] += 1
        summary["last_error"] = message
        if category == "provider_error":
            summary["provider_errors"] += 1
        elif category == "bridge_error":
            summary["bridge_errors"] += 1
        elif category == "admin_error":
            summary["admin_errors"] += 1

        payload = {
            "timestamp": _utc_now(),
            "session_id": _current_session["session_id"],
            "category": category,
            "message": message,
        }
        if context:
            payload["context"] = deepcopy(context)

        _current_session["last_updated"] = payload["timestamp"]
        _record_error_event_locked({
            "kind": "runtime_error",
            "timestamp": payload["timestamp"],
            "category": category,
            "message": message,
            **({"context": deepcopy(context)} if context else {}),
        })
        _current_session["status"] = {
            "code": "error",
            "label": "Error",
            "detail": message,
            "updated_at": payload["timestamp"],
            "session_id": _current_session["session_id"],
            "mode": _current_session["mode"],
            "command": None,
            "reply": None,
            "model": _current_session["metadata"].get("model"),
            "category": category,
        }
        _append_jsonl(_current_session["paths"]["events"], {
            "timestamp": payload["timestamp"],
            "type": "error",
            "session_id": _current_session["session_id"],
            "error": deepcopy(payload),
        })
        _refresh_status_locked()
        _refresh_errors_locked()
        _refresh_summary_locked()
        _refresh_indexes_locked()
        return deepcopy(payload)


def finalize_session(reason: str = "shutdown") -> dict[str, Any] | None:
    """Mark the current session as finished and flush final summary files."""
    global _current_session
    with _lock:
        if _current_session is None:
            return None

        if _current_session.get("ended_at") is not None:
            return _public_session_snapshot(_current_session)

        ended_at = _utc_now()
        _current_session["ended_at"] = ended_at
        _current_session["last_updated"] = ended_at
        summary = _current_session["summary"]
        summary["events_total"] += 1
        _append_jsonl(_current_session["paths"]["events"], {
            "timestamp": ended_at,
            "type": "session_end",
            "session_id": _current_session["session_id"],
            "reason": reason,
        })
        _current_session["status"] = {
            "code": "finished",
            "label": "Finished",
            "detail": reason,
            "updated_at": ended_at,
            "session_id": _current_session["session_id"],
            "mode": _current_session["mode"],
            "command": summary.get("last_command"),
            "reply": summary.get("last_reply"),
            "model": _current_session["metadata"].get("model"),
        }
        _write_manifest_locked()
        _refresh_status_locked()
        _refresh_summary_locked()
        _refresh_indexes_locked()
        return _public_session_snapshot(_current_session)
