// SquirrelAI/water.nut - Ship and ferry route building
//
// Handles: SHP (cargo ships, industry-to-industry OR industry-to-town, t/i prefix IDs)
//          FRY (passenger ferries, town-to-town, bare integer town IDs)
//
// Key API behaviours:
//   - AIMarine.BuildDock(tile, station_id) needs a slope tile at the coast
//   - AIMarine.BuildWaterDepot(tile, front) needs two adjacent water tiles
//   - AIMarine.BuildCanal(tile) converts flat land to water
//   - Ships auto-pathfind through connected water — no pathfinder needed
//   - AIVehicle.RefitVehicle(veh, cargo) refits a vehicle in depot
//
// Canal constraint: if connecting two water bodies would require building
// more than 20 canal tiles, the route is rejected as too inefficient.



// -----------------------------------------------------------------------
// Entry points
// -----------------------------------------------------------------------

function SquirrelAI::BuildShipRoute(from_str, to_str, eng_id, cargo_label = "") {
    AILog.Info("BuildShipRoute: " + from_str + " -> " + to_str +
               " eng=" + eng_id + " cargo=" + cargo_label);

    if (!AIEngine.IsValidEngine(eng_id)) {
        this.WriteReply("ERR:SHP:" + from_str + ":" + to_str + ":NO_ENGINE");
        return;
    }

    local from_loc = this._ResolveLoc(from_str);
    local to_loc   = this._ResolveLoc(to_str);

    if (from_loc == null || to_loc == null) {
        this.WriteReply("ERR:SHP:" + from_str + ":" + to_str + ":BAD_LOC");
        return;
    }
    AILog.Info("Source: " + from_loc.label + "  Dest: " + to_loc.label);

    // Cargo selection is adapter-based so external module logic can be swapped in.
    local cargo_id = this.SelectRouteCargo(from_str, to_str, eng_id, cargo_label);
    if (cargo_id == -1) {
        if (cargo_label.len() > 0) {
            AILog.Warning("Engine " + eng_id + " cannot refit to " + cargo_label);
            this.WriteReply("ERR:SHP:" + from_str + ":" + to_str + ":BAD_REFIT");
            return;
        }

        AILog.Warning("No compatible cargo: " + from_str + " -> " + to_str);
        this.WriteReply("ERR:SHP:" + from_str + ":" + to_str + ":NO_CARGO");
        return;
    }

    if (!this._LocationProducesCargo(from_str, cargo_id)) {
        AILog.Warning("Source " + from_str + " does not produce cargo " +
                      AICargo.GetCargoLabel(cargo_id));
        this.WriteReply("ERR:SHP:" + from_str + ":" + to_str + ":NO_CARGO");
        return;
    }
    if (!this._LocationAcceptsCargo(to_str, cargo_id)) {
        AILog.Warning("Destination " + to_str + " does not accept cargo " +
                      AICargo.GetCargoLabel(cargo_id));
        this.WriteReply("ERR:SHP:" + from_str + ":" + to_str + ":NO_CARGO");
        return;
    }

    AILog.Info("Selected cargo ID: " + cargo_id);

    this._BuildWaterRoute(from_loc.tile, to_loc.tile, eng_id, "SHP",
                           from_str, to_str, true, cargo_id);
}

function SquirrelAI::BuildFerryRoute(from_id, to_id, eng_id) {
    AILog.Info("BuildFerryRoute: town " + from_id + " -> town " + to_id +
               " eng=" + eng_id);

    if (!AIEngine.IsValidEngine(eng_id)) {
        this.WriteReply("ERR:FRY:" + from_id + ":" + to_id + ":NO_ENGINE");
        return;
    }
    if (!AITown.IsValidTown(from_id)) {
        this.WriteReply("ERR:FRY:" + from_id + ":" + to_id + ":BAD_TOWN");
        return;
    }
    if (!AITown.IsValidTown(to_id)) {
        this.WriteReply("ERR:FRY:" + from_id + ":" + to_id + ":BAD_TOWN");
        return;
    }

    local from_tile = AITown.GetLocation(from_id);
    local to_tile   = AITown.GetLocation(to_id);

    this._BuildWaterRoute(from_tile, to_tile, eng_id, "FRY",
                           from_id, to_id, false, -1);
}

