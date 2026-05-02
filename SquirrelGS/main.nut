// SquirrelGS/main.nut - GameScript for the SquirrelAI framework
//
// Entry point and runtime state machine. Loaded automatically by OpenTTD.
//
// Responsibilities:
//   - Main loop: HandleEvents() + PollMailbox() every tick
//   - Listen for Admin Port packets, dispatch !ping / !export / !cmd
//   - Sign protocol: WriteCmd(), PollMailbox(), _CleanupCmd()
//   - Command timeout state machine (IDLE → WAITING → IDLE)
//   - Export on explicit !export commands from the bridge
//
// Split files (loaded via require after class definition):
//   export.nut - ExportAll, ExportIndustries, ExportTowns, etc.
//   utils.nut  - CargoLabel, VehTypeStr, VehStateStr, SplitString

class SquirrelGS extends GSController {

    // --- Configuration ---
    MAILBOX_X       = 1;
    MAILBOX_Y       = 1;
    CMD_TIMEOUT     = 5000;   // ticks before a command times out

    // --- Runtime state ---
    tick_count     = 0;
    cmd_state      = 0;       // 0 = IDLE, 1 = WAITING for AI reply
    cmd_wait_ticks = 0;
    cmd_sign_id    = -1;      // sign id of the current CMD sign

    // ===================================================================
    // MAIN LOOP
    // ===================================================================

    function Start() {
        GSLog.Info("=== SquirrelGS READY ===");

        while (true) {
            tick_count++;
            this.HandleEvents();

            this.PollMailbox();
            if (cmd_state == 1) {
                cmd_wait_ticks++;
                if (cmd_wait_ticks >= CMD_TIMEOUT) {
                    GSLog.Warning("[CMD] Timeout after " + CMD_TIMEOUT + " ticks");
                    if (GSSign.IsValidSign(cmd_sign_id)) {
                        GSSign.RemoveSign(cmd_sign_id);
                    }
                    cmd_sign_id = -1;
                    GSAdmin.Send({t = "ERR", reason = "TIMEOUT"});
                    cmd_state      = 0;
                    cmd_wait_ticks = 0;
                }
            }

            GSController.Sleep(1);
        }
    }

    // ===================================================================
    // EVENT HANDLING
    // ===================================================================

    function HandleEvents() {
        while (GSEventController.IsEventWaiting()) {
            local e = GSEventController.GetNextEvent();
            if (e.GetEventType() == GSEvent.ET_ADMIN_PORT) {
                local ap  = GSEventAdminPort.Convert(e);
                local obj = ap.GetObject();
                if (obj == null) {
                    GSLog.Warning("Null admin port object");
                    return;
                }
                if ("msg" in obj) {
                    local msg = obj["msg"].tostring();
                    GSLog.Info("[IN] " + msg);
                    this.ParseCommand(msg);
                }
            }
        }
    }

    function ParseCommand(msg) {
        if (msg == "!ping") {
            GSLog.Info("PONG!");
            GSAdmin.Send({t = "PONG"});
            return;
        }

        if (msg == "!delsign") {
            if (cmd_state == 1 && GSSign.IsValidSign(cmd_sign_id)) {
                GSSign.RemoveSign(cmd_sign_id);
                GSLog.Info("[CMD] Sign deleted by admin");
            }
            cmd_sign_id    = -1;
            cmd_state      = 0;
            cmd_wait_ticks = 0;
            GSAdmin.Send({t = "DONE", msg = "DELSIGN"});
            return;
        }

        if (msg.len() > 8 && msg.slice(0, 8) == "!export ") {
            local chunk = msg.slice(8);
            this.DispatchExport(chunk);
            return;
        }

        if (msg == "!mailbox") {
            local mailbox = GSMap.GetTileIndex(MAILBOX_X, MAILBOX_Y);
            GSLog.Info("[MAILBOX] tile=" + mailbox +
                       " (" + MAILBOX_X + "," + MAILBOX_Y + ")");
            local sign_list = GSSignList();
            for (local s = sign_list.Begin(); !sign_list.IsEnd(); s = sign_list.Next()) {
                GSLog.Info("[SIGN " + s + "] tile=" + GSSign.GetLocation(s) +
                           " text=" + GSSign.GetName(s));
            }
            return;
        }

        if (msg.len() > 5 && msg.slice(0, 5) == "!cmd ") {
            local payload = msg.slice(5);
            this.WriteCmd(payload);
            return;
        }

        GSLog.Info("UNKNOWN CMD: " + msg);
    }

