// SquirrelAI/road.nut - Road vehicle route building
//
// Handles: TRK, BUS, CTY commands
// Builds road stops, connects them via RoadPathFinder, builds depot, buys vehicles.
//
// Key API caveats handled:
//   - AIRoad.SetCurrentRoadType() must be set before any road construction
//   - BuildRoadStation does NOT auto-build road to front tile — explicit BuildRoad needed
//   - BuildDriveThroughRoadStation may fail on town-owned road — fall back to bay stop
//   - BuildRoadDepot does NOT auto-connect — explicit BuildRoad needed
//   - IsRoadTile() returns true for drive-through stops, false for bay stops and depots
//   - Road pathfinder takes simple tile arrays (not [tile, prev_tile] pairs like rail)

// -----------------------------------------------------------------------
// Entry points
// -----------------------------------------------------------------------

function SquirrelAI::BuildTruckRoute(from_str, to_str, eng_id, count) {
    AILog.Info("BuildTruckRoute: " + from_str + " -> " + to_str +
               " eng=" + eng_id + " count=" + count);

    if (!AIEngine.IsValidEngine(eng_id)) {
        this.WriteReply("ERR:TRK:" + from_str + ":" + to_str + ":NO_ENGINE");
        return;
    }

    AIRoad.SetCurrentRoadType(AIRoad.ROADTYPE_ROAD);

    // Select a compatible cargo for this specific route.
    local cargo_id = this.SelectRouteCargo(from_str, to_str, eng_id, "");
    if (cargo_id == -1) {
        AILog.Warning("No compatible truck cargo for route " + from_str + " -> " + to_str +
                      " with engine " + eng_id);
        this.WriteReply("ERR:TRK:" + from_str + ":" + to_str + ":NO_CARGO");
        return;
    }
    AILog.Info("Truck route cargo selected: " + AICargo.GetCargoLabel(cargo_id));

    local refit_cargo_id = -1;
    if (AIEngine.GetCargoType(eng_id) != cargo_id) {
        refit_cargo_id = cargo_id;
    }

    local from_loc = this._ResolveLoc(from_str);
    local to_loc   = this._ResolveLoc(to_str);

    if (from_loc == null || to_loc == null) {
        this.WriteReply("ERR:TRK:" + from_str + ":" + to_str + ":BAD_LOC");
        return;
    }
    AILog.Info("Source: " + from_loc.label + "  Dest: " + to_loc.label);

    this._BuildRoadRoute(from_loc.tile, to_loc.tile, eng_id, count,
                          AIRoad.ROADVEHTYPE_TRUCK, "TRK", from_str, to_str, true,
                          cargo_id, refit_cargo_id);
}

function SquirrelAI::BuildBusRoute(from_str, to_str, eng_id, count) {
    AILog.Info("BuildBusRoute: " + from_str + " -> " + to_str +
               " eng=" + eng_id + " count=" + count);

    if (!AIEngine.IsValidEngine(eng_id)) {
        this.WriteReply("ERR:BUS:" + from_str + ":" + to_str + ":NO_ENGINE");
        return;
    }

    AIRoad.SetCurrentRoadType(AIRoad.ROADTYPE_ROAD);

    local from_loc = this._ResolveLoc(from_str);
    local to_loc   = this._ResolveLoc(to_str);

    if (from_loc == null || to_loc == null) {
        this.WriteReply("ERR:BUS:" + from_str + ":" + to_str + ":BAD_LOC");
        return;
    }
    AILog.Info("Source: " + from_loc.label + "  Dest: " + to_loc.label);

    this._BuildRoadRoute(from_loc.tile, to_loc.tile, eng_id, count,
                          AIRoad.ROADVEHTYPE_BUS, "BUS", from_str, to_str, false,
                          -1, -1);
}

