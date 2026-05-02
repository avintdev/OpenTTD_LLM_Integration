"""commands/queue.py — Sequential command dispatcher.

Processes one command at a time: sends a CMD/SELL sign payload and blocks
until the GameScript forwards a DONE or ERR reply, or until COMMAND_TIMEOUT_TICKS
worth of real time has elapsed.
"""

from __future__ import annotations

import threading
from typing import Optional

import config
from commands.validator import validate_decision
from session_store import record_command_result, record_error, record_validation_skip, set_status

_lock        = threading.Lock()
_reply_event = threading.Event()
_last_reply: Optional[dict] = None
_last_cmd_sent: str = ""
_last_cmd_reply: dict = {}
_cmd_history: list[dict] = []


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

def dispatch(decisions, state_snapshot=None) -> list[dict]:
    """Process a list of Decision objects one at a time, in order.

    Returns a per-command result list so callers can react to command outcomes.
    """
    from admin.connection import send_gamescript

    results: list[dict] = []
    for decision in decisions:
        error = validate_decision(decision, state_snapshot=state_snapshot)
        if error:
            print(f"[QUEUE] Skipping invalid decision: {error}")
            record_validation_skip(decision, error, context={"state_snapshot": bool(state_snapshot)})
            continue

        cmd = _decision_to_cmd(decision, state_snapshot=state_snapshot)
        reply = _send_and_wait(cmd, send_gamescript)
        print(f"[QUEUE] Reply: {reply}")
        results.append({"cmd": cmd, "reply": reply})

    return results


def handle_reply(data: dict) -> None:
    """Called by admin/connection when a DONE or ERR packet arrives from the GS."""
    global _last_reply
    with _lock:
        _last_reply = data
    _reply_event.set()


def get_last_command_result() -> dict:
    """Return the last sent command and its DONE/ERR reply packet."""
    with _lock:
        return {
            "cmd": _last_cmd_sent,
            "reply": _last_cmd_reply.copy() if isinstance(_last_cmd_reply, dict) else _last_cmd_reply,
        }


def get_recent_command_results(limit: int = 10) -> list[dict]:
    """Return recent command->reply pairs for the current bridge session only."""
    if limit < 1:
        limit = 1
    with _lock:
        return [entry.copy() for entry in _cmd_history[-limit:]]


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

