// SquirrelAI/air.nut - Aircraft route building
//
// Handles: PLN (passenger planes, town-to-town, bare integer town IDs)
//          CPL (cargo planes, industry-to-industry OR industry-to-town, t/i prefix IDs)
//
// Key API behaviours:
//   - AIAirport.BuildAirport(tile, type, station_id) needs flat land
//   - Airports have built-in hangars — no separate depot needed
//   - AIAirport.GetHangarOfAirport(tile) returns the hangar tile
//   - AIEngine.GetPlaneType() → PT_SMALL_PLANE, PT_BIG_PLANE, PT_HELICOPTER
//   - Big planes need AT_LARGE or bigger; crash frequently on small airports
//   - Town noise limits may prevent airport construction (BuildAirport fails)
//   - AIVehicle.RefitVehicle(veh, cargo) refits a vehicle in a depot/hangar

// -----------------------------------------------------------------------
// Entry points
// -----------------------------------------------------------------------

function SquirrelAI::BuildPlaneRoute(from_id, to_id, eng_id, count = 1) {
    AILog.Info("BuildPlaneRoute: town " + from_id + " -> town " + to_id +
               " eng=" + eng_id + " count=" + count);

    if (!AIEngine.IsValidEngine(eng_id)) {
        this.WriteReply("ERR:PLN:" + from_id + ":" + to_id + ":NO_ENGINE");
        return;
    }
    if (!AITown.IsValidTown(from_id)) {
        this.WriteReply("ERR:PLN:" + from_id + ":" + to_id + ":BAD_TOWN");
        return;
}
    if (!AITown.IsValidTown(to_id)) {
        this.WriteReply("ERR:PLN:" + from_id + ":" + to_id + ":BAD_TOWN");
        return;
    }

    local from_tile = AITown.GetLocation(from_id);
    local to_tile   = AITown.GetLocation(to_id);

    this._BuildAirRoute(from_tile, to_tile, eng_id, "PLN",
                         from_id, to_id, false, -1, count);
}

function SquirrelAI::BuildCargoPlaneRoute(from_str, to_str, eng_id, cargo_label = "", count = 1) {
    AILog.Info("BuildCargoPlaneRoute: " + from_str + " -> " + to_str +
               " eng=" + eng_id + " cargo=" + cargo_label + " count=" + count);

    if (!AIEngine.IsValidEngine(eng_id)) {
        this.WriteReply("ERR:CPL:" + from_str + ":" + to_str + ":NO_ENGINE");
        return;
    }

    // Source must be an industry (cargo producer)
    if (from_str.len() < 2 ||
            (from_str.slice(0,1) != "i" && from_str.slice(0,1) != "I")) {
        this.WriteReply("ERR:CPL:" + from_str + ":" + to_str + ":BAD_IND");
        return;
    }

    local from_loc = this._ResolveLoc(from_str);
    local to_loc   = this._ResolveLoc(to_str);

    if (from_loc == null || to_loc == null) {
        this.WriteReply("ERR:CPL:" + from_str + ":" + to_str + ":BAD_LOC");
        return;
    }
    AILog.Info("Source: " + from_loc.label + "  Dest: " + to_loc.label);

    // Determine cargo — explicit label overrides auto-detect
    local cargo_id = -1;
    if (cargo_label.len() > 0) {
        cargo_id = this._ResolveCargo(cargo_label);
        if (cargo_id != -1 && !AIEngine.CanRefitCargo(eng_id, cargo_id)) {
            AILog.Warning("Engine " + eng_id + " cannot refit to " + cargo_label);
            this.WriteReply("ERR:CPL:" + from_str + ":" + to_str + ":BAD_REFIT");
            return;
        }
    }
    if (cargo_id == -1) {
        cargo_id = this._FindCompatibleCargo(from_str, to_str, eng_id);
    }
    if (cargo_id == -1) {
        AILog.Warning("No compatible cargo: " + from_str + " -> " + to_str);
        this.WriteReply("ERR:CPL:" + from_str + ":" + to_str + ":NO_CARGO");
        return;
    }

    // Validate explicit or auto-selected cargo against source production and destination acceptance.
    local from_id = from_str.slice(1).tointeger();
    local produced = AICargoList_IndustryProducing(from_id);
    if (!produced.HasItem(cargo_id)) {
        AILog.Warning("Source " + from_str + " does not produce cargo " +
                      AICargo.GetCargoLabel(cargo_id));
        this.WriteReply("ERR:CPL:" + from_str + ":" + to_str + ":NO_CARGO");
        return;
    }

    local destination_ok = false;
    local airport_catchment = this._StationCatchmentRadius(AIStation.STATION_AIRPORT);
    if (to_str.len() >= 2) {
        local to_prefix = to_str.slice(0, 1);
        local to_id = to_str.slice(1).tointeger();
        if (to_prefix == "i" || to_prefix == "I") {
            if (AIIndustry.IsValidIndustry(to_id)) {
                local accepted = AICargoList_IndustryAccepting(to_id);
                destination_ok = accepted.HasItem(cargo_id);
            }
        } else if (to_prefix == "t" || to_prefix == "T") {
            if (AITown.IsValidTown(to_id)) {
                local to_tile = AITown.GetLocation(to_id);
                destination_ok = (AITile.GetCargoAcceptance(to_tile, cargo_id, 1, 1,
                                                            airport_catchment) >= 8);
            }
        }
    }

    if (!destination_ok) {
        AILog.Warning("Destination " + to_str + " does not accept cargo " +
                      AICargo.GetCargoLabel(cargo_id));
        this.WriteReply("ERR:CPL:" + from_str + ":" + to_str + ":NO_CARGO");
        return;
    }

    AILog.Info("Selected cargo ID: " + cargo_id);

    this._BuildAirRoute(from_loc.tile, to_loc.tile, eng_id, "CPL",
                         from_str, to_str, true, cargo_id, count);
}

