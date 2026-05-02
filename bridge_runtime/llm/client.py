"""llm/client.py — Thin LLM API wrapper.

Calls an OpenAI-compatible endpoint (LM Studio or any v1/chat/completions API)
and parses the response into a typed list of Decision objects.

Decision is a union:
  RouteDecision — instruct the AI to build a new transport route
  SellDecision  — instruct the AI to sell a vehicle
    CloneDecision — clone an existing vehicle and shared orders
    AddWagonsDecision — append wagons to an existing train
    ReplaceEngineDecision — trigger mass engine replacement
    LoanDecision  — borrow money
    RepayDecision — repay part of loan
    RepayAllDecision — repay full loan
    SkipDecision — explicit no-op/wait
"""

from __future__ import annotations

import json
import time
import re
import base64
from dataclasses import dataclass
from typing import Union

import requests

import config
from game.state import GameState
from llm.prompt import build_prompt, build_system_prompt
from session_store import record_error, record_interaction, set_status
from datetime import datetime


def _extract_reasoning_text(response_json: dict) -> str:
    """Best-effort extraction of reasoning text from OpenAI-compatible payloads."""
    reasoning_parts: list[str] = []

    choices = response_json.get("choices", [])
    if not choices:
        return ""

    choice0 = choices[0] if isinstance(choices[0], dict) else {}
    msg = choice0.get("message", {}) if isinstance(choice0, dict) else {}

    # Common vendor fields for reasoning-capable models.
    direct_candidates = [
        msg.get("reasoning"),
        msg.get("reasoning_content"),
        msg.get("reasoning_details"),
        choice0.get("reasoning"),
        choice0.get("reasoning_details"),
        response_json.get("reasoning"),
    ]
    for candidate in direct_candidates:
        if isinstance(candidate, str) and candidate.strip():
            reasoning_parts.append(candidate.strip())

    # Some APIs return an array of content blocks including reasoning blocks.
    content = msg.get("content")
    if isinstance(content, list):
        for block in content:
            if not isinstance(block, dict):
                continue
            if block.get("type") in ("reasoning", "reasoning_content"):
                txt = block.get("text") or block.get("content")
                if isinstance(txt, str) and txt.strip():
                    reasoning_parts.append(txt.strip())

    # Google OpenAI-compatible responses may expose only a thought signature.
    extra_content = msg.get("extra_content")
    if isinstance(extra_content, dict):
        google_meta = extra_content.get("google")
        if isinstance(google_meta, dict):
            thought_sig = google_meta.get("thought_signature")
            if isinstance(thought_sig, str) and thought_sig.strip():
                reasoning_parts.append(f"[google_thought_signature] {thought_sig.strip()}")

    return "\n\n".join(reasoning_parts)


def _build_chat_completions_url(base_url: str) -> str:
    """Accept either a base /v1 URL or a full chat/completions URL."""
    normalized = base_url.rstrip("/")
    if normalized.endswith("/chat/completions"):
        return normalized
    return f"{normalized}/chat/completions"


def _extract_response_text(response_json: dict) -> str:
    """Extract assistant text from a chat/completions-style payload."""
    choices = response_json.get("choices", [])
    if not choices:
        return ""

    choice0 = choices[0] if isinstance(choices[0], dict) else {}
    message = choice0.get("message", {}) if isinstance(choice0, dict) else {}
    content = message.get("content", "")

    if isinstance(content, str):
        return content

    # Handle tool/block style payloads by concatenating text-like blocks.
    if isinstance(content, list):
        parts: list[str] = []
        for block in content:
            if not isinstance(block, dict):
                continue
            txt = block.get("text") or block.get("content")
            if isinstance(txt, str) and txt.strip():
                parts.append(txt.strip())
        return "\n\n".join(parts)

    return ""


