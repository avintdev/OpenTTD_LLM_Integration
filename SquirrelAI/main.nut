// SquirrelAI/main.nut - LLM-driven AI Script for OpenTTD 15.x
//
// Entry point only. Sets up state, runs the polling loop, and
// dispatches commands to handler files via ExecuteCommand().
//
// Runtime files loaded after the class definition:
//   utils.nut    - Split, ParseWagons, _max, _abs
//   transport_shared.nut - shared build validation and rollback helpers
//   modules/metalibrary/ship_provider.nut - vendored MetaLibrary waypoint hook
//   modules/metalibrary/cargo_provider.nut - route cargo selector hook
//   integrations.nut - provider adapters for external modules
//   rail.nut     - BuildRailRoute + station/depot/builder helpers
//   vehicles.nut - SellVehicle, CloneVehicle, SendToDepot, etc.
//   finance.nut  - TakeLoan, RepayLoan, RepayAllLoan
//   road.nut     - BuildTruckRoute, BuildBusRoute, BuildCityPublicTransport
//   water.nut    - BuildShipRoute, BuildFerryRoute
//   air.nut      - BuildPlaneRoute, BuildCargoPlaneRoute

require("modules/aaahogex/utils.nut");
require("modules/aaahogex/tile.nut");
require("modules/aaahogex/aystar.nut");
require("modules/aaahogex/pathfinder.nut");
require("modules/aaahogex/roadpathfinder.nut");
require("modules/aaahogex/place.nut");
require("modules/aaahogex/station.nut");
require("modules/aaahogex/estimator.nut");
require("modules/aaahogex/route.nut");
require("modules/aaahogex/trainroute.nut");
require("modules/aaahogex/railbuilder.nut");
require("modules/aaahogex/road.nut");
require("modules/aaahogex/water.nut");
require("modules/aaahogex/air.nut");

class SquirrelAI extends AIController {
    static container = Container();
    static notBuildableList = AIList();
    static distanceEstimateSamples = [];
    static distanceSampleIndex = [];
    static pathfindings = 0;
    static function DoInterval() { if (AIController.GetOpsTillSuspend() < 500) AIController.Sleep(1); }
    static function GetOpLimit() { return AIController.GetOpsTillSuspend(); }
    static function GetEstimateRange(a1) { return 0; }
    static function GetMaxCargoPlaces() { return 100; }
    static productionEstimateSamples = [10, 20, 30, 50, 80, 130, 210, 340, 550, 890, 1440, 2330, 3770];
    roiBase = false;
    firs = false;
    ecs = false;
    mountain = 0;
    futureIncomeRate = 1.0;
    loadData = {};
    noRouteCnadidates = [];
    yeti = false;
    townRoadType = 0;
    buildingTimeBase = 1;
    roadTrafficRate = 1;
    vehicleProfibitBase = 0;
    waterRemovable = true;
    canUsePlaceOnWater = true;
    supressInterval = false;
    pathFindLimit = 100;
    isUseAirportNoise = false;
    openttdVersion = 15;

    maxTrains = 1000;
    maxRoadVehicle = 1000;
    maxShips = 1000;
    maxAircraft = 1000;
    maxStationSpread = 14;

    function isRich() { return false; }
    function IsRich() { return false; }
    function GetSortedRoutePlans() { return []; }
    function isPreferReusingExistingRoads() { return false; }
    function IsPreferReusingExistingRoads() { return false; }
    function WaitDays(days) { AIController.Sleep(days); }
    function IsDistantJoinStations() { return false; }
    function IsInfrastructureMaintenance() { return false; }
    function GetQuarterlyIncome(periods = null) { return 100000; }
    function GetUsableMoney() { return 1000000; }
    function GetValue(roi = null, incomePerBuildingTime = null, incomePerVehicle = null) { return 1000000; }
    function HasIncome(threshold = null) { return true; }
    function IsTooExpensive(cost, arg2=null) { return false; }
    function IsInflation() { return false; }
    function GetDayLengthFactor() { return 1.0; }
    function GetRoadvehSlopeSteepness() { return 3; }
    function GetTrainSlopeSteepness() { return 3; }
    function GetVehicleBreakdownDifficulty() { return 0; }
    function IsEnableVehicleBreakdowns() { return false; }
    function IsDisableRoad() { return false; }
    function IsDisableTrams() { return false; }
    function isPaxMailOnly() { return false; }
    function IsPaxMailOnly() { return false; }
    function isFreightOnly() { return false; }
    function IsFreightOnly() { return false; }
    function IsManyTypesOfFreightAsPossible() { return false; }
    function IsAvoidExtendCoverageAreaInTowns() { return false; }
    function CanExtendCoverageAreaInTowns() { return true; }
    function IsAvoidRemovingWater() { return false; }
    function CanRemoveWater() { return true; }
    function IsAvoidSecondaryIndustryStealing() { return false; }
    function IsDisabledPrefixedStatoinName() { return true; }
    function GetPassengerCargo() { return 0; }
    function GetMailCargo() { return 2; }
    function GetPaxMailCargos() { return [0, 2]; }