function SquirrelAI::_LocationProducesCargo(id_str, cargo_id) {
    if (id_str.len() < 2) return false;

    local prefix = id_str.slice(0, 1);
    local id = id_str.slice(1).tointeger();
    local dock_catchment = this._StationCatchmentRadius(AIStation.STATION_DOCK);

    if (prefix == "i" || prefix == "I") {
        if (!AIIndustry.IsValidIndustry(id)) return false;
        local produced = AICargoList_IndustryProducing(id);
        return produced.HasItem(cargo_id);
    }

    if (prefix == "t" || prefix == "T") {
        if (!AITown.IsValidTown(id)) return false;
        local tile = AITown.GetLocation(id);
        return (AITile.GetCargoProduction(tile, cargo_id, 1, 1, dock_catchment) >= 1);
    }

    return false;
}

function SquirrelAI::_LocationAcceptsCargo(id_str, cargo_id) {
    if (id_str.len() < 2) return false;

    local prefix = id_str.slice(0, 1);
    local id = id_str.slice(1).tointeger();
    local dock_catchment = this._StationCatchmentRadius(AIStation.STATION_DOCK);

    if (prefix == "i" || prefix == "I") {
        if (!AIIndustry.IsValidIndustry(id)) return false;
        local accepted = AICargoList_IndustryAccepting(id);
        return accepted.HasItem(cargo_id);
    }

    if (prefix == "t" || prefix == "T") {
        if (!AITown.IsValidTown(id)) return false;
        local tile = AITown.GetLocation(id);
        return (AITile.GetCargoAcceptance(tile, cargo_id, 1, 1, dock_catchment) >= 8);
    }

    return false;
}

// -----------------------------------------------------------------------
// Shared route builder
// -----------------------------------------------------------------------

function SquirrelAI::_BuildWaterRoute(from_tile, to_tile, eng_id, prefix,
                                       from_id, to_id, is_cargo, cargo_id) {
    // Step 1: Build/find dock A (source)
    local dkA = this.FindOrBuildDock(from_tile,
                                     cargo_id,
                                     false,
                                     is_cargo && cargo_id != -1);
    if (dkA == null) {
        this.WriteReply("ERR:" + prefix + ":" + from_id + ":" + to_id + ":NO_COAST");
        return;
    }
    AILog.Info("Dock A: tile=" + dkA.tile + " station_id=" + dkA.station_id);

    // Step 2: Build/find dock B (destination)
    local dkB = this.FindOrBuildDock(to_tile,
                                     cargo_id,
                                     is_cargo && cargo_id != -1,
                                     false);
    if (dkB == null) {
        this.WriteReply("ERR:" + prefix + ":" + from_id + ":" + to_id + ":NO_COAST");
        return;
    }
    AILog.Info("Dock B: tile=" + dkB.tile + " station_id=" + dkB.station_id);

    if (is_cargo && cargo_id != -1) {
        if (!this._DockMatchesCargo(dkA.tile, cargo_id, false, true)) {
            AILog.Warning("Source dock cargo coverage mismatch after build/reuse");
            this.WriteReply("ERR:" + prefix + ":" + from_id + ":" + to_id + ":NO_CARGO");
            return;
        }
        if (!this._DockMatchesCargo(dkB.tile, cargo_id, true, false)) {
            AILog.Warning("Destination dock cargo coverage mismatch after build/reuse");
            this.WriteReply("ERR:" + prefix + ":" + from_id + ":" + to_id + ":NO_CARGO");
            return;
        }
    }

    // Step 3: Check water connectivity (with canal constraint)
    local waterA = this._AdjacentWaterTile(dkA.tile);
    local waterB = this._AdjacentWaterTile(dkB.tile);
    if (waterA == -1 || waterB == -1) {
        this.WriteReply("ERR:" + prefix + ":" + from_id + ":" + to_id + ":NO_WATER");
        return;
    }

    if (!this._CheckWaterConnection(waterA, waterB)) {
        // Not connected — try to build a canal bridge (max 20 tiles)
        local canals = this._TryBuildCanalConnection(waterA, waterB, 20);
        if (canals < 0) {
            this.WriteReply("ERR:" + prefix + ":" + from_id + ":" + to_id + ":NO_WATERWAY");
            return;
        }
        AILog.Info("Built " + canals + " canal tiles to connect water bodies");
    }

    // Step 4: Build/find water depot near dock A
    local depot = this.FindOrBuildWaterDepot(dkA.tile);
    if (depot == -1) {
        this.WriteReply("ERR:" + prefix + ":" + from_id + ":" + to_id + ":NO_DEPOT");
        return;
    }

    // Step 5: Buy vessel(s)
    // Execution-only policy: start one ship per new route.
    // LLM scales fleet explicitly using CLN/SEL/DEP commands.
    local ship_count = 1;

    local lead_ship = this.BuyShip(depot, dkA.station_id, dkB.station_id, eng_id,
                                   is_cargo, cargo_id, ship_count);
    if (lead_ship == -1) {
        this.WriteReply("ERR:" + prefix + ":" + from_id + ":" + to_id + ":NO_FUNDS");
        return;
    }

    this.WriteReply("DONE:" + prefix + ":" + from_id + ":" + to_id);
}