def _decision_to_cmd(decision, state_snapshot=None) -> str:
    """Convert a Decision object to the !cmd string sent to the GameScript."""
    from llm.client import (
        RouteDecision,
        SellDecision,
        LoanDecision,
        RepayDecision,
        RepayAllDecision,
        SkipDecision,
        CloneDecision,
        AddWagonsDecision,
        ReplaceEngineDecision,
    )

    if isinstance(decision, RouteDecision):
        # Format the !cmd string based on the transport mode
        # PLN/FRY: bare ids. TRN/TRK/BUS/CPL/SHP: usually prefix, except when already prefixed
        from_id = str(decision.from_id)
        to_id = str(decision.to_id)
        
        rtype = decision.route_type.upper()
        if rtype == "CTY":
            count = str(decision.wagons).strip()
            if not count.isdigit():
                count = "1"
            return f"!cmd CTY:{from_id}:{decision.eng_id}:{count}"

        if rtype in ("PLN", "FRY"):
            # bare integers
            qty_part = f":{decision.qty}" if getattr(decision, "qty", 1) > 1 else ""
            if rtype == "PLN":
                return f"!cmd {rtype}:{from_id}:{to_id}:{decision.eng_id}{qty_part}"
            return f"!cmd {rtype}:{from_id}:{to_id}:{decision.eng_id}"
            
        # Ensure i/t prefixes for non-PLN/FRY modes if the LLM provided bare ints.
        from game.exporter import _state
        state_ref = state_snapshot if state_snapshot is not None else _state

        def _normalize_loc(raw: str, is_from: bool) -> str:
            if not raw.isdigit():
                return raw

            n = int(raw)
            in_town = n in state_ref.towns
            in_ind  = n in state_ref.industries

            # CPL/SHP source must be industry-prefixed.
            if is_from and rtype in ("CPL", "SHP"):
                return f"i{n}"

            # BUS is town-oriented by default.
            if rtype == "BUS" and in_town:
                return f"t{n}"

            if in_ind and not in_town:
                return f"i{n}"
            if in_town and not in_ind:
                return f"t{n}"

            # Ambiguous or missing from snapshot: keep current default to industry.
            return f"i{n}"

        from_id = _normalize_loc(from_id, is_from=True)
        to_id = _normalize_loc(to_id, is_from=False)

        if rtype == "TRN":
            return f"!cmd TRN:{from_id}:{to_id}:{decision.eng_id}:{decision.wagons}"
        elif rtype in ("TRK", "BUS"):
            # count is derived from wagons or defaults to 1 if empty
            count = decision.wagons if decision.wagons and decision.wagons.isdigit() else "1"
            return f"!cmd {rtype}:{from_id}:{to_id}:{decision.eng_id}:{count}"
        elif rtype in ("CPL", "SHP"):
            cargo_part = f":{decision.cargo}" if decision.cargo else ""
            qty_part = ""
            if rtype == "CPL" and getattr(decision, "qty", 1) > 1:
                cargo_part = f":{decision.cargo}" if decision.cargo else ":" # Pad empty cargo
                qty_part = f":{getattr(decision, 'qty', 1)}"
                
            if rtype == "CPL":
                return f"!cmd {rtype}:{from_id}:{to_id}:{decision.eng_id}{cargo_part}{qty_part}"
            return f"!cmd {rtype}:{from_id}:{to_id}:{decision.eng_id}{cargo_part}"
        else:
            # Fallback
            return f"!cmd {rtype}:{from_id}:{to_id}:{decision.eng_id}:{decision.wagons}"
            
    if isinstance(decision, SellDecision):
        return f"!cmd SEL:{decision.veh_id}"
    if isinstance(decision, LoanDecision):
        return f"!cmd LON:{decision.amount}"
    if isinstance(decision, RepayDecision):
        return f"!cmd RPY:{decision.amount}"
    if isinstance(decision, RepayAllDecision):
        return "!cmd RPA"
    if isinstance(decision, SkipDecision):
        return "!cmd SKP"
    if isinstance(decision, CloneDecision):
        return f"!cmd CLN:{decision.veh_id}:{decision.count}"
    if isinstance(decision, AddWagonsDecision):
        return f"!cmd ADW:{decision.veh_id}:{decision.wagons}"
    if isinstance(decision, ReplaceEngineDecision):
        return f"!cmd RPL:{decision.old_eng_id}:{decision.new_eng_id}"
    raise ValueError(f"Unknown decision type: {type(decision)}")


def _send_and_wait(cmd: str, send_fn) -> dict:
    """Send a command and block until DONE/ERR reply or timeout.

    Timeout is estimated from COMMAND_TIMEOUT_TICKS assuming ~20 ticks/second.
    """
    global _last_reply, _last_cmd_sent, _last_cmd_reply

    timeout_seconds = config.COMMAND_TIMEOUT_TICKS / 20.0

    _reply_event.clear()
    with _lock:
        _last_reply = None

    set_status("dispatching", detail={"cmd": cmd}, label="Dispatching")

    try:
        send_fn(cmd)
    except Exception as exc:
        record_error("bridge_error", f"Failed to send command {cmd}: {exc}", context={"cmd": cmd})
        raise

    print(f"[CMD]   {cmd}")
    with _lock:
        _last_cmd_sent = cmd

    set_status("waiting_for_game_reply", detail={"cmd": cmd}, label="Waiting for Game Reply", command=cmd)

    replied = _reply_event.wait(timeout=timeout_seconds)

    with _lock:
        reply = _last_reply

    if not replied:
        print(f"[TIMEOUT] No reply within {timeout_seconds:.0f}s for: {cmd}")
        timeout_reply = {"t": "ERR", "reason": "TIMEOUT"}
        with _lock:
            _last_cmd_reply = timeout_reply
            _cmd_history.append({"cmd": cmd, "reply": timeout_reply})
            if len(_cmd_history) > 10:
                _cmd_history.pop(0)
        record_command_result(cmd, timeout_reply, outcome="timeout", context={"timeout_seconds": timeout_seconds})
        return timeout_reply

    final_reply = reply or {}
    with _lock:
        _last_cmd_reply = final_reply
        _cmd_history.append({"cmd": cmd, "reply": final_reply.copy() if isinstance(final_reply, dict) else final_reply})
        if len(_cmd_history) > 10:
            _cmd_history.pop(0)
    record_command_result(cmd, final_reply, context={"timeout_seconds": timeout_seconds})
    return final_reply