function SquirrelAI::BuildCityPublicTransport(town_id_str, eng_id, count) {
    AILog.Info("BuildCityPublicTransport: " + town_id_str + " eng=" + eng_id + " count=" + count);

    if (!AIEngine.IsValidEngine(eng_id)) {
        this.WriteReply("ERR:CTY:" + town_id_str + ":NO_ENGINE");
        return;
    }

    if (AIEngine.GetVehicleType(eng_id) != AIVehicle.VT_ROAD) {
        this.WriteReply("ERR:CTY:" + town_id_str + ":NO_ENGINE");
        return;
    }

    if (!AIEngine.IsBuildable(eng_id)) {
        this.WriteReply("ERR:CTY:" + town_id_str + ":NO_ENGINE");
        return;
    }

    local road_type = AIEngine.GetRoadType(eng_id);
    AIRoad.SetCurrentRoadType(road_type);

    local town_loc = this._ResolveLoc(town_id_str);
    if (town_loc == null) {
        this.WriteReply("ERR:CTY:" + town_id_str + ":BAD_LOC");
        return;
    }
    local town_tile = town_loc.tile;
    local town_id = AITile.GetClosestTown(town_tile);
    if (!AITown.IsValidTown(town_id)) {
        this.WriteReply("ERR:CTY:" + town_id_str + ":BAD_LOC");
        return;
    }

    local pop = AITown.GetPopulation(town_id);
    
    local cargo_id = AIEngine.GetCargoType(eng_id);
    local road_veh_type = (cargo_id == this.GetPassengerCargo()) ? AIRoad.ROADVEHTYPE_BUS : AIRoad.ROADVEHTYPE_TRUCK;
    local station_type = (road_veh_type == AIRoad.ROADVEHTYPE_BUS) ? AIStation.STATION_BUS_STOP : AIStation.STATION_TRUCK_STOP;

    local target_stops = 2;
    if (pop >= 1000) target_stops = 3;
    if (pop >= 2500) target_stops = 4;
    if (pop >= 5000) target_stops = 5;

    local cx = AIMap.GetTileX(town_tile);
    local cy = AIMap.GetTileY(town_tile);

    local max_radius = 12;
    if (pop >= 3000) max_radius = 18;

    local built_stops = []; 
    local built_tiles = [];

    local candidates = AIList();

    for (local radius = 1; radius <= max_radius; radius++) {
        for (local dx = -radius; dx <= radius; dx++) {
            for (local dy = -radius; dy <= radius; dy++) {
                if (this._abs(dx) != radius && this._abs(dy) != radius) continue;

                local sx = cx + dx;
                local sy = cy + dy;
                local tile = AIMap.GetTileIndex(sx, sy);
                if (!AIMap.IsValidTile(tile)) continue;

                if (!AIRoad.IsRoadTile(tile)) continue; 

                // Check cargo production/acceptance
                if (!this._RoadStopMatchesCargo(tile, cargo_id, true, true, station_type)) {
                    continue; 
                }
                
                // Base score: favor closer to center, penalized by radius
                local score = 100 - radius * 4;

                if (score > 0) {
                    candidates.AddItem(tile, score);
                }
            }
        }
    }

    candidates.Sort(AIList.SORT_BY_VALUE, AIList.SORT_DESCENDING);

    local offsets = [[1, 0], [-1, 0], [0, 1], [0, -1]];
    
    for (local item = candidates.Begin(); !candidates.IsEnd() && built_stops.len() < target_stops; item = candidates.Next()) {
        local tile = item;
        local sx = AIMap.GetTileX(tile);
        local sy = AIMap.GetTileY(tile);
        
        local min_dist = 9999;
        foreach (pt in built_tiles) {
            local d = AIMap.DistanceManhattan(tile, pt);
            if (d < min_dist) min_dist = d;
        }
        if (min_dist < 6 && built_stops.len() > 0) continue; // enforce minimum spacing of 6 tiles

        // Try to build drive-through stop
        foreach (off in offsets) {
            local front = AIMap.GetTileIndex(sx + off[0], sy + off[1]);
            if (!AIMap.IsValidTile(front)) continue;
            
            if (AIRoad.BuildDriveThroughRoadStation(tile, front, road_veh_type, AIStation.STATION_NEW)) {
                local st_id = AIStation.GetStationID(tile);
                AILog.Info("[CTY] Built stop '" + AIStation.GetName(st_id) + "' at (" + sx + "," + sy + ")");
                built_stops.push({tile = tile, front = front, station_id = st_id});
                built_tiles.push(tile);
                break;
            }
        }
    }

    if (built_stops.len() < 2) {
        AILog.Warning("Could not build enough stops for CTY command in " + town_id_str);
        this.WriteReply("ERR:CTY:" + town_id_str + ":NO_SPACE");
        return;
    }

    // Connect stops
    for (local i = 0; i < built_stops.len() - 1; i++) {
        this._CheckOrConnectTownRoads(built_stops[i].front, built_stops[i+1].front, eng_id);
        AIRoad.BuildRoad(built_stops[i].tile, built_stops[i].front);
        AIRoad.BuildRoad(built_stops[i+1].tile, built_stops[i+1].front);
    }
    // Connect last to first to complete the loop
    this._CheckOrConnectTownRoads(built_stops[built_stops.len()-1].front, built_stops[0].front, eng_id);
    AIRoad.BuildRoad(built_stops[built_stops.len()-1].tile, built_stops[built_stops.len()-1].front);
    AIRoad.BuildRoad(built_stops[0].tile, built_stops[0].front);

    // Build depot near any of the stops
    local depot = -1;
    foreach (stop in built_stops) {
        depot = this.FindOrBuildRoadDepot(stop.front);
        if (depot != -1) break;
    }
    

    if (depot == -1) {
        this.WriteReply("ERR:CTY:" + town_id_str + ":NO_DEPOT");
        return;
    }

    // Buy vehicles
    if (count < 1) count = 1;
    local first_veh = -1;
    local bought = 0;
    
    for (local i = 0; i < count; i++) {
        local veh;
        if (first_veh == -1) {
            veh = AIVehicle.BuildVehicle(depot, eng_id);
            if (!AIVehicle.IsValidVehicle(veh)) {
                this.WriteReply("ERR:CTY:" + town_id_str + ":NO_FUNDS");
                return;
            }
            first_veh = veh;
            // Setup orders
            foreach (stop in built_stops) {
                local loc = AIStation.GetLocation(stop.station_id);
                AIOrder.AppendOrder(veh, loc, AIOrder.OF_FULL_LOAD_ANY);
            }
        } else {
            veh = AIVehicle.CloneVehicle(depot, first_veh, true);
            if (!AIVehicle.IsValidVehicle(veh)) {
                AILog.Warning("Failed to clone vehicle " + i + " for CTY route.");
                break;
            }
        }
        AIVehicle.StartStopVehicle(veh);
        bought++;
    }

    if (bought == 0) {
        this.WriteReply("ERR:CTY:" + town_id_str + ":NO_FUNDS");
        return;
    }

    this.WriteReply("DONE:CTY:" + town_id_str);
}

