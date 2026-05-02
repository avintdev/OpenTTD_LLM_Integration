class SquirrelGSInfo extends GSInfo {
    function GetAuthor()      { return "avintdev"; }
    function GetName()        { return "SquirrelGS"; }
    function GetShortName()   { return "SQGS"; }
    function GetDescription() { return "Commandable GS"; }
    function GetVersion()     { return 1; }
    function GetDate()        { return "2026-03-05"; }
    function GetAPIVersion()  { return "15"; }
    function CreateInstance() { return "SquirrelGS"; }
}
RegisterGS(SquirrelGSInfo());
