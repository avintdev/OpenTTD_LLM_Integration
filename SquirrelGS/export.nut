// SquirrelGS/export.nut - Game state export functions
//
// All five export functions. Iterates game data and sends flat
// JSON-like packets to Python via GSAdmin.Send().

function SquirrelGS::ExportAll() {
    this.ExportInfo();
    this.ExportIndustries();
    this.ExportTowns();
    this.ExportCompanies();
    this.ExportEngines();
    this.ExportVehicles();
    this.ExportStations();
}

// One packet per produced cargo, then one per accepted cargo, per industry.
function SquirrelGS::ExportInfo() {
    local date = GSDate.GetCurrentDate();

    GSAdmin.Send({
        t      = "INFO",
        year   = GSDate.GetYear(date),
        month  = GSDate.GetMonth(date),
        day    = GSDate.GetDayOfMonth(date)
    });
}

function SquirrelGS::ExportIndustries() {
    local count    = 0;
    local ind_list = GSIndustryList();
    local station_tiles = [];
    local all_types = GSStation.STATION_TRAIN    | GSStation.STATION_AIRPORT |
                      GSStation.STATION_TRUCK_STOP | GSStation.STATION_BUS_STOP |
                      GSStation.STATION_DOCK;

    local st_list = GSStationList(all_types);
    for (local st = st_list.Begin(); !st_list.IsEnd(); st = st_list.Next()) {
        station_tiles.push(GSStation.GetLocation(st));
    }

    for (local ind = ind_list.Begin(); !ind_list.IsEnd(); ind = ind_list.Next()) {
        local loc     = GSIndustry.GetLocation(ind);
        local type_id = GSIndustry.GetIndustryType(ind);
        local type_nm = GSIndustryType.GetName(type_id);
        local ix      = GSMap.GetTileX(loc);
        local iy      = GSMap.GetTileY(loc);
        local is_coastal = this.IsCoastal(loc);
        local near_station = false;

        foreach (st_tile in station_tiles) {
            if (GSMap.DistanceManhattan(loc, st_tile) <= 4) {
                near_station = true;
                break;
            }
        }

        // Produced cargoes (use industry INSTANCE id, not type id)
        local prod_list = GSCargoList_IndustryProducing(ind);
        for (local cargo = prod_list.Begin(); !prod_list.IsEnd(); cargo = prod_list.Next()) {
            local prod  = GSIndustry.GetLastMonthProduction(ind, cargo);
            local trans = GSIndustry.GetLastMonthTransported(ind, cargo);

            GSAdmin.Send({
                t      = "IND",
                id     = ind,
                x      = ix,
                y      = iy,
                type   = type_nm,
                cargo  = this.CargoLabel(cargo),
                prod   = prod,
                trans_lm = trans,
                served = (trans > 0),
                served_lm = (trans > 0),
                near_station = near_station,
                role   = "produces",
                coastal = is_coastal
            });
            count++;
        }

        // Accepted cargoes (use industry INSTANCE id, not type id)
        local acc_list = GSCargoList_IndustryAccepting(ind);
        for (local cargo = acc_list.Begin(); !acc_list.IsEnd(); cargo = acc_list.Next()) {
            GSAdmin.Send({
                t      = "IND",
                id     = ind,
                x      = ix,
                y      = iy,
                type   = type_nm,
                cargo  = this.CargoLabel(cargo),
                prod   = 0,
                served = false,
                served_lm = false,
                trans_lm = 0,
                near_station = near_station,
                role   = "accepts",
                coastal = is_coastal
            });
            count++;
        }
    }

    GSAdmin.Send({t = "EXPORT_END", chunk = "industries"});
    GSLog.Info("[EXPORT] Industries done - " + count + " packets");
}

function SquirrelGS::ExportTowns() {
    local count     = 0;
    local town_list = GSTownList();

    for (local town = town_list.Begin(); !town_list.IsEnd(); town = town_list.Next()) {
        local loc = GSTown.GetLocation(town);
        local is_coastal = this.IsCoastal(loc);

        GSAdmin.Send({
            t       = "TOWN",
            id      = town,
            x       = GSMap.GetTileX(loc),
            y       = GSMap.GetTileY(loc),
            name    = GSTown.GetName(town),
            pop     = GSTown.GetPopulation(town),
            coastal = is_coastal
        });
        count++;
    }

    GSAdmin.Send({t = "EXPORT_END", chunk = "towns"});
    GSLog.Info("[EXPORT] Towns done - " + count + " packets");
}