// -----------------------------------------------------------------------
// Dock management: find existing or build new
//
// Reuses a nearby dock (within 10 tiles Manhattan) before building new.
// -----------------------------------------------------------------------

function SquirrelAI::FindOrBuildDock(location_tile,
                                      cargo_id = -1,
                                      require_acceptance = false,
                                      require_production = false) {
    local station_list = AIStationList(AIStation.STATION_DOCK);
    for (local s = station_list.Begin(); !station_list.IsEnd(); s = station_list.Next()) {
        local st_tile = AIStation.GetLocation(s);
    if (AIMap.DistanceManhattan(st_tile, location_tile) <= 15) {
    if (!this._DockMatchesCargo(st_tile, cargo_id,
                                        require_acceptance,
                                        require_production)) {
                continue;
    }
            AILog.Info("[REUSE] Dock '" + AIStation.GetName(s) + "' at (" +
                       AIMap.GetTileX(st_tile) + "," + AIMap.GetTileY(st_tile) + ")");
            return { tile = st_tile, station_id = s };
}
    }
    return this.BuildDockNear(location_tile,
                              cargo_id,
                      require_acceptance,
                              require_production);
}

function SquirrelAI::_DockMatchesCargo(dock_tile, cargo_id,
                                        require_acceptance,
                                        require_production) {
    if (cargo_id == -1) return true;
    if (!AIMap.IsValidTile(dock_tile)) return false;

    local dock_catchment = this._StationCatchmentRadius(AIStation.STATION_DOCK);
    local acceptance = AITile.GetCargoAcceptance(dock_tile, cargo_id, 1, 1, dock_catchment);
    local production = AITile.GetCargoProduction(dock_tile, cargo_id, 1, 1, dock_catchment);

    if (require_acceptance && acceptance < 8) return false;
    if (require_production && production < 1) return false;
    return true;
}

// -----------------------------------------------------------------------
// Dock building: spiral search for a valid coastal tile
//
// A dock needs a slope tile adjacent to water. We try BuildDock at each
// candidate tile; the engine validates slope and water adjacency for us.
// -----------------------------------------------------------------------

