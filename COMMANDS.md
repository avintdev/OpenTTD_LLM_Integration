# OpenTTD Command Reference

Commands are sent to the GameScript via the admin port as `!cmd <TYPE>:<args…>`.
Parameter IDs come directly from the live export snapshot (`gs_packets.jsonl`).
All command names are 3 characters or fewer.

## Runtime Notes

- The Python bridge now serves a dashboard on `http://localhost:8080/` in live, debug, and standalone modes.
- Session summaries, status, and interaction history are written under `web/sessions/`.
- Each session folder also includes `errors.jsonl` plus a grouped `errors.json` catalog for classifying game-side, LLM-side, bridge, and validation errors.
- Session IDs now include the start timestamp and active model name.
- Model changes are persisted through `bridge_runtime/secrets.py` and reloaded by the running bridge.


## Admin Commands

These are sent directly to the GS (not via `!cmd`):

| Command | Description |
|---------|-------------|
| `!ping` | Returns PONG — connectivity check |
| `!delsign` | Deletes the current command sign and resets state. Use to cancel a stuck/failed command so a new one can be sent. |
| `!export <chunk>` | Triggers export of a specific chunk (`industries`, `towns`, `companies`, `engines`, `vehicles`, `stations`, `all`) |
| `!mailbox` | Lists all signs at the mailbox tile |


## ID Prefixes

Industry and town IDs can overlap (both start from 0), so the `from`/`to` parameters in route commands **require** a prefix:

| Prefix | Meaning | Example |
|--------|---------|----------|
| `t` | Town | `t4` = town 4 |
| `i` | Industry | `i0` = industry 0 |

Bare numbers without a prefix are rejected. Examples:


## Naming Convention

Commands use short, consistent 3-character codes:

| Code | Vehicle / Action |
|------|-----------------|
| `TRN` | Train — any cargo; type determined entirely by wagon/engine choice |
| `TRK` | Truck — cargo road vehicle (supports industry and town IDs) |
| `BUS` | Bus — passenger road vehicle (supports town and industry IDs) |
| `CTY` | City Transport — public transport within a single town (buses/trucks for mail/valuables) |
| `SHP` | Ship — cargo vessel (industry source, industry/town dest, t/i prefix IDs, auto-refit, canal limit 20 tiles) |
| `FRY` | Ferry — passenger vessel (town-to-town) |
| `PLN` | Plane — passenger/mail aircraft (town-to-town, bare town IDs) |
| `CPL` | Cargo plane — freight aircraft (industry source, industry/town dest, t/i prefix IDs, auto-refit) |


## Decision Ownership


LLM fleet-scaling workflow examples

Mode playbooks (explicit command sequences)
	1. `TRN:iFROM:iTO:ENG:WAGONxN`
	2. Observe `VEH` profit + source waiting cargo from exports.
	3. `CLN:{lead_train}:{k}` to scale up, or `DEP:{veh}` -> `SEL:{veh}` to scale down.
	1. `TRK:iFROM:tTO:ENG:1`
	2. Add capacity with `CLN:{lead_truck}:{k}`.
	3. If over-supplied, stop first (`STP:{veh}`), then depot/sell (`DEP` + `SEL`).
	1. `BUS:tFROM:tTO:ENG:1`
	2. Use `CLN` for demand spikes.
	3. Use `STP`/`RUN` for temporary demand shaping before selling.
	1. `CTY:TOWN:ENG:COUNT`
	2. Creates a loop route with multiple distinct stops inside a single town.
	3. Adjust capacity using `CLN` or `DEP`+`SEL`.
	1. `SHP:iFROM:tTO:ENG[:CARGO]`
	2. Scale only via `CLN` (no autonomous ship scaling by AI policy).
	3. Retire hulls via `DEP` + `SEL`.
	1. `FRY:FROM_TOWN:TO_TOWN:ENG`
	2. Add vessels with `CLN` when queues persist.
	3. Reduce with `DEP` + `SEL` if sustained under-utilization.
	1. `PLN:FROM_TOWN:TO_TOWN:ENG[:QTY]`
	2. Scale via `CLN` after export confirmation.
	3. Pause congestion tests using `STP`, resume with `RUN`.
	1. `CPL:iFROM:tTO:ENG[:CARGO][:QTY]`
	2. Tune capacity with `CLN` and retire extra units using `DEP` + `SEL`.
	3. Use `RPL` when a better cargo plane becomes available.

Provider startup operator check


## Currently Implemented

