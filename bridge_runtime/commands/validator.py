"""commands/validator.py — Pre-send sanity checks for Decision objects.

Validates that IDs referenced by a decision exist in the most recent
export snapshot before the command is sent to the GameScript.

Note: wagon cargo compatibility is intentionally NOT validated here —
incorrect LLM cargo choices are observable failures used for benchmarking.
"""

from __future__ import annotations

import re


def validate_decision(decision, state_snapshot=None) -> str | None:
    """Return an error description string if the decision is invalid, else None.

    Checks performed:
      RouteDecision:
        - from_id != to_id
        - eng_id exists in current engine export
        - from_id industry exists on current map
        - to_id industry exists on current map
      SellDecision:
        - veh_id exists in current vehicle export
            CloneDecision:
                - veh_id exists in current vehicle export
                - count > 0
            AddWagonsDecision:
                - veh_id exists and is a train in current vehicle export
                - wagons follows '<wagon_id>x<count>[+...]' (or '<wagon_id>[+...]')
                - wagon engine IDs exist and are train wagons
            ReplaceEngineDecision:
                - old_eng_id/new_eng_id exist in current engine export
                - old/new engines are the same vehicle type
            LoanDecision:
                - amount > 0 and multiple of 10,000
            RepayDecision:
                - amount > 0
            RepayAllDecision / SkipDecision:
                - always valid
    """
    # Late imports to avoid circular dependencies and to always use the
    # most up-to-date game state snapshot.
    from llm.client import (
        RouteDecision,
        SellDecision,
        CloneDecision,
        AddWagonsDecision,
        ReplaceEngineDecision,
        LoanDecision,
        RepayDecision,
        RepayAllDecision,
        SkipDecision,
    )
    from game.exporter import _state

    # Prefer the exact snapshot that produced the LLM decision.
    state_ref = state_snapshot if state_snapshot is not None else _state

    if isinstance(decision, RouteDecision):
        # 1) Parse IDs
        from_id_str = str(decision.from_id)
        to_id_str   = str(decision.to_id)
        rtype = decision.route_type.upper()
        
        # CTY is an intra-town mode, so same source/destination is valid there.
        if rtype != "CTY" and from_id_str == to_id_str:
            return f"from_id == to_id ({from_id_str}): cannot build a route to itself"

        # 2) Validate Engine
        if decision.eng_id not in state_ref.engines:
            return (
                f"engine ID {decision.eng_id} not found in current export "
                "(may not be available this game year)"
            )
            
        eng_vtype = state_ref.engines[decision.eng_id].vtype
        
        vtype_map = {
            "TRN": "TRAIN",
            "TRK": "ROAD",
            "BUS": "ROAD",
            "CTY": "ROAD",
            "SHP": "WATER",
            "FRY": "WATER",
            "PLN": "AIR",
            "CPL": "AIR"
        }
        expected_vtype = vtype_map.get(rtype)
        if expected_vtype and expected_vtype != eng_vtype:
            return f"engine {decision.eng_id} is vtype {eng_vtype}, but route type {rtype} requires {expected_vtype}"
            
        qty = getattr(decision, "qty", 1)
        if qty <= 0:
            return f"qty must be > 0, got {qty}"

        if rtype == "TRN":
            # Train engine must be a locomotive, not a wagon.
            if state_ref.engines[decision.eng_id].is_wagon:
                return f"engine {decision.eng_id} is a wagon, not a train locomotive"

            wagons = str(decision.wagons).strip()
            if not wagons:
                return "TRN requires non-empty wagons in '<wagon_id>x<count>[+...]' format"

            segments = wagons.split("+")
            for seg in segments:
                seg = seg.strip()
                m = re.match(r"^(\d+)x(\d+)$", seg)
                if m is None:
                    return (
                        f"invalid wagon segment '{seg}'; expected '<wagon_id>x<count>' "
                        "(example: 29x5+28x1)"
                    )

                wid = int(m.group(1))
                count = int(m.group(2))
                if count <= 0:
                    return f"wagon count must be > 0 in segment '{seg}'"

                if wid not in state_ref.engines:
                    return f"wagon engine ID {wid} not found in current engine export"

                weng = state_ref.engines[wid]
                if weng.vtype != "TRAIN" or not weng.is_wagon:
                    return f"engine ID {wid} is not a valid train wagon"

        # Helper to extract integer ID from potentially prefixed string
        def extract_id(s: str) -> int:
            return int(s[1:]) if s.startswith(('i', 'I', 't', 'T')) else int(s)

        from_int = extract_id(from_id_str)
        to_int   = extract_id(to_id_str)

        # 3) Validate endpoints based on route type
        if rtype == "CTY":
            if from_int not in state_ref.towns:
                return f"town_id={from_int} not found as town (required for CTY)"
        elif rtype in ("PLN", "FRY"):
            # Must be towns
            if from_int not in state_ref.towns:
                return f"source from_id={from_int} not found as town (required for {rtype})"
            if to_int not in state_ref.towns:
                return f"destination to_id={to_int} not found as town (required for {rtype})"
        elif rtype in ("CPL", "SHP"):
            # Source must be industry, dest can be industry or town
            if from_int not in state_ref.industries:
                return f"source from_id={from_int} not found as industry (required for {rtype})"
            if to_int not in state_ref.industries and to_int not in state_ref.towns:
                return f"destination to_id={to_int} not found as industry or town"
        else: # TRN, TRK, BUS
            from_ok = (from_int in state_ref.industries or from_int in state_ref.towns)
            if not from_ok:
                return f"source from_id={from_int} not found as industry or town"
            to_ok = (to_int in state_ref.industries or to_int in state_ref.towns)
            if not to_ok:
                return f"destination to_id={to_int} not found as industry or town"

        return None

    if isinstance(decision, SellDecision):
        if decision.veh_id not in state_ref.vehicles:
            return f"vehicle ID {decision.veh_id} not found in current export"
        return None

    if isinstance(decision, CloneDecision):
        if decision.veh_id not in state_ref.vehicles:
            return f"vehicle ID {decision.veh_id} not found in current export"
        if decision.count <= 0:
            return "clone count must be > 0"
        return None

    if isinstance(decision, AddWagonsDecision):
        if decision.veh_id not in state_ref.vehicles:
            return f"vehicle ID {decision.veh_id} not found in current export"

        veh_type = str(getattr(state_ref.vehicles[decision.veh_id], "type", "")).upper()
        if veh_type not in ("TRAIN", "RAIL"):
            return f"vehicle {decision.veh_id} is type {veh_type}, ADW requires TRAIN"

        wagons = str(decision.wagons).strip()
        if not wagons:
            return "ADW requires non-empty wagons string"

        segments = wagons.split("+")
        for seg in segments:
            seg = seg.strip()
            m = re.match(r"^(\d+)(?:x(\d+))?$", seg)
            if m is None:
                return (
                    f"invalid ADW wagon segment '{seg}'; expected '<wagon_id>x<count>' "
                    "(or '<wagon_id>')"
                )

            wid = int(m.group(1))
            count = int(m.group(2)) if m.group(2) is not None else 1
            if count <= 0:
                return f"wagon count must be > 0 in segment '{seg}'"

            if wid not in state_ref.engines:
                return f"wagon engine ID {wid} not found in current engine export"

            weng = state_ref.engines[wid]
            if weng.vtype != "TRAIN" or not weng.is_wagon:
                return f"engine ID {wid} is not a valid train wagon"

        return None

    if isinstance(decision, ReplaceEngineDecision):
        if decision.old_eng_id not in state_ref.engines:
            return f"old engine ID {decision.old_eng_id} not found in current export"
        if decision.new_eng_id not in state_ref.engines:
            return f"new engine ID {decision.new_eng_id} not found in current export"

        old_vtype = state_ref.engines[decision.old_eng_id].vtype
        new_vtype = state_ref.engines[decision.new_eng_id].vtype
        if old_vtype != new_vtype:
            return (
                f"engine type mismatch: old engine {decision.old_eng_id} is {old_vtype}, "
                f"new engine {decision.new_eng_id} is {new_vtype}"
            )
        return None

    if isinstance(decision, LoanDecision):
        if decision.amount <= 0:
            return "loan amount must be > 0"
        if decision.amount % 10000 != 0:
            return "loan amount must be a multiple of 10000"
        return None

    if isinstance(decision, RepayDecision):
        if decision.amount <= 0:
            return "repay amount must be > 0"
        return None

    if isinstance(decision, (RepayAllDecision, SkipDecision)):
        return None

    return f"unknown decision type: {type(decision)}"