function SquirrelAI::BuildDockNear(center_tile,
                                    cargo_id = -1,
                                    require_acceptance = false,
                                    require_production = false) {
    local cx = AIMap.GetTileX(center_tile);
    local cy = AIMap.GetTileY(center_tile);

    AILog.Info("Searching for dock site near (" + cx + "," + cy + ")");

    for (local radius = 2; radius <= 20; radius++) {
        local candidates = [];

        for (local dx = -radius; dx <= radius; dx++) {
            for (local dy = -radius; dy <= radius; dy++) {
                if (this._abs(dx) != radius && this._abs(dy) != radius) continue;

                local sx = cx + dx;
                local sy = cy + dy;
                if (sx < 2 || sy < 2) continue;
                if (sx >= AIMap.GetMapSizeX() - 2) continue;
                if (sy >= AIMap.GetMapSizeY() - 2) continue;

                local tile = AIMap.GetTileIndex(sx, sy);
                if (!AIMap.IsValidTile(tile)) continue;

                if (!this._DockMatchesCargo(tile, cargo_id,
                                            require_acceptance,
                                            require_production)) {
                    continue;
                }

                local score = this.ScoreDockTile(tile, center_tile) - (radius * 2);
                if (score <= -10000) continue;

                candidates.push({
                    tile = tile,
                    score = score,
                    sx = sx,
                    sy = sy,
                    radius = radius
                });
            }
        }

        if (candidates.len() > 0) {
            candidates.sort(function(a, b) {
                if (a.score == b.score) {
                    if (a.radius == b.radius) return 0;
                    return (a.radius < b.radius) ? -1 : 1;
                }
                return (a.score > b.score) ? -1 : 1;
            });

            foreach (cand in candidates) {
                for (local retry = 0; retry < 3; retry++) {
                    if (AIMarine.BuildDock(cand.tile, AIStation.STATION_NEW)) {
                        local st_id = AIStation.GetStationID(cand.tile);
                        AILog.Info("[BUILD] Dock '" + AIStation.GetName(st_id) +
                                   "' at (" + cand.sx + "," + cand.sy + ") score=" +
                                   cand.score + " radius=" + cand.radius);
                        return { tile = cand.tile, station_id = st_id };
                    }

                    if (AIError.GetLastError() == AIError.ERR_VEHICLE_IN_THE_WAY) {
                        AIController.Sleep(3);
                        continue;
                    }
                    break;
                }
            }
        }
    }

    AILog.Warning("Could not build dock near (" + cx + "," + cy + ")");
    return null;
}

// -----------------------------------------------------------------------
// Water depot: find existing or build new
//
// A water depot needs two adjacent water tiles (tile + front).
// Searches outward from the dock location.
// -----------------------------------------------------------------------

function SquirrelAI::FindOrBuildWaterDepot(near_tile) {
    // Check for existing water depot nearby
    local nx = AIMap.GetTileX(near_tile);
    local ny = AIMap.GetTileY(near_tile);
    local best_depot = -1;
    local best_dist = 999999;

    for (local r = 1; r <= 15; r++) {
        for (local dx = -r; dx <= r; dx++) {
            for (local dy = -r; dy <= r; dy++) {
                if (this._abs(dx) != r && this._abs(dy) != r) continue;
                local tile = AIMap.GetTileIndex(nx + dx, ny + dy);
                if (AIMap.IsValidTile(tile) && AIMarine.IsWaterDepotTile(tile)) {
                    local d = AIMap.DistanceManhattan(tile, near_tile);
                    if (d < best_dist) {
                        best_dist = d;
                        best_depot = tile;
                    }
                }
            }
        }
    }

    if (best_depot != -1) {
        AILog.Info("[REUSE] Water depot at (" +
                   AIMap.GetTileX(best_depot) + "," + AIMap.GetTileY(best_depot) +
                   ") dist=" + best_dist);
        return best_depot;
    }

    return this.BuildWaterDepotNear(near_tile);
}

