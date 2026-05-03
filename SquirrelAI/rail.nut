// SquirrelAI/rail.nut - Rail route building
//
// Handles: TRN command
// Builds stations, connects them via RailPathFinder, builds depot, buys train.

function SquirrelAI::BuildRailRoute(from_str, to_str, eng_id, wagons_str) {
    AILog.Info("BuildRailRoute: " + from_str + " -> " + to_str +
               " eng=" + eng_id + " wagons=" + wagons_str);

    if (!AIEngine.IsValidEngine(eng_id)) {
        this.WriteReply("ERR:" + from_str + ":" + to_str + ":NO_ENGINE");
        return;
    }

    // Set rail type to match the engine
    AIRail.SetCurrentRailType(AIEngine.GetRailType(eng_id));

    // Resolve locations (mandatory t/i prefix)
    local from_loc = this._ResolveLoc(from_str);
    local to_loc   = this._ResolveLoc(to_str);

    if (from_loc == null || to_loc == null) {
        this.WriteReply("ERR:" + from_str + ":" + to_str + ":NO_SPACE");
        return;
    }

    local from_tile = from_loc.tile;
    local to_tile   = to_loc.tile;
    AILog.Info("Source: " + from_loc.label + "  Dest: " + to_loc.label);

    if (!AIMap.IsValidTile(from_tile) || !AIMap.IsValidTile(to_tile)) {
        this.WriteReply("ERR:" + from_str + ":" + to_str + ":NO_SPACE");
        return;
    }

    // Parse wagons and compute platform length
    local wagon_list = this.ParseWagons(wagons_str);
    local route_cargo_id = -1;
    local train_catchment = this._StationCatchmentRadius(AIStation.STATION_TRAIN);

    // Validate cargo flow: first wagon cargo must be produced at source and
    // accepted at destination.
    if (wagon_list.len() > 0) {
        local first_wagon_eng = wagon_list[0].id;
        if (AIEngine.IsValidEngine(first_wagon_eng)) {
            local wagon_cargo = AIEngine.GetCargoType(first_wagon_eng);
            route_cargo_id = wagon_cargo;

            local source_ok = false;
            local from_prefix = from_str.slice(0, 1);
            if (from_prefix == "i" || from_prefix == "I") {
                local from_id = from_str.slice(1).tointeger();
                if (AIIndustry.IsValidIndustry(from_id)) {
                    local produced = AICargoList_IndustryProducing(from_id);
                    source_ok = produced.HasItem(wagon_cargo);
                }
            } else if (from_prefix == "t" || from_prefix == "T") {
                local from_id = from_str.slice(1).tointeger();
                if (AITown.IsValidTown(from_id)) {
                    local town_tile = AITown.GetLocation(from_id);
                    source_ok = (AITile.GetCargoProduction(town_tile, wagon_cargo, 1, 1,
                                                           train_catchment) >= 1);
                }
            }

            local destination_ok = false;
            local to_prefix = to_str.slice(0, 1);
            if (to_prefix == "i" || to_prefix == "I") {
                local to_id = to_str.slice(1).tointeger();
                if (AIIndustry.IsValidIndustry(to_id)) {
                    local accepted = AICargoList_IndustryAccepting(to_id);
                    destination_ok = accepted.HasItem(wagon_cargo);
                }
            } else if (to_prefix == "t" || to_prefix == "T") {
                local to_id = to_str.slice(1).tointeger();
                if (AITown.IsValidTown(to_id)) {
                    local town_tile = AITown.GetLocation(to_id);
                    destination_ok = (AITile.GetCargoAcceptance(town_tile, wagon_cargo, 1, 1,
                                                                train_catchment) >= 8);
                }
            }

            if (!source_ok || !destination_ok) {
                AILog.Warning("Rail cargo flow invalid for " + AICargo.GetCargoLabel(wagon_cargo) +
                              " source_ok=" + source_ok + " destination_ok=" + destination_ok);
                this.WriteReply("ERR:" + from_str + ":" + to_str + ":NO_CARGO");
                return;
            }
        }
    }
    local total_wagons = 0;
    foreach (w in wagon_list) total_wagons += w.count;
    // 1 engine + N wagons in half-tile units -> platform length
    local platform_len = this._max(3, (total_wagons + 2) / 2 + 1);
    if (platform_len > 7) platform_len = 7;

    AILog.Info("Platform length: " + platform_len + " (wagons=" + total_wagons + ")");

    // Prefer orientation with stronger geometric alignment + endpoint openness.
    local score_ne_sw = this.ComputeOrientationScore(from_tile, to_tile, AIRail.RAILTRACK_NE_SW);
    local score_nw_se = this.ComputeOrientationScore(from_tile, to_tile, AIRail.RAILTRACK_NW_SE);
    local use_nesw = (score_ne_sw >= score_nw_se);
    local direction = use_nesw ? AIRail.RAILTRACK_NE_SW : AIRail.RAILTRACK_NW_SE;
    AILog.Info("Station direction: " + (use_nesw ? "NE_SW" : "NW_SE") +
               " (score_ne_sw=" + score_ne_sw + ", score_nw_se=" + score_nw_se + ")");

    // Build or reuse station A (source)
    local stA_result = this.FindOrBuildStation(
        from_tile,
        platform_len,
        direction,
        0,
        true,
        route_cargo_id,
        false,
        route_cargo_id != -1
    );
    if (stA_result == null) {
        this.WriteReply("ERR:" + from_str + ":" + to_str + ":NO_SPACE");
        return;
    }
    local stA_tile = stA_result.tile;
    local stA_id   = stA_result.station_id;
    local build_direction = ("direction" in stA_result) ? stA_result.direction : direction;
    AILog.Info("Station A: tile=" + stA_tile + " station_id=" + stA_id);

    // Build or reuse station B (destination)
    local stB_result = this.FindOrBuildStation(
        to_tile,
        platform_len,
        build_direction,
        0,
        false,
        route_cargo_id,
        route_cargo_id != -1,
        false
    );
    if (stB_result == null) {
        this.WriteReply("ERR:" + from_str + ":" + to_str + ":NO_SPACE");
        return;
    }
    local stB_tile = stB_result.tile;
    local stB_id   = stB_result.station_id;
    AILog.Info("Station B: tile=" + stB_tile + " station_id=" + stB_id);

    if (route_cargo_id != -1) {
        if (!this._RailStationMatchesCargo(stA_tile, route_cargo_id, false, true)) {
            AILog.Warning("Source rail station cargo coverage mismatch after build/reuse");
            this.WriteReply("ERR:" + from_str + ":" + to_str + ":NO_CARGO");
            return;
        }
        if (!this._RailStationMatchesCargo(stB_tile, route_cargo_id, true, false)) {
            AILog.Warning("Destination rail station cargo coverage mismatch after build/reuse");
            this.WriteReply("ERR:" + from_str + ":" + to_str + ":NO_CARGO");
            return;
        }
    }



    // Connect rail
    local rail_ok = this.ConnectStations(stA_tile, stB_tile, platform_len, build_direction, eng_id);
    if (!rail_ok) {
        this.WriteReply("ERR:" + from_str + ":" + to_str + ":NO_PATH");
        return;
    }

    // Build depot near station A
    local depot = this.BuildDepotNearStation(stA_tile, platform_len, build_direction);
    if (depot == -1) {
        AILog.Info("Could not build depot near station A, trying station B...");
        local stB_dir = ("direction" in stB_result) ? stB_result.direction : build_direction;
        depot = this.BuildDepotNearStation(stB_tile, platform_len, stB_dir);

        if (depot == -1) {
            AILog.Info("Could not build depot near station B, trying somewhere on the route...");
            depot = this._BuildDepotSomewhereOnRoute(stA_tile, stB_tile);
        }

        if (depot == -1) {
            this.WriteReply("ERR:" + from_str + ":" + to_str + ":NO_SPACE");
            return;
        }
    }

    // Buy and dispatch train
    local lead_train = this.BuyTrain(depot, stA_id, stB_id, eng_id, wagon_list);
    if (lead_train == -1) {
        this.WriteReply("ERR:" + from_str + ":" + to_str + ":NO_FUNDS");
        return;
    }

    this.WriteReply("DONE:" + from_str + ":" + to_str);
}