    function PostPending(ticks, obj) {}
    function GetMeetPlacePlans(a1, a2) { return []; }
    function GetFreightTrains(a1=null) { return []; }
    function GetTransferCandidates(a1,a2) { return []; }
    function CreateRoutePlans() { return []; }
    function GetBuildableStationByPath(arg1, arg2, arg3=null, arg4=null) { return null; }
    function GetEstimateDistanceIndex(dist) { return 0; }
    function GetEstimateProductionIndex(prod) { return 0; }
    function SearchAndBuildAdditionalDestAsFarAsPossible(a1,a2,a3,a4,a5,a6,a7) {}
    function SearchAndBuildToMeetSrcDemandMin(a1,a2) {}

    function isUseAirportNoise() { return false; }
    constructions = [];
    routeCandidates = [];
    stockpiled = null;
    pendingCoastTiles = [];
    maybePurchasedLand = [];
    estimateTable = {};


    // AAAHogEx compatibility hooks used by path builders and terrain leveling.
    static function Get() { return SquirrelAI.container.instance; }
    // AAAHogEx may pass optional mode/reason args to wait helpers.
    static function WaitForMoney(cost, arg2 = null, reason = null) { return true; }
    static function WaitForPrice(cost, arg2 = null, reason = null) { return true; }
    static function GetInflatedMoney(val) { return val; }
    static function GetInflationRate() { return 1.0; }

    static function IsBuildable(tile) { return AITile.IsBuildable(tile); }
    static function IsBuildableRectangle(t, w, h) { return true; }
    static function IsPurchasedLand(tile) { return false; }
    static function PlantTreeTown(town) { return true; }
    static function PlantTree(tile) { return true; }

    MAILBOX_X      = 1;
    MAILBOX_Y      = 1;
    POLL_INTERVAL  = 50;
    CATCHMENT      = 4;
    _handled_signs = null;
    _integrations  = null;
    BUILD_TAG      = "2026-04-07-pathlog-v2";

    // Required by OpenTTD: saves AI state when game is saved.
    function Save() { return {}; }
    function Load(version, data) {}

    // -----------------------------------------------------------------------
    // Entry point
    // -----------------------------------------------------------------------

    function Start() {
        SquirrelAI.container.instance = this;
        AILog.Info("=== SquirrelAI READY ===");
        AILog.Info("[BUILD] " + BUILD_TAG);
        AICompany.SetName("SquirrelAI Corp");

        this._handled_signs = {};
        this.InitIntegrations();

        // Pick the first available rail type as default
        local rail_types = AIRailTypeList();
        if (rail_types.IsEmpty()) {
            AILog.Error("No rail types available!");
            return;
        }
        AIRail.SetCurrentRailType(rail_types.Begin());
        AILog.Info("Rail type set to: " + AIRail.GetName(rail_types.Begin()));

        local tick = 0;
        while (true) {
            this.PollMailbox();
            tick++;
            if (tick % 20 == 0) {
                AILog.Info("[AI TICK] " + tick + " - mailbox tile=" + AIMap.GetTileIndex(MAILBOX_X, MAILBOX_Y));
            }
            AIController.Sleep(POLL_INTERVAL);
        }
    }

    // -----------------------------------------------------------------------
    // Mailbox polling
    // -----------------------------------------------------------------------