function SquirrelAI::BuildWaterDepotNear(center_tile) {
    local cx = AIMap.GetTileX(center_tile);
    local cy = AIMap.GetTileY(center_tile);
    local offsets = [[1, 0], [-1, 0], [0, 1], [0, -1]];
    local candidates = [];

    for (local radius = 2; radius <= 20; radius++) {
        for (local dx = -radius; dx <= radius; dx++) {
            for (local dy = -radius; dy <= radius; dy++) {
                if (this._abs(dx) != radius && this._abs(dy) != radius) continue;

                local sx = cx + dx;
                local sy = cy + dy;
                if (sx < 2 || sy < 2) continue;
                if (sx >= AIMap.GetMapSizeX() - 2) continue;
                if (sy >= AIMap.GetMapSizeY() - 2) continue;

                local tile = AIMap.GetTileIndex(sx, sy);
                if (!AIMap.IsValidTile(tile)) continue;
                if (!AITile.IsWaterTile(tile)) continue;

                // Try each adjacent water tile as the front
                foreach (off in offsets) {
                    local front = AIMap.GetTileIndex(sx + off[0], sy + off[1]);
                    if (!AIMap.IsValidTile(front)) continue;
                    if (!AITile.IsWaterTile(front)) continue;

                    local score = this.ScoreWaterDepotTile(tile, front, center_tile) - (radius * 2);
                    if (score <= -10000) continue;

                    candidates.push({
                        tile = tile,
                        front = front,
                        score = score,
                        sx = sx,
                        sy = sy,
                        radius = radius
                    });
                }
            }
        }
    }

    if (candidates.len() == 0) {
        AILog.Warning("Could not build water depot near (" + cx + "," + cy + ")");
        return -1;
    }

    candidates.sort(function(a, b) {
        if (a.score == b.score) {
            if (a.radius == b.radius) return 0;
            return (a.radius < b.radius) ? -1 : 1;
        }
        return (a.score > b.score) ? -1 : 1;
    });

    foreach (cand in candidates) {
        for (local retry = 0; retry < 3; retry++) {
            if (AIMarine.BuildWaterDepot(cand.tile, cand.front)) {
                AILog.Info("[BUILD] Water depot at (" + cand.sx + "," + cand.sy +
                           ") score=" + cand.score + " radius=" + cand.radius);
                return cand.tile;
            }

            if (AIError.GetLastError() == AIError.ERR_VEHICLE_IN_THE_WAY) {
                AIController.Sleep(3);
                continue;
            }
            break;
        }
    }

    AILog.Warning("Could not build water depot near (" + cx + "," + cy + ")");
    return -1;
}

// -----------------------------------------------------------------------
// Navigability check: true if a tile can be traversed by ships.
//
// IMPORTANT: AITile.IsWaterTile() returns FALSE for coast/shore transition
// tiles (OpenTTD excludes them internally). We must also accept coast tiles
// or docks built on slopes facing the shore will always fail the water check.
// -----------------------------------------------------------------------

function SquirrelAI::_IsNavigable(tile) {
    return AITile.IsWaterTile(tile) || AITile.IsCoastTile(tile);
}

// -----------------------------------------------------------------------
// Find a navigable tile adjacent to or very near the given dock tile.
//
// Searches expanding rings radius 1..4. Accepts water AND coast tiles.
// Radius > 1 is needed when:
//   - AIStation.GetLocation() returns the dock's water-part tile (the tile
//     adjacent to the slope), and we need to look past the dock structure.
//   - The slope faces a coast transition tile (IsWaterTile = false, but
//     IsCoastTile = true and ships CAN navigate it).
// Returns tile index or -1 if no navigable tile found within radius 4.
// -----------------------------------------------------------------------

function SquirrelAI::_AdjacentWaterTile(tile) {
    local tx = AIMap.GetTileX(tile);
    local ty = AIMap.GetTileY(tile);

    for (local r = 1; r <= 4; r++) {
        for (local dx = -r; dx <= r; dx++) {
            for (local dy = -r; dy <= r; dy++) {
                // Perimeter of this ring only (skip inner rings already checked)
                if (this._abs(dx) != r && this._abs(dy) != r) continue;
                local adj = AIMap.GetTileIndex(tx + dx, ty + dy);
                if (!AIMap.IsValidTile(adj)) continue;
                if (this._IsNavigable(adj)) return adj;
            }
        }
    }
    return -1;
}

// -----------------------------------------------------------------------
// Water connectivity: try MetaLibrary Lakes first, then fallback BFS.
//
// Returns true if tileA and tileB are on the same connected navigable body.
// Fallback BFS limit is 10 000 unique tiles to handle full-map oceans.
// -----------------------------------------------------------------------

