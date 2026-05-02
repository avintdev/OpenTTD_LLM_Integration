# SquirrelAI OpenTTD Bridge

LLM-driven OpenTTD AI plus a GameScript bridge. The Python bridge talks to the OpenTTD admin port, requests live game exports from `SquirrelGS`, asks an OpenAI-compatible chat endpoint for decisions, and sends commands to `SquirrelAI`.

## Contents

- `SquirrelAI/` - OpenTTD AI script.
- `SquirrelGS/` - OpenTTD GameScript bridge.
- `bridge_runtime/` - Python admin-port bridge and dashboard server.
- `web/index.html` - local dashboard served at `http://localhost:8080/`.
- `COMMANDS.md` - command and export packet reference.

## Setup

1. Install Python 3.10 or newer.
2. Install Python dependencies:

   ```powershell
   py -m venv .venv
   .\.venv\Scripts\Activate.ps1
   pip install -r requirements.txt
   ```

   Optional native Gemini mode requires `google-genai`:

   ```powershell
   pip install google-genai
   ```

3. Copy `SquirrelAI/` and `SquirrelGS/` into your OpenTTD AI and GameScript script folders.
4. Enable the OpenTTD admin port and set its password to match `ADMIN_PASSWORD`.
5. Copy `bridge_runtime/secrets.example.py` to `bridge_runtime/secrets.py`
   and edit the local values. `secrets.py` is ignored by git:

   ```python
   import os

   ADMIN_PASSWORD = "bridge_password"
   LLM_URL = "http://localhost:1234/v1"
   LLM_MODEL = "your-model-name"
   LLM_API_KEY = os.environ.get("OPENAI_API_KEY", "")
   ```

6. Start an OpenTTD game with `SquirrelGS` and `SquirrelAI` active, then run:

   ```powershell
   python bridge_runtime/bridge.py
   ```

Useful modes:

```powershell
python bridge_runtime/bridge.py --debug       # manual REPL, no LLM dispatch loop
python bridge_runtime/bridge.py --standalone  # dashboard only, no OpenTTD connection
```

## Licensing

This repository vendors GPL-3.0 AAAHogEx-derived runtime modules, so distribute this combined source under GPL-3.0 and keep the included `LICENSE` file. See `THIRD_PARTY_NOTICES.md` for the third-party code and dependency notices.