// -----------------------------------------------------------------------
// Shared route builder
// -----------------------------------------------------------------------

function SquirrelAI::_BuildAirRoute(from_tile, to_tile, eng_id, prefix,
                                     from_id, to_id, is_cargo, cargo_id, count = 1) {
    // Determine suitable airport types for this engine
    local apt_types = this._GetAirportTypes(eng_id);
    if (apt_types.len() == 0) {
        AILog.Warning("No airport type available for engine " + eng_id);
        this.WriteReply("ERR:" + prefix + ":" + from_id + ":" + to_id + ":NO_APT_TYPE");
        return;
    }

    // AAAHogEx-like passenger behavior: qualify by town cargo acceptance,
    // not strict town-center tile coverage.
    local passenger_cargo_id = this.GetPassengerCargo();
    local airport_match_cargo_id = is_cargo ? cargo_id : passenger_cargo_id;
    local from_require_acceptance = !is_cargo;
    local to_require_acceptance = !is_cargo;
    local from_coverage_tile = -1;
    local to_coverage_tile = -1;

    // Build/find airport A (source)
    local apA = this.FindOrBuildAirport(
        from_tile,
        apt_types,
        eng_id,
        airport_match_cargo_id,
        from_require_acceptance,
        is_cargo && cargo_id != -1,
        from_coverage_tile
    );
    if (apA == null) {
        this.WriteReply("ERR:" + prefix + ":" + from_id + ":" + to_id + ":NO_SPACE");
        return;
    }

    AILog.Info("Airport A: tile=" + apA.tile + " station_id=" + apA.station_id);

    // Build/find airport B (destination)
    local apB = this.FindOrBuildAirport(
        to_tile,
        apt_types,
        eng_id,
        airport_match_cargo_id,
        to_require_acceptance,
        false,
        to_coverage_tile
    );
    if (apB == null) {
        this.WriteReply("ERR:" + prefix + ":" + from_id + ":" + to_id + ":NO_SPACE");
        return;
    }
    AILog.Info("Airport B: tile=" + apB.tile + " station_id=" + apB.station_id);

    local apA_tile = this._GetAirportReferenceTile(apA.station_id);
    local apB_tile = this._GetAirportReferenceTile(apB.station_id);
    if (!AIMap.IsValidTile(apA_tile)) apA_tile = apA.tile;
    if (!AIMap.IsValidTile(apB_tile)) apB_tile = apB.tile;

    if (is_cargo && cargo_id != -1) {
        local apA_type = AIAirport.GetAirportType(apA_tile);
        local apB_type = AIAirport.GetAirportType(apB_tile);

        if (!this._AirportAreaMatchesCargo(apA_tile, apA_type, cargo_id, false, true)) {
            AILog.Warning("Source airport cargo coverage mismatch after build/reuse");
            this.WriteReply("ERR:" + prefix + ":" + from_id + ":" + to_id + ":NO_CARGO");
            return;
        }
        if (!this._AirportAreaMatchesCargo(apB_tile, apB_type, cargo_id, true, false)) {
            AILog.Warning("Destination airport cargo coverage mismatch after build/reuse");
            this.WriteReply("ERR:" + prefix + ":" + from_id + ":" + to_id + ":NO_CARGO");
            return;
        }
    }

    // Get hangar from airport A (planes are built and serviced here)
    local hangar = AIAirport.GetHangarOfAirport(apA_tile);
    if (!AIMap.IsValidTile(hangar)) {
        AILog.Warning("Could not find hangar at airport A");
        this.WriteReply("ERR:" + prefix + ":" + from_id + ":" + to_id + ":NO_HANGAR");
        return;
    }

    local hangar_owner = AITile.GetOwner(hangar);
    if (!AICompany.IsMine(hangar_owner)) {
        AILog.Warning("Hangar not owned by this company (owner=" + hangar_owner + ")");
        this.WriteReply("ERR:" + prefix + ":" + from_id + ":" + to_id + ":NO_HANGAR");
        return;
    }

    // Buy plane and set orders
    local lead_plane = -1;
    for (local i = 0; i < count; i++) {
        local plane = this.BuyPlane(hangar, apA.station_id, apB.station_id, eng_id, is_cargo, cargo_id);
        if (plane == -1) {
            if (i == 0) {
                return this.WriteReply("ERR:" + prefix + ":" + from_id + ":" + to_id + ":NO_FUNDS");
            } else {
                AILog.Warning("Ran out of funds after buying " + i + " planes");
                break;
            }
        }
        if (i == 0) lead_plane = plane;
    }

    this.WriteReply("DONE:" + prefix + ":" + from_id + ":" + to_id);
}