| Command | Format | Key Parameters |
|---------|--------|----------------|
| **TRN** | `!cmd TRN:{from}:{to}:{eng_id}:{wagons}` | `from`/`to` = `t`/`i` prefixed IDs (mandatory); `wagons` = `WxN` spec e.g. `29x5` |
| **TRK** | `!cmd TRK:{from}:{to}:{eng_id}:{count}` | `from`/`to` = `t`/`i` prefixed IDs; `count` = number of trucks; engine type already determines cargo |
| **BUS** | `!cmd BUS:{from}:{to}:{eng_id}:{count}` | `from`/`to` = `t`/`i` prefixed IDs; `count` = number of buses |
| **CTY** | `!cmd CTY:{town_id}:{eng_id}:{count}` | `town_id` = bare or `t`-prefixed ID; `count` = number of vehicles; builds an inner-city loop route |
| **PLN** | `!cmd PLN:{from_id}:{to_id}:{eng_id}[:{qty}]` | `from_id`/`to_id` = town IDs (bare integers); `qty` = optional number of planes; airports built automatically |
| **CPL** | `!cmd CPL:{from}:{to}:{eng_id}[:{cargo}][:{qty}]` | `from` = `i`-prefixed industry ID; `to` = `i`-prefixed industry **or** `t`-prefixed town ID; `cargo` = optional cargo label (e.g. MAIL, VALU) to refit to; `qty` = optional number of planes; auto-refit to compatible cargo if omitted |
| **SHP** | `!cmd SHP:{from}:{to}:{eng_id}[:{cargo}]` | `from`/`to` = `t`/`i` prefixed IDs; `cargo` = optional cargo label (e.g. MAIL, COAL) to refit to; auto-refit; docks built automatically; canal limit 20 tiles |
| **FRY** | `!cmd FRY:{from_id}:{to_id}:{eng_id}` | `from_id`/`to_id` = town IDs (bare integers); docks built automatically |
| **SEL** | `!cmd SEL:{veh_id}` | `veh_id` from vehicles export |
| **DEP** | `!cmd DEP:{veh_id}` | `veh_id` from vehicles export |
| **STP** | `!cmd STP:{veh_id}` | `veh_id` from vehicles export |
| **RUN** | `!cmd RUN:{veh_id}` | `veh_id` from vehicles export |
| Command | Format | Parameters | Notes |
|---------|--------|------------|-------|
| **TRN** | `!cmd TRN:{from}:{to}:{eng_id}:{wagons}` | `from`/`to`: `t`/`i` prefixed IDs (mandatory) | *Implemented.* One command covers all train types. `t4` = town 4, `i0` = industry 0. |

### Road Vehicles

| Command | Format | Parameters | Notes |
|---------|--------|------------|-------|
| **TRK** | `!cmd TRK:{from}:{to}:{eng_id}:{count}` | `from`/`to`: `t`/`i` prefixed IDs (mandatory); `count`: number of trucks; engine type implies cargo | *Implemented.* Cargo or mail trucks. |
| **BUS** | `!cmd BUS:{from}:{to}:{eng_id}:{count}` | `from`/`to`: `t`/`i` prefixed IDs (mandatory); `count`: number of buses | *Implemented.* Passenger buses. |
| **CTY** | `!cmd CTY:{town_id}:{eng_id}:{count}` | `town_id`: town ID; `count`: number of vehicles | *Implemented.* Automatically places multiple stops in town based on population, creating a local loop route. |

### Ships

| Command | Format | Parameters | Notes |
|---------|--------|------------|-------|
| **SHP** | `!cmd SHP:{from}:{to}:{eng_id}[:{cargo}]` | `from`/`to`: `t`/`i` prefixed IDs; `cargo`: optional cargo label to refit to; auto-refit to compatible cargo | *Implemented.* Cargo ship route; canal limit 20 tiles |
| **FRY** | `!cmd FRY:{from_id}:{to_id}:{eng_id}` | `from_id`/`to_id`: town IDs (bare integers) | *Implemented.* Passenger ferry between coastal towns |

### Aircraft

| Command | Format | Parameters | Notes |
|---------|--------|------------|-------|
| **PLN** | `!cmd PLN:{from_id}:{to_id}:{eng_id}[:{qty}]` | `from_id`/`to_id`: town IDs (bare); `qty`: option plane count | *Implemented.* Passenger/mail air route between towns |
| **CPL** | `!cmd CPL:{from}:{to}:{eng_id}[:{cargo}][:{qty}]` | `from`: `i`-prefixed ID; `to`: `i`/`t` prefix; `cargo`/`qty`: optional | *Implemented.* Cargo air route; full-load at source, force-unload at dest |

### Vehicle Management

| Command | Format | Parameters | Notes |
|---------|--------|------------|-------|
| **SEL** | `!cmd SEL:{veh_id}` | `veh_id` from `VEH` packets | *Implemented.* Permanently removes vehicle |
| **CLN** | `!cmd CLN:{veh_id}:{count}` | `veh_id`: source vehicle; `count`: how many copies | *Implemented.* Duplicates vehicle + orders; scales up profitable routes |
| **DEP** | `!cmd DEP:{veh_id}` | `veh_id` | *Implemented.* Sends vehicle to nearest depot for servicing or pre-sell |
| **STP** | `!cmd STP:{veh_id}` | `veh_id` | *Implemented.* Pauses a vehicle (useful for loss-making routes) |
| **RUN** | `!cmd RUN:{veh_id}` | `veh_id` | *Implemented.* Restarts a previously stopped vehicle |
| **ADW** | `!cmd ADW:{veh_id}:{wagons}` | `wagons`: `NxC` spec | *Implemented.* Appends wagons to an existing train to boost capacity |
| **RPL** | `!cmd RPL:{old_eng_id}:{new_eng_id}` | Both from `ENG` packets | *Implemented.* Mass fleet upgrade — replaces all vehicles using old engine |