def _extract_provider_error(response_json: object) -> dict | None:
    """Return provider error payload when APIs return HTTP 200 with an error body."""
    if not isinstance(response_json, dict):
        return None
    error = response_json.get("error")
    return error if isinstance(error, dict) else None


def _json_default(obj):
    """JSON serializer fallback for values like bytes returned by some SDK models."""
    if isinstance(obj, bytes):
        try:
            return obj.decode("utf-8")
        except UnicodeDecodeError:
            return {
                "__type__": "bytes_base64",
                "data": base64.b64encode(obj).decode("ascii"),
            }
    return str(obj)


def _coerce_positive_int(value: object) -> int | None:
    """Best-effort conversion to a positive integer; returns None when unset/invalid."""
    try:
        parsed = int(value)
    except (TypeError, ValueError):
        return None
    return parsed if parsed > 0 else None


def log_interaction(entry: dict):
    """Save one interaction entry for the web dashboard."""
    record_interaction(entry)


# ---------------------------------------------------------------------------
# Decision types
# ---------------------------------------------------------------------------

@dataclass
class RouteDecision:
    action:     str   # always "build"
    route_type: str   # TRN, TRK, BUS, PLN, CPL, SHP, FRY
    from_id:    Union[int, str]
    to_id:      Union[int, str]
    eng_id:     int
    wagons:     str = ""  # e.g. "5x4" or "5x4+6x2", empty for non-train
    cargo:      str = ""  # e.g. "MAIL", empty by default
    qty:        int = 1   # Used to build multiple planes for PLN/CPL, defaults to 1


@dataclass
class SellDecision:
    action:  str       # always "sell"
    veh_id:  int
    reason:  str = ""


@dataclass
class LoanDecision:
    action: str        # always "lon"
    amount: int


@dataclass
class RepayDecision:
    action: str        # always "rpy"
    amount: int


@dataclass
class RepayAllDecision:
    action: str = "rpa"


@dataclass
class SkipDecision:
    action: str = "skp"


@dataclass
class CloneDecision:
    action: str = "cln"
    veh_id: int = 0
    count: int = 1


@dataclass
class AddWagonsDecision:
    action: str = "adw"
    veh_id: int = 0
    wagons: str = ""


@dataclass
class ReplaceEngineDecision:
    action: str = "rpl"
    old_eng_id: int = 0
    new_eng_id: int = 0


Decision = Union[
    RouteDecision,
    SellDecision,
    LoanDecision,
    RepayDecision,
    RepayAllDecision,
    SkipDecision,
    CloneDecision,
    AddWagonsDecision,
    ReplaceEngineDecision,
]


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

