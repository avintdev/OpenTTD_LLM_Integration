"""game/exporter.py — Drives the periodic export cycle.

Responsibilities:
  - Send !export all every EXPORT_INTERVAL_SECONDS.
  - Feed incoming packets into the shared GameState.
  - Fire the on_complete callback (in a background thread) when all 6
    EXPORT_END markers have been received.
"""

import threading
import time

import config
from game.state import GameState

_state                = GameState()
_lock                 = threading.Lock()
_on_complete_callback = None   # callable(GameState)


def set_on_complete(callback) -> None:
    """Register the callback invoked when a full export cycle completes."""
    global _on_complete_callback
    _on_complete_callback = callback


def handle_packet(data: dict) -> None:
    """Ingest one export packet; fire the callback if the state is now complete."""
    global _state
    snapshot = None
    callback = None
    with _lock:
        _state.ingest(data)
        if _state.is_complete and _on_complete_callback is not None:
            snapshot = _state
            if snapshot.year <= 0:
                # Some GS packages do not emit INFO; fall back to admin DATE.
                from admin import connection
                snapshot.year = connection.get_current_server_year() or 1950
            callback = _on_complete_callback
            _state   = GameState()   # fresh state for the next cycle

    if snapshot is not None:
        threading.Thread(target=callback, args=(snapshot,), daemon=True).start()


def trigger_export() -> None:
    """Send !export all to kick off a new export cycle."""
    from admin.connection import send_gamescript
    send_gamescript("!export all")
    print("[EXPORT] Export cycle triggered.")


def start_export_loop() -> None:
    """Start the background thread that triggers exports on a fixed interval."""
    # We do a late import of the lock so we can wait if the LLM is busy
    from runtime_state import llm_lock

    def _loop():
        # First export right away
        time.sleep(2)
        try:
            trigger_export()
        except Exception as exc:
            print(f"[EXPORT] Error triggering initial export: {exc}")

        while True:
            # Wait for the next cycle BEFORE triggering again
            time.sleep(config.EXPORT_INTERVAL_SECONDS)

            # Block and wait if the LLM is actively thinking from previous data
            with llm_lock:
                pass

            try:
                trigger_export()
            except Exception as exc:
                print(f"[EXPORT] Error triggering export: {exc}")

    threading.Thread(target=_loop, daemon=True, name="export-loop").start()
    print(f"[EXPORT] Export loop started (interval={config.EXPORT_INTERVAL_SECONDS}s).")