    function _IsRepeatableMailboxCommand(text) {
        if (text == "SKP") return true;
        if (text == null || text.len() < 4) return false;
        if (text.slice(3, 4) != ":") return false;
        local prefix = text.slice(0, 3);
        return prefix == "LON" || prefix == "RPY";
    }

    function PollMailbox() {
        local mailbox = AIMap.GetTileIndex(MAILBOX_X, MAILBOX_Y);

        local sign_list = AISignList();
        for (local s = sign_list.Begin(); !sign_list.IsEnd(); s = sign_list.Next()) {
            local sign_tile = AISign.GetLocation(s);
            if (sign_tile != mailbox) continue;

            local text = AISign.GetName(s);
            if (text == null) { AILog.Info("Sign text null, skipping handle=" + s.tostring()); continue; }
            if (text.len() == 0) { AILog.Info("Sign empty, skipping handle=" + s.tostring()); continue; }

            // Skip signs we already processed (GS signs can't be removed by AI)
            if (s in this._handled_signs && this._handled_signs[s] == text) {
                if (!this._IsRepeatableMailboxCommand(text)) {
                    AILog.Info("Sign already handled, sending duplicate ACK to unblock GS cleanup, handle=" + s.tostring());
                    this.WriteReply("DONE:DUP");
                    return;
                }
                AILog.Info("Sign already handled but command is repeatable; executing again, handle=" + s.tostring());
            }

            // Skip our own reply signs
            if (text.len() >= 4 && text.slice(0, 4) == "DONE") { AILog.Info("Skipping reply sign DONE handle=" + s.tostring()); continue; }
            if (text.len() >= 3 && text.slice(0, 3) == "ERR")  { AILog.Info("Skipping reply sign ERR handle=" + s.tostring()); continue; }

            AILog.Info("Mailbox sign found: [" + text + "] (handle=" + s.tostring() + ") - attempting removal");

            // Best effort: removal may fail for signs we don't own.
            AISign.RemoveSign(s);
            local still = AISign.GetName(s);
            if (still != null && still.len() > 0 && still == text) {
                AILog.Warning("AISign.RemoveSign failed (likely not owned by AI); dedupe is by handle+text except repeatable commands (LON/RPY/SKP): [" + still + "] handle=" + s.tostring());
            } else {
                AILog.Info("Sign removed (or changed) before execution, handle=" + s.tostring());
            }

            // Mark handled regardless of remove result to avoid re-executing every tick.
            // If the sign text changes later, it will be processed again.
            this._handled_signs[s] <- text;
            this.ExecuteCommand(text);
            return;
        }
    }

    // -----------------------------------------------------------------------
    // Command dispatch
    // -----------------------------------------------------------------------