// -----------------------------------------------------------------------
// Airport type selection
//
// Returns an ordered list of airport types suitable for the engine,
// from smallest (cheapest) to largest. Only includes types available
// in the current game year.
// -----------------------------------------------------------------------

function SquirrelAI::_GetAirportTypes(eng_id) {
    local plane_type = AIEngine.GetPlaneType(eng_id);
    local types = [];

    if (plane_type == AIAirport.PT_SMALL_PLANE) {
        // Small planes can use any fixed-wing airport
        local candidates = [
            AIAirport.AT_SMALL, AIAirport.AT_COMMUTER,
            AIAirport.AT_LARGE, AIAirport.AT_METROPOLITAN,
            AIAirport.AT_INTERNATIONAL, AIAirport.AT_INTERCON
        ];
        foreach (at in candidates) {
            if (AIAirport.IsAirportInformationAvailable(at)) types.push(at);
        }
    } else if (plane_type == AIAirport.PT_BIG_PLANE) {
        // Big planes need AT_LARGE or bigger (high crash risk on small airports)
        local candidates = [
            AIAirport.AT_LARGE, AIAirport.AT_METROPOLITAN,
            AIAirport.AT_INTERNATIONAL, AIAirport.AT_INTERCON
        ];
        foreach (at in candidates) {
            if (AIAirport.IsAirportInformationAvailable(at)) types.push(at);
    }
    } else {
        // Helicopters: dedicated heliports and airports with helipads
        local candidates = [
    AIAirport.AT_HELIDEPOT, AIAirport.AT_HELISTATION,
            AIAirport.AT_HELIPORT
        ];
        foreach (at in candidates) {
    if (AIAirport.IsAirportInformationAvailable(at)) types.push(at);
        }
    }

    return types;
}

function SquirrelAI::_GetAirportReferenceTile(station_id) {
    local base_tile = AIStation.GetLocation(station_id);
    if (!AIMap.IsValidTile(base_tile)) return -1;

    local bx = AIMap.GetTileX(base_tile);
    local by = AIMap.GetTileY(base_tile);
    local best_tile = -1;
    local best_x = 999999;
    local best_y = 999999;

    for (local dx = -12; dx <= 12; dx++) {
        for (local dy = -12; dy <= 12; dy++) {
            local tx = bx + dx;
            local ty = by + dy;
            if (tx < 0 || ty < 0) continue;
            if (tx >= AIMap.GetMapSizeX()) continue;
            if (ty >= AIMap.GetMapSizeY()) continue;

            local tile = AIMap.GetTileIndex(tx, ty);
            if (!AIMap.IsValidTile(tile)) continue;
            if (!AIAirport.IsAirportTile(tile)) continue;
            if (AIStation.GetStationID(tile) != station_id) continue;

            if (best_tile == -1 || ty < best_y || (ty == best_y && tx < best_x)) {
                best_tile = tile;
                best_x = tx;
                best_y = ty;
            }
        }
    }

    return best_tile;
}

