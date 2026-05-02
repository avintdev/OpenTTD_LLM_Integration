"""Runtime settings read/write helpers for model configuration.

This module updates the `secrets.py` source of truth by changing:
- `LLM_MODEL = "..."`
- `LLM_API_KEY = os.environ.get("ENV_NAME")`
"""

from __future__ import annotations

import re
from pathlib import Path

import config


ROOT = Path(__file__).resolve().parent
SECRETS_PATH = ROOT / "secrets.py"


_MODEL_RE = re.compile(r"^\s*LLM_MODEL\s*=\s*(.+)$", re.MULTILINE)
_API_KEY_RE = re.compile(r"^\s*LLM_API_KEY\s*=\s*(.+)$", re.MULTILINE)
_OS_IMPORT_RE = re.compile(r"^\s*import\s+os\s*$", re.MULTILINE)
_ENV_GET_RE = re.compile(r"os\.environ\.get\(\s*[\"']([^\"']+)[\"']\s*\)")


def _read_secrets_text() -> str:
    if not SECRETS_PATH.exists():
        return "import os\n\n"
    return SECRETS_PATH.read_text(encoding="utf-8")


def _extract_api_key_env_name(expr_text: str) -> str:
    match = _ENV_GET_RE.search(expr_text)
    if match:
        return match.group(1)
    return ""


def get_runtime_settings() -> dict:
    """Return current model settings as seen by runtime + persisted secrets.py."""
    text = _read_secrets_text()

    model_match = _MODEL_RE.search(text)
    api_match = _API_KEY_RE.search(text)

    persisted_model = ""
    persisted_api_key_env = ""

    if model_match:
        raw = model_match.group(1).strip()
        if (raw.startswith('"') and raw.endswith('"')) or (raw.startswith("'") and raw.endswith("'")):
            persisted_model = raw[1:-1]
        else:
            persisted_model = raw

    if api_match:
        persisted_api_key_env = _extract_api_key_env_name(api_match.group(1).strip())

    return {
        "model": str(getattr(config, "LLM_MODEL", "") or ""),
        "api_key_env": persisted_api_key_env,
        "llm_url": str(getattr(config, "LLM_URL", "") or ""),
        "timeout": int(getattr(config, "LLM_TIMEOUT", 0) or 0),
        "persisted_model": persisted_model,
    }


def update_runtime_settings(model: str, api_key_env: str) -> dict:
    """Persist model + API-key env var name to secrets.py and reload config."""
    model = (model or "").strip()
    api_key_env = (api_key_env or "").strip()

    if not model:
        raise ValueError("model cannot be empty")
    if not re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", api_key_env):
        raise ValueError("api_key_env must be a valid environment variable name")

    text = _read_secrets_text()

    if not _OS_IMPORT_RE.search(text):
        text = "import os\n\n" + text

    model_line = f'LLM_MODEL = "{model}"'
    key_line = f'LLM_API_KEY = os.environ.get("{api_key_env}")'

    if _MODEL_RE.search(text):
        text = _MODEL_RE.sub(model_line, text, count=1)
    else:
        text = text.rstrip() + "\n" + model_line + "\n"

    if _API_KEY_RE.search(text):
        text = _API_KEY_RE.sub(key_line, text, count=1)
    else:
        text = text.rstrip() + "\n" + key_line + "\n"

    SECRETS_PATH.write_text(text, encoding="utf-8")
    config.reload_runtime_settings()
    return get_runtime_settings()
