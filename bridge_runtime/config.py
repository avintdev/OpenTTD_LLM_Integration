# All configuration constants for the SquirrelAI bridge

from __future__ import annotations

import importlib


# Runtime-loaded values from secrets.py
ADMIN_PASSWORD = "bridge_password"
LLM_URL = "http://localhost:1234/v1"
LLM_MODEL = "your-model-name"
LLM_TIMEOUT = 600
LLM_API_KEY = ""
LLM_REASONING_ENABLED = False
LLM_REASONING_BUDGET = None
SKIP_EXPORT_COOLDOWN_SECONDS = 120
LLM_MONEY_PER_COMMAND = 100000


def _get_secret(module, name: str, default):
	return getattr(module, name, default) if module is not None else default


def reload_runtime_settings() -> None:
	"""Reload runtime settings from secrets.py with safe defaults."""
	global ADMIN_PASSWORD
	global LLM_URL
	global LLM_MODEL
	global LLM_TIMEOUT
	global LLM_API_KEY
	global LLM_REASONING_ENABLED
	global LLM_REASONING_BUDGET
	global SKIP_EXPORT_COOLDOWN_SECONDS
	global LLM_MONEY_PER_COMMAND

	try:
		import secrets as secrets_module
		secrets_module = importlib.reload(secrets_module)
	except ImportError:
		secrets_module = None

	ADMIN_PASSWORD = _get_secret(secrets_module, "ADMIN_PASSWORD", "bridge_password")
	LLM_URL = _get_secret(secrets_module, "LLM_URL", "http://localhost:1234/v1")
	LLM_MODEL = _get_secret(secrets_module, "LLM_MODEL", "your-model-name")
	LLM_TIMEOUT = int(_get_secret(secrets_module, "LLM_TIMEOUT", 600))
	LLM_API_KEY = _get_secret(secrets_module, "LLM_API_KEY", "")

	LLM_REASONING_ENABLED = bool(
		_get_secret(secrets_module, "LLM_REASONING_ENABLED", False)
	)
	LLM_REASONING_BUDGET = _get_secret(secrets_module, "LLM_REASONING_BUDGET", None)
	SKIP_EXPORT_COOLDOWN_SECONDS = float(
		_get_secret(secrets_module, "SKIP_EXPORT_COOLDOWN_SECONDS", 120)
	)
	LLM_MONEY_PER_COMMAND = int(
		_get_secret(secrets_module, "LLM_MONEY_PER_COMMAND", 100000)
	)


reload_runtime_settings()


# Static transport constants
ADMIN_HOST = "127.0.0.1"
ADMIN_PORT = 3977

EXPORT_INTERVAL_SECONDS = 10
AUTO_EXPORT_ENABLED = True

MAILBOX_X = 1
MAILBOX_Y = 1

COMMAND_TIMEOUT_TICKS = 5000