// -----------------------------------------------------------------------
// Shared route builder
// -----------------------------------------------------------------------

function SquirrelAI::_CheckOrConnectTownRoads(start_tile, end_tile, eng_id) {
    local visited = {};
    local queue = [ start_tile ];
    visited[start_tile] <- true;
    local found = false;
    
    local offsets = [[1,0],[-1,0],[0,1],[0,-1]];
    local head = 0;
    while(head < queue.len() && head < 5000) {
        local cur = queue[head++];
        if (cur == end_tile) {
            found = true;
            break;
        }
        
        if (AIBridge.IsBridgeTile(cur)) {
            local other = AIBridge.GetOtherBridgeEnd(cur);
            if (other != cur && !(other in visited)) {
                visited[other] <- true;
                queue.push(other);
            }
        } else if (AITunnel.IsTunnelTile(cur)) {
            local other = AITunnel.GetOtherTunnelEnd(cur);
            if (other != cur && !(other in visited)) {
                visited[other] <- true;
                queue.push(other);
            }
        }
        
        foreach(off in offsets) {
            local next = AIMap.GetTileIndex(AIMap.GetTileX(cur)+off[0], AIMap.GetTileY(cur)+off[1]);
            if (!AIMap.IsValidTile(next)) continue;
            if (next in visited) continue;
            
            if (AIRoad.IsRoadTile(next) && AIRoad.AreRoadTilesConnected(cur, next)) {
                visited[next] <- true;
                queue.push(next);
            }
        }
    }
    
    if (found) {
        AILog.Info("[CTY] Verified existing town road connection.");
        return true;
    }
    
    AILog.Warning("[CTY] Need to build connection (not connected)...");
    return this.ConnectByRoad(start_tile, end_tile, eng_id);
}

