// SquirrelAI/utils.nut - Shared pure helper functions
//
// Used by all other AI files. No side effects, no API calls.

function SquirrelAI::Split(str, sep) {
    local result = [];
    local current = "";
    for (local i = 0; i < str.len(); i++) {
        if (str.slice(i, i + 1) == sep) {
            result.push(current);
            current = "";
        } else {
            current += str.slice(i, i + 1);
        }
    }
    result.push(current);
    return result;
}

function SquirrelAI::_IsLocationPrefixToken(token) {
    if (token == null) return false;
    if (token.len() != 1) return false;
    return (token == "i" || token == "I" || token == "t" || token == "T");
}

function SquirrelAI::_ConsumeLocationToken(parts, start_idx) {
    if (start_idx < 0 || start_idx >= parts.len()) return null;

    local token = parts[start_idx];
    if (token == null || token.len() == 0) return null;

    if (this._IsLocationPrefixToken(token)) {
        if (start_idx + 1 >= parts.len()) return null;

        local ident = parts[start_idx + 1];
        if (ident == null || ident.len() == 0) return null;

        return { value = token + ident, next = start_idx + 2 };
    }

    return { value = token, next = start_idx + 1 };
}

function SquirrelAI::_ParseIntegerToken(token) {
    try {
        return token.tointeger();
    } catch (e) {
        return null;
    }
}

function SquirrelAI::ParseWagons(wagons_str) {
    local result = [];
    local tokens = this.Split(wagons_str, "+");
    foreach (token in tokens) {
        local parts = this.Split(token, "x");
        if (parts.len() == 2) {
            result.push({ id = parts[0].tointeger(), count = parts[1].tointeger() });
        } else if (parts.len() == 1 && parts[0].len() > 0) {
            result.push({ id = parts[0].tointeger(), count = 1 });
        }
    }
    return result;
}

function SquirrelAI::_max(a, b) { return (a > b) ? a : b; }
function SquirrelAI::_abs(a)     { return (a < 0) ? -a : a; }

function SquirrelAI::_StationCatchmentRadius(station_type) {
    local radius = 4;
    try {
        radius = AIStation.GetCoverageRadius(station_type);
    } catch (e) {
        radius = 4;
    }
    if (radius < 1) radius = 4;
    return radius;
}

function SquirrelAI::_StationTypeForEngine(eng_id) {
    if (!AIEngine.IsValidEngine(eng_id)) return AIStation.STATION_TRUCK_STOP;

    local vt = AIEngine.GetVehicleType(eng_id);
    if (vt == AIVehicle.VT_RAIL) return AIStation.STATION_TRAIN;
    if (vt == AIVehicle.VT_WATER) return AIStation.STATION_DOCK;
    if (vt == AIVehicle.VT_AIR) return AIStation.STATION_AIRPORT;
    return AIStation.STATION_TRUCK_STOP;
}

function SquirrelAI::_CatchmentRadiusForEngine(eng_id) {
    return this._StationCatchmentRadius(this._StationTypeForEngine(eng_id));
}

function SquirrelAI::_TileMatchesCargoForStation(tile, cargo_id, station_type,
                                                  require_acceptance,
                                                  require_production) {
    if (cargo_id == -1) return true;

    local catchment = this._StationCatchmentRadius(station_type);
    local acceptance = AITile.GetCargoAcceptance(tile, cargo_id, 1, 1, catchment);
    local production = AITile.GetCargoProduction(tile, cargo_id, 1, 1, catchment);

    if (require_acceptance && acceptance < 8) return false;
    if (require_production && production < 1) return false;
    return true;
}

// Resolve a location ID string to a tile.
// Prefix is MANDATORY: "t4" = town 4, "i4" = industry 4.
// Returns { tile, label } or null.
function SquirrelAI::_ResolveLoc(id_str) {
    if (id_str.len() < 2) return null;
    local first = id_str.slice(0, 1);
    local num   = id_str.slice(1);

    if (first == "t" || first == "T") {
        local id = num.tointeger();
        if (AITown.IsValidTown(id)) {
            return { tile = AITown.GetLocation(id), label = "town " + id };
        }
        AILog.Warning("Invalid town ID: " + id);
        return null;
    }
    if (first == "i" || first == "I") {
        local id = num.tointeger();
        if (AIIndustry.IsValidIndustry(id)) {
            return { tile = AIIndustry.GetLocation(id), label = "industry " + id };
        }
        AILog.Warning("Invalid industry ID: " + id);
        return null;
    }

    AILog.Warning("Location must start with 't' or 'i': " + id_str);
    return null;
}