// -----------------------------------------------------------------------
// Station: find existing or build new
// -----------------------------------------------------------------------

function SquirrelAI::_RailStationMatchesCargo(tile, cargo_id,
                                               require_acceptance,
                                               require_production) {
    return this.ValidateCatchment(tile, cargo_id, AIStation.STATION_TRAIN,
                                  require_acceptance, require_production);
}

function SquirrelAI::_RailPlatformMatchesCargo(sx, sy, direction, platform_len, cargo_id,
                                                require_acceptance,
                                                require_production) {
    if (cargo_id == -1) return true;

    local catchment = this._StationCatchmentRadius(AIStation.STATION_TRAIN);
    local has_acceptance = !require_acceptance;
    local has_production = !require_production;

    for (local p = 0; p < platform_len; p++) {
        local tile;
        if (direction == AIRail.RAILTRACK_NE_SW) {
            tile = AIMap.GetTileIndex(sx + p, sy);
        } else {
            tile = AIMap.GetTileIndex(sx, sy + p);
        }
        if (!AIMap.IsValidTile(tile)) continue;

        local acceptance = AITile.GetCargoAcceptance(tile, cargo_id, 1, 1, catchment);
        local production = AITile.GetCargoProduction(tile, cargo_id, 1, 1, catchment);
        if (require_acceptance && acceptance >= 8) has_acceptance = true;
        if (require_production && production >= 1) has_production = true;

        if (has_acceptance && has_production) return true;
    }

    return has_acceptance && has_production;
}