def _call_gemini_native(game_state: GameState) -> list[Decision]:
    """Execute LLM call using the official google-genai SDK instead of the OpenAI proxy."""
    try:
        from google import genai
        from google.genai import types
    except ImportError:
        raise ImportError("google-genai is not installed. Please run `pip install google-genai`.")
    
    started = time.time()
    system_prompt = build_system_prompt()
    user_prompt = build_prompt(game_state)

    set_status(
        "llm_request_outgoing",
        label="LLM Request Outgoing",
        detail={"provider": "gemini_native", "model": config.LLM_MODEL},
        model=config.LLM_MODEL,
    )

    client = genai.Client(api_key=getattr(config, "LLM_API_KEY", ""))
    
    gen_config_kwargs = {
        "system_instruction": system_prompt,
        "temperature": 0.2,
    }

    thinking_budget: int | None = None
    
    if getattr(config, "LLM_REASONING_ENABLED", False):
        model_name = str(getattr(config, "LLM_MODEL", "")).lower()
        is_flash_lite = "flash-lite" in model_name

        configured_budget = _coerce_positive_int(
            getattr(config, "LLM_REASONING_BUDGET", None)
        )

        # Flash-Lite typically requires an explicit budget to emit thought text.
        if configured_budget is None and is_flash_lite:
            thinking_budget = 1024
        else:
            thinking_budget = configured_budget

        if thinking_budget is not None and is_flash_lite:
            thinking_budget = max(512, min(24576, thinking_budget))

        thinking_config_kwargs = {
            "include_thoughts": True,
        }
        if thinking_budget is not None:
            thinking_config_kwargs["thinking_budget"] = thinking_budget

        gen_config_kwargs["thinking_config"] = types.ThinkingConfig(
            **thinking_config_kwargs
        )

    response = None
    max_attempts = 3
    for attempt in range(1, max_attempts + 1):
        try:
            response = client.models.generate_content(
                model=config.LLM_MODEL,
                contents=user_prompt,
                config=types.GenerateContentConfig(**gen_config_kwargs)
            )
            break
        except Exception as exc:
            if attempt < max_attempts:
                time.sleep(attempt * 2)
                continue
            record_error(
                "provider_error",
                f"Gemini native request failed: {exc}",
                context={"model": config.LLM_MODEL},
            )
            raise exc

    content = response.text if response and hasattr(response, "text") else ""

    reasoning_text = ""
    thought_signature_seen = False
    if response and getattr(response, "candidates", None):
        for candidate in response.candidates:
            if getattr(candidate, "content", None) and getattr(candidate.content, "parts", None):
                for part in getattr(candidate.content, "parts", []):
                    part_text = getattr(part, "text", "")
                    if getattr(part, "thought", False) and part_text:
                        reasoning_text += str(part_text).strip() + "\n\n"

                    thought_signature = getattr(part, "thought_signature", None)
                    if not isinstance(thought_signature, str) and hasattr(part, "model_dump"):
                        try:
                            part_dump = part.model_dump(mode="json", exclude_none=True)
                            if isinstance(part_dump, dict):
                                thought_signature = part_dump.get("thought_signature")
                        except Exception:
                            thought_signature = None

                    if isinstance(thought_signature, str) and thought_signature.strip():
                        thought_signature_seen = True

    reasoning_value = reasoning_text.strip()
    if (
        not reasoning_value
        and thought_signature_seen
        and getattr(config, "LLM_REASONING_ENABLED", False)
    ):
        reasoning_value = (
            "[thinking enabled; provider returned thought_signature metadata but "
            "no thought text]"
        )

    usage = {}
    if response and getattr(response, "usage_metadata", None):
        meta = response.usage_metadata
        usage = {
            "prompt_tokens": getattr(meta, "prompt_token_count", 0),
            "completion_tokens": getattr(meta, "candidates_token_count", 0),
            "total_tokens": getattr(meta, "total_token_count", 0),
        }

    raw_response = ""
    if response is not None and hasattr(response, "model_dump"):
        try:
            # Use JSON mode so bytes and provider-specific types are normalized.
            raw_response = response.model_dump(mode="json", exclude_none=True)
        except Exception:
            raw_response = str(response)
    else:
        raw_response = str(response)

    log_interaction({
        "timestamp": datetime.utcnow().isoformat() + "Z",
        "model": config.LLM_MODEL,
        "latency_ms": int((time.time() - started) * 1000),
        "prompt": json.dumps([
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": user_prompt}
        ], indent=2),
        "response": content,
        "reasoning": reasoning_value,
        "reasoning_meta": {
            "reasoning_enabled": bool(getattr(config, "LLM_REASONING_ENABLED", False)),
            "thinking_budget": thinking_budget,
            "thought_signature_seen": thought_signature_seen,
            "thought_text_seen": bool(reasoning_text.strip()),
        },
        "usage": usage,
        "raw_response": raw_response,
    })

    set_status(
        "llm_response_incoming",
        label="LLM Response Incoming",
        detail={"provider": "gemini_native", "response_chars": len(content)},
        model=config.LLM_MODEL,
    )

    return _filter_and_limit_decisions(_parse_decisions(content), game_state)