function SquirrelAI::_CheckWaterConnection(tileA, tileB) {
    if (_SquirrelAIHasMetaLibraryLakes()) {
        try {
            local lakes = _MinchinWeb_Lakes_();
            lakes.InitializePath([tileA], [tileB]);

            local tries = 0;
            while (tries < 120) {
                local connected = lakes.FindPath(200);
                if (connected == true) {
                    return true;
                }
                if (connected == null) {
                    AILog.Warning("MetaLibrary Lakes returned null, falling back to BFS connectivity");
                    break;
                }

                tries++;
                AIController.Sleep(1);
            }
        } catch (e) {
            AILog.Warning("MetaLibrary Lakes check failed, falling back to BFS connectivity");
        }
    } else {
        AILog.Info("MetaLibrary Lakes unavailable, using BFS connectivity fallback");
    }

    local open = [tileA];
    local visited = {};
    visited[tileA] <- true;
    local count = 0;

    while (open.len() > 0 && count < 10000) {
        local current = open.remove(0);
        count++;

        if (AIMap.DistanceManhattan(current, tileB) <= 4) {
            return true;
        }

        local cx = AIMap.GetTileX(current);
        local cy = AIMap.GetTileY(current);
        foreach (off in [[1, 0], [-1, 0], [0, 1], [0, -1]]) {
            local ntile = AIMap.GetTileIndex(cx + off[0], cy + off[1]);
            if (!AIMap.IsValidTile(ntile)) continue;
            if (ntile in visited) continue;
            if (!this._IsNavigable(ntile)) continue;
            visited[ntile] <- true;
            open.push(ntile);
        }
    }

    return false;
}

// -----------------------------------------------------------------------
// Canal connection: attempt to bridge two disconnected water bodies
//
// Collects border water tiles from each body, finds the closest pair,
// and builds an L-shaped canal path between them. Returns the number
// of canal tiles built, or -1 if impossible or exceeds max_tiles.
// -----------------------------------------------------------------------

function SquirrelAI::_TryBuildCanalConnection(waterA, waterB, max_tiles) {
    // BFS from each side to collect water-body border tiles (tiles adjacent to land)
    local borderA = this._WaterBorderTiles(waterA, 1500);
    local borderB = this._WaterBorderTiles(waterB, 1500);

    if (borderA.len() == 0 || borderB.len() == 0) return -1;

    // Find the closest pair of border tiles
    local best_dist = 9999;
    local best_a = -1;
    local best_b = -1;

    foreach (a in borderA) {
        foreach (b in borderB) {
            local d = AIMap.DistanceManhattan(a, b);
            if (d < best_dist) {
                best_dist = d;
                best_a = a;
                best_b = b;
            }
        }
    }

    if (best_dist > max_tiles) {
        AILog.Warning("Water bodies too far apart: " + best_dist +
                      " tiles (max " + max_tiles + ")");
        return -1;
    }
    if (best_dist <= 1) {
        // Already adjacent — might just be a BFS limit issue
        return 0;
    }

    AILog.Info("Attempting canal: " + best_dist + " tiles between water bodies");

    // Build L-shaped canal path from best_a toward best_b
    local ax = AIMap.GetTileX(best_a);
    local ay = AIMap.GetTileY(best_a);
    local bx = AIMap.GetTileX(best_b);
    local by = AIMap.GetTileY(best_b);

    local canals_built = 0;

    // Horizontal leg
    local x = ax;
    local step_x = (bx > ax) ? 1 : ((bx < ax) ? -1 : 0);
    while (x != bx) {
        x += step_x;
        local tile = AIMap.GetTileIndex(x, ay);
        if (this._IsNavigable(tile)) continue;  // already navigable water/coast
        if (!AIMarine.BuildCanal(tile)) {
            AILog.Warning("Canal blocked at (" + x + "," + ay + "): " +
                          AIError.GetLastErrorString());
            return -1;
        }
        canals_built++;
    }

    // Vertical leg
    local y = ay;
    local step_y = (by > ay) ? 1 : ((by < ay) ? -1 : 0);
    while (y != by) {
        y += step_y;
        local tile = AIMap.GetTileIndex(bx, y);
        if (this._IsNavigable(tile)) continue;  // already navigable water/coast
        if (!AIMarine.BuildCanal(tile)) {
            AILog.Warning("Canal blocked at (" + bx + "," + y + "): " +
                          AIError.GetLastErrorString());
            return -1;
        }
        canals_built++;
    }

    AILog.Info("Canal complete: " + canals_built + " tiles built");
    return canals_built;
}

// -----------------------------------------------------------------------
// Collect border water tiles from a water body (tiles adjacent to land).
// These are the closest points where a canal could connect.
// -----------------------------------------------------------------------