// -----------------------------------------------------------------------
// Airport compatibility check
//
// Verifies that an existing airport's type can handle the given engine.
// Big planes on small airports have extreme crash risk in OpenTTD.
// ------------------------------------------------------------------

function SquirrelAI::_IsAirportSuitable(station_id, eng_id) {
    local tile = this._GetAirportReferenceTile(station_id);
    if (!AIMap.IsValidTile(tile)) return false;

    local apt_type = AIAirport.GetAirportType(tile);
    local plane_type = AIEngine.GetPlaneType(eng_id);

    if (plane_type == AIAirport.PT_BIG_PLANE) {
// Big planes: only AT_LARGE and above
        return (apt_type == AIAirport.AT_LARGE ||
                apt_type == AIAirport.AT_METROPOLITAN ||
                apt_type == AIAirport.AT_INTERNATIONAL ||
                apt_type == AIAirport.AT_INTERCON);
    }
    if (plane_type == AIAirport.PT_HELICOPTER) {
// Helicopters: heliports + airports with helipads
        return (apt_type == AIAirport.AT_HELIPORT ||
                apt_type == AIAirport.AT_HELIDEPOT ||
                apt_type == AIAirport.AT_HELISTATION ||
        apt_type == AIAirport.AT_METROPOLITAN ||
                apt_type == AIAirport.AT_INTERNATIONAL ||
                apt_type == AIAirport.AT_INTERCON);
    }
    // Small planes: any non-heliport airport is fine
    return (apt_type != AIAirport.AT_HELIPORT &&
            apt_type != AIAirport.AT_HELIDEPOT &&
            apt_type != AIAirport.AT_HELISTATION);
}

function SquirrelAI::_AirportAreaMatchesCargo(top_left_tile, airport_type, cargo_id,
                                               require_acceptance,
                                               require_production) {
    if (cargo_id == -1) return true;

    local sx = AIMap.GetTileX(top_left_tile);
    local sy = AIMap.GetTileY(top_left_tile);
    local w = AIAirport.GetAirportWidth(airport_type);
    local h = AIAirport.GetAirportHeight(airport_type);
    local catchment = this._StationCatchmentRadius(AIStation.STATION_AIRPORT);

    local has_acceptance = !require_acceptance;
    local has_production = !require_production;

    for (local x = 0; x < w; x++) {
        for (local y = 0; y < h; y++) {
            local tile = AIMap.GetTileIndex(sx + x, sy + y);
            if (!AIMap.IsValidTile(tile)) continue;

            local acceptance = AITile.GetCargoAcceptance(tile, cargo_id, 1, 1, catchment);
            local production = AITile.GetCargoProduction(tile, cargo_id, 1, 1, catchment);

            if (require_acceptance && acceptance >= 8) has_acceptance = true;
            if (require_production && production >= 1) has_production = true;

            if (has_acceptance && has_production) return true;
        }
    }

    return has_acceptance && has_production;
}

function SquirrelAI::_AirportAreaCoversTile(top_left_tile, airport_type, target_tile) {
    if (!AIMap.IsValidTile(target_tile)) return true;

    local sx = AIMap.GetTileX(top_left_tile);
    local sy = AIMap.GetTileY(top_left_tile);
    local tx = AIMap.GetTileX(target_tile);
    local ty = AIMap.GetTileY(target_tile);
    local w = AIAirport.GetAirportWidth(airport_type);
    local h = AIAirport.GetAirportHeight(airport_type);
    local catchment = this._StationCatchmentRadius(AIStation.STATION_AIRPORT);

    local min_x = tx - catchment;
    local max_x = tx + catchment;
    local min_y = ty - catchment;
    local max_y = ty + catchment;

    return (sx <= max_x &&
            sx + w - 1 >= min_x &&
            sy <= max_y &&
            sy + h - 1 >= min_y);
}

