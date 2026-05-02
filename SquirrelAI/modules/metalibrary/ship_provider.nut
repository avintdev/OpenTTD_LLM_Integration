// Adapter wrapper for vendored MetaLibrary ship routing.
// Uses Pathfinder.Ship where possible and falls back to SpiralWalker spacing.

require("Array.nut");
require("Constants.nut");
require("Extras.nut");
require("Lakes.nut");
require("Line.Walker.nut");
require("Log.nut");
require("Marine.nut");
require("Pathfinder.Ship.nut");
require("Spiral.Walker.nut");

function _MWAbs(a) {
    return (a < 0) ? -a : a;
}

function _MWFindNearbyWaterTile(x, y, maxRadius) {
    local walker = _MinchinWeb_SW_();
    local start = AIMap.GetTileIndex(x, y);
    walker.Start(start);

    while (walker.GetStep() <= (maxRadius * maxRadius * 4 + 1)) {
        local tile = walker.Walk();
        if (!AIMap.IsValidTile(tile)) continue;

        local tx = AIMap.GetTileX(tile);
        local ty = AIMap.GetTileY(tile);
        if (_MWAbs(tx - x) > maxRadius || _MWAbs(ty - y) > maxRadius) continue;

        if (AITile.IsWaterTile(tile) || AIMarine.IsBuoyTile(tile)) {
            return tile;
        }
    }

    return -1;
}

function _ExternalShipWaypointsFallback(tileA, tileB) {
    local buoys = [];
    local dist = AIMap.DistanceManhattan(tileA, tileB);

    if (dist < 30) return buoys;

    local ax = AIMap.GetTileX(tileA).tofloat();
    local ay = AIMap.GetTileY(tileA).tofloat();
    local bx = AIMap.GetTileX(tileB).tofloat();
    local by = AIMap.GetTileY(tileB).tofloat();

    local interval = 20.0;
    local segments = (dist / interval).tointeger();
    if (segments < 1) return buoys;

    for (local s = 1; s <= segments; s++) {
        local frac = s.tofloat() / (segments + 1).tofloat();
        local mx = (ax + (bx - ax) * frac).tointeger();
        local my = (ay + (by - ay) * frac).tointeger();

        local tile = _MWFindNearbyWaterTile(mx, my, 5);
        if (tile == -1) continue;

        if (AIMarine.IsBuoyTile(tile)) {
            buoys.push(tile);
            continue;
        }

        if (AIMarine.BuildBuoy(tile)) {
            buoys.push(tile);
        }
    }

    return buoys;
}

function ExternalShipWaypoints(tileA, tileB) {
    local pf = _MinchinWeb_ShipPathfinder_();
    pf.cost.max_buoy_spacing = 45;

    pf.InitializePath([tileA], [tileB]);

    local path = false;
    local attempts = 0;
    while (path == false && attempts < 120) {
        path = pf.FindPath(250);
        attempts++;
        AIController.Sleep(1);
    }

    if (path == null || path == false) {
        AILog.Warning("[INTEGRATION] MetaLibrary ShipPathfinder failed; using fallback buoy spacing");
        return _ExternalShipWaypointsFallback(tileA, tileB);
    }

    local built_path = pf.BuildPathBuoys();
    if (built_path == null || built_path.len() < 3) {
        return [];
    }

    local buoys = [];
    for (local i = 1; i < built_path.len() - 1; i++) {
        local tile = built_path[i];
        if (AIMarine.IsBuoyTile(tile)) {
            buoys.push(tile);
        }
    }

    return buoys;
}