function SquirrelAI::_BuildRoadRoute(from_tile, to_tile, eng_id, count,
                                      road_veh_type, prefix, from_id, to_id, is_cargo,
                                      route_cargo_id = -1, refit_cargo_id = -1) {
    // Step 1: Build/find stop A
    local stA = this.FindOrBuildRoadStop(
        from_tile,
        road_veh_type,
        route_cargo_id,
        false,
        is_cargo && route_cargo_id != -1,
        to_tile
    );
    if (stA == null) {
        this.WriteReply("ERR:" + from_id + ":" + to_id + ":NO_SPACE");
        return;
    }
    AILog.Info("Stop A: tile=" + stA.tile + " front=" + stA.front +
               " station_id=" + stA.station_id);

    // Step 2: Build/find stop B
    local stB = this.FindOrBuildRoadStop(
        to_tile,
        road_veh_type,
        route_cargo_id,
        is_cargo && route_cargo_id != -1,
        false,
        from_tile
    );
    if (stB == null) {
        this.WriteReply("ERR:" + from_id + ":" + to_id + ":NO_SPACE");
        return;
    }
    AILog.Info("Stop B: tile=" + stB.tile + " front=" + stB.front +
               " station_id=" + stB.station_id);

    if (is_cargo && route_cargo_id != -1) {
        local station_type = (road_veh_type == AIRoad.ROADVEHTYPE_BUS)
            ? AIStation.STATION_BUS_STOP
            : AIStation.STATION_TRUCK_STOP;

        if (!this._RoadStopMatchesCargo(stA.tile, route_cargo_id,
                                        false, true, station_type)) {
            AILog.Warning("Source road stop cargo coverage mismatch after build/reuse");
            this.WriteReply("ERR:" + from_id + ":" + to_id + ":NO_CARGO");
            return;
        }
        if (!this._RoadStopMatchesCargo(stB.tile, route_cargo_id,
                                        true, false, station_type)) {
            AILog.Warning("Destination road stop cargo coverage mismatch after build/reuse");
            this.WriteReply("ERR:" + from_id + ":" + to_id + ":NO_CARGO");
            return;
        }
    }

    // Step 3: Connect by road (pathfinder builds the road)
    if (!this.ConnectByRoad(stA.front, stB.front, eng_id)) {
        this.WriteReply("ERR:" + from_id + ":" + to_id + ":NO_PATH");
        return;
    }



    // Ensure stops connect to the road just built
    AIRoad.BuildRoad(stA.tile, stA.front);
    AIRoad.BuildRoad(stB.tile, stB.front);

    // Step 3b: Extend coverage in towns for bus routes only.
    if (road_veh_type == AIRoad.ROADVEHTYPE_BUS) {
        this._ExtendRoadCoverage(from_tile, stA.station_id, road_veh_type);
        this._ExtendRoadCoverage(to_tile, stB.station_id, road_veh_type);
    }


    // Step 4: Build depot near stop A (adjacent to existing road)
    local depot = this.FindOrBuildRoadDepot(stA.front);
    if (depot == -1) {
        this.WriteReply("ERR:" + from_id + ":" + to_id + ":NO_DEPOT");
        return;
    }

    // Step 5: Buy vehicles
    local lead_veh = this.BuyRoadVehicles(depot, stA.station_id, stB.station_id,
                                          eng_id, count, is_cargo, refit_cargo_id);
    if (lead_veh == -1) {
        this.WriteReply("ERR:" + from_id + ":" + to_id + ":NO_FUNDS");
        return;
    }

    this.WriteReply("DONE:" + from_id + ":" + to_id);
}

// -----------------------------------------------------------------------
// Stop management: find existing or build new
// -----------------------------------------------------------------------

function SquirrelAI::FindOrBuildRoadStop(location_tile, road_veh_type,
                                          cargo_id = -1,
                                          require_acceptance = false,
                                          require_production = false,
                                          target_tile = -1) {
    local station_type = (road_veh_type == AIRoad.ROADVEHTYPE_BUS)
        ? AIStation.STATION_BUS_STOP
        : AIStation.STATION_TRUCK_STOP;

    local best_reuse = null;
    local best_reuse_score = -1000000;

    local station_list = AIStationList(station_type);
    for (local s = station_list.Begin(); !station_list.IsEnd(); s = station_list.Next()) {
        local st_tile = AIStation.GetLocation(s);
        if (AIMap.DistanceManhattan(st_tile, location_tile) <= 4) {
            if (!this._RoadStopMatchesCargo(st_tile, cargo_id,
                                            require_acceptance, require_production,
                                            station_type)) {
                continue;
            }
            local front = this._FindRoadFront(st_tile);
            local score = 100 - (AIMap.DistanceManhattan(st_tile, location_tile) * 8);
            score += this._RoadTargetDeltaScore(location_tile, front, target_tile, 6);

            if (best_reuse == null || score > best_reuse_score) {
                best_reuse = { tile = st_tile, front = front, station_id = s };
                best_reuse_score = score;
            }
        }
    }

    if (best_reuse != null) {
        AILog.Info("[REUSE] Road stop '" + AIStation.GetName(best_reuse.station_id) + "' at (" +
                   AIMap.GetTileX(best_reuse.tile) + "," + AIMap.GetTileY(best_reuse.tile) +
                   ") score=" + best_reuse_score);
        return best_reuse;
    }

    return this.BuildRoadStopNear(
        location_tile,
        road_veh_type,
        cargo_id,
        require_acceptance,
        require_production,
        station_type,
        target_tile
    );
}

function SquirrelAI::_RoadStopMatchesCargo(station_tile, cargo_id,
                                            require_acceptance,
                                            require_production,
                                            station_type = AIStation.STATION_TRUCK_STOP) {
    return this.ValidateCatchment(station_tile, cargo_id, station_type,
                                  require_acceptance, require_production);
}