function SquirrelAI::_AirportHasLandAccess(top_left_tile, airport_type) {
    local sx = AIMap.GetTileX(top_left_tile);
    local sy = AIMap.GetTileY(top_left_tile);
    local w = AIAirport.GetAirportWidth(airport_type);
    local h = AIAirport.GetAirportHeight(airport_type);

    for (local x = -1; x <= w; x++) {
        for (local y = -1; y <= h; y++) {
            local inside_footprint = (x >= 0 && x < w && y >= 0 && y < h);
            if (inside_footprint) continue;

            local tile = AIMap.GetTileIndex(sx + x, sy + y);
            if (!AIMap.IsValidTile(tile)) continue;

            if (AIRoad.IsRoadTile(tile) || AITile.IsBuildable(tile)) return true;
        }
    }

    return false;
}

function SquirrelAI::_LevelAirportSiteAaaHogEx(tile, airport_type, is_test_mode) {
    local w = AIAirport.GetAirportWidth(airport_type);
    local h = AIAirport.GetAirportHeight(airport_type);
    return Rectangle(HgTile(tile), HgTile(tile + AIMap.GetTileIndex(w, h)))
        .LevelTiles(AIRail.RAILTRACK_NW_SE, is_test_mode);
}

function SquirrelAI::_BuildAirportWithAaaHogExLeveling(tile, airport_type) {
    local w = AIAirport.GetAirportWidth(airport_type);
    local h = AIAirport.GetAirportHeight(airport_type);

    if (this.isUseAirportNoise) {
        local authority_town = AIAirport.GetNearestTown(tile, airport_type);
        if (AITown.IsValidTown(authority_town)) {
            local allowed_noise = AITown.GetAllowedNoise(authority_town);
            if (AIAirport.GetNoiseLevelIncrease(tile, airport_type) > allowed_noise) {
                AILog.Info("[AIR] Skip tile " + tile + " type=" + airport_type +
                           " (noise limit exceeded)");
                return false;
            }
        }
    }

    {
        local test_mode = AITestMode();

        for (local x = 0; x < w; x++) {
            for (local y = 0; y < h; y++) {
                local check = tile + AIMap.GetTileIndex(x, y);
                if (!AIMap.IsValidTile(check) || !AITile.IsBuildable(check)) {
                    return false;
                }
            }
        }

        if (!AIAirport.BuildAirport(tile, airport_type, AIStation.STATION_NEW)) {
            local err = AIError.GetLastError();
            if (err == AIStation.ERR_STATION_TOO_MANY_STATIONS_IN_TOWN ||
                err == AIStation.ERR_STATION_TOO_CLOSE_TO_ANOTHER_STATION) {
                AILog.Info("[AIR] Skip tile " + tile + " type=" + airport_type +
                           " (station authority limit)");
                return false;
            }
        }

        if (!this._LevelAirportSiteAaaHogEx(tile, airport_type, true)) {
            AILog.Info("[AIR] Skip tile " + tile + " type=" + airport_type +
                       " (test leveling failed)");
            return false;
        }
    }

    if (!this._LevelAirportSiteAaaHogEx(tile, airport_type, false)) {
        AILog.Info("[AIR] Skip tile " + tile + " type=" + airport_type +
                   " (leveling failed)");
        return false;
    }

    if (!AIAirport.BuildAirport(tile, airport_type, AIStation.STATION_NEW)) {
        AILog.Info("[AIR] BuildAirport failed at tile " + tile + " type=" +
                   airport_type + " err=" + AIError.GetLastErrorString());
        return false;
    }
    return true;
}

// -----------------------------------------------------------------------
// Airport management: find existing or build new
//
// Reuses a nearby airport (within 15 tiles Manhattan distance) if it is
// compatible with the engine's plane type. Otherwise builds a new one,
// trying each type in the preference list from _GetAirportTypes.
// -----------------------------------------------------------------------