### Financial

| Command | Format | Parameters | Notes |
|---------|--------|------------|-------|
| **LON** | `!cmd LON:{amount}` | `amount` in £, must be a multiple of 10,000 | *Implemented.* Increases the company loan up to max allowed |
| **RPY** | `!cmd RPY:{amount}` | `amount` in £ | *Implemented.* Partially repays the outstanding loan |
| **RPA** | `!cmd RPA` | — | *Implemented.* Repays the entire outstanding loan in one go |

### Meta / Flow Control

| Command | Format | Parameters | Notes |
|---------|--------|------------|-------|
| **SKP** | `!cmd SKP` | — | Explicit no-op; LLM signals it is waiting for better conditions |
| **PRI** | `!cmd PRI:{industry_id}:{level}` | `level`: 1–5 | Hint to the GS to favour a specific industry in future route scoring |

---

## Export Data Quick Reference

The following fields are available from the live snapshot for use as command parameters:

| Export Type | Key Fields | Used By |
|-------------|-----------|---------|
| `IND` | `id`, `type`, `cargo`, `prod`, `served`, `role`, `x`, `y` | TRN, TRK, SHP, CPL |
| `TOWN` | `id`, `name`, `pop`, `x`, `y` | TRN, BUS, CTY, FRY, PLN |
| `ENG` | `id`, `name`, `vtype`, `cargo`, `cap`, `speed`, `power`, `reliability`, `price`, `running_cost`, `is_wagon` (trains only), `refit` (comma-separated cargo labels) | All route commands |
| `VEH` | `id`, `type`, `profit_ly`, `profit_ty`, `age`, `running_cost`, `status` | SEL, CLN, DEP, STP, RUN, ADW |
| `CO` | `id`, `money`, `loan`, `vehs` | LON, RPY, deciding expansion budget |

---

## Notes

- **Wagon spec format:** `WxN` where `W` = wagon engine ID (from `ENG` export) and `N` = count (e.g. `29x5` = 5 Coal Trucks). Use `+` to mix types: `29x4+90x2` (4 Coal Trucks + 2 Mail Vans).
- **TRN covers all train types.** Passenger, mail, cargo, and express are all `TRN` — just pick the right engine and wagons.
- **ID prefixes are mandatory for TRN/TRK/BUS** — Use `t` for town, `i` for industry. Example: `!cmd TRN:i0:t4:15:29x5` routes from industry 0 to town 4. (For `CTY`, bare town IDs are also allowed).
- **PLN/FRY use bare town IDs** — No prefix. Example: `!cmd PLN:7:13:45` routes between town 7 and town 13.
- **CPL and SHP auto-refit** — The engine is automatically refitted to a cargo the source industry produces and the destination industry or town accepts. If no compatible cargo exists, the command fails with `NO_CARGO`.
- **CPL/SHP source must be an industry** — Towns produce only passengers and mail; those are handled by PLN (plane) and FRY (ferry). Use `i`-prefixed IDs for the source. The destination (`to`) accepts both `i` (industry) and `t` (town) — for example, delivering goods from a factory (`i42`) to a town (`t7`).
- **SHP/FRY canal constraint** — Water routes that would require building more than 20 canal tiles to connect disconnected water bodies are rejected (`NO_WATERWAY`). Routes on naturally connected waterways always work.
- **Industry export** now includes both `produces` and `accepts` roles. Accepting-only industries (e.g. Power Station) appear with `role: "accepts"`.
- **Engine export** now includes `vtype` field (`TRAIN`, `ROAD`, `WATER`, `AIR`), `reliability` percentage, live `price`, and `running_cost`, and filters to only currently-available engines (uses `GSCompanyMode` to scope by game year). `is_wagon` is only present on `TRAIN` type engines.
- **Rail type** is selected automatically from `eng_id` via `AIRail.SetCurrentRailType(AIEngine.GetRailType(eng_id))`, so normal rail, electrified rail, monorail, and maglev all work without extra parameters.
- **Sign length limit:** Signs are capped at 32 characters. With realistic IDs (≤ 9999) all commands fit comfortably.
- **CLN** is the fastest way to scale a proven profitable route without re-specifying all parameters.
- **RPL** now validates replacement safety before applying autoreplace: old/new engines must be valid and the same vehicle type, the new engine must be able to carry/refit the old engine cargo profile (default + currently loaded cargo), and aircraft replacements are blocked if any active route order targets an airport incompatible with the new plane.