    function ExecuteCommand(payload) {
        AILog.Info("CMD received: " + payload);

        // No-arg commands (no colon)
        if (payload == "SKP") {
            this.WriteReply("DONE:SKP");
            return;
        }
        if (payload == "RPA") {
            this.RepayAllLoan();
            return;
        }

        // All other commands have PREFIX:args format
        if (payload.len() < 4 || payload.slice(3, 4) != ":") {
            AILog.Warning("Unknown command: " + payload);
            this.WriteReply("ERR:UNKNOWN");
            return;
        }

        local prefix = payload.slice(0, 3);
        local body   = payload.slice(4);
        local parts  = this.Split(body, ":");

        switch (prefix) {
            // --- Route building ---
            case "TRN":
                local trn_from_tok = this._ConsumeLocationToken(parts, 0);
                local trn_to_tok = (trn_from_tok == null) ? null : this._ConsumeLocationToken(parts, trn_from_tok.next);
                if (trn_from_tok == null || trn_to_tok == null || trn_to_tok.next + 1 >= parts.len()) {
                    this.WriteReply("ERR:PARSE:bad TRN");
                    return;
                }
                local trn_eng_id = this._ParseIntegerToken(parts[trn_to_tok.next]);
                if (trn_eng_id == null) { this.WriteReply("ERR:PARSE:bad TRN"); return; }
                this.BuildRailRoute(trn_from_tok.value, trn_to_tok.value,
                                    trn_eng_id, parts[trn_to_tok.next + 1]);
                break;
            case "TRK":
                local trk_from_tok = this._ConsumeLocationToken(parts, 0);
                local trk_to_tok = (trk_from_tok == null) ? null : this._ConsumeLocationToken(parts, trk_from_tok.next);
                if (trk_from_tok == null || trk_to_tok == null || trk_to_tok.next + 1 >= parts.len()) {
                    this.WriteReply("ERR:PARSE:bad TRK");
                    return;
                }
                local trk_eng_id = this._ParseIntegerToken(parts[trk_to_tok.next]);
                local trk_count = this._ParseIntegerToken(parts[trk_to_tok.next + 1]);
                if (trk_eng_id == null || trk_count == null) {
                    this.WriteReply("ERR:PARSE:bad TRK");
                    return;
                }
                this.BuildTruckRoute(trk_from_tok.value, trk_to_tok.value,
                                     trk_eng_id, trk_count);
                break;
            case "BUS":
                local bus_from_tok = this._ConsumeLocationToken(parts, 0);
                local bus_to_tok = (bus_from_tok == null) ? null : this._ConsumeLocationToken(parts, bus_from_tok.next);
                if (bus_from_tok == null || bus_to_tok == null || bus_to_tok.next + 1 >= parts.len()) {
                    this.WriteReply("ERR:PARSE:bad BUS");
                    return;
                }
                local bus_eng_id = this._ParseIntegerToken(parts[bus_to_tok.next]);
                local bus_count = this._ParseIntegerToken(parts[bus_to_tok.next + 1]);
                if (bus_eng_id == null || bus_count == null) {
                    this.WriteReply("ERR:PARSE:bad BUS");
                    return;
                }

                // BUS only serves towns; auto-prefix bare IDs with "t".
                local bus_from = bus_from_tok.value;
                local bus_to   = bus_to_tok.value;
                if (bus_from.len() > 0 && bus_from.slice(0,1) != "t" && bus_from.slice(0,1) != "T") {
                    bus_from = "t" + bus_from;
                }
                if (bus_to.len() > 0 && bus_to.slice(0,1) != "t" && bus_to.slice(0,1) != "T") {
                    bus_to = "t" + bus_to;
                }
                this.BuildBusRoute(bus_from, bus_to,
                                   bus_eng_id, bus_count);
                break;
            case "CTY":
                if (parts.len() < 3) { this.WriteReply("ERR:PARSE:bad CTY"); return; }
                local cty_town = parts[0];
                local cty_eng_id = this._ParseIntegerToken(parts[1]);
                local cty_count = this._ParseIntegerToken(parts[2]);
                if (cty_eng_id == null || cty_count == null) {
                    this.WriteReply("ERR:PARSE:bad CTY");
                    return;
                }
                if (cty_town.len() > 0 && cty_town.slice(0,1) != "t" && cty_town.slice(0,1) != "T") {
                    cty_town = "t" + cty_town;
                }
                this.BuildCityPublicTransport(cty_town, cty_eng_id, cty_count);
                break;
            case "SHP":
                local shp_from_tok = this._ConsumeLocationToken(parts, 0);
                local shp_to_tok = (shp_from_tok == null) ? null : this._ConsumeLocationToken(parts, shp_from_tok.next);
                if (shp_from_tok == null || shp_to_tok == null || shp_to_tok.next >= parts.len()) {
                    this.WriteReply("ERR:PARSE:bad SHP");
                    return;
                }
                local shp_eng_id = this._ParseIntegerToken(parts[shp_to_tok.next]);
                if (shp_eng_id == null) { this.WriteReply("ERR:PARSE:bad SHP"); return; }
                local shp_cargo = (shp_to_tok.next + 1 < parts.len()) ? parts[shp_to_tok.next + 1] : "";
                this.BuildShipRoute(shp_from_tok.value, shp_to_tok.value,
                                    shp_eng_id, shp_cargo);
                break;
            case "FRY":
                if (parts.len() < 3) { this.WriteReply("ERR:PARSE:bad FRY"); return; }
                local fry_from = this._ParseIntegerToken(parts[0]);
                local fry_to = this._ParseIntegerToken(parts[1]);
                local fry_eng_id = this._ParseIntegerToken(parts[2]);
                if (fry_from == null || fry_to == null || fry_eng_id == null) {
                    this.WriteReply("ERR:PARSE:bad FRY");
                    return;
                }
                this.BuildFerryRoute(fry_from, fry_to, fry_eng_id);
                break;
            case "PLN":
                if (parts.len() < 3) { this.WriteReply("ERR:PARSE:bad PLN"); return; }
                local pln_from = this._ParseIntegerToken(parts[0]);
                local pln_to = this._ParseIntegerToken(parts[1]);
                local pln_eng_id = this._ParseIntegerToken(parts[2]);
                if (pln_from == null || pln_to == null || pln_eng_id == null) {
                    this.WriteReply("ERR:PARSE:bad PLN");
                    return;
                }
                local pln_qty = (parts.len() >= 4) ? this._ParseIntegerToken(parts[3]) : 1;
                if (pln_qty == null) pln_qty = 1;
                this.BuildPlaneRoute(pln_from, pln_to, pln_eng_id, pln_qty);
                break;
            case "CPL":
                local cpl_from_tok = this._ConsumeLocationToken(parts, 0);
                local cpl_to_tok = (cpl_from_tok == null) ? null : this._ConsumeLocationToken(parts, cpl_from_tok.next);
                if (cpl_from_tok == null || cpl_to_tok == null || cpl_to_tok.next >= parts.len()) {
                    this.WriteReply("ERR:PARSE:bad CPL");
                    return;
                }
                local cpl_eng_id = this._ParseIntegerToken(parts[cpl_to_tok.next]);
                if (cpl_eng_id == null) { this.WriteReply("ERR:PARSE:bad CPL"); return; }
                local cpl_cargo = (cpl_to_tok.next + 1 < parts.len()) ? parts[cpl_to_tok.next + 1] : "";
                local cpl_qty = (cpl_to_tok.next + 2 < parts.len()) ? this._ParseIntegerToken(parts[cpl_to_tok.next + 2]) : 1;
                if (cpl_qty == null) cpl_qty = 1;
                this.BuildCargoPlaneRoute(cpl_from_tok.value, cpl_to_tok.value,
                                          cpl_eng_id, cpl_cargo, cpl_qty);
                break;

            // --- Vehicle management ---
            case "SEL":
                this.SellVehicle(body.tointeger());
                break;
            case "CLN":
                if (parts.len() < 2) { this.WriteReply("ERR:PARSE:bad CLN"); return; }
                this.CloneVehicle(parts[0].tointeger(), parts[1].tointeger());
                break;
            case "DEP":
                this.SendToDepot(body.tointeger());
                break;
            case "STP":
                this.StopVehicle(body.tointeger());
                break;
            case "RUN":
                this.StartVehicle(body.tointeger());
                break;
            case "ADW":
                if (parts.len() < 2) { this.WriteReply("ERR:PARSE:bad ADW"); return; }
                this.AddWagons(parts[0].tointeger(), parts[1]);
                break;
            case "RPL":
                if (parts.len() < 2) { this.WriteReply("ERR:PARSE:bad RPL"); return; }
                this.ReplaceEngine(parts[0].tointeger(), parts[1].tointeger());
                break;

            // --- Finance ---
            case "LON":
                this.TakeLoan(body.tointeger());
                break;
            case "RPY":
                this.RepayLoan(body.tointeger());
                break;

            // --- Meta ---
            case "PRI":
                // Priority hint: acknowledged but no action from AI.
                this.WriteReply("DONE:PRI");
                break;

            default:
                AILog.Warning("Unknown command prefix: " + prefix);
                this.WriteReply("ERR:UNKNOWN:" + prefix);
                break;
        }
    }

    // -----------------------------------------------------------------------
    // Reply writing
    // -----------------------------------------------------------------------

    function WriteReply(sign_str) {
        local mailbox = AIMap.GetTileIndex(MAILBOX_X, MAILBOX_Y);
        AISign.BuildSign(mailbox, sign_str);
        AILog.Info("Reply: " + sign_str);
    }
}

// Load active adapters and command handlers after class definition.
require("utils.nut");
require("transport_shared.nut");
require("modules/metalibrary/ship_provider.nut");
require("modules/metalibrary/cargo_provider.nut");
require("integrations.nut");
require("rail.nut");
require("vehicles.nut");
require("finance.nut");
require("road.nut");
require("water.nut");
require("air.nut");