def call(game_state: GameState) -> list[Decision]:
    """Send the current game state to the LLM and return parsed decisions."""
    llm_url = str(getattr(config, "LLM_URL", "") or "").strip()
    is_gemini_model = str(getattr(config, "LLM_MODEL", "")).startswith("gemini")
    is_google_openai_compat = "generativelanguage.googleapis.com" in llm_url

    # Prefer native Gemini SDK for Gemini models so thinking config and
    # thought extraction work reliably, even when OpenAI-compatible URL is set.
    if is_gemini_model and (llm_url == "" or is_google_openai_compat):
        return _call_gemini_native(game_state)
        
    payload = {
        "model": config.LLM_MODEL,
        "messages": [
            {"role": "system", "content": build_system_prompt()},
            {"role": "user",   "content": build_prompt(game_state)},
        ],
        "temperature": 0.2,
    }

    # Ensure we do not send the specialized reasoning payload to Google's OpenAI API compatible endpoint
    if getattr(config, "LLM_REASONING_ENABLED", False) and "generativelanguage.googleapis.com" not in llm_url:
        payload["reasoning"] = {"enabled": True}

    headers = {}
    if getattr(config, "LLM_API_KEY", ""):
        headers["Authorization"] = f"Bearer {config.LLM_API_KEY}"

    started = time.time()
    url = _build_chat_completions_url(llm_url)
    set_status(
        "llm_request_outgoing",
        label="LLM Request Outgoing",
        detail={"provider": "openai_compat", "model": config.LLM_MODEL, "url": url},
        model=config.LLM_MODEL,
    )
    sent_payload = dict(payload)
    response_json = {}
    response = None
    max_attempts = 3

    for attempt in range(1, max_attempts + 1):
        response = requests.post(
            url,
            json=sent_payload,
            headers=headers or None,
            timeout=config.LLM_TIMEOUT,
        )

        # OpenRouter may reject when account privacy/guardrail rules leave no endpoint.
        # If reasoning is enabled, retry once without it to reduce provider constraints.
        if (
            response.status_code == 404
            and "openrouter.ai" in str(config.LLM_URL)
            and isinstance(sent_payload.get("reasoning"), dict)
            and "No endpoints available matching your guardrail restrictions and data policy" in response.text
        ):
            sent_payload = dict(sent_payload)
            sent_payload.pop("reasoning", None)
            response = requests.post(
                url,
                json=sent_payload,
                headers=headers or None,
                timeout=config.LLM_TIMEOUT,
            )

        try:
            response.raise_for_status()
        except requests.HTTPError as exc:
            body_preview = response.text[:1000] if response is not None else ""
            status = response.status_code if response is not None else None
            is_transient_http = status in (429, 500, 502, 503, 504, 524)
            if is_transient_http and attempt < max_attempts:
                wait_seconds = attempt * 2
                print(
                    f"[LLM] HTTP {status} from provider, retrying in {wait_seconds}s "
                    f"({attempt + 1}/{max_attempts})"
                )
                time.sleep(wait_seconds)
                continue

            record_error(
                "provider_error",
                f"HTTP {status} from provider: {body_preview}",
                context={"model": config.LLM_MODEL, "url": url, "attempt": attempt},
            )
            raise requests.HTTPError(
                f"{exc} | response body: {body_preview}",
                response=response,
                request=response.request if response is not None else None,
            ) from exc

        try:
            response_json = response.json()
        except ValueError as exc:
            body_preview = response.text[:1000] if response is not None else ""
            record_error(
                "provider_error",
                f"LLM response was not valid JSON: {body_preview}",
                context={"model": config.LLM_MODEL, "url": url},
            )
            raise ValueError(f"LLM response was not valid JSON: {body_preview}") from exc

        provider_error = _extract_provider_error(response_json)
        if provider_error:
            err_code = provider_error.get("code")
            err_msg = str(provider_error.get("message", "")).strip()
            metadata = provider_error.get("metadata")

            lowered = err_msg.lower()
            is_transient_provider = (
                err_code == 429
                or (isinstance(err_code, int) and err_code >= 500)
                or "temporarily rate-limited" in lowered
                or "too many requests" in lowered
            )
            if is_transient_provider and attempt < max_attempts:
                wait_seconds = attempt * 2
                print(
                    f"[LLM] Provider rate-limited request, retrying in {wait_seconds}s "
                    f"({attempt + 1}/{max_attempts})"
                )
                time.sleep(wait_seconds)
                continue

            metadata_str = f" metadata={json.dumps(metadata)}" if metadata is not None else ""
            record_error(
                "provider_error",
                f"Provider error in response body: code={err_code} message={err_msg}{metadata_str}",
                context={"model": config.LLM_MODEL, "url": url, "attempt": attempt},
            )
            raise requests.HTTPError(
                f"Provider error in response body: code={err_code} message={err_msg}{metadata_str}",
                response=response,
                request=response.request if response is not None else None,
            )

        # Successful response with no embedded provider error.
        break

    content = _extract_response_text(response_json)
    reasoning_text = _extract_reasoning_text(response_json)

    # Log a richer record for the dashboard.
    log_interaction({
        "timestamp": datetime.utcnow().isoformat() + "Z",
        "model": config.LLM_MODEL,
        "latency_ms": int((time.time() - started) * 1000),
        "prompt": json.dumps(sent_payload["messages"], indent=2),
        "response": content,
        "reasoning": reasoning_text,
        "usage": response_json.get("usage", {}),
        # Keep raw provider payload for debugging parser/dash issues.
        "raw_response": response_json,
    })

    set_status(
        "llm_response_incoming",
        label="LLM Response Incoming",
        detail={"provider": "openai_compat", "response_chars": len(content)},
        model=config.LLM_MODEL,
    )
    
    return _filter_and_limit_decisions(_parse_decisions(content), game_state)


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

