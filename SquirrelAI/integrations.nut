// SquirrelAI/integrations.nut - Integration adapters for external modules
//
// Active adapters:
//   - cargo_selector: cargo provider hook or _FindRouteCargo fallback
//   - ship_waypoints: ship provider hook or _PlaceBuoys fallback
//   - built-in placement scoring for road, rail, dock, and water depot candidates
//
// Road and rail path construction are handled directly by the AAAHogEx
// builders loaded in main.nut; they are not selected through this adapter.

function _SquirrelAIHasExternalShipWaypoints() {
    try {
        local fn = ::ExternalShipWaypoints;
        return fn != null;
    } catch (e) {
        return false;
    }
}

function _SquirrelAIHasExternalSelectRouteCargo() {
    try {
        local fn = ::ExternalSelectRouteCargo;
        return fn != null;
    } catch (e) {
        return false;
    }
}

function _SquirrelAIHasMetaLibraryLakes() {
    try {
        local ctor = ::_MinchinWeb_Lakes_;
        return ctor != null;
    } catch (e) {
        return false;
    }
}

function SquirrelAI::InitIntegrations() {
    local ship_wp_provider = "builtin";
    local cargo_provider = "builtin";

    if (_SquirrelAIHasExternalShipWaypoints()) {
        ship_wp_provider = "metalibrary";
    }
    if (_SquirrelAIHasExternalSelectRouteCargo()) {
        cargo_provider = "metalibrary";
    }

    this._integrations = {
        cargo_selector = cargo_provider,
        ship_waypoints = ship_wp_provider
    };

    AILog.Info("[INTEGRATION] Providers: cargo=" + this._integrations.cargo_selector +
               " ship_wp=" + this._integrations.ship_waypoints);

    AILog.Info("[INTEGRATION] Mode providers: " +
               "road=aaahogex/builtin-placement" +
               " rail=aaahogex/builtin-placement" +
               " water=" + this._integrations.ship_waypoints + "/" +
               this._integrations.cargo_selector + "/builtin-placement" +
               " air=execution-only");
}

function SquirrelAI::ScoreRoadStopTile(tile, town_id, road_veh_type, existing_tiles) {
    return 1;
}

function SquirrelAI::ScoreRoadDepotTile(tile, front_tile, center_tile) {
    if (!AIMap.IsValidTile(tile) || !AIMap.IsValidTile(front_tile)) return -100000;

    local score = 100;
    if (AITile.GetSlope(tile) == AITile.SLOPE_FLAT) score += 40;
    if (AIRoad.IsRoadTile(front_tile)) score += 40;
    score -= AIMap.DistanceManhattan(tile, center_tile) * 5;
    return score;
}

function SquirrelAI::ScoreRailStationTile(tile, direction, platform_len, target_tile) {
    if (!AIMap.IsValidTile(tile)) return -100000;

    local score = 120;
    score -= AIMap.DistanceManhattan(tile, target_tile) * 6;
    return score;
}

function SquirrelAI::ScoreRailDepotTile(depot_tile, exit_tile, station_tile, direction) {
    if (!AIMap.IsValidTile(depot_tile) || !AIMap.IsValidTile(exit_tile)) return -100000;

    local score = 140;
    score -= AIMap.DistanceManhattan(depot_tile, exit_tile) * 12;
    score -= AIMap.DistanceManhattan(depot_tile, station_tile) * 2;
    return score;
}

function SquirrelAI::ScoreDockTile(tile, center_tile) {
    if (!AIMap.IsValidTile(tile)) return -100000;

    local score = 100;
    if (AITile.IsCoastTile(tile)) score += 30;
    if (AITile.IsSeaTile(tile)) score += 10;
    score -= AIMap.DistanceManhattan(tile, center_tile) * 4;
    return score;
}

function SquirrelAI::ScoreWaterDepotTile(tile, front_tile, dock_tile) {
    if (!AIMap.IsValidTile(tile) || !AIMap.IsValidTile(front_tile)) return -100000;

    local score = 120;
    score -= AIMap.DistanceManhattan(tile, dock_tile) * 5;
    if (AITile.IsWaterTile(front_tile)) score += 15;
    return score;
}

function SquirrelAI::SelectRouteCargo(from_str, to_str, eng_id, cargo_label = "") {
    if (cargo_label.len() > 0) {
        local explicit_id = this._ResolveCargo(cargo_label);
        if (explicit_id == -1) return -1;
        if (!AIEngine.CanRefitCargo(eng_id, explicit_id)) return -1;
        return explicit_id;
    }

    if (_SquirrelAIHasExternalSelectRouteCargo() &&
        this._integrations.cargo_selector == "metalibrary") {
        return ExternalSelectRouteCargo(from_str, to_str, eng_id);
    }

    return this._FindRouteCargo(from_str, to_str, eng_id);
}

function SquirrelAI::GetShipWaypoints(tileA, tileB) {
    if (_SquirrelAIHasExternalShipWaypoints() &&
        this._integrations.ship_waypoints == "metalibrary") {
        return ExternalShipWaypoints(tileA, tileB);
    }

    return this._PlaceBuoys(tileA, tileB);
}