function SquirrelAI::_WaterBorderTiles(start_tile, max_search) {
    local open = [start_tile];
    local visited = {};
    visited[start_tile] <- true;
    local borders = [];
    local count = 0;

    while (open.len() > 0 && count < max_search) {
        local current = open.remove(0);
        count++;
        local is_border = false;

        local cx = AIMap.GetTileX(current);
        local cy = AIMap.GetTileY(current);
        foreach (off in [[1, 0], [-1, 0], [0, 1], [0, -1]]) {
            local ntile = AIMap.GetTileIndex(cx + off[0], cy + off[1]);
            if (!AIMap.IsValidTile(ntile)) continue;
            if (ntile in visited) continue;

            if (this._IsNavigable(ntile)) {
                visited[ntile] <- true;
                open.push(ntile);
            } else {
                is_border = true;
            }
        }

        if (is_border) borders.push(current);
    }

    return borders;
}

// -----------------------------------------------------------------------
// Vehicle purchase: buy ship and set orders
//
// Cargo ships (SHP): refit to cargo, full-load at source, force-unload at dest
// Ferries (FRY): bidirectional passenger service
// -----------------------------------------------------------------------

function SquirrelAI::BuyShip(depot, stA_id, stB_id, eng_id, is_cargo, cargo_id,
                             count = 1) {
    if (count < 1) count = 1;

    if (!AIStation.IsValidStation(stA_id) || !AIStation.IsValidStation(stB_id)) {
        AILog.Warning("Station became invalid before ship purchase: stA=" + stA_id +
                      " stB=" + stB_id);
        return -1;
    }

    local stA_tile = AIStation.GetLocation(stA_id);
    local stB_tile = AIStation.GetLocation(stB_id);

    if (!AIMap.IsValidTile(stA_tile) || !AIMap.IsValidTile(stB_tile)) {
        AILog.Warning("Station location invalid before ship purchase: stA_tile=" +
                      stA_tile + " stB_tile=" + stB_tile);
        return -1;
    }

    // Compute waypoint plan before spending money on a new vessel.
    local buoys = this.GetShipWaypoints(stA_tile, stB_tile);
    if (buoys == null) buoys = [];

    local veh = AIVehicle.BuildVehicle(depot, eng_id);
    if (!AIVehicle.IsValidVehicle(veh)) {
        AILog.Warning("Failed to buy ship " + eng_id +
                      ": " + AIError.GetLastErrorString());
        return -1;
    }
    AILog.Info("Bought ship: veh_id=" + veh);

    // Refit cargo ships to the required cargo type
    if (is_cargo && cargo_id != -1) {
        if (!AIVehicle.RefitVehicle(veh, cargo_id)) {
            AILog.Warning("Failed to refit ship to cargo " + cargo_id +
                          ": " + AIError.GetLastErrorString());
            AIVehicle.SellVehicle(veh);
            return -1;
        }
        AILog.Info("Refitted ship to cargo " + cargo_id);
    }

    local append_order = function(v, order_tile, flags) {
        if (!AIOrder.AppendOrder(v, order_tile, flags)) {
            AILog.Warning("Failed to append ship order at tile " + order_tile +
                          ": " + AIError.GetLastErrorString());
            return false;
        }
        return true;
    };

    if (is_cargo) {
        if (!append_order(veh, stA_tile, AIOrder.OF_FULL_LOAD_ANY)) {
            AIVehicle.SendVehicleToDepot(veh);
            AIVehicle.SellVehicle(veh);
            return -1;
        }
        foreach (b in buoys) {
            if (!append_order(veh, b, AIOrder.OF_NONE)) {
                AIVehicle.SendVehicleToDepot(veh);
                AIVehicle.SellVehicle(veh);
                return -1;
            }
        }
        if (!append_order(veh, stB_tile, AIOrder.OF_UNLOAD | AIOrder.OF_NO_LOAD)) {
            AIVehicle.SendVehicleToDepot(veh);
            AIVehicle.SellVehicle(veh);
            return -1;
        }
        // Return buoys (reverse order)
        for (local i = buoys.len() - 1; i >= 0; i--) {
            if (!append_order(veh, buoys[i], AIOrder.OF_NONE)) {
                AIVehicle.SendVehicleToDepot(veh);
                AIVehicle.SellVehicle(veh);
                return -1;
            }
        }
    } else {
        if (!append_order(veh, stA_tile, AIOrder.OF_NONE)) {
            AIVehicle.SendVehicleToDepot(veh);
            AIVehicle.SellVehicle(veh);
            return -1;
        }
        foreach (b in buoys) {
            if (!append_order(veh, b, AIOrder.OF_NONE)) {
                AIVehicle.SendVehicleToDepot(veh);
                AIVehicle.SellVehicle(veh);
                return -1;
            }
        }
        if (!append_order(veh, stB_tile, AIOrder.OF_NONE)) {
            AIVehicle.SendVehicleToDepot(veh);
            AIVehicle.SellVehicle(veh);
            return -1;
        }
        for (local i = buoys.len() - 1; i >= 0; i--) {
            if (!append_order(veh, buoys[i], AIOrder.OF_NONE)) {
                AIVehicle.SendVehicleToDepot(veh);
                AIVehicle.SellVehicle(veh);
                return -1;
            }
        }
    }

    AIVehicle.StartStopVehicle(veh);

    local bought = 1;
    for (local i = 1; i < count; i++) {
        local cloned_veh = AIVehicle.CloneVehicle(depot, veh, true);
        if (AIVehicle.IsValidVehicle(cloned_veh)) {
            AIVehicle.StartStopVehicle(cloned_veh);
            bought++;
        } else {
            AILog.Warning("Failed to clone ship " + i + ": " +
                          AIError.GetLastErrorString());
        }
    }

    AILog.Info("Ship dispatched: first_veh=" + veh + " buoys=" + buoys.len() +
               " fleet=" + bought + "/" + count);
    return veh;
}

