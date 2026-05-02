class SquirrelAI extends AIInfo {
    function GetAuthor()       { return "avintdev"; }
    function GetName()         { return "SquirrelAI"; }
    function GetShortName()    { return "SQAI"; }
    function GetDescription()  { return "LLM-driven AI for SquirrelAI framework"; }
    function GetVersion()      { return 1; }
    function GetDate()         { return "2026-03-09"; }
    function GetAPIVersion()   { return "15"; }
    function CreateInstance()  { return "SquirrelAI"; }
    function MinVersionToLoad() { return 1; }
}

RegisterAI(SquirrelAI());