// Find the front tile (adjacent road) of an existing road stop
function SquirrelAI::_FindRoadFront(station_tile) {
    local sx = AIMap.GetTileX(station_tile);
    local sy = AIMap.GetTileY(station_tile);
    local best_adj = station_tile;
    local best_score = -100000;

    foreach (off in [[1, 0], [-1, 0], [0, 1], [0, -1]]) {
        local adj = AIMap.GetTileIndex(sx + off[0], sy + off[1]);
        if (!AIMap.IsValidTile(adj)) continue;

        local score = 0;
        if (AIRoad.IsRoadTile(adj)) {
            score += 50;
        } else if (AITile.IsBuildable(adj)) {
            score += 10;
        }

        local road_neighbors = 0;
        local ax = AIMap.GetTileX(adj);
        local ay = AIMap.GetTileY(adj);
        foreach (off2 in [[1, 0], [-1, 0], [0, 1], [0, -1]]) {
            local n2 = AIMap.GetTileIndex(ax + off2[0], ay + off2[1]);
            if (AIMap.IsValidTile(n2) && AIRoad.IsRoadTile(n2)) road_neighbors++;
        }
        score += road_neighbors * 8;

        if (!this.ValidateQueueSpace(adj, 1)) score -= 35;

        if (score > best_score) {
            best_score = score;
            best_adj = adj;
        }
    }

    return best_adj;
}

function SquirrelAI::_RoadTargetDeltaScore(origin_tile, candidate_tile, target_tile, weight = 4) {
    if (!AIMap.IsValidTile(origin_tile) || !AIMap.IsValidTile(candidate_tile) ||
        !AIMap.IsValidTile(target_tile)) {
        return 0;
    }

    local origin_dist = AIMap.DistanceManhattan(origin_tile, target_tile);
    local candidate_dist = AIMap.DistanceManhattan(candidate_tile, target_tile);
    return (origin_dist - candidate_dist) * weight;
}

// -----------------------------------------------------------------------
// Road stop building: search near location, try drive-through then bay
//
// Priority order per candidate tile:
//   1. Drive-through on existing road (best throughput, uses town roads)
//   2. Bay stop on clear land with adjacent road/buildable front
//
// Drive-through on town-owned road may fail (ERR_ROAD_CANNOT_BUILD_ON_TOWN_ROAD).
// Bay stops always work on clear land.
// -----------------------------------------------------------------------

function SquirrelAI::BuildRoadStopNear(center_tile, road_veh_type,
                                        cargo_id = -1,
                                        require_acceptance = false,
                                        require_production = false,
                                        station_type = AIStation.STATION_TRUCK_STOP,
                                        target_tile = -1) {
    local cx = AIMap.GetTileX(center_tile);
    local cy = AIMap.GetTileY(center_tile);
    local offsets = [[1, 0], [-1, 0], [0, 1], [0, -1]];
    local candidates = [];

    local town_id = AITile.GetClosestTown(center_tile);
    local has_town = AITown.IsValidTown(town_id);
    local existing_tiles = [];

    for (local radius = 2; radius <= 10; radius++) {
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

                // Candidate type 1: drive-through on existing road tile.
                if (AIRoad.IsRoadTile(tile)) {
                    foreach (off in offsets) {
                        local front = AIMap.GetTileIndex(sx + off[0], sy + off[1]);
                        if (!AIMap.IsValidTile(front)) continue;
                        if (!this._RoadStopMatchesCargo(tile, cargo_id,
                                                        require_acceptance,
                                                        require_production,
                                                        station_type)) {
                            continue;
                        }

                        local score = 1;
                        if (has_town) {
                            score = this.ScoreRoadStopTile(tile, town_id, road_veh_type, existing_tiles);
                        }
                        if (score <= -1) continue;

                        if (!this.ValidateQueueSpace(front, 1)) {
                            score -= 3;
                        }

                        candidates.push({
                            tile = tile,
                            front = front,
                            is_drive = true,
                            score = (score * 10) - (radius * 2) +
                                this._RoadTargetDeltaScore(center_tile, front, target_tile, 5),
                            radius = radius,
                            sx = sx,
                            sy = sy
                        });
                    }
                }

                // Candidate type 2: bay stop on clear land.
                if (AITile.IsBuildable(tile)) {
                    foreach (off in offsets) {
                        local front = AIMap.GetTileIndex(sx + off[0], sy + off[1]);
                        if (!AIMap.IsValidTile(front)) continue;
                        if (!AIRoad.IsRoadTile(front) && !AITile.IsBuildable(front)) continue;
                        if (!this._RoadStopMatchesCargo(tile, cargo_id,
                                                        require_acceptance,
                                                        require_production,
                                                        station_type)) {
                            continue;
                        }

                        local score = 1;
                        if (has_town && AIRoad.IsRoadTile(front)) {
                            // Bay stop itself is land, so use adjacent road quality.
                            score = this.ScoreRoadStopTile(front, town_id, road_veh_type, existing_tiles);
                        }
                        if (score <= -1) continue;

                        if (!this.ValidateQueueSpace(front, 1)) {
                            score -= 3;
                        }

                        local front_bonus = AIRoad.IsRoadTile(front) ? 6 : 2;
                        candidates.push({
                            tile = tile,
                            front = front,
                            is_drive = false,
                            score = (score * 8) + front_bonus - (radius * 2) +
                                this._RoadTargetDeltaScore(center_tile, front, target_tile, 5),
                            radius = radius,
                            sx = sx,
                            sy = sy
                        });
                    }
                }
            }
        }
    }

    if (candidates.len() == 0) {
        AILog.Warning("Could not build road stop near (" + cx + "," + cy + ")");
        return null;
    }

    candidates.sort(function(a, b) {
        if (a.score == b.score) {
            if (a.radius == b.radius) return 0;
            return (a.radius < b.radius) ? -1 : 1;
        }
        return (a.score > b.score) ? -1 : 1;
    });

    foreach (cand in candidates) {
        local built = false;
        for (local retry = 0; retry < 3; retry++) {
            if (cand.is_drive) {
                built = AIRoad.BuildDriveThroughRoadStation(
                    cand.tile, cand.front, road_veh_type, AIStation.STATION_NEW);
            } else {
                built = AIRoad.BuildRoadStation(
                    cand.tile, cand.front, road_veh_type, AIStation.STATION_NEW);
                if (built) {
                    // BuildRoadStation does NOT auto-build road to front.
                    AIRoad.BuildRoad(cand.tile, cand.front);
                }
            }

            if (built) {
                local st_id = AIStation.GetStationID(cand.tile);
                local kind = cand.is_drive ? "Drive-through" : "Bay";
                AILog.Info("[BUILD] " + kind + " stop '" + AIStation.GetName(st_id) +
                           "' at (" + cand.sx + "," + cand.sy + ") score=" + cand.score +
                           " radius=" + cand.radius);
                return { tile = cand.tile, front = cand.front, station_id = st_id };
            }

            if (AIError.GetLastError() == AIError.ERR_VEHICLE_IN_THE_WAY) {
                AIController.Sleep(3);
                continue;
            }
            break;
        }
    }

    AILog.Warning("Could not build road stop near (" + cx + "," + cy + ")");
    return null;
}