function SquirrelAI::FindOrBuildStation(ind_tile, platform_len, direction, ind_id,
                                         allow_alternate = true,
                                         cargo_id = -1,
                                         require_acceptance = false,
                                         require_production = false) {
    local station_list = AIStationList(AIStation.STATION_TRAIN);
    for (local s = station_list.Begin(); !station_list.IsEnd(); s = station_list.Next()) {
        local st_tile = AIStation.GetLocation(s);
        if (AIMap.DistanceManhattan(st_tile, ind_tile) <= 4) {
        if (!this._RailStationMatchesCargo(st_tile, cargo_id,
                                               require_acceptance,
                                               require_production)) {
                continue;
    }

            AILog.Info("[REUSE] Extending train station '" + AIStation.GetName(s) +
                       "' with new platform");
    // Build a new platform adjacent to the existing station (joined)
            local new_platform = this.BuildAdjacentPlatform(
                st_tile,
                platform_len,
        direction,
                s,
                cargo_id,
                require_acceptance,
        require_production
            );

            if (new_platform != null) return new_platform;
    // If extending fails, prefer a dedicated nearby station to avoid
            // routing from an arbitrary existing platform tile.
            AILog.Info("[REUSE] Could not extend, trying new station near target");
            local fresh_station = this.BuildNewStation(
        ind_tile,
                platform_len,
                direction,
                allow_alternate,
        cargo_id,
                require_acceptance,
                require_production
            );
            if (fresh_station != null) return fresh_station;

            // Last resort fallback.
    AILog.Info("[REUSE] New station failed, reusing existing platform directly");
            return {
                tile       = st_tile,
                station_id = s,
        direction  = direction
            };
        }
    }
    return this.BuildNewStation(
        ind_tile,
        platform_len,
        direction,
        allow_alternate,
        cargo_id,
        require_acceptance,
        require_production
    );
}

// Build a new platform adjacent to an existing station, joined to it.
function SquirrelAI::BuildAdjacentPlatform(existing_tile, platform_len, direction, station_id,
                                            cargo_id = -1,
                                            require_acceptance = false,
                                            require_production = false) {
    local sx = AIMap.GetTileX(existing_tile);
    local sy = AIMap.GetTileY(existing_tile);

    // Try nearby tiles in expanding rings; this is more robust than a fixed
    // perpendicular-only offset and works better for irregular station layouts.
    local offsets = [];
    for (local r = 1; r <= 4; r++) {
        for (local dx = -r; dx <= r; dx++) {
            for (local dy = -r; dy <= r; dy++) {
                if (this._abs(dx) != r && this._abs(dy) != r) continue;
                offsets.push([dx, dy]);
            }
        }
    }

    foreach (off in offsets) {
        local nx = sx + off[0];
        local ny = sy + off[1];
        if (nx < 2 || ny < 2) continue;
        if (nx >= AIMap.GetMapSizeX() - 2) continue;
        if (ny >= AIMap.GetMapSizeY() - 2) continue;

        local tile = AIMap.GetTileIndex(nx, ny);

        // Check all tiles in the platform footprint are buildable
        local can_build = true;
        for (local p = 0; p < platform_len; p++) {
            local check_tile;
            if (direction == AIRail.RAILTRACK_NE_SW) {
                check_tile = AIMap.GetTileIndex(nx + p, ny);
            } else {
                check_tile = AIMap.GetTileIndex(nx, ny + p);
            }
            if (!AIMap.IsValidTile(check_tile) || !AITile.IsBuildable(check_tile)) {
                can_build = false;
                break;
            }
        }
        if (!can_build) continue;

        if (!this._RailPlatformMatchesCargo(nx, ny, direction, platform_len, cargo_id,
                                            require_acceptance,
                                            require_production)) {
            continue;
        }

        // Build joined to existing station
        if (AIRail.BuildRailStation(tile, direction, 1, platform_len, station_id)) {
            AILog.Info("[BUILD] New platform at (" + nx + "," + ny +
                       ") joined to station " + AIStation.GetName(station_id));
            return {
                tile       = tile,
                station_id = station_id,
                direction  = direction
            };
        }
    }

    return null;
}