// -----------------------------------------------------------------------
// Cargo matching: find a cargo the source industry produces, the
// destination (industry or town) accepts, and the engine can refit to.
//
// from_str must have "i" prefix (industry source).
// to_str may have "i" (industry) or "t" (town) prefix.
// Returns the first compatible cargo ID, or -1 if none found.
// -----------------------------------------------------------------------

// -----------------------------------------------------------------------
// Resolve a cargo label string (e.g. "MAIL", "PASS") to a cargo ID.
// Returns the cargo ID, or -1 if not found.
// -----------------------------------------------------------------------

function SquirrelAI::_ResolveCargo(label) {
    local cargo_list = AICargoList();
    for (local c = cargo_list.Begin(); !cargo_list.IsEnd(); c = cargo_list.Next()) {
        if (AICargo.GetCargoLabel(c) == label) return c;
    }
    AILog.Warning("Unknown cargo label: " + label);
    return -1;
}

function SquirrelAI::_FindCompatibleCargo(from_str, to_str, eng_id) {
    if (from_str.len() < 2) return -1;
    local from_prefix = from_str.slice(0, 1);
    if (from_prefix != "i" && from_prefix != "I") {
        AILog.Warning("_FindCompatibleCargo: source must be an industry, got: " + from_str);
        return -1;
    }
    local from_id = from_str.slice(1).tointeger();
    if (!AIIndustry.IsValidIndustry(from_id)) return -1;

    local produced = AICargoList_IndustryProducing(from_id);
    local catchment = this._CatchmentRadiusForEngine(eng_id);
    if (to_str.len() < 2) return -1;
    local to_prefix = to_str.slice(0, 1);

    for (local c = produced.Begin(); !produced.IsEnd(); c = produced.Next()) {
        if (!AIEngine.CanRefitCargo(eng_id, c)) continue;

        if (to_prefix == "i" || to_prefix == "I") {
            local to_id = to_str.slice(1).tointeger();
            if (!AIIndustry.IsValidIndustry(to_id)) continue;
            local accepted = AICargoList_IndustryAccepting(to_id);
            if (accepted.HasItem(c)) return c;
        } else if (to_prefix == "t" || to_prefix == "T") {
            local to_id = to_str.slice(1).tointeger();
            if (!AITown.IsValidTown(to_id)) continue;
            local town_tile = AITown.GetLocation(to_id);
            if (AITile.GetCargoAcceptance(town_tile, c, 1, 1, catchment) >= 8) return c;
        }
    }

    return -1;
}

// -----------------------------------------------------------------------
// Universal cargo matching: works for any source/dest combo:
//   i->i, i->t, t->t, t->i
// For industry sources, uses produced cargoes.
// For town sources, finds cargoes the engine can refit to that the dest
// accepts (typical: passengers, mail, valuables, goods).
// Returns the first compatible cargo ID, or -1 if none found.
// -----------------------------------------------------------------------

function SquirrelAI::_FindRouteCargo(from_str, to_str, eng_id) {
    if (from_str.len() < 2 || to_str.len() < 2) return -1;
    local from_prefix = from_str.slice(0, 1);

    // If source is an industry, delegate to the industry-specific version
    if (from_prefix == "i" || from_prefix == "I") {
        return this._FindCompatibleCargo(from_str, to_str, eng_id);
    }

    // Source is a town: iterate all cargoes the engine can carry,
    // pick the first one accepted by both source town and destination.
    if (from_prefix != "t" && from_prefix != "T") return -1;
    local from_id = from_str.slice(1).tointeger();
    if (!AITown.IsValidTown(from_id)) return -1;
    local from_tile = AITown.GetLocation(from_id);

    local to_prefix = to_str.slice(0, 1);
    local catchment = this._CatchmentRadiusForEngine(eng_id);
    local cargo_list = AICargoList();

    for (local c = cargo_list.Begin(); !cargo_list.IsEnd(); c = cargo_list.Next()) {
        if (!AIEngine.CanRefitCargo(eng_id, c)) continue;

        // Source town must produce/have this cargo available
        if (AITile.GetCargoProduction(from_tile, c, 1, 1, catchment) < 1) continue;

        // Check destination accepts it
        if (to_prefix == "t" || to_prefix == "T") {
            local to_id = to_str.slice(1).tointeger();
            if (!AITown.IsValidTown(to_id)) continue;
            local to_tile = AITown.GetLocation(to_id);
            if (AITile.GetCargoAcceptance(to_tile, c, 1, 1, catchment) >= 8) return c;
        } else if (to_prefix == "i" || to_prefix == "I") {
            local to_id = to_str.slice(1).tointeger();
            if (!AIIndustry.IsValidIndustry(to_id)) continue;
            local accepted = AICargoList_IndustryAccepting(to_id);
            if (accepted.HasItem(c)) return c;
        }
    }

    return -1;
}
