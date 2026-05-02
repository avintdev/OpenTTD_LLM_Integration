"""admin/connection.py — Pure transport layer for the OpenTTD Admin Port.

Responsibilities:
  - Establish and maintain the TCP connection via pyopenttdadmin.
  - send_gamescript(msg) — wraps a string in the required packet format.
    - Route incoming GameScriptPackets (including STAT) to game/exporter or commands/queue.
  - on_welcome, on_error, on_shutdown handlers.
"""

import struct
import json
from pathlib import Path
from typing import Optional

from pyopenttdadmin import Admin, AdminUpdateType, AdminUpdateFrequency, openttdpacket

import config
from session_store import record_error

_admin: Optional[Admin] = None
_log_file = None         # open file handle for JSONL packet log
_current_server_date: int = 0
_current_server_year: int = 0


def _is_leap_year(year: int) -> bool:
    """Return True if year is leap in the proleptic Gregorian calendar."""
    return (year % 4 == 0) and ((year % 100 != 0) or (year % 400 == 0))


def _openttd_date_to_year(date_days: int) -> int:
    """Convert OpenTTD date (days since 0000-01-01) to year."""
    if date_days <= 0:
        return 0

    year = 0
    days_left = date_days
    while True:
        year_days = 366 if _is_leap_year(year) else 365
        if days_left < year_days:
            return year
        days_left -= year_days
        year += 1


def get_current_server_year() -> int:
    """Return latest year observed from admin DATE updates, or 0 if unknown."""
    return _current_server_year


def _log(data: dict) -> None:
    """Append one packet as a JSON line to the log file."""
    if _log_file is not None:
        _log_file.write(json.dumps(data) + "\n")
        _log_file.flush()


def _p(*args) -> None:
    """Print with immediate flush so output appears even inside admin.run()."""
    print(*args, flush=True)


def get_admin() -> Admin:
    """Return the active Admin connection (must call connect() first)."""
    if _admin is None:
        raise RuntimeError("Not connected. Call connect() first.")
    return _admin


def connect(log_path: str | None = None) -> Admin:
    """Connect to the OpenTTD admin port and register all packet handlers.

    If log_path is given, every incoming GS packet is appended as a JSON line
    to that file so the export can be inspected offline.
    """
    global _admin, _log_file
    if log_path:
        _log_file = open(log_path, "a", encoding="utf-8")
        _p(f"[LOG]   Packet log -> {Path(log_path).resolve()}")

    _admin = Admin(ip=config.ADMIN_HOST, port=config.ADMIN_PORT)
    _admin.login("SquirrelBridge", password=config.ADMIN_PASSWORD)

    @_admin.add_handler(openttdpacket.WelcomePacket)
    def on_welcome(admin, packet):
        _p("[READY] Connected to OpenTTD server.")
        admin.subscribe(AdminUpdateType.GAMESCRIPT, AdminUpdateFrequency.AUTOMATIC)
        admin.subscribe(AdminUpdateType.DATE, AdminUpdateFrequency.DAILY)
        _p("[READY] Subscribed to GameScript packets.")

    @_admin.add_handler(openttdpacket.DatePacket)
    def on_date(admin, packet):
        global _current_server_date, _current_server_year
        _current_server_date = int(packet.date)
        _current_server_year = _openttd_date_to_year(_current_server_date)

    @_admin.add_handler(openttdpacket.ShutdownPacket)
    def on_shutdown(admin, packet):
        _p("[SHUTDOWN] Server shutting down.")

    @_admin.add_handler(openttdpacket.ErrorPacket)
    def on_error(admin, packet):
        _p(f"[ERROR] Admin port error: {packet}")
        record_error("admin_error", f"Admin port error: {packet}")

    @_admin.add_handler(openttdpacket.GameScriptPacket)
    def on_gamescript(admin, packet):
        raw = packet.json.rstrip("\x00")  # strip C-string null terminator
        try:
            data = json.loads(raw)
        except json.JSONDecodeError:
            _p(f"[GS<]   (bad JSON) {raw!r}")
            return
        _p(f"[GS<]   {data}")
        _log(data)
        _dispatch_gamescript(data)

    return _admin


def send_gamescript(msg: str) -> None:
    """Send a raw command string to the GameScript via the Admin port.

    The Admin port requires a type-6 packet with a JSON-wrapped payload.
    """
    if _admin is None:
        raise RuntimeError("Not connected. Call connect() first.")
    payload = json.dumps({"msg": msg})
    encoded = payload.encode("utf-8") + b"\x00"
    length  = 3 + len(encoded)
    packet  = struct.pack("<HB", length, 6) + encoded
    _admin.socket.sendall(packet)
    _p(f"[GS>]   {msg}")


def _dispatch_gamescript(data: dict) -> None:
    """Route a parsed GameScript packet to the correct subsystem.

    Export data (INFO, IND, TOWN, CO, ENG, VEH, STAT, EXPORT_END) → game/exporter
    Command replies (DONE, ERR)                          → commands/queue
    """
    # Late imports avoid circular dependencies at module load time.
    from game import exporter
    from commands import queue

    if not isinstance(data, dict):
        return

    t = data.get("t", "")
    if t in ("INFO", "IND", "TOWN", "CO", "ENG", "VEH", "STAT", "EXPORT_END"):
        exporter.handle_packet(data)
    elif t in ("DONE", "ERR"):
        queue.handle_reply(data)
    else:
        _p(f"[GS] Unhandled packet type '{t}': {data}")