function SquirrelGS::ExportCompanies() {
    local count = 0;
    for (local c = 0; c < 15; c++) {
        local resolved = GSCompany.ResolveCompanyID(c);
        if (resolved == GSCompany.COMPANY_INVALID) continue;

        local veh_count = 0;
        local mode = GSCompanyMode(resolved);
        local veh_list = GSVehicleList();
        for (local v = veh_list.Begin(); !veh_list.IsEnd(); v = veh_list.Next()) {
            veh_count++;
        }

        // API compatibility: some GS API versions expose company finance getters
        // as parameterized methods, while others use current GSCompanyMode context.
        local money = 0;
        local loan = 0;
        try {
            money = GSCompany.GetBankBalance(resolved);
        } catch (e) {
            money = GSCompany.GetBankBalance();
        }
        try {
            loan = GSCompany.GetLoanAmount(resolved);
        } catch (e) {
            loan = GSCompany.GetLoanAmount();
        }

        mode = null; // restore deity mode

        GSAdmin.Send({
            t     = "CO",
            id    = c,
            name  = GSCompany.GetName(resolved),
            money = money,
            loan  = loan,
            vehs  = veh_count
        });
        count++;
    }

    GSAdmin.Send({t = "EXPORT_END", chunk = "companies"});
    GSLog.Info("[EXPORT] Companies done - " + count + " packets");
}

function SquirrelGS::ExportEngines() {
    local count     = 0;
    local veh_types = [GSVehicle.VT_RAIL, GSVehicle.VT_ROAD,
                       GSVehicle.VT_WATER, GSVehicle.VT_AIR];
    local plane_speed_factor = 1;

    // OpenTTD applies plane-speed scaling (e.g. 1/4 speed). Export nominal AIR speed
    // by undoing this factor so values match engine list expectations.
    try {
        plane_speed_factor = GSGameSettings.GetValue("vehicle.plane_speed");
        if (plane_speed_factor <= 0) plane_speed_factor = 1;
    } catch (e) {
        plane_speed_factor = 1;
    }

    // Find a valid company to scope the engine list to currently-available engines.
    // GSEngineList in deity mode returns ALL defined engines (including future ones).
    // Wrapping in GSCompanyMode filters to only engines buildable this game year.
    local check_company = GSCompany.COMPANY_INVALID;
    for (local c = 0; c < 15; c++) {
        if (GSCompany.ResolveCompanyID(c) != GSCompany.COMPANY_INVALID) {
            check_company = c;
            break;
        }
    }

    if (check_company == GSCompany.COMPANY_INVALID) {
        GSLog.Warning("[EXPORT] No valid company found — engine list will be empty");
        GSAdmin.Send({t = "EXPORT_END", chunk = "engines"});
        return;
    }

    local mode = GSCompanyMode(check_company);

    foreach (vt in veh_types) {
        local eng_list = GSEngineList(vt);
        for (local e = eng_list.Begin(); !eng_list.IsEnd(); e = eng_list.Next()) {
            local name = GSEngine.GetName(e);
            if (name == null) continue;

            local cargo_type = GSEngine.GetCargoType(e);
            local power      = GSEngine.GetPower(e);
            local speed      = GSEngine.GetMaxSpeed(e);
            if (power < 0) power = 0;
            if (vt == GSVehicle.VT_AIR) {
                speed *= plane_speed_factor;
            }

            local pkt = {
                t           = "ENG",
                id          = e,
                name        = name,
                vtype       = this.VehTypeStr(vt),
                power       = power,
                speed       = speed,
                cargo       = this.CargoLabel(cargo_type),
                cap         = GSEngine.GetCapacity(e),
                reliability = GSEngine.GetReliability(e),
                price       = GSEngine.GetPrice(e),
                running_cost = GSEngine.GetRunningCost(e)
            };

            // Only trains distinguish engines from wagons
            if (vt == GSVehicle.VT_RAIL) {
                pkt.is_wagon <- (power == 0);
            }

            // Refit capabilities: list all cargoes this engine can carry
            local refit_labels = "";
            local cl = GSCargoList();
            for (local c = cl.Begin(); !cl.IsEnd(); c = cl.Next()) {
                if (GSEngine.CanRefitCargo(e, c)) {
                    if (refit_labels.len() > 0) refit_labels += ",";
                    refit_labels += this.CargoLabel(c);
                }
            }
            if (refit_labels.len() > 0) {
                pkt.refit <- refit_labels;
            }

            GSAdmin.Send(pkt);
            count++;
        }
    }


    mode = null;  // restore deity mode

    GSAdmin.Send({t = "EXPORT_END", chunk = "engines"});
    GSLog.Info("[EXPORT] Engines done - " + count + " packets");
}