    function DispatchExport(chunk) {
        GSLog.Info("[EXPORT] Exporting: " + chunk);
        switch (chunk) {
            case "industries": this.ExportIndustries(); break;
            case "towns":      this.ExportTowns();      break;
            case "companies":  this.ExportCompanies();  break;
            case "engines":    this.ExportEngines();     break;
            case "vehicles":   this.ExportVehicles();    break;
            case "stations":   this.ExportStations();    break;
            case "all":        this.ExportAll();         break;
            default:
                GSLog.Warning("Unknown export chunk: " + chunk);
        }
    }

    // ===================================================================
    // SIGN PROTOCOL - CMD dispatch & reply polling
    // ===================================================================

    function WriteCmd(payload) {
        if (cmd_state == 1) {
            GSLog.Warning("[CMD] Busy - still waiting for previous reply");
            GSAdmin.Send({t = "ERR", reason = "BUSY"});
            return;
        }
        local mailbox = GSMap.GetTileIndex(MAILBOX_X, MAILBOX_Y);
        GSLog.Info("[CMD] Attempting sign at tile " + mailbox +
                   " valid=" + GSMap.IsValidTile(mailbox) +
                   " payload=[" + payload + "]");
        local sign_id = GSSign.BuildSign(mailbox, payload);
        if (GSSign.IsValidSign(sign_id)) {
            GSLog.Info("[CMD] Sign placed OK: id=" + sign_id + " text=" + payload);
            cmd_sign_id    = sign_id;
            cmd_state      = 1;
            cmd_wait_ticks = 0;
        } else {
            GSLog.Error("[CMD] BuildSign FAILED: " + GSError.GetLastErrorString());
            GSAdmin.Send({t = "ERR", reason = "SIGN_FAIL"});
        }
    }

    function PollMailbox() {
        local mailbox = GSMap.GetTileIndex(MAILBOX_X, MAILBOX_Y);

        for (local c = GSCompany.COMPANY_FIRST; c <= 14; c++) {
            if (GSCompany.ResolveCompanyID(c) == GSCompany.COMPANY_INVALID) continue;

            local scope = GSCompanyMode(c);
            local sign_list = GSSignList();
            for (local s = sign_list.Begin(); !sign_list.IsEnd(); s = sign_list.Next()) {
                if (GSSign.GetLocation(s) != mailbox) continue;
                local text = GSSign.GetName(s);
                if (text == null || text.len() == 0) continue;

                if (text.len() >= 4 && text.slice(0, 4) == "DONE") {
                    GSLog.Info("[REPLY] " + text);
                    GSSign.RemoveSign(s);
                    scope = null;
                    if (cmd_state == 1) {
                        this._CleanupCmd(text, "DONE");
                    }
                    return;
                }
                if (text.len() >= 3 && text.slice(0, 3) == "ERR") {
                    GSLog.Info("[REPLY] " + text);
                    GSSign.RemoveSign(s);
                    scope = null;
                    if (cmd_state == 1) {
                        this._CleanupCmd(text, "ERR");
                    }
                    return;
                }
            }
        }
    }

    // ===================================================================
    // HELPERS
    // ===================================================================

    function _CleanupCmd(text, type) {
        if (GSSign.IsValidSign(cmd_sign_id)) {
            GSSign.RemoveSign(cmd_sign_id);
        }
        cmd_sign_id    = -1;
        cmd_state      = 0;
        cmd_wait_ticks = 0;
        GSAdmin.Send({t = type, msg = text});
    }

}

// Load method implementations from split files
require("export.nut");
require("utils.nut");