function SquirrelAI::BuildNewStation(industry_tile, platform_len, direction,
                                      allow_alternate = true,
                                      cargo_id = -1,
                                      require_acceptance = false,
                                      require_production = false) {
    local ix = AIMap.GetTileX(industry_tile);
    local iy = AIMap.GetTileY(industry_tile);
    local candidates = [];

    local directions = [direction];
    if (allow_alternate) {
        local alt = (direction == AIRail.RAILTRACK_NE_SW)
            ? AIRail.RAILTRACK_NW_SE
            : AIRail.RAILTRACK_NE_SW;
        if (alt != direction) directions.push(alt);
    }

    for (local radius = 2; radius <= 10; radius++) {
        for (local dx = -radius; dx <= radius; dx++) {
            for (local dy = -radius; dy <= radius; dy++) {
                if (this._abs(dx) != radius && this._abs(dy) != radius) continue;

                local sx = ix + dx;
                local sy = iy + dy;
                if (sx < 2 || sy < 2) continue;
                if (sx >= AIMap.GetMapSizeX() - 2) continue;
                if (sy >= AIMap.GetMapSizeY() - 2) continue;

                local tile = AIMap.GetTileIndex(sx, sy);

                foreach (dir in directions) {
                    local can_build = true;
                    for (local p = 0; p < platform_len; p++) {
                        local check_tile;
                        if (dir == AIRail.RAILTRACK_NE_SW) {
                            check_tile = AIMap.GetTileIndex(sx + p, sy);
                        } else {
                            check_tile = AIMap.GetTileIndex(sx, sy + p);
                        }
                        if (!AIMap.IsValidTile(check_tile) || !AITile.IsBuildable(check_tile)) {
                            can_build = false;
                            break;
                        }
                    }
                    if (!can_build) continue;

                    if (!this._RailPlatformMatchesCargo(sx, sy, dir, platform_len, cargo_id,
                                                        require_acceptance,
                                                        require_production)) {
                        continue;
                    }

                    local score = this.ScoreRailStationTile(tile, dir, platform_len, industry_tile);
                    if (dir == direction) score += 15;
                    score -= radius * 4;

                    candidates.push({
                        tile = tile,
                        direction = dir,
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
        AILog.Warning("Could not build station near (" + ix + "," + iy + ")");
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
        for (local retry = 0; retry < 3; retry++) {
            if (AIRail.BuildRailStation(cand.tile, cand.direction, 1, platform_len,
                                        AIStation.STATION_NEW)) {
                local st_id = AIStation.GetStationID(cand.tile);
                AILog.Info("[BUILD] Train station '" + AIStation.GetName(st_id) +
                           "' at (" + cand.sx + "," + cand.sy + ") score=" + cand.score +
                           " radius=" + cand.radius);
                return {
                    tile = cand.tile,
                    station_id = st_id,
                    direction = cand.direction
                };
            }

            if (AIError.GetLastError() == AIError.ERR_VEHICLE_IN_THE_WAY) {
                AIController.Sleep(3);
                continue;
            }
            break;
        }
    }

    AILog.Warning("Could not build station near (" + ix + "," + iy + ")");
    return null;
}
// -----------------------------------------------------------------------
// Rail building: pathfinder-based connection
// -----------------------------------------------------------------------

function SquirrelAI::ConnectStations(stA_tile, stB_tile, platform_len, direction, eng_id = null) {
    local ax = AIMap.GetTileX(stA_tile);
    local ay = AIMap.GetTileY(stA_tile);
    local bx = AIMap.GetTileX(stB_tile);
    local by = AIMap.GetTileY(stB_tile);

    AILog.Info("ConnectStations: A=(" + ax + "," + ay + ") B=(" + bx + "," + by + ")");

    local sources = [];
    local goals = [];

    if (direction == AIRail.RAILTRACK_NE_SW) {
        sources.push([AIMap.GetTileIndex(ax - 1, ay),
                      AIMap.GetTileIndex(ax, ay)]);
        sources.push([AIMap.GetTileIndex(ax + platform_len, ay),
                      AIMap.GetTileIndex(ax + platform_len - 1, ay)]);
        goals.push([AIMap.GetTileIndex(bx - 1, by),
                    AIMap.GetTileIndex(bx, by)]);
        goals.push([AIMap.GetTileIndex(bx + platform_len, by),
                    AIMap.GetTileIndex(bx + platform_len - 1, by)]);
    } else {
        sources.push([AIMap.GetTileIndex(ax, ay - 1),
                      AIMap.GetTileIndex(ax, ay)]);
        sources.push([AIMap.GetTileIndex(ax, ay + platform_len),
                      AIMap.GetTileIndex(ax, ay + platform_len - 1)]);
        goals.push([AIMap.GetTileIndex(bx, by - 1),
                    AIMap.GetTileIndex(bx, by)]);
        goals.push([AIMap.GetTileIndex(bx, by + platform_len),
                    AIMap.GetTileIndex(bx, by + platform_len - 1)]);
    }

    foreach (pair in sources) {
        if (!AIMap.IsValidTile(pair[0]) || !AIMap.IsValidTile(pair[1])) {
            AILog.Warning("Invalid rail source endpoint pair");
            return false;
        }
    }
    foreach (pair in goals) {
        if (!AIMap.IsValidTile(pair[0]) || !AIMap.IsValidTile(pair[1])) {
            AILog.Warning("Invalid rail goal endpoint pair");
            return false;
        }
    }

    local source_entry_ok = false;
    foreach (pair in sources) {
        if (this.ValidateEntryExit(pair[0], 1)) {
            source_entry_ok = true;
            break;
        }
    }
    local goal_entry_ok = false;
    foreach (pair in goals) {
        if (this.ValidateEntryExit(pair[0], 1)) {
            goal_entry_ok = true;
            break;
        }
    }
    if (!source_entry_ok || !goal_entry_ok) {
        AILog.Warning("Rail entry/exit validation failed before path build");
        return false;
    }

    AILog.Info("Pathfinder searching via AAAHogEx RailPathBuilder...");
    local dist = AIMap.DistanceManhattan(stA_tile, stB_tile);
    local limitCount = 600;

    // Build simple shuttle lines without auto one-way signals.
    // This avoids terminal signal lockups on straight, crossing-free routes.
    local builder = RailPathBuilder();
    builder.Initialize(Container(sources), Container(goals), [], limitCount, null);
    builder.pathBuildParams = {
        engine = (eng_id != null && AIEngine.IsValidEngine(eng_id)) ? eng_id : null,
        cargo = null,
        distance = dist,
        platformLength = platform_len,
        isSingle = true,
        isOneway = false,
        isBiDirectional = true
    };

    local built = builder.Build();
    if (built != true) {
        if (built == null) {
            AILog.Warning("AAAHogEx RailPathBuilder returned null in forward direction; trying reverse");
        } else {
            AILog.Warning("AAAHogEx RailPathBuilder failed in forward direction; trying reverse");
        }

        local builder2 = RailPathBuilder();
        builder2.Initialize(Container(goals), Container(sources), [], limitCount * 2, null);
        builder2.pathBuildParams = {
            engine = (eng_id != null && AIEngine.IsValidEngine(eng_id)) ? eng_id : null,
            cargo = null,
            distance = dist,
            platformLength = platform_len,
            isSingle = true,
            isOneway = false,
            isBiDirectional = true
        };

        local reverse_built = builder2.Build();
        if (reverse_built != true) {
            if (reverse_built == null) {
                AILog.Warning("AAAHogEx RailPathBuilder returned null in reverse direction");
            } else {
                AILog.Warning("AAAHogEx RailPathBuilder failed both directions");
            }
            return false;
        }
    }

    AILog.Info("Rail connection complete.");
    return true;
}

// -----------------------------------------------------------------------
// Depot building
// -----------------------------------------------------------------------
function SquirrelAI::_IsDepotConnectedToRail(depot_tile) {
    if (!AIMap.IsValidTile(depot_tile)) return false;
    if (!AIRail.IsRailDepotTile(depot_tile)) return false;

    local front = AIRail.GetRailDepotFrontTile(depot_tile);
    if (!AIMap.IsValidTile(front)) return false;

    local fx = AIMap.GetTileX(front);
    local fy = AIMap.GetTileY(front);

    local connected = [];
    local has_straight_continuation = false;
    local continuing_branches = 0;
    foreach (off in [[1, 0], [-1, 0], [0, 1], [0, -1]]) {
        local adj = AIMap.GetTileIndex(fx + off[0], fy + off[1]);
        if (!AIMap.IsValidTile(adj)) continue;
        if (adj == depot_tile) continue;
        if (AIRail.IsRailDepotTile(adj)) continue;
        if (!AIRail.IsRailTile(adj) && !AIRail.IsRailStationTile(adj)) continue;

        if (!AIRail.AreTilesConnected(adj, front, depot_tile)) continue;
        connected.push(adj);

        local ax = AIMap.GetTileX(adj);
        local ay = AIMap.GetTileY(adj);
        local dir_x = ax - fx;
        local dir_y = ay - fy;

        local branch_continues = false;
        foreach (next_off in [[1, 0], [-1, 0], [0, 1], [0, -1]]) {
            local next = AIMap.GetTileIndex(ax + next_off[0], ay + next_off[1]);
            if (!AIMap.IsValidTile(next)) continue;
            if (next == front || next == depot_tile) continue;
            if (AIRail.IsRailDepotTile(next)) continue;
            if (!AIRail.IsRailTile(next) && !AIRail.IsRailStationTile(next)) continue;
            if (!AIRail.AreTilesConnected(next, adj, front)) continue;

            branch_continues = true;
            if (next_off[0] == dir_x && next_off[1] == dir_y) {
                has_straight_continuation = true;
            }
        }

        if (branch_continues) {
            continuing_branches++;
        }
    }

    if (connected.len() == 0) return false;

    // A single branch must continue straight long enough to avoid the
    // immediate double-turn pattern that can trap trains leaving the depot.
    // With two or more continuing branches, the front tile is a usable Y/junction.
    return has_straight_continuation || continuing_branches >= 2;
}

function SquirrelAI::_ConnectDepotCandidate(depot_tile, exit_tile, st_end_tile, far_tile) {
    if (!AIMap.IsValidTile(depot_tile) || !AIMap.IsValidTile(exit_tile)) return false;
    if (!AIRail.IsRailDepotTile(depot_tile)) return false;

    if (AIMap.IsValidTile(st_end_tile) &&
        !AIRail.AreTilesConnected(st_end_tile, exit_tile, depot_tile)) {
        AIRail.BuildRail(st_end_tile, exit_tile, depot_tile);
        AIRail.BuildRail(depot_tile, exit_tile, st_end_tile);
    }

    if (AIMap.IsValidTile(far_tile) && AIRail.IsRailTile(far_tile) &&
        !AIRail.AreTilesConnected(far_tile, exit_tile, depot_tile)) {
        AIRail.BuildRail(far_tile, exit_tile, depot_tile);
        AIRail.BuildRail(depot_tile, exit_tile, far_tile);
    }

    // If still not valid, try connecting the depot exit to any adjacent rail
    // neighbors to create a small local junction accessible from both sides.
    if (!this._IsDepotConnectedToRail(depot_tile)) {
        local ex = AIMap.GetTileX(exit_tile);
        local ey = AIMap.GetTileY(exit_tile);
        foreach (off in [[1, 0], [-1, 0], [0, 1], [0, -1]]) {
            local near = AIMap.GetTileIndex(ex + off[0], ey + off[1]);
            if (!AIMap.IsValidTile(near)) continue;
            if (near == depot_tile) continue;
            if (!AIRail.IsRailTile(near) && !AIRail.IsRailStationTile(near)) continue;
            if (AIRail.AreTilesConnected(near, exit_tile, depot_tile)) continue;

            AIRail.BuildRail(near, exit_tile, depot_tile);
            AIRail.BuildRail(depot_tile, exit_tile, near);
        }
    }

    return this._IsDepotConnectedToRail(depot_tile);
}

function SquirrelAI::_BuildDepotSomewhereOnRoute(stA_tile, stB_tile) {
    local dist = AIMap.DistanceManhattan(stA_tile, stB_tile);
    if (dist <= 10) return -1;

    // Check at 1/4, 1/2, 3/4 along the way
    local ax = AIMap.GetTileX(stA_tile);
    local ay = AIMap.GetTileY(stA_tile);
    local bx = AIMap.GetTileX(stB_tile);
    local by = AIMap.GetTileY(stB_tile);

    local fractions = [0.5, 0.25, 0.75, 0.125, 0.875];
    foreach(f in fractions) {
        local cx = ax + ((bx - ax) * f).tointeger();
        local cy = ay + ((by - ay) * f).tointeger();
        local center_tile = AIMap.GetTileIndex(cx, cy);
        if (!AIMap.IsValidTile(center_tile)) continue;

        local depot = this._TryBuildDepotOnConnectedRail(center_tile, 10, -1);
        if (depot != -1) return depot;
    }
    return -1;
}

function SquirrelAI::_TryBuildDepotOnConnectedRail(center_tile, max_radius = 8, restrict_station_id = null) {
    local sx = AIMap.GetTileX(center_tile);
    local sy = AIMap.GetTileY(center_tile);
    if (restrict_station_id == null) {
        if (AIRail.IsRailStationTile(center_tile)) {
            restrict_station_id = AIStation.GetStationID(center_tile);
        } else {
            restrict_station_id = -1;
        }
    }
    local candidates = [];

    for (local r = 1; r <= max_radius; r++) {
        for (local dx = -r; dx <= r; dx++) {
            for (local dy = -r; dy <= r; dy++) {
                if (this._abs(dx) != r && this._abs(dy) != r) continue;

                local front = AIMap.GetTileIndex(sx + dx, sy + dy);
                if (!AIMap.IsValidTile(front)) continue;
                if (AIRail.IsRailDepotTile(front)) continue;
                if (!AIRail.IsRailTile(front) && !AIRail.IsRailStationTile(front)) continue;
                if (!AICompany.IsMine(AITile.GetOwner(front))) continue;

                if (restrict_station_id != -1 && AIRail.IsRailStationTile(front) &&
                    AIStation.IsValidStation(restrict_station_id) &&
                    AIStation.GetStationID(front) != restrict_station_id) {
                    continue;
                }

                local score = 180 - (r * 8);
                if (!AIRail.IsRailStationTile(front)) score += 20;

                local fx = AIMap.GetTileX(front);
                local fy = AIMap.GetTileY(front);
                foreach (off in [[1, 0], [-1, 0], [0, 1], [0, -1]]) {
                    local depot = AIMap.GetTileIndex(fx + off[0], fy + off[1]);
                    if (!AIMap.IsValidTile(depot)) continue;
                    if (!AITile.IsBuildable(depot)) continue;

                    candidates.push({
                        depot = depot,
                        front = front,
                        score = score - AIMap.DistanceManhattan(depot, center_tile)
                    });
                }
            }
        }
    }

    if (candidates.len() == 0) return -1;

    candidates.sort(function(a, b) {
        if (a.score == b.score) return 0;
        return (a.score > b.score) ? -1 : 1;
    });

    foreach (cand in candidates) {
        if (!AIRail.BuildRailDepot(cand.depot, cand.front)) continue;

        if (this._IsDepotConnectedToRail(cand.depot)) {
            AILog.Info("[BUILD:FALLBACK] Rail depot at (" +
                       AIMap.GetTileX(cand.depot) + "," + AIMap.GetTileY(cand.depot) +
                       ") on connected rail front");
            return cand.depot;
        }

        AITile.DemolishTile(cand.depot);
    }

    return -1;
}

function SquirrelAI::BuildDepotNearStation(station_tile, platform_len, direction) {
    local sx = AIMap.GetTileX(station_tile);
    local sy = AIMap.GetTileY(station_tile);
    local candidates = [];

    // Check for existing rail depot nearby first
    for (local r = 1; r <= 6; r++) {
        for (local dx = -r; dx <= r; dx++) {
            for (local dy = -r; dy <= r; dy++) {
                if (this._abs(dx) != r && this._abs(dy) != r) continue;
                local tile = AIMap.GetTileIndex(sx + dx, sy + dy);
                if (!AIMap.IsValidTile(tile)) continue;
                if (AIRail.IsRailDepotTile(tile)) {
                    if (!this._IsDepotConnectedToRail(tile)) {
                        AILog.Info("[SKIP] Disconnected nearby depot at (" +
                                   (sx + dx) + "," + (sy + dy) + ")");
                        continue;
                    }
                    AILog.Info("[REUSE] Rail depot at (" +
                               (sx + dx) + "," + (sy + dy) + ")");
                    return tile;
                }
            }
        }
    }

    // Each exit: exit tile, station-end tile, far tile (mainline side), perpendicular offset
    local exits = [];
    if (direction == AIRail.RAILTRACK_NE_SW) {
        exits.push({ exit   = AIMap.GetTileIndex(sx - 1, sy),
                     st_end = AIMap.GetTileIndex(sx, sy),
                     far    = AIMap.GetTileIndex(sx - 2, sy),
                     perp_x = 0, perp_y = 1 });
        exits.push({ exit   = AIMap.GetTileIndex(sx + platform_len, sy),
                     st_end = AIMap.GetTileIndex(sx + platform_len - 1, sy),
                     far    = AIMap.GetTileIndex(sx + platform_len + 1, sy),
                     perp_x = 0, perp_y = 1 });
    } else {
        exits.push({ exit   = AIMap.GetTileIndex(sx, sy - 1),
                     st_end = AIMap.GetTileIndex(sx, sy),
                     far    = AIMap.GetTileIndex(sx, sy - 2),
                     perp_x = 1, perp_y = 0 });
        exits.push({ exit   = AIMap.GetTileIndex(sx, sy + platform_len),
                     st_end = AIMap.GetTileIndex(sx, sy + platform_len - 1),
                     far    = AIMap.GetTileIndex(sx, sy + platform_len + 1),
                     perp_x = 1, perp_y = 0 });
    }

    // Prefer the exit connected to mainline track (pathfinder built there)
    local sorted = [];
    foreach (e in exits) {
        if (AIMap.IsValidTile(e.far) && AIRail.IsRailTile(e.far)) {
            sorted.insert(0, e);
        } else {
            sorted.push(e);
        }
    }

    foreach (e in sorted) {
        local ex = AIMap.GetTileX(e.exit);
        local ey = AIMap.GetTileY(e.exit);

        foreach (sign in [-1, 1]) {
            local depot = AIMap.GetTileIndex(
                ex + e.perp_x * sign,
                ey + e.perp_y * sign
            );
            if (!AIMap.IsValidTile(depot)) continue;
            if (!AITile.IsBuildable(depot)) continue;

            local score = this.ScoreRailDepotTile(depot, e.exit, station_tile, direction);
            if (AIMap.IsValidTile(e.far) && AIRail.IsRailTile(e.far)) {
                score += 30;
            }

            candidates.push({
                depot = depot,
                exit = e.exit,
                st_end = e.st_end,
                far = e.far,
                score = score
            });
        }
    }

    if (candidates.len() == 0) {
        AILog.Warning("Could not build depot near station at (" + sx + "," + sy + ")");
        return -1;
    }

    candidates.sort(function(a, b) {
        if (a.score == b.score) return 0;
        return (a.score > b.score) ? -1 : 1;
    });

    foreach (cand in candidates) {
        for (local retry = 0; retry < 3; retry++) {
            if (AIRail.BuildRailDepot(cand.depot, cand.exit)) {
                AILog.Info("[BUILD] Rail depot at (" +
                    AIMap.GetTileX(cand.depot) + "," + AIMap.GetTileY(cand.depot) +
                    ") score=" + cand.score);

                if (this._ConnectDepotCandidate(cand.depot, cand.exit, cand.st_end, cand.far)) {
                    return cand.depot;
                }

                AILog.Info("[SKIP] Depot candidate was not connected; retrying other candidates");
                AITile.DemolishTile(cand.depot);
            }

            if (AIError.GetLastError() == AIError.ERR_VEHICLE_IN_THE_WAY) {
                AIController.Sleep(3);
                continue;
            }
            break;
        }
    }

    local fallback_depot = this._TryBuildDepotOnConnectedRail(station_tile);
    if (fallback_depot != -1) return fallback_depot;

    AILog.Warning("Could not build depot near station at (" + sx + "," + sy + ")");
    return -1;
}

// -----------------------------------------------------------------------
// Vehicle purchase & orders
// -----------------------------------------------------------------------

function SquirrelAI::BuyTrain(depot, stA_id, stB_id, eng_id, wagon_list) {
    local veh = AIVehicle.BuildVehicle(depot, eng_id);
    if (!AIVehicle.IsValidVehicle(veh)) {
        AILog.Warning("Failed to buy engine " + eng_id +
                      ": " + AIError.GetLastErrorString());
        return -1;
    }
    AILog.Info("Bought engine: veh_id=" + veh);

    foreach (wg in wagon_list) {
        for (local i = 0; i < wg.count; i++) {
            local w = AIVehicle.BuildVehicle(depot, wg.id);
            if (AIVehicle.IsValidVehicle(w)) {
                AIVehicle.MoveWagonChain(w, 0, veh, AIVehicle.GetNumWagons(veh) - 1);
            } else {
                AILog.Warning("Failed to buy wagon " + wg.id +
                              ": " + AIError.GetLastErrorString());
            }
        }
    }

    local stA_tile = AIStation.GetLocation(stA_id);
    local stB_tile = AIStation.GetLocation(stB_id);

    AIOrder.AppendOrder(veh, stA_tile, AIOrder.OF_FULL_LOAD_ANY);
    AIOrder.AppendOrder(veh, stB_tile, AIOrder.OF_UNLOAD | AIOrder.OF_NO_LOAD);

    AIVehicle.StartStopVehicle(veh);
    AILog.Info("Train dispatched: veh_id=" + veh +
               " wagons=" + AIVehicle.GetNumWagons(veh));
    return veh;
}