function SquirrelGS::ExportVehicles() {
    local count = 0;

    for (local v = 0; v < 5000; v++) {
        if (!GSVehicle.IsValidVehicle(v)) continue;

        local state = GSVehicle.GetState(v);
        local cap_total = 0;
        local cap_main = 0;
        local main_cargo_label = "";
        local cap_by_cargo = {};

        local cl = GSCargoList();
        for (local c = cl.Begin(); !cl.IsEnd(); c = cl.Next()) {
            local cargo_cap = 0;
            try {
                cargo_cap = GSVehicle.GetCapacity(v, c);
            } catch (e) {
                cargo_cap = 0;
            }

            if (cargo_cap <= 0) continue;

            local cargo_label = this.CargoLabel(c);
            cap_by_cargo[cargo_label] <- cargo_cap;
            cap_total += cargo_cap;
            if (cargo_cap > cap_main) {
                cap_main = cargo_cap;
                main_cargo_label = cargo_label;
            }
        }

        // Resolve vehicle owner/company with compatibility fallbacks between GS API versions
        local owner = -1;
        try {
            owner = GSVehicle.GetCompany(v);
        } catch (e) {
            try {
                owner = GSVehicle.GetOwner(v);
            } catch (e2) {
                try {
                    owner = GSVehicle.GetOwnerCompany(v);
                } catch (e3) {
                    // Last resort: leave as -1 (unknown)
                    owner = -1;
                }
            }
        }

        GSAdmin.Send({
            t            = "VEH",
            id           = v,
            company      = owner,
            type         = this.VehTypeStr(GSVehicle.GetVehicleType(v)),
            name         = GSVehicle.GetName(v),
            profit_ly    = GSVehicle.GetProfitLastYear(v),
            profit_ty    = GSVehicle.GetProfitThisYear(v),
            age          = GSVehicle.GetAge(v) / 365,
            running_cost = GSVehicle.GetRunningCost(v),
            status       = this.VehStateStr(state),
            cargo        = main_cargo_label,
            cap          = cap_total,
            cap_main     = cap_main,
            cap_by_cargo = cap_by_cargo
        });
        count++;
    }

    GSAdmin.Send({t = "EXPORT_END", chunk = "vehicles"});
    GSLog.Info("[EXPORT] Vehicles done - " + count + " packets");
}

// One packet per station, all companies.
// Iterates each company in GSCompanyMode so the station list is scoped
// to stations that company owns, then merges them all.
function SquirrelGS::ExportStations() {
    local count = 0;
    local all_types = GSStation.STATION_TRAIN    | GSStation.STATION_AIRPORT |
                      GSStation.STATION_TRUCK_STOP | GSStation.STATION_BUS_STOP |
                      GSStation.STATION_DOCK;

    for (local c = 0; c < 15; c++) {
        local resolved = GSCompany.ResolveCompanyID(c);
        if (resolved == GSCompany.COMPANY_INVALID) continue;

        local mode = GSCompanyMode(c);
        local st_list = GSStationList(all_types);
        for (local s = st_list.Begin(); !st_list.IsEnd(); s = st_list.Next()) {
            local loc = GSStation.GetLocation(s);
            local sx  = GSMap.GetTileX(loc);
            local sy  = GSMap.GetTileY(loc);

            GSAdmin.Send({
                t       = "STAT",
                id      = s,
                name    = GSStation.GetName(s),
                company = c,
                x       = sx,
                y       = sy,
                train   = GSStation.HasStationType(s, GSStation.STATION_TRAIN),
                bus     = GSStation.HasStationType(s, GSStation.STATION_BUS_STOP),
                truck   = GSStation.HasStationType(s, GSStation.STATION_TRUCK_STOP),
                airport = GSStation.HasStationType(s, GSStation.STATION_AIRPORT),
                dock    = GSStation.HasStationType(s, GSStation.STATION_DOCK),
                town    = GSStation.GetNearestTown(s)
            });
            count++;
        }
        mode = null;  // restore deity mode
    }

    GSAdmin.Send({t = "EXPORT_END", chunk = "stations"});
    GSLog.Info("[EXPORT] Stations done - " + count + " packets");
}
