// SquirrelGS/utils.nut - Pure helper functions
//
// Shared by main and export. No side effects, no API state changes.

function SquirrelGS::CargoLabel(cargo_id) {
    if (!GSCargo.IsValidCargo(cargo_id)) return "NONE";
    local label = GSCargo.GetCargoLabel(cargo_id);
    if (label != null && typeof label == "string") return label;
    local name = GSCargo.GetName(cargo_id);
    if (name != null) return name;
    return "C" + cargo_id;
}

function SquirrelGS::VehTypeStr(vt) {
    switch (vt) {
        case GSVehicle.VT_RAIL:  return "TRAIN";
        case GSVehicle.VT_ROAD:  return "ROAD";
        case GSVehicle.VT_WATER: return "WATER";
        case GSVehicle.VT_AIR:   return "AIR";
    }
    return "UNKNOWN";
}

function SquirrelGS::VehStateStr(vs) {
    switch (vs) {
        case GSVehicle.VS_RUNNING:    return "RUNNING";
        case GSVehicle.VS_STOPPED:    return "STOPPED";
        case GSVehicle.VS_IN_DEPOT:   return "IN_DEPOT";
        case GSVehicle.VS_AT_STATION: return "AT_STATION";
        case GSVehicle.VS_BROKEN:     return "BROKEN";
        case GSVehicle.VS_CRASHED:    return "CRASHED";
    }
    return "UNKNOWN";
}

function SquirrelGS::SplitString(str, sep) {
    local result  = [];
    local current = "";
    for (local i = 0; i < str.len(); i++) {
        if (str.slice(i, i + 1) == sep) {
            if (current.len() > 0) result.push(current);
            current = "";
        } else {
            current += str.slice(i, i + 1);
        }
    }
    if (current.len() > 0) result.push(current);
    return result;
}

function SquirrelGS::_abs(val) {
    return val < 0 ? -val : val;
}

function SquirrelGS::IsCoastal(center_tile, radius = 6) {
    local cx = GSMap.GetTileX(center_tile);
    local cy = GSMap.GetTileY(center_tile);
    for (local dx = -radius; dx <= radius; dx++) {
        for (local dy = -radius; dy <= radius; dy++) {
            local nx = cx + dx;
            local ny = cy + dy;
            if (nx < 1 || ny < 1 || nx >= GSMap.GetMapSizeX() - 1 || ny >= GSMap.GetMapSizeY() - 1) continue;
            local tile = GSMap.GetTileIndex(nx, ny);
            if (GSMap.IsValidTile(tile) && GSTile.IsWaterTile(tile)) return true;
        }
    }
    return false;
}