// -----------------------------------------------------------------------
// Road connection: pathfinder + build
//
// Uses OpenTTD's built-in road pathfinder library.
// Road pathfinder takes simple tile arrays (not [tile, prev_tile] pairs).
// Handles bridges and tunnels automatically.
// -----------------------------------------------------------------------

function SquirrelAI::ConnectByRoad(from_tile, to_tile, eng_id=null) {
    AILog.Info("ConnectByRoad: from=(" + AIMap.GetTileX(from_tile) + "," +
               AIMap.GetTileY(from_tile) + ") to=(" + AIMap.GetTileX(to_tile) + "," +
               AIMap.GetTileY(to_tile) + ")");

    local builder = RoadBuilder(eng_id, null);
    local distance = AIMap.DistanceManhattan(from_tile, to_tile);
    builder.pathFindLimit = max(builder.pathFindLimit, min(500, 80 + distance));

    // AAAHogEx's BuildPath handles finding and building the infrastructure
    local result = builder.BuildPath([from_tile], [to_tile], false);
    if (!result) {
        AILog.Warning("AAAHogEx RoadBuilder failed to connect the route.");
        return false;
    }

    AILog.Info("Road connection complete via AAAHogEx.");
    return true;
}

// -----------------------------------------------------------------------
// Town coverage: build additional stops spread across the town
//
// After building the primary stop, this function adds extra stops
// joined to the same station at different parts of the town for better
// coverage for bus routes.
// Uses drive-through stops on existing town roads.
// -----------------------------------------------------------------------

