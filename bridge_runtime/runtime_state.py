"""Shared bridge runtime state."""

import threading


llm_lock = threading.Lock()
