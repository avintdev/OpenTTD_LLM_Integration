// Adapter-style cargo selector provider.
// Uses OpenTTD native cargo/acceptance APIs to select a compatible cargo.

function _MWStationTypeForEngine(eng_id) {
    if (!AIEngine.IsValidEngine(eng_id)) return AIStation.STATION_TRUCK_STOP;

    local vt = AIEngine.GetVehicleType(eng_id);
    if (vt == AIVehicle.VT_RAIL) return AIStation.STATION_TRAIN;
    if (vt == AIVehicle.VT_WATER) return AIStation.STATION_DOCK;
    if (vt == AIVehicle.VT_AIR) return AIStation.STATION_AIRPORT;
    return AIStation.STATION_TRUCK_STOP;
}

function _MWCatchmentRadiusForEngine(eng_id) {
    local radius = 4;
    try {
        radius = AIStation.GetCoverageRadius(_MWStationTypeForEngine(eng_id));
    } catch (e) {
        radius = 4;
    }
    if (radius < 1) radius = 4;
    return radius;
}

function _MWSelectCargoForIndustrySource(from_str, to_str, eng_id) {
    if (from_str.len() < 2) return -1;
    local from_prefix = from_str.slice(0, 1);
    if (from_prefix != "i" && from_prefix != "I") return -1;

    local from_id = from_str.slice(1).tointeger();
    if (!AIIndustry.IsValidIndustry(from_id)) return -1;

    local produced = AICargoList_IndustryProducing(from_id);
    local catchment = _MWCatchmentRadiusForEngine(eng_id);
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
            local to_tile = AITown.GetLocation(to_id);
            if (AITile.GetCargoAcceptance(to_tile, c, 1, 1, catchment) >= 8) return c;
        }
    }

    return -1;
}

function ExternalSelectRouteCargo(from_str, to_str, eng_id) {
    if (from_str.len() < 2 || to_str.len() < 2) return -1;

    local from_prefix = from_str.slice(0, 1);
    if (from_prefix == "i" || from_prefix == "I") {
        return _MWSelectCargoForIndustrySource(from_str, to_str, eng_id);
    }

    if (from_prefix != "t" && from_prefix != "T") return -1;

    local from_id = from_str.slice(1).tointeger();
    if (!AITown.IsValidTown(from_id)) return -1;
    local from_tile = AITown.GetLocation(from_id);
    local catchment = _MWCatchmentRadiusForEngine(eng_id);

    local to_prefix = to_str.slice(0, 1);
    local cargo_list = AICargoList();

    for (local c = cargo_list.Begin(); !cargo_list.IsEnd(); c = cargo_list.Next()) {
        if (!AIEngine.CanRefitCargo(eng_id, c)) continue;

        if (AITile.GetCargoProduction(from_tile, c, 1, 1, catchment) < 1) continue;

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
