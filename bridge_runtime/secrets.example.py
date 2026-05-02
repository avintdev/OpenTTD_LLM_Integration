"""Example local runtime settings.

Copy this file to secrets.py and edit values for your machine. The real
secrets.py file is intentionally git-ignored.
"""

import os


ADMIN_PASSWORD = "bridge_password"
LLM_URL = "http://localhost:1234/v1"
LLM_MODEL = "your-model-name"
LLM_TIMEOUT = 600
LLM_API_KEY = os.environ.get("OPENAI_API_KEY", "")

LLM_REASONING_ENABLED = False
LLM_REASONING_BUDGET = None
SKIP_EXPORT_COOLDOWN_SECONDS = 120
LLM_MONEY_PER_COMMAND = 100000