function SquirrelAI::_ExtendRoadCoverage(town_tile, station_id, road_veh_type) {
    if (road_veh_type != AIRoad.ROADVEHTYPE_BUS) return;

    local town_id = AITile.GetClosestTown(town_tile);
    if (!AITown.IsValidTown(town_id)) return;

    local pop = AITown.GetPopulation(town_id);
    if (pop < 500) {
        AILog.Info("Town " + AITown.GetName(town_id) +
                   " too small for coverage stops (pop=" + pop + ")");
        return;
    }

    local center = AITown.GetLocation(town_id);
    local cx = AIMap.GetTileX(center);
    local cy = AIMap.GetTileY(center);

    // Target extra stops based on population
    local target_extra = 1;
    if (pop >= 1500) target_extra = 2;
    if (pop >= 5000) target_extra = 3;

    local max_radius = 10;
    if (pop >= 3000) max_radius = 15;

    local veh_label = (road_veh_type == AIRoad.ROADVEHTYPE_BUS) ? "bus" : "truck";
    AILog.Info("Extending " + veh_label + " coverage in " + AITown.GetName(town_id) +
               " (pop=" + pop + ", target=" + target_extra + " extra)");

    local built = 0;
    local offsets = [[1, 0], [-1, 0], [0, 1], [0, -1]];
    local built_tiles = [];  // track built stop locations for spacing
    local existing_tiles = [AIStation.GetLocation(station_id)];

    // Search outward from radius 5 — inner ring is covered by primary stop
    for (local radius = 5; radius <= max_radius && built < target_extra; radius++) {
        local candidates = AIList();

        for (local dx = -radius; dx <= radius && built < target_extra; dx++) {
            for (local dy = -radius; dy <= radius && built < target_extra; dy++) {
                if (this._abs(dx) != radius && this._abs(dy) != radius) continue;

                local sx = cx + dx;
                local sy = cy + dy;
                if (sx < 2 || sy < 2) continue;
                if (sx >= AIMap.GetMapSizeX() - 2) continue;
                if (sy >= AIMap.GetMapSizeY() - 2) continue;

                local tile = AIMap.GetTileIndex(sx, sy);
                if (!AIMap.IsValidTile(tile)) continue;

                // Only build on existing town road tiles
                if (!AIRoad.IsRoadTile(tile)) continue;

                // Enforce minimum spacing between extra stops (at least 4 tiles apart)
                local too_close = false;
                foreach (prev in built_tiles) {
                    if (AIMap.DistanceManhattan(tile, prev) < 4) {
                        too_close = true;
                        break;
                    }
                }
                if (too_close) continue;

                local score = this.ScoreRoadStopTile(tile, town_id, road_veh_type, existing_tiles);
                if (score > 0) {
                    candidates.AddItem(tile, score);
                }
            }
        }

        candidates.Sort(AIList.SORT_BY_VALUE, AIList.SORT_DESCENDING);
        for (local tile = candidates.Begin(); !candidates.IsEnd() && built < target_extra; tile = candidates.Next()) {
            local sx = AIMap.GetTileX(tile);
            local sy = AIMap.GetTileY(tile);

            // Try drive-through stop joined to existing station
            foreach (off in offsets) {
                local front = AIMap.GetTileIndex(sx + off[0], sy + off[1]);
                if (!AIMap.IsValidTile(front)) continue;
                if (AIRoad.BuildDriveThroughRoadStation(
                        tile, front, road_veh_type, station_id)) {
                    AILog.Info("[COVERAGE] Built extra " + veh_label + " stop at (" + sx + "," +
                               sy + ") for station " + AIStation.GetName(station_id));
                    built_tiles.push(tile);
                    existing_tiles.push(tile);
                    built++;
                    break;
                }
            }
        }
    }

    if (built > 0) {
        AILog.Info("[COVERAGE] +" + built + " " + veh_label + " stop(s) in " + AITown.GetName(town_id));
    } else {
        AILog.Info("[COVERAGE] No extra stops needed/possible in " +
                   AITown.GetName(town_id));
    }
}

// -----------------------------------------------------------------------
// Depot management: find existing or build new road depot
//
// Searches for an existing road depot within 8 tiles of the center.
// Only builds a new one if none is found.
// -----------------------------------------------------------------------

function SquirrelAI::FindOrBuildRoadDepot(center_tile) {
    local cx = AIMap.GetTileX(center_tile);
    local cy = AIMap.GetTileY(center_tile);

    // Search for existing road depot nearby
    for (local r = 1; r <= 15; r++) {
        for (local dx = -r; dx <= r; dx++) {
            for (local dy = -r; dy <= r; dy++) {
                if (this._abs(dx) != r && this._abs(dy) != r) continue;
                local sx = cx + dx;
                local sy = cy + dy;
                local tile = AIMap.GetTileIndex(sx, sy);
                if (!AIMap.IsValidTile(tile)) continue;
                if (AIRoad.IsRoadDepotTile(tile)) {
                    AILog.Info("[REUSE] Road depot at (" + sx + "," + sy + ")");;
                    return tile;
                }
            }
        }
    }

    return this.BuildRoadDepotNear(center_tile);
}

// -----------------------------------------------------------------------
// Depot building: find buildable tile adjacent to existing road
//
// Must be called AFTER ConnectByRoad so road tiles exist near the stop.
// BuildRoadDepot does NOT auto-connect — we call BuildRoad explicitly.
// -----------------------------------------------------------------------

