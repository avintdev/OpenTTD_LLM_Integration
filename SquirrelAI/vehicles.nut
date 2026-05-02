// SquirrelAI/vehicles.nut - Post-deployment vehicle operations
//
// Handles: SEL, CLN, DEP, STP, RUN, ADW, RPL commands

function SquirrelAI::SellVehicle(veh_id) {
    AILog.Info("SellVehicle: " + veh_id);

    if (!AIVehicle.IsValidVehicle(veh_id)) {
        this.WriteReply("ERR:SEL:" + veh_id + ":INVALID_VEH");
        return;
    }

    // Stop the vehicle first — SendVehicleToDepot only works on moving vehicles
    if (AIVehicle.GetState(veh_id) != AIVehicle.VS_IN_DEPOT) {
        // Ensure vehicle is running so it can path to depot
        local state = AIVehicle.GetState(veh_id);
        if (state == AIVehicle.VS_STOPPED) {
            AIVehicle.StartStopVehicle(veh_id);
            AIController.Sleep(5);
        }
        AIVehicle.SendVehicleToDepot(veh_id);
    }

    // Wait up to ~90 seconds (ships/trains can be far from depot)
    local waited = 0;
    while (waited < 2700) {
        if (AIVehicle.GetState(veh_id) == AIVehicle.VS_IN_DEPOT) break;
        AIController.Sleep(10);
        waited += 10;
    }

    if (AIVehicle.GetState(veh_id) != AIVehicle.VS_IN_DEPOT) {
        this.WriteReply("ERR:SEL:" + veh_id + ":NO_DEPOT");
        return;
    }

    AIVehicle.SellVehicle(veh_id);
    this.WriteReply("DONE:SEL:" + veh_id);
}

function SquirrelAI::CloneVehicle(veh_id, count) {
    AILog.Info("CloneVehicle: " + veh_id + " x" + count);

    if (!AIVehicle.IsValidVehicle(veh_id)) {
        this.WriteReply("ERR:CLN:" + veh_id + ":INVALID_VEH");
        return;
    }

    local cloned = 0;
    for (local i = 0; i < count; i++) {
        // CloneVehicle(veh_id, share_orders)
        local new_veh = AIVehicle.CloneVehicle(
            AIVehicle.GetLocation(veh_id), veh_id, true);
        if (AIVehicle.IsValidVehicle(new_veh)) {
            AIVehicle.StartStopVehicle(new_veh);
            cloned++;
        } else {
            AILog.Warning("Clone failed: " + AIError.GetLastErrorString());
        }
    }

    if (cloned > 0) {
        this.WriteReply("DONE:CLN:" + veh_id + ":" + cloned);
    } else {
        this.WriteReply("ERR:CLN:" + veh_id + ":FAILED");
    }
}

function SquirrelAI::SendToDepot(veh_id) {
    AILog.Info("SendToDepot: " + veh_id);

    if (!AIVehicle.IsValidVehicle(veh_id)) {
        this.WriteReply("ERR:DEP:" + veh_id + ":INVALID_VEH");
        return;
    }

    if (AIVehicle.SendVehicleToDepot(veh_id)) {
        this.WriteReply("DONE:DEP:" + veh_id);
    } else {
        this.WriteReply("ERR:DEP:" + veh_id + ":FAILED");
    }
}

function SquirrelAI::StopVehicle(veh_id) {
    AILog.Info("StopVehicle: " + veh_id);

    if (!AIVehicle.IsValidVehicle(veh_id)) {
        this.WriteReply("ERR:STP:" + veh_id + ":INVALID_VEH");
        return;
    }

    if (AIVehicle.GetState(veh_id) == AIVehicle.VS_RUNNING) {
        AIVehicle.StartStopVehicle(veh_id);
    }
    this.WriteReply("DONE:STP:" + veh_id);
}