function SquirrelAI::FindOrBuildAirport(location_tile, apt_types, eng_id,
                                         cargo_id = -1,
                                         require_acceptance = false,
                                         require_production = false,
                                         coverage_tile = -1) {
    // Check for existing compatible airport nearby
    local station_list = AIStationList(AIStation.STATION_AIRPORT);
    for (local s = station_list.Begin(); !station_list.IsEnd(); s = station_list.Next()) {
        local st_tile = this._GetAirportReferenceTile(s);
        if (!AIMap.IsValidTile(st_tile)) continue;
        if (!AICompany.IsMine(AITile.GetOwner(st_tile))) {
            continue;
        }

        if (AIMap.DistanceManhattan(st_tile, location_tile) <= 15) {
            if (this._IsAirportSuitable(s, eng_id)) {
                local apt_type = AIAirport.GetAirportType(st_tile);
                if (!this._AirportHasLandAccess(st_tile, apt_type)) {
                    AILog.Info("[REUSE] Airport " + AIStation.GetName(s) +
                               " skipped (no land-side access)");
                    continue;
                }
                if (!this._AirportAreaMatchesCargo(st_tile, apt_type, cargo_id,
                                                   require_acceptance,
                                                   require_production)) {
                    if (cargo_id != -1) {
                        AILog.Info("[REUSE] Airport " + AIStation.GetName(s) +
                                   " skipped (cargo catchment mismatch)");
                    }
                    continue;
                }
                if (AIMap.IsValidTile(coverage_tile) &&
                    !this._AirportAreaCoversTile(st_tile, apt_type, coverage_tile)) {
                    AILog.Info("[REUSE] Airport " + AIStation.GetName(s) +
                               " skipped (outside town coverage)");
                    continue;
                }
                AILog.Info("[REUSE] Airport '" + AIStation.GetName(s) + "' at (" +
                           AIMap.GetTileX(st_tile) + "," + AIMap.GetTileY(st_tile) + ")");
                return { tile = st_tile, station_id = s };
            } else {
                AILog.Info("Nearby airport " + AIStation.GetName(s) +
                           " not suitable for engine " + eng_id + ", skipping");
            }
        }
    }

    // No suitable existing airport — build a new one
    // Try each type in preference order (smallest first)
    foreach (apt_type in apt_types) {
        local result = this.BuildAirportNear(
            location_tile,
            apt_type,
            cargo_id,
            require_acceptance,
            require_production,
            coverage_tile
        );
        if (result != null) return result;
    }

    return null;
}

// -----------------------------------------------------------------------
// Airport building: spiral search for flat buildable site
//
// Searches outward from center_tile in expanding rings (radius 3..25).
// For each candidate position, pre-filters by checking all tiles in the
// airport footprint are buildable, then attempts AIAirport.BuildAirport.
// The build call itself enforces flatness and noise limits.
// -----------------------------------------------------------------------

