"""bridge.py — SquirrelAI entry point.

Wires all components together and starts all threads:
  1. Admin port connection (persistent TCP to OpenTTD)
  2. Export loop (periodically requests game state from the GameScript)
  3. LLM callback (called when a full export cycle completes)
  4. Optional interactive REPL for manual testing (--debug flag)

Nothing else lives here — all business logic belongs in its own module.
"""

import sys
import json
import threading
import http.server
import socketserver
import time
from pathlib import Path
from urllib.parse import urlparse

from game  import exporter
from llm   import client as llm_client
from commands import queue
import config
import session_store
import settings_manager
from runtime_state import llm_lock

ROOT = Path(__file__).resolve().parent
APP_ROOT = ROOT.parent
WEB_ROOT = APP_ROOT / "web"

# Web server thread
class WebHandler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(WEB_ROOT), **kwargs)
    def log_message(self, format, *args):
        pass # Silence verbose access logs
    
    def end_headers(self):
        # Disable caching for logs dynamically fetching
        self.send_header("Cache-Control", "no-cache, no-store, must-revalidate")
        self.send_header("Pragma", "no-cache")
        self.send_header("Expires", "0")
        super().end_headers()

    def _write_json(self, status_code: int, payload: dict) -> None:
        body = json.dumps(payload, indent=2).encode("utf-8")
        self.send_response(status_code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _read_json_body(self) -> dict:
        length = int(self.headers.get("Content-Length", "0") or 0)
        if length <= 0:
            return {}
        raw = self.rfile.read(length)
        if not raw:
            return {}
        try:
            payload = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            return {}
        return payload if isinstance(payload, dict) else {}

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path

        if path == "/api/settings":
            self._write_json(200, settings_manager.get_runtime_settings())
            return

        if path == "/api/status":
            snapshot = session_store.get_session_snapshot() or {}
            self._write_json(200, snapshot.get("status", {}))
            return

        if path == "/api/session":
            self._write_json(200, session_store.get_session_snapshot() or {})
            return

        if path == "/api/errors":
            snapshot = session_store.get_session_snapshot() or {}
            self._write_json(200, {
                "session_id": snapshot.get("session_id"),
                "errors": session_store.get_error_catalog(),
            })
            return

        return super().do_GET()

    def do_POST(self):
        parsed = urlparse(self.path)
        path = parsed.path

        payload = self._read_json_body()

        if path == "/api/settings":
            model = str(payload.get("model", "") or "").strip()
            api_key_env = str(payload.get("api_key_env", "") or "").strip()

            try:
                settings = settings_manager.update_runtime_settings(model, api_key_env)
            except ValueError as exc:
                self._write_json(400, {"error": str(exc)})
                return
            except Exception as exc:
                self._write_json(500, {"error": f"Failed to update settings: {exc}"})
                return

            session_store.set_status(
                "settings_updated",
                label="Settings Updated",
                detail={"model": settings.get("model"), "api_key_env": settings.get("api_key_env")},
                model=settings.get("model"),
            )
            self._write_json(200, settings)
            return

        if path == "/api/errors/classify":
            classifications = payload.get("classifications", {})
            if not isinstance(classifications, dict):
                self._write_json(400, {"error": "classifications must be an object"})
                return
            updated = session_store.set_error_classifications(classifications)
            self._write_json(200, {"classifications": updated, "errors": session_store.get_error_catalog()})
            return

        self._write_json(404, {"error": "unknown endpoint"})

class ReusableTCPServer(socketserver.TCPServer):
    allow_reuse_address = True


def start_web_server():
    port = 8080
    Handler = WebHandler
    print(f"[*] Dashboard running at http://localhost:{port}/")
    try:
        with ReusableTCPServer(("", port), Handler) as httpd:
            httpd.serve_forever()
    except Exception as e:
        print(f"[!] Failed to start web dashboard: {e}")

def _schedule_next_export(delay_seconds: float | None = None) -> None:
    """Trigger the next export only after the previous LLM cycle fully completes."""
    if not config.AUTO_EXPORT_ENABLED:
        return

    delay = config.EXPORT_INTERVAL_SECONDS if delay_seconds is None else max(0.0, float(delay_seconds))

    def _run():
        time.sleep(delay)
        try:
            exporter.trigger_export()
        except Exception as exc:
            print(f"[EXPORT] Error triggering export: {exc}")
            session_store.record_error("bridge_error", f"Failed to trigger export: {exc}", context={"delay_seconds": delay})

    threading.Thread(target=_run, daemon=True, name="next-export").start()


def _is_successful_skip(dispatch_result: dict) -> bool:
    cmd = str(dispatch_result.get("cmd", "")).strip().lower()
    if cmd != "!cmd skp":
        return False

    reply = dispatch_result.get("reply")
    if not isinstance(reply, dict):
        return False
    return str(reply.get("t", "")).upper() == "DONE"

def _on_state_complete(state) -> None:
    """Called in a background thread once exporter has a full GameState snapshot."""
    dispatch_results: list[dict] = []
    with llm_lock:
        try:
            session_store.set_status(
                "llm_processing",
                detail={"year": state.year, "month": state.month},
                label="LLM Processing",
                model=config.LLM_MODEL,
            )
            print("[BRIDGE] Full game state received — calling LLM...")
            decisions = llm_client.call(state)
            print(f"[BRIDGE] LLM returned {len(decisions)} decision(s).")
            session_store.set_status(
                "dispatching",
                detail={"decisions": len(decisions)},
                label="Dispatching",
                model=config.LLM_MODEL,
            )
            dispatch_results = queue.dispatch(decisions, state_snapshot=state)
        except Exception as exc:
            print(f"[BRIDGE] LLM/dispatch error: {exc}")
            session_store.record_error("bridge_error", f"LLM/dispatch error: {exc}", context={"year": state.year, "month": state.month})
        finally:
            # Start next export only after the full LLM/dispatch cycle finishes.
            delay = config.EXPORT_INTERVAL_SECONDS
            if any(_is_successful_skip(item) for item in dispatch_results):
                delay = max(delay, float(config.SKIP_EXPORT_COOLDOWN_SECONDS))
                print(f"[EXPORT] SKP cooldown active; pausing next export for {delay:.1f}s.")
            session_store.set_status(
                "idle",
                detail={"next_export_in_seconds": delay},
                label="LLM Waiting",
                model=config.LLM_MODEL,
            )
            _schedule_next_export(delay_seconds=delay)


def _repl_loop() -> None:
    """Interactive REPL for manual testing.  Run with --debug.

    Useful commands:
      !ping                          heartbeat check
      !export industries             trigger one export chunk
      !export towns
      !export companies
      !export engines
      !export vehicles
      !cmd TRN:<f>:<t>:<e>:<wagons>  queue a train route command
      !cmd SEL:<veh_id>              queue a sell command
      quit                           exit
    """
    print("[REPL] Debug REPL ready. Type a command or 'quit' to exit.")
    from admin import connection

    while True:
        try:
            cmd = input("> ").strip()
        except (EOFError, KeyboardInterrupt):
            break
        if not cmd:
            continue
        if cmd.lower() == "quit":
            break
        try:
            connection.send_gamescript(cmd)
        except Exception as exc:
            print(f"[REPL] Error: {exc}")


def _run_dashboard_only(reason: str) -> None:
    session_store.set_status(
        "dashboard_only",
        detail=reason,
        label="Dashboard Only",
        model=config.LLM_MODEL,
    )
    print(f"[BRIDGE] {reason}", flush=True)
    print("[BRIDGE] Press Ctrl-C to exit.", flush=True)
    try:
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        pass
    finally:
        session_store.finalize_session(reason="dashboard_only_exit")


def main() -> None:
    debug = "--debug" in sys.argv
    standalone = "--standalone" in sys.argv

    mode = "standalone" if standalone else ("debug" if debug else "live")

    session_store.start_session(
        mode=mode,
        metadata={
            "model": config.LLM_MODEL,
            "llm_url": config.LLM_URL,
            "auto_export_enabled": bool(config.AUTO_EXPORT_ENABLED),
            "standalone": standalone,
        },
    )

    threading.Thread(target=start_web_server, daemon=True, name="dashboard").start()

    if standalone:
        session_store.set_status(
            "standalone_ready",
            detail="Dashboard-only mode: OpenTTD connection disabled",
            label="Standalone Ready",
            model=config.LLM_MODEL,
        )
        print("[BRIDGE] Standalone mode active (no OpenTTD connection). Press Ctrl-C to exit.", flush=True)
        try:
            while True:
                time.sleep(1)
        except KeyboardInterrupt:
            pass
        finally:
            session_store.finalize_session(reason="standalone_exit")
        return

    print("[BRIDGE] Connecting to OpenTTD admin port...", flush=True)
    try:
        from admin import connection
    except ModuleNotFoundError as exc:
        session_store.record_error("bridge_error", f"Missing admin dependency: {exc}")
        _run_dashboard_only("Missing admin dependency (pyopenttdadmin)")
        return

    log_path = "gs_packets.jsonl" if debug else None
    try:
        admin = connection.connect(log_path=log_path)
    except Exception as exc:
        session_store.record_error("bridge_error", f"Failed to connect to OpenTTD admin port: {exc}")
        _run_dashboard_only("OpenTTD admin connection failed")
        return

    session_store.set_status(
        "connected",
        detail={"debug": debug},
        label="Connected",
        model=config.LLM_MODEL,
    )

    if debug:
        print("[BRIDGE] Debug mode — LLM loop disabled, REPL active.", flush=True)
        if log_path:
            print(f"[BRIDGE] All GS packets saved to: {log_path}", flush=True)
        session_store.set_status(
            "manual_repl",
            detail="Debug REPL active",
            label="Manual REPL",
            model=config.LLM_MODEL,
        )
        threading.Thread(target=_repl_loop, daemon=True, name="repl").start()
    else:
        exporter.set_on_complete(_on_state_complete)
        if config.AUTO_EXPORT_ENABLED:
            # Kick off the first export; every next export is completion-driven.
            threading.Thread(
                target=lambda: (time.sleep(2), exporter.trigger_export()),
                daemon=True,
                name="initial-export",
            ).start()
            print(
                f"[EXPORT] Completion-driven loop active (interval={config.EXPORT_INTERVAL_SECONDS}s, skip_cooldown={config.SKIP_EXPORT_COOLDOWN_SECONDS}s).",
                flush=True,
            )
            session_store.set_status(
                "waiting_for_export",
                detail={"interval_seconds": config.EXPORT_INTERVAL_SECONDS},
                label="LLM Waiting",
                model=config.LLM_MODEL,
            )
        else:
            print("[EXPORT] Auto export disabled. Use manual !export commands only.", flush=True)
            session_store.set_status(
                "manual_export",
                detail="Auto export disabled",
                label="Waiting for Manual Export",
                model=config.LLM_MODEL,
            )

    print("[BRIDGE] Running. Press Ctrl-C to exit.", flush=True)
    try:
        admin.run()
    finally:
        session_store.finalize_session(reason="bridge_exit")


if __name__ == "__main__":
    main()