function SquirrelAI::BuildRoadDepotNear(center_tile) {
    local cx = AIMap.GetTileX(center_tile);
    local cy = AIMap.GetTileY(center_tile);
    local offsets = [[1, 0], [-1, 0], [0, 1], [0, -1]];
    local candidates = [];

    for (local radius = 1; radius <= 15; radius++) {
        for (local dx = -radius; dx <= radius; dx++) {
            for (local dy = -radius; dy <= radius; dy++) {
                if (this._abs(dx) != radius && this._abs(dy) != radius) continue;

                local sx = cx + dx;
                local sy = cy + dy;
                local tile = AIMap.GetTileIndex(sx, sy);

                if (!AIMap.IsValidTile(tile) || !AITile.IsBuildable(tile)) continue;

                // Depot must be on flat ground to connect properly
                if (AITile.GetSlope(tile) != AITile.SLOPE_FLAT) continue;

                // Depot front must face an existing road tile that is NOT a station
                foreach (off in offsets) {
                    local front = AIMap.GetTileIndex(sx + off[0], sy + off[1]);
                    if (!AIMap.IsValidTile(front)) continue;
                    if (!AIRoad.IsRoadTile(front)) continue;
                    if (AITile.IsStationTile(front)) continue;

                    local score = this.ScoreRoadDepotTile(tile, front, center_tile) - (radius * 3);
                    candidates.push({
                        tile = tile,
                        front = front,
                        score = score,
                        radius = radius,
                        sx = sx,
                        sy = sy
                    });
                }
            }
        }
    }

    if (candidates.len() == 0) {
        AILog.Warning("Could not build road depot near (" + cx + "," + cy + ")");
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
            if (AIRoad.BuildRoadDepot(cand.tile, cand.front)) {
                AILog.Info("[BUILD] Road depot at (" + cand.sx + "," + cand.sy +
                           ") score=" + cand.score + " radius=" + cand.radius);
                // Ensure road connection between depot and front tile
                AIRoad.BuildRoad(cand.tile, cand.front);
                return cand.tile;
            }

            if (AIError.GetLastError() == AIError.ERR_VEHICLE_IN_THE_WAY) {
                AIController.Sleep(3);
                continue;
            }
            break;
        }
    }

    AILog.Warning("Could not build road depot near (" + cx + "," + cy + ")");
    return -1;
}

// -----------------------------------------------------------------------
// Vehicle purchase: buy first vehicle with orders, clone the rest
//
// Trucks: full load at source, unload at destination (one-way cargo)
// Buses: default behavior at both stops (bidirectional passengers)
// -----------------------------------------------------------------------

function SquirrelAI::BuyRoadVehicles(depot, stA_id, stB_id, eng_id, count, is_cargo,
                                      refit_cargo_id = -1) {
    if (count < 1) count = 1;

    local stA_tile = AIStation.GetLocation(stA_id);
    local stB_tile = AIStation.GetLocation(stB_id);

    // Buy the first vehicle and set up orders
    local first_veh = AIVehicle.BuildVehicle(depot, eng_id);
    if (!AIVehicle.IsValidVehicle(first_veh)) {
        AILog.Warning("Failed to buy road vehicle " + eng_id +
                      ": " + AIError.GetLastErrorString());
        return -1;
    }
    AILog.Info("Bought road vehicle: veh_id=" + first_veh);

    // Refit to explicit cargo if specified
    if (refit_cargo_id != -1) {
        if (!AIVehicle.RefitVehicle(first_veh, refit_cargo_id)) {
            AILog.Warning("Failed to refit truck to cargo " + refit_cargo_id +
                          ": " + AIError.GetLastErrorString());
            AIVehicle.SellVehicle(first_veh);
            return -1;
        }
        AILog.Info("Refitted truck to cargo " + refit_cargo_id);
    }

    if (is_cargo) {
        // Trucks: wait for full load at source, force-unload at destination
        AIOrder.AppendOrder(first_veh, stA_tile, AIOrder.OF_FULL_LOAD_ANY);
        AIOrder.AppendOrder(first_veh, stB_tile, AIOrder.OF_UNLOAD | AIOrder.OF_NO_LOAD);
    } else {
        // Buses: wait for full load at both stops
        AIOrder.AppendOrder(first_veh, stA_tile, AIOrder.OF_FULL_LOAD_ANY);
        AIOrder.AppendOrder(first_veh, stB_tile, AIOrder.OF_FULL_LOAD_ANY);
    }

    AIVehicle.StartStopVehicle(first_veh);

    // Clone additional vehicles with shared orders
    local bought = 1;
    for (local i = 1; i < count; i++) {
        local new_veh = AIVehicle.CloneVehicle(depot, first_veh, true);
        if (AIVehicle.IsValidVehicle(new_veh)) {
            AIVehicle.StartStopVehicle(new_veh);
            bought++;
        } else {
            AILog.Warning("Failed to clone vehicle " + i + ": " +
                          AIError.GetLastErrorString());
        }
    }

    AILog.Info("Road vehicles dispatched: " + bought + "/" + count);
    return first_veh;
}