// -----------------------------------------------------------------------
// Place buoy waypoints between two dock tiles at wider intervals.
// Returns an array of buoy tile locations (may be empty if docks are close).
// -----------------------------------------------------------------------

function SquirrelAI::_PlaceBuoys(tileA, tileB) {
    local buoys = [];
    local dist = AIMap.DistanceManhattan(tileA, tileB);

    // Only place buoys for routes longer than 45 tiles.
    if (dist < 45) return buoys;

    local ax = AIMap.GetTileX(tileA).tofloat();
    local ay = AIMap.GetTileY(tileA).tofloat();
    local bx = AIMap.GetTileX(tileB).tofloat();
    local by = AIMap.GetTileY(tileB).tofloat();

    // Place buoys every ~45 tiles along the straight line.
    local interval = 45.0;
    local segments = (dist / interval).tointeger();
    if (segments < 1) return buoys;

    for (local s = 1; s <= segments; s++) {
        local frac = s.tofloat() / (segments + 1).tofloat();
        local mx = (ax + (bx - ax) * frac).tointeger();
        local my = (ay + (by - ay) * frac).tointeger();

        // Search for a nearby water tile to place the buoy
        local placed = false;
        for (local r = 0; r <= 5 && !placed; r++) {
            for (local dx = -r; dx <= r && !placed; dx++) {
                for (local dy = -r; dy <= r && !placed; dy++) {
                    if (r > 0 && this._abs(dx) != r && this._abs(dy) != r) continue;
                    local tx = mx + dx;
                    local ty = my + dy;
                    if (tx < 1 || ty < 1) continue;
                    if (tx >= AIMap.GetMapSizeX() - 1) continue;
                    if (ty >= AIMap.GetMapSizeY() - 1) continue;

                    local tile = AIMap.GetTileIndex(tx, ty);
                    if (!AIMap.IsValidTile(tile)) continue;
                    if (!AITile.IsWaterTile(tile)) continue;

                    // Check if there's already a buoy here
                    if (AIMarine.IsBuoyTile(tile)) {
                        buoys.push(tile);
                        placed = true;
                        break;
                    }

                    if (AIMarine.BuildBuoy(tile)) {
                        AILog.Info("[BUILD] Buoy at (" + tx + "," + ty + ")");
                        buoys.push(tile);
                        placed = true;
                    }
                }
            }
        }
    }

    return buoys;
}