function SquirrelAI::BuildAirportNear(center_tile, airport_type,
                                       cargo_id = -1,
                                       require_acceptance = false,
                                       require_production = false,
                                       coverage_tile = -1) {
    local w  = AIAirport.GetAirportWidth(airport_type);
    local h  = AIAirport.GetAirportHeight(airport_type);
    local cx = AIMap.GetTileX(center_tile);
    local cy = AIMap.GetTileY(center_tile);
    local coverage_enabled = AIMap.IsValidTile(coverage_tile);
    local search_radius_max = 25;

    local coverage_min_sx = 0;
    local coverage_max_sx = 0;
    local coverage_min_sy = 0;
    local coverage_max_sy = 0;

    if (coverage_enabled) {
        local tx = AIMap.GetTileX(coverage_tile);
        local ty = AIMap.GetTileY(coverage_tile);
        local catchment = this._StationCatchmentRadius(AIStation.STATION_AIRPORT);

        coverage_min_sx = tx - catchment - (w - 1);
        coverage_max_sx = tx + catchment;
        coverage_min_sy = ty - catchment - (h - 1);
        coverage_max_sy = ty + catchment;

        local dx_limit = max(this._abs(coverage_min_sx - cx), this._abs(coverage_max_sx - cx));
        local dy_limit = max(this._abs(coverage_min_sy - cy), this._abs(coverage_max_sy - cy));
        search_radius_max = min(search_radius_max, max(dx_limit, dy_limit));
        if (search_radius_max < 3) search_radius_max = 3;
    }

    AILog.Info("Searching for " + w + "x" + h + " airport site near (" +
               cx + "," + cy + ")");

    for (local radius = 3; radius <= search_radius_max; radius++) {
        for (local dx = -radius; dx <= radius; dx++) {
            for (local dy = -radius; dy <= radius; dy++) {
                // Only check the perimeter of each ring
                if (this._abs(dx) != radius && this._abs(dy) != radius) continue;

                local sx = cx + dx;
                local sy = cy + dy;
                if (sx < 2 || sy < 2) continue;
                if (sx + w >= AIMap.GetMapSizeX() - 2) continue;
                if (sy + h >= AIMap.GetMapSizeY() - 2) continue;

                if (coverage_enabled &&
                    (sx < coverage_min_sx || sx > coverage_max_sx ||
                     sy < coverage_min_sy || sy > coverage_max_sy)) {
                    continue;
                }

                local tile = AIMap.GetTileIndex(sx, sy);
                if (!AIMap.IsValidTile(tile)) continue;

                // Pre-filter: check every tile in the footprint is buildable
                local can_build = true;
                for (local x = 0; x < w && can_build; x++) {
                    for (local y = 0; y < h && can_build; y++) {
                        local check = AIMap.GetTileIndex(sx + x, sy + y);
                        if (!AIMap.IsValidTile(check) || !AITile.IsBuildable(check)) {
                            can_build = false;
                        }
                    }
                }
                if (!can_build) continue;

                if (!this._AirportAreaMatchesCargo(tile, airport_type, cargo_id,
                                                   require_acceptance,
                                                   require_production)) {
                    continue;
                }

                if (!this._AirportHasLandAccess(tile, airport_type)) {
                    continue;
                }

                if (coverage_enabled &&
                    !this._AirportAreaCoversTile(tile, airport_type, coverage_tile)) {
                    continue;
                }

                // AAAHogEx-aligned flow: test + level terrain, then build.
                if (this._BuildAirportWithAaaHogExLeveling(tile, airport_type)) {
                    local st_id = AIStation.GetStationID(tile);
                    AILog.Info("[BUILD] Airport '" + AIStation.GetName(st_id) +
                               "' at (" + sx + "," + sy + ") type=" + airport_type);
                    return { tile = tile, station_id = st_id };
                }
            }
        }
    }

    AILog.Warning("Could not build airport type " + airport_type +
                  " near (" + cx + "," + cy + ")");
    return null;
}

// -----------------------------------------------------------------------
// Vehicle purchase: buy aircraft and set orders
//
// Passenger planes (PLN): full-load-any at both ends
// Cargo planes (CPL): full-load-any at source, force-unload at destination
// -----------------------------------------------------------------------

function SquirrelAI::BuyPlane(hangar, stA_id, stB_id, eng_id, is_cargo, cargo_id) {
    local veh = AIVehicle.BuildVehicle(hangar, eng_id);
    if (!AIVehicle.IsValidVehicle(veh)) {
        AILog.Warning("Failed to buy aircraft " + eng_id +
                      ": " + AIError.GetLastErrorString());
        return -1;
    }
    AILog.Info("Bought aircraft: veh_id=" + veh);

    // Refit cargo planes to the required cargo type
    if (is_cargo && cargo_id != -1) {
        if (!AIVehicle.RefitVehicle(veh, cargo_id)) {
            AILog.Warning("Failed to refit aircraft to cargo " + cargo_id +
                          ": " + AIError.GetLastErrorString());
            AIVehicle.SellVehicle(veh);
            return -1;
        }
        AILog.Info("Refitted aircraft to cargo " + cargo_id);
    }

    local stA_tile = AIStation.GetLocation(stA_id);
    local stB_tile = AIStation.GetLocation(stB_id);

    if (is_cargo) {
        // Cargo planes: wait for full load at source, force-unload at destination
        AIOrder.AppendOrder(veh, stA_tile, AIOrder.OF_FULL_LOAD_ANY);
        AIOrder.AppendOrder(veh, stB_tile, AIOrder.OF_UNLOAD | AIOrder.OF_NO_LOAD);
    } else {
        // Passenger planes: wait until full load at both ends.
        AIOrder.AppendOrder(veh, stA_tile, AIOrder.OF_FULL_LOAD_ANY);
        AIOrder.AppendOrder(veh, stB_tile, AIOrder.OF_FULL_LOAD_ANY);
    }

    AIVehicle.StartStopVehicle(veh);
    AILog.Info("Aircraft dispatched: veh_id=" + veh);
    return veh;
}

// _FindCompatibleCargo is defined in utils.nut (handles both industry and town destinations)

