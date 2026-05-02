// SquirrelAI/transport_shared.nut - Shared transport helpers
//
// These helpers are intentionally transport-agnostic and deterministic.

function SquirrelAI::NewBuildJournal(mode, from_id, to_id) {
    return {
        mode = mode,
        from_id = from_id,
        to_id = to_id,
        vehicles = []
    };
}

function SquirrelAI::JournalVehicle(journal, veh_id) {
    if (journal == null) return;
    if (!("vehicles" in journal)) journal.vehicles <- [];
    journal.vehicles.push(veh_id);
}

function SquirrelAI::CleanupPartialBuild(journal) {
    if (journal == null) return;
    if (!("vehicles" in journal)) return;

    foreach (veh_id in journal.vehicles) {
        if (!AIVehicle.IsValidVehicle(veh_id)) continue;
        AIVehicle.SendVehicleToDepot(veh_id);
        AIVehicle.SellVehicle(veh_id);
    }
}

function SquirrelAI::ValidateCatchment(tile, cargo_id, station_type,
                                       require_acceptance = false,
                                       require_production = false) {
    return this._TileMatchesCargoForStation(tile, cargo_id, station_type,
                                            require_acceptance,
                                            require_production);
}

function SquirrelAI::ComputeCoverageScore(tile, cargo_id, station_type) {
    if (!AIMap.IsValidTile(tile) || cargo_id == -1) return 0;

    local catchment = this._StationCatchmentRadius(station_type);
    local acceptance = AITile.GetCargoAcceptance(tile, cargo_id, 1, 1, catchment);
    local production = AITile.GetCargoProduction(tile, cargo_id, 1, 1, catchment);
    return acceptance + (production * 8);
}

function SquirrelAI::ValidateEntryExit(tile, min_links = 1) {
    if (!AIMap.IsValidTile(tile)) return false;

    local tx = AIMap.GetTileX(tile);
    local ty = AIMap.GetTileY(tile);
    local links = 0;

    foreach (off in [[1, 0], [-1, 0], [0, 1], [0, -1]]) {
        local adj = AIMap.GetTileIndex(tx + off[0], ty + off[1]);
        if (!AIMap.IsValidTile(adj)) continue;

        if (AIRoad.IsRoadTile(adj) || AIRail.IsRailTile(adj) ||
            AITile.IsWaterTile(adj) || AITile.IsCoastTile(adj) ||
            AITile.IsBuildable(adj)) {
            links++;
        }
    }

    return links >= min_links;
}

function SquirrelAI::ValidateQueueSpace(tile, required_free = 1) {
    if (!AIMap.IsValidTile(tile)) return false;

    local tx = AIMap.GetTileX(tile);
    local ty = AIMap.GetTileY(tile);
    local free_slots = 0;

    foreach (off in [[1, 0], [-1, 0], [0, 1], [0, -1]]) {
        local adj = AIMap.GetTileIndex(tx + off[0], ty + off[1]);
        if (!AIMap.IsValidTile(adj)) continue;

        if (AITile.IsBuildable(adj) || AIRoad.IsRoadTile(adj) ||
            AIRail.IsRailTile(adj) || AITile.IsWaterTile(adj) ||
            AITile.IsCoastTile(adj)) {
            free_slots++;
        }
    }

    return free_slots >= required_free;
}

function SquirrelAI::ComputeOrientationScore(from_tile, to_tile, direction) {
    if (!AIMap.IsValidTile(from_tile) || !AIMap.IsValidTile(to_tile)) return -100000;

    local fx = AIMap.GetTileX(from_tile);
    local fy = AIMap.GetTileY(from_tile);
    local tx = AIMap.GetTileX(to_tile);
    local ty = AIMap.GetTileY(to_tile);

    local dx = this._abs(tx - fx);
    local dy = this._abs(ty - fy);

    local axis_bias = 0;
    if (direction == AIRail.RAILTRACK_NE_SW) {
        axis_bias = dx - dy;
    } else {
        axis_bias = dy - dx;
    }

    local endpoint_bonus = 0;
    if (this.ValidateEntryExit(from_tile, 1)) endpoint_bonus += 10;
    if (this.ValidateEntryExit(to_tile, 1)) endpoint_bonus += 10;

    return (axis_bias * 5) + endpoint_bonus;
}