function SquirrelAI::StartVehicle(veh_id) {
    AILog.Info("StartVehicle: " + veh_id);

    if (!AIVehicle.IsValidVehicle(veh_id)) {
        this.WriteReply("ERR:RUN:" + veh_id + ":INVALID_VEH");
        return;
    }

    if (AIVehicle.GetState(veh_id) != AIVehicle.VS_RUNNING) {
        AIVehicle.StartStopVehicle(veh_id);
    }
    this.WriteReply("DONE:RUN:" + veh_id);
}

function SquirrelAI::AddWagons(veh_id, wagons_str) {
    AILog.Info("AddWagons: veh=" + veh_id + " wagons=" + wagons_str);

    if (!AIVehicle.IsValidVehicle(veh_id)) {
        this.WriteReply("ERR:ADW:" + veh_id + ":INVALID_VEH");
        return;
    }

    // Send to depot first
    if (AIVehicle.GetState(veh_id) != AIVehicle.VS_IN_DEPOT) {
        local state = AIVehicle.GetState(veh_id);
        if (state == AIVehicle.VS_STOPPED) {
            AIVehicle.StartStopVehicle(veh_id);
            AIController.Sleep(5);
        }
        AIVehicle.SendVehicleToDepot(veh_id);
        
        local waited = 0;
        while (waited < 2700) {
            if (AIVehicle.GetState(veh_id) == AIVehicle.VS_IN_DEPOT) break;
            AIController.Sleep(10);
            waited += 10;
        }
        if (AIVehicle.GetState(veh_id) != AIVehicle.VS_IN_DEPOT) {
            this.WriteReply("ERR:ADW:" + veh_id + ":NO_DEPOT");
            return;
        }
    }

    local depot = AIVehicle.GetLocation(veh_id);
    local wagon_list = this.ParseWagons(wagons_str);
    local added = 0;

    foreach (wg in wagon_list) {
        for (local i = 0; i < wg.count; i++) {
            local w = AIVehicle.BuildVehicle(depot, wg.id);
            if (AIVehicle.IsValidVehicle(w)) {
                AIVehicle.MoveWagonChain(w, 0, veh_id,
                    AIVehicle.GetNumWagons(veh_id) - 1);
                added++;
            } else {
                AILog.Warning("Failed to buy wagon " + wg.id +
                              ": " + AIError.GetLastErrorString());
            }
        }
    }

    // Restart the vehicle
    AIVehicle.StartStopVehicle(veh_id);
    this.WriteReply("DONE:ADW:" + veh_id + ":" + added);
}

function SquirrelAI::_CanEngineCarryCargo(eng_id, cargo_id) {
    if (!AICargo.IsValidCargo(cargo_id)) return true;

    if (AIEngine.GetCargoType(eng_id) == cargo_id) return true;

    return AIEngine.CanRefitCargo(eng_id, cargo_id);
}

// Build a conservative cargo profile for vehicles using old_eng_id.
// Includes old engine default cargo and any cargo currently loaded.
function SquirrelAI::_GetReplacementCargoProfile(old_eng_id) {
    local required = {};

    local default_cargo = AIEngine.GetCargoType(old_eng_id);
    if (AICargo.IsValidCargo(default_cargo)) {
        required.rawset(default_cargo, true);
    }

    local all_cargos = [];
    local cargo_list = AICargoList();
    for (local c = cargo_list.Begin(); !cargo_list.IsEnd(); c = cargo_list.Next()) {
        all_cargos.push(c);
    }

    local vehicles = AIVehicleList();
    for (local v = vehicles.Begin(); !vehicles.IsEnd(); v = vehicles.Next()) {
        if (!AIVehicle.IsValidVehicle(v)) continue;
        if (AIVehicle.GetEngineType(v) != old_eng_id) continue;

        foreach (c in all_cargos) {
            if (AIVehicle.GetCargoLoad(v, c) > 0) {
                required.rawset(c, true);
            }
        }
    }

    local result = [];
    foreach (c, _ in required) {
        result.push(c);
    }
    return result;
}

