"""llm/prompt.py — Prompt construction for the LLM decision engine.

Keeps all prompt-related logic isolated so it can be tuned independently
of the API transport (llm/client.py).
"""

import json

import config
from game.state import GameState


def build_system_prompt() -> str:
    """Return the fixed system-level prompt that frames the LLM's role."""
    return (
        "You are an AI playing OpenTTD as SquirrelAI Corp, an open-source transport simulation game.\n"
    )


def build_prompt(state: GameState) -> str:
    """Serialise the complete game state into the user-turn prompt."""
    # Pull recent bridge-dispatched command outcomes so the LLM can avoid retries.
    from commands.queue import get_recent_command_results
    recent_cmd_results = get_recent_command_results(limit=10)

    industries = [
        {
            "id": ind.id,
            "loc_id": f"i{ind.id}",
            "x": ind.x,
            "y": ind.y,
            "type": ind.type,
            "cargo": ind.cargo,
            "prod": ind.prod,
            "served": ind.served,
            "served_lm": getattr(ind, "served_lm", ind.served),
            "trans_lm": getattr(ind, "trans_lm", 0),
            "near_station": getattr(ind, "near_station", False),
            "role": ind.role,
            "coastal": getattr(ind, "coastal", False),
        }
        for group in state.industries.values()
        for ind in group
    ]

    towns = [
        {
            "id": t.id,
            "loc_id": f"t{t.id}",
            "x": t.x,
            "y": t.y,
            "name": t.name,
            "pop": t.pop,
            "coastal": getattr(t, "coastal", False),
        }
        for t in state.towns.values()
    ]

    companies = [
        {
            "id": c.id, "name": c.name,
            "money": c.money, "loan": c.loan, "vehs": c.vehs,
        }
        for c in state.companies.values()
    ]

    engines = []
    for e in state.engines.values():
        eng = {
            "id": e.id, "name": e.name, "vtype": e.vtype,
            "power": e.power, "speed": e.speed,
            "cargo": e.cargo, "cap": e.cap,
            "is_wagon": e.is_wagon, "reliability": e.reliability,
            "price": e.price, "running_cost": e.running_cost,
        }
        if e.refit:
            eng["refit"] = e.refit
        engines.append(eng)

    train_engines = [e for e in engines if e["vtype"] == "TRAIN" and not e["is_wagon"]]
    train_wagons = [e for e in engines if e["vtype"] == "TRAIN" and e["is_wagon"]]
    road_vehicles = [e for e in engines if e["vtype"] == "ROAD"]
    airplanes = [e for e in engines if e["vtype"] == "AIR"]
    ships = [e for e in engines if e["vtype"] == "WATER"]

    allowed_ids = {
        "TRN_engine_ids": [e["id"] for e in train_engines],
        "TRN_wagon_ids": [e["id"] for e in train_wagons],
        "TRK_BUS_engine_ids": [e["id"] for e in road_vehicles],
        "PLN_CPL_engine_ids": [e["id"] for e in airplanes],
    }

    vehicles = [
        {
            "id": v.id, "company": v.company, "type": v.type, "name": v.name,
            "profit_ly": v.profit_ly, "profit_ty": v.profit_ty,
            "age": v.age, "running_cost": v.running_cost, "status": v.status,
            "cargo": getattr(v, "cargo", ""),
            "cap": getattr(v, "cap", 0),
            "cap_main": getattr(v, "cap_main", getattr(v, "cap", 0)),
            "cap_by_cargo": getattr(v, "cap_by_cargo", {}),
        }
        for v in state.vehicles.values()
    ]

    stations = [
        {
            "id": s.id, "name": s.name, "company": s.company,
            "x": s.x, "y": s.y,
            "train": s.train, "bus": s.bus, "truck": s.truck,
            "airport": s.airport, "dock": s.dock,
            "town": s.town,
        }
        for s in state.stations.values()
    ]

    # Determine command limit based on SquirrelAI Corp money
    ai_money = 0
    for c in state.companies.values():
        if c.name == "SquirrelAI Corp":
            ai_money = c.money
            break

    cmd_limit = 1
    money_per_command = max(10000, int(getattr(config, "LLM_MONEY_PER_COMMAND", 100000)))
    if ai_money >= money_per_command:
        cmd_limit = int(ai_money // money_per_command)

    prompt_parts = [f"Current game state (Year: {state.year}) - SquirrelAI Corp Balance: {ai_money}:\n"]

    if recent_cmd_results:
        prompt_parts.append("--- RECENT COMMAND/REPLY HISTORY (CURRENT SESSION, last 10 max) ---")
        prompt_parts.append(json.dumps(recent_cmd_results, indent=2) + "\n")
    
    if companies:
        prompt_parts.append("--- COMPANIES (financial status) ---")
        prompt_parts.append(json.dumps(companies, indent=2) + "\n")
        
    if industries:
        prompt_parts.append("--- INDUSTRIES (freight destinations/sources) ---")
        prompt_parts.append(json.dumps(industries, indent=2) + "\n")
        
    if towns:
        prompt_parts.append("--- TOWNS (passenger destinations/sources) ---")
        prompt_parts.append(json.dumps(towns, indent=2) + "\n")
        
    if train_engines:
        prompt_parts.append("--- TRAIN ENGINES (for TRN routes) ---")
        prompt_parts.append(json.dumps(train_engines, indent=2) + "\n")
        
    if train_wagons:
        prompt_parts.append("--- TRAIN WAGONS (for TRN routes) ---")
        prompt_parts.append(json.dumps(train_wagons, indent=2) + "\n")
        
    if road_vehicles:
        prompt_parts.append("--- ROAD VEHICLES (for TRK/BUS routes) ---")
        prompt_parts.append(json.dumps(road_vehicles, indent=2) + "\n")
        
    if airplanes:
        prompt_parts.append("--- AIRPLANES (for PLN/CPL routes) ---")
        prompt_parts.append(json.dumps(airplanes, indent=2) + "\n")

    prompt_parts.append("--- ALLOWED ENGINE IDS BY MODE (MUST USE THESE EXACT IDS) ---")
    prompt_parts.append(json.dumps(allowed_ids, indent=2) + "\n")
        
    if stations:
        prompt_parts.append("--- EXISTING STATIONS (already serviced towns/industries) ---")
        prompt_parts.append(json.dumps(stations, indent=2) + "\n")
        
    if vehicles:
        prompt_parts.append("--- ACTIVE VEHICLES (your currently operating vehicles, potential to sell if losing money) ---")
        prompt_parts.append(json.dumps(vehicles, indent=2) + "\n")

    prompt_parts.append(
                        "====== EXPERT TRANSPORT AI INSTRUCTIONS ======\n"
        "\n"


        "\n"


        "Your goal is to build highly profitable transport routes, aggressively scale your transport empire, and manage your vehicle fleet.\n\n"
        "CRITICAL INSTRUCTIONS & ANTI-HALLUCINATION RULES:\n"
        f"1. MULTIPLE DECISIONS ALLOWED: You can output up to {cmd_limit} action(s) this turn based on your current balance of {ai_money}. U should try to fill this limit to maximize investments and ROI.\n"
        "2. NO HALLUCINATION: Every ID you use (eng_id, veh_id, from_id, to_id) MUST be chosen from the EXACT 'id' values shown in the current game state JSON provided to you.\n"
        "3. DO NOT INVENT IDs: If you supply an engine ID, vehicle ID, industry ID, or town ID that is not explicitly listed in the input state, the game will reject your command.\n"
        "4. STRICT OUTPUT: List your JSON commands (one per line) at the very top of your response. Then, after two empty new lines, provide a brief explanation.\n\n"
        "INDUSTRY FRESHNESS FIELDS:\n"
        "  - served / served_lm: based on last-month transported amount (monthly granularity).\n"
        "  - trans_lm: exact last-month transported units for that cargo at that industry.\n"
        "  - near_station: fast-updating infrastructure hint (true when any station is within ~4 tiles).\n\n"
        "UNDERSTANDING THE INPUT DATA (Where to find IDs & Costs):\n"
        "  - 'industries' list: Contains freight locations. Use exact 'loc_id' (e.g., 'i12') for from_id / to_id.\n"
        "  - 'towns' list: Contains passenger/mail locations. Use exact 'loc_id' (e.g., 't5').\n"
        "  - 'engines' list: Contains purchaseable vehicles. Use the exact integer 'id' for eng_id when building.\n"
        "       * Every engine row includes 'price' and 'running_cost'; treat those as authoritative over generic tables.\n"
        "       * Every engine row includes EXACT 'price' (purchase cost) and 'running_cost'. Rely exclusively on these exact numbers for your financial math.\n"
        "  - 'vehicles' list: Contains existing active vehicles. Use the exact integer 'id' for 'veh_id' when selling.\n\n"
        "       * Capacity fields: 'cap' (total), 'cap_main' (largest single-cargo capacity), and 'cap_by_cargo'.\n\n"
        "RULES FOR BUILDING ROUTES:\n"
        "1. Prefer industries with served=false/served_lm=false and use near_station to avoid duplicating covered routes.\n"
        "2. For cargo routes, only build if the chosen cargo is produced at source AND accepted at destination.\n"
        "3. Sell loss-making vehicles (negative profit) BUT ONLY IF they have age >= 1825 days (5 years). Do NOT sell new vehicles.\n"
        "4. Infrastructure reuse: check the 'stations' list for existing stops/airports/docks near a planned endpoint to save capital.\n\n"
        "PROFIT, ROI & DISTANCE STRATEGY (CRITICAL):\n"
        "  - Abstract Revenue Formula: Payment ~= Distance x Cargo Volume Delivered x Vehicle Speed.\n"
        "  - Maximizing ROI: Because infrastructure (rails, roads, airports) is a massive one-time fixed cost, your goal is to push the highest possible volume over the longest possible distance at the highest possible speed.\n"
        "  - Long distances exponentially increase profits, provided the vehicles are fast enough to deliver before cargo value decays.\n"
        "  - Short routes have terrible ROI because the fixed CapEx of stations/depots is never recouped by the tiny delivery payouts.\n\n"
        "CAPACITY SIZING & FLEET DEPLOYMENT:\n"
        "  - A route's throughput must match the source industry's 'prod' (production rate) or town's 'pop' (population).\n"
        "  - Total Fleet Capacity Needed ~= Industry Production x (Route Distance / Vehicle Speed).\n"
        "  - Try to minimize the number of long routes with small number or trucks/wagons.\n"
        "  - Try to only deploy a few airplanes per airport - they can flood the airport and get stuck in the depot generating costs but no profit. It is better to expand to towns with no airports yet. Once you have served most towns with airports try to look for other investments.\n"
        "  - Scale train wagon compositions directly to the demanded cargo throughput. Maximize train length where possible.\n\n"
        "AGGRESSIVE FINANCING & LOAN POLICY:\n"
        "  - Money sitting in the bank is wasted potential. Maximize your investments.\n"
        "  - Loan interest is exceptionally low (~2%). You start with 100,000 but can borrow up to 300,000.\n"
        "  - ALWAYS borrow aggressively (output 'LON' action) to fund massive, high-ROI, long-distance routes rather than settling for cheap, low-ROI short routes.\n"
        "  - AIRPLANES ARE HIGHLY PROFITABLE. If you have enough money (check balance + max loan), PRIORITIZE building airplane routes (PLN or CPL) over trains or road vehicles - also remember that airplanes can cover long distances quickly and there are no additional tiles to be constructed.\n"
        "  - If you lack cash for a highly profitable long-distance corridor, output 'LON'.\n"
        "  - Financial decision JSON (mapped by bridge to actual commands):\n"
        "      * {\"action\":\"lon\",\"amount\":50000} -> !cmd LON:50000 (amount must be multiple of 10000).\n"
        "      * {\"action\":\"rpy\",\"amount\":50000} -> !cmd RPY:50000.\n"
        "      * {\"action\":\"rpa\"} -> !cmd RPA.\n"
        "  - Repeating LON/RPY across turns is allowed when still financially necessary; repeated SKP is also allowed when waiting is still the correct action.\n"
        "  - Only output 'SKP' (wait) if you are maxed out on loans (300,000) and cannot afford any productive builds.\n"
        f"{f'  - IMPORTANT: Since your balance is >= {money_per_command:,}, you are NOT allowed to use SKP this turn. You must take productive actions.' if ai_money >= money_per_command else ''}\n\n"
        "ECONOMY QUICK ESTIMATE (fallback circa values; tile/terrain and clearing can increase total cost significantly):\n"
        "  - BuildRoad=150, BuildRail=300, BuildSignals=48, BuildBridge=500.\n"
        "  - BuildStationBus=450, BuildStationTruck=450, BuildStationRail=3000, BuildStationAirport=25000, BuildStationDock=500.\n"
        "  - BuildDepotRoad=800, BuildDepotTrain=800, BuildDepotShip=500.\n"
        "  - BuildTunnel is not exported by this GS API directly; treat tunnel cost as map-dependent and estimate conservatively.\n"
        "  - (For vehicle costs, refer strictly to the 'price' field in the engines JSON array).\n\n"
        "TRANSPORT MODES (route_type) & ID RULES:\n"
        "  TRN - Train (Cargo/Pax). IDs: 't' or 'i' prefix. MUST supply 'wagons' field as '<wagon_engine_id>x<count>[+...]'.\n"
        "        Example: '29x4+28x1' means 4 coal wagons (id 29) and 1 mail wagon (id 28). Do NOT use cargo labels in wagons.\n"
        "  TRK - Truck (Cargo). IDs: 't' or 'i' prefix. Cargo is auto-selected/refit when needed.\n"
        "  BUS - Bus (Pax). IDs: 't' or 'i' prefix.\n"
        "  CTY - City Transport. IDs: 'town_id' uses bare integer or 't' prefix (e.g. 4 or t4). Builds multiple stops in a loop within a single town for passenger/mail/valuables.\n"
        "  PLN - Plane (Pax/Mail). IDs: bare integers of towns. Optionally use 'qty' to build multiple planes at once.\n"
        "  CPL - Cargo Plane. IDs: 'from_id' MUST be 'i' prefix, 'to_id' can be 'i' or 't'. Optionally use 'qty' to build multiple planes.\n\n"
        "VEHICLE MANAGEMENT ACTIONS (existing fleet):\n"
        "  ADW - Add wagons to an existing train (TRAIN vehicles only).\n"
        "        JSON format: {\"action\":\"adw\",\"veh_id\":42,\"wagons\":\"29x2+90x1\"}\n"
        "        Wagons format: '<wagon_engine_id>x<count>[+<wagon_engine_id>x<count>...]'.\n"
        "        Use when a train line is profitable but capacity constrained.\n"
        "  RPL - Mass-replace old engine type with a newer compatible engine type.\n"
        "        JSON format: {\"action\":\"rpl\",\"old_eng_id\":9,\"new_eng_id\":11}\n"
        "        Use when better engines are available and broad fleet upgrade is high ROI.\n\n"
        "SELF-CHECK BEFORE OUTPUT (mandatory):\n"
        "  A) eng_id is in the mode's allowed engine-id list, and for TRN, wagons are valid numeric IDs.\n"
        "  B) Cargo flow is valid (produced at source, accepted at destination).\n"
        "  C) Are you maximizing ROI? Did you choose the longest viable route with high-speed, high-capacity vehicles?\n"
        "  D) Did you allocate enough vehicle capacity ('wagons' count) to fully absorb the production?\n"
        "  E) Do you need more money to build a better route? If yes, output LON.\n"
        "  F) Output JSON first, then a short explanation paragraph.\n\n"
        "OUTPUT FORMAT (Strictly enforced!):\n"
        "  - Your response must start with one or more JSON objects, each on its own line.\n"
        "  - After the commands, leave two empty new lines, then provide your explanation.\n"
        "  Build route examples by mode (choose ONE action only per turn):\n"
        "{\"action\":\"build\", \"route_type\":\"TRN\", \"from_id\":\"i4\", \"to_id\":\"t8\", \"eng_id\":21, \"wagons\":\"29x5+28x1\"}\n"
        "{\"action\":\"build\", \"route_type\":\"TRK\", \"from_id\":\"i4\", \"to_id\":\"i8\", \"eng_id\":123, \"wagons\":\"2\"}\n"
        "{\"action\":\"build\", \"route_type\":\"BUS\", \"from_id\":\"t2\", \"to_id\":\"t7\", \"eng_id\":116, \"wagons\":\"3\"}\n"
        "{\"action\":\"build\", \"route_type\":\"CTY\", \"town_id\":4, \"eng_id\":116, \"wagons\":\"3\"}\n"
        "{\"action\":\"build\", \"route_type\":\"PLN\", \"from_id\":2, \"to_id\":7, \"eng_id\":216, \"qty\":3}\n"
        "{\"action\":\"build\", \"route_type\":\"CPL\", \"from_id\":\"i4\", \"to_id\":\"t7\", \"eng_id\":219, \"cargo\":\"GOOD\", \"qty\":2}\n"
        "  Loan/repay/skip JSON examples (actual executable decision format):\n"
        "{\"action\":\"lon\",\"amount\":50000}\n"
        "{\"action\":\"rpy\",\"amount\":50000}\n"
        "{\"action\":\"rpa\"}\n"
        "{\"action\":\"skp\"}\n"
        "Use only IDs present in the current state and allowed-id lists; examples above are format references only.\n"
        "For long-distance passenger/mail opportunities, prefer PLN when valid towns and engines exist.\n"
        "  Sell vehicle example:\n"
        "{\"action\":\"sell\", \"veh_id\":42, \"reason\":\"Unprofitable this year and aged 5+ years\"}\n"
        "I chose this because vehicle 42 has a negative profit and is old enough (age >= 1825 days) to have proved it won't be profitable.\n"
        "  Vehicle management examples:\n"
        "{\"action\":\"adw\",\"veh_id\":42,\"wagons\":\"29x2\"}\n"
        "{\"action\":\"rpl\",\"old_eng_id\":9,\"new_eng_id\":11}\n"
        "PREVIOUS ERROR CODES (avoid repeating these mistakes):\n"
        "  NO_PATH      — pathfinder found no valid route\n"
        "  NO_FUNDS     — AI has insufficient funds\n"
        "  NO_SPACE     — no buildable tile adjacent to industry\n"
        "  NO_ENGINE    — specified engine ID not available this year\n"
        "  NO_CARGO     — no valid source->destination cargo flow (including endpoint catchment mismatch)\n"
        "  BAD_REFIT    — engine cannot refit to specified cargo label\n"
        "  NO_WATERWAY  — ship route would require too many canal tiles or cannot connect water bodies\n"
        "  ALREADY_BUILT — route already exists between these industries\n"
        "  INVALID_VEH  — vehicle ID does not exist or is not AI-owned\n"
        "  BAD_TOWN     — invalid town ID for PLN\n"
        "  BAD_IND      — invalid industry ID for source\n"

        "\n"

        "\n"
        "Analyse the state and make your decision(s).\n"
        "Output your JSON commands at the top, followed by two empty lines and your explanation paragraph detailing your ROI and capacity math.\n"
        "Commands are case-sensitive. If RECENT COMMAND/REPLY HISTORY contains reply.t='ERR', do not retry the exact same command (exception: LON/RPY/SKP may be repeated when still appropriate).\n"
        "DO NOT hallucinate IDs, ensure they perfectly match the exact IDs listed in the input state. Focus on unserved towns and industries - it is usually better to open new routes/build new airports rather then reusing the ones already built. Broken vehicles get fixed in the depot automatically.\n"
        "Focus on maximizing ROI through massive distance, high volume, and high speed. Borrow heavily to fund it. When estimating the cost do not forget to factor in the cost of necessary infrastructure (rails, roads, stations) in addition to vehicle purchase costs - the cost estimates mentioned before can be a bit lower than the actual price due to different price for different tile types + building bridges or tunnels is even more expensive.\n"
    )

    return "\n".join(prompt_parts)