def _filter_and_limit_decisions(decisions: list[Decision], game_state: GameState) -> list[Decision]:
    """Apply budget-based limits and rules to the returned decisions."""
    ai_money = 0
    for c in game_state.companies.values():
        if c.name == "SquirrelAI Corp":
            ai_money = c.money
            break

    money_per_command = max(10000, int(getattr(config, "LLM_MONEY_PER_COMMAND", 100000)))

    limit = 1
    if ai_money >= money_per_command:
        limit = int(ai_money // money_per_command)

    # Enforce NO SKP if there is enough budget to act.
    if ai_money >= money_per_command:
        before = len(decisions)
        decisions = [d for d in decisions if not isinstance(d, SkipDecision)]

        removed = before - len(decisions)
        if removed:
            print(
                f"[LLM] Dropped {removed} SKP decision(s): balance {ai_money} "
                f">= command budget threshold {money_per_command}."
            )

    if len(decisions) > limit:
        print(
            f"[LLM] Truncating decisions from {len(decisions)} to {limit} "
            f"based on balance policy ({ai_money} / {money_per_command})."
        )

    return decisions[:limit]


def _parse_decisions(content: str) -> list[Decision]:
    """Extract multiple JSON objects from the LLM response, stripping formatting."""
    content = content.strip()

    # Strip explicit reasoning blocks used by some models/providers.
    # Example:
    #   <think> ... </think>
    content = re.sub(r"<think>.*?</think>", "", content, flags=re.IGNORECASE | re.DOTALL).strip()
    
    # Strip markdown block formatting if present
    if content.startswith("```json"):
        content = content[7:]
    elif content.startswith("```"):
        content = content[3:]
    
    content = content.strip()
            
    decoder = json.JSONDecoder()
    raw_list = []
    pos = 0

    # 1. Sequential parse from the top
    while pos < len(content):
        while pos < len(content) and content[pos].isspace():
            pos += 1
        if pos >= len(content) or content[pos] not in ("{", "["):
            break
        try:
            obj, next_pos = decoder.raw_decode(content, pos)
            if isinstance(obj, dict):
                raw_list.append(obj)
            elif isinstance(obj, list):
                raw_list.extend([x for x in obj if isinstance(x, dict)])
            pos = next_pos
        except json.JSONDecodeError:
            break

    # 2. Fallback: Search for any JSON objects if top-down parsing yielded nothing
    if not raw_list:
        starts = [i for i, ch in enumerate(content) if ch in ("{", "[")]
        for start_idx in starts:
            candidate = content[start_idx:]
            try:
                parsed, _ = decoder.raw_decode(candidate)
                if isinstance(parsed, dict):
                    raw_list.append(parsed)
                    break
                if isinstance(parsed, list):
                    valid_items = [x for x in parsed if isinstance(x, dict)]
                    if valid_items:
                        raw_list.extend(valid_items)
                        break
            except json.JSONDecodeError:
                continue

    if not raw_list:
        print(f"[LLM] JSON parse error: unable to decode any candidate. Raw: {content[:300]}...")
        return []

    decisions: list[Decision] = []
    for item in raw_list:
        if not isinstance(item, dict):
            print(f"[LLM] Ignoring non-object JSON item: {item!r}")
            continue

        action = str(item.get("action", "")).strip()
        action_norm = action.lower()
        try:
            if action_norm == "build":
                route_type = str(item.get("route_type", "TRN")).upper()
                if route_type == "CTY":
                    town_id = item.get("town_id", item.get("from_id"))
                    if town_id is None:
                        raise KeyError("town_id")
                    decisions.append(RouteDecision(
                        action="build",
                        route_type=route_type,
                        from_id=town_id,
                        to_id=town_id,
                        eng_id=int(item["eng_id"]),
                        wagons=str(item.get("wagons", "1")),
                        cargo=str(item.get("cargo", "")),
                        qty=1,
                    ))
                else:
                    decisions.append(RouteDecision(
                        action="build",
                        route_type=route_type,
                        from_id=item["from_id"],
                        to_id=item["to_id"],
                        eng_id=int(item["eng_id"]),
                        wagons=str(item.get("wagons", "")),
                        cargo=str(item.get("cargo", "")),
                        qty=int(item.get("qty", 1)),
                    ))
            elif action_norm == "sell":
                decisions.append(SellDecision(
                    action="sell",
                    veh_id=int(item["veh_id"]),
                    reason=str(item.get("reason", "")),
                ))
            elif action_norm in ("lon", "loan"):
                decisions.append(LoanDecision(
                    action="lon",
                    amount=int(item["amount"]),
                ))
            elif action_norm in ("rpy", "repay"):
                decisions.append(RepayDecision(
                    action="rpy",
                    amount=int(item["amount"]),
                ))
            elif action_norm in ("rpa", "repay_all", "repayall"):
                decisions.append(RepayAllDecision(action="rpa"))
            elif action_norm in ("skp", "skip", "wait"):
                decisions.append(SkipDecision(action="skp"))
            elif action_norm in ("cln", "clone"):
                decisions.append(CloneDecision(
                    action="cln",
                    veh_id=int(item["veh_id"]),
                    count=int(item.get("count", 1)),
                ))
            elif action_norm in ("adw", "add_wagons", "addwagons"):
                decisions.append(AddWagonsDecision(
                    action="adw",
                    veh_id=int(item["veh_id"]),
                    wagons=str(item["wagons"]),
                ))
            elif action_norm in ("rpl", "replace_engine", "replace"):
                decisions.append(ReplaceEngineDecision(
                    action="rpl",
                    old_eng_id=int(item["old_eng_id"]),
                    new_eng_id=int(item["new_eng_id"]),
                ))
            else:
                print(f"[LLM] Unknown action '{action}', skipping.")
        except (KeyError, ValueError) as exc:
            print(f"[LLM] Malformed decision item {item}: {exc}")

    return decisions