// Returns a list of aircraft using old_eng_id whose current orders contain
// at least one airport incompatible with new_eng_id.
function SquirrelAI::_GetAirReplacementConflicts(old_eng_id, new_eng_id) {
    local conflicts = [];
    local vehicles = AIVehicleList();

    for (local v = vehicles.Begin(); !vehicles.IsEnd(); v = vehicles.Next()) {
        if (!AIVehicle.IsValidVehicle(v)) continue;
        if (AIVehicle.GetVehicleType(v) != AIVehicle.VT_AIR) continue;
        if (AIVehicle.GetEngineType(v) != old_eng_id) continue;

        local order_count = AIOrder.GetOrderCount(v);
        for (local i = 0; i < order_count; i++) {
            local dest = AIOrder.GetOrderDestination(v, i);
            if (!AIMap.IsValidTile(dest)) continue;

            local station_id = AIStation.GetStationID(dest);
            if (!AIStation.IsValidStation(station_id)) continue;

            local suitable = true;
            try {
                suitable = this._IsAirportSuitable(station_id, new_eng_id);
            } catch (e) {
                // If suitability cannot be evaluated, treat as unsafe.
                suitable = false;
            }

            if (!suitable) {
                conflicts.push({
                    veh_id = v,
                    station_id = station_id,
                    order_index = i
                });
                break;
            }
        }
    }

    return conflicts;
}

function SquirrelAI::ReplaceEngine(old_eng_id, new_eng_id) {
    AILog.Info("ReplaceEngine: " + old_eng_id + " -> " + new_eng_id);

    if (!AIEngine.IsValidEngine(old_eng_id)) {
        this.WriteReply("ERR:RPL:" + old_eng_id + ":INVALID_OLD_ENG");
        return;
    }

    if (!AIEngine.IsValidEngine(new_eng_id)) {
        this.WriteReply("ERR:RPL:" + old_eng_id + ":INVALID_ENG");
        return;
    }

    local old_type = AIEngine.GetVehicleType(old_eng_id);
    local new_type = AIEngine.GetVehicleType(new_eng_id);
    if (old_type != new_type) {
        this.WriteReply("ERR:RPL:" + old_eng_id + ":BAD_TYPE");
        return;
    }

    // Guard against cross-cargo replacements that the new engine cannot carry.
    local required_cargos = this._GetReplacementCargoProfile(old_eng_id);
    foreach (cargo_id in required_cargos) {
        if (!this._CanEngineCarryCargo(new_eng_id, cargo_id)) {
            local label = AICargo.GetCargoLabel(cargo_id);
            AILog.Warning("RPL blocked: engine " + new_eng_id +
                          " cannot carry/refit cargo " + label +
                          " used by engine " + old_eng_id);
            this.WriteReply("ERR:RPL:" + old_eng_id + ":INCOMPATIBLE_CARGO");
            return;
        }
    }

    // Guard against plane-to-airport incompatibility crashes.
    if (old_type == AIVehicle.VT_AIR) {
        local conflicts = this._GetAirReplacementConflicts(old_eng_id, new_eng_id);
        if (conflicts.len() > 0) {
            local c = conflicts[0];
            AILog.Warning("RPL blocked: vehicle " + c.veh_id +
                          " has incompatible airport order '" +
                          AIStation.GetName(c.station_id) + "' for engine " +
                          new_eng_id + " (order=" + c.order_index + ")");
            this.WriteReply("ERR:RPL:" + old_eng_id + ":INCOMPATIBLE_AIRPORT");
            return;
        }
    }

    // Use the autoreplace API
    local group = AIGroup.GROUP_ALL;
    if (AIGroup.SetAutoReplace(group, old_eng_id, new_eng_id)) {
        this.WriteReply("DONE:RPL:" + old_eng_id + ":" + new_eng_id);
    } else {
        this.WriteReply("ERR:RPL:" + old_eng_id + ":FAILED");
    }
}
