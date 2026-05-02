// SquirrelAI/finance.nut - Loan management
//
// Handles: LON, RPY, RPA commands
// Thin wrappers around the AICompany loan API.

function SquirrelAI::TakeLoan(amount) {
    AILog.Info("TakeLoan: " + amount);

    local current = AICompany.GetLoanAmount();
    local max_loan = AICompany.GetMaxLoanAmount();
    local target = current + amount;

    if (target > max_loan) {
        this.WriteReply("ERR:LON:EXCEEDS_MAX");
        return;
    }

    if (AICompany.SetLoanAmount(target)) {
        this.WriteReply("DONE:LON:" + target);
    } else {
        this.WriteReply("ERR:LON:FAILED");
    }
}

function SquirrelAI::RepayLoan(amount) {
    AILog.Info("RepayLoan: " + amount);

    local current = AICompany.GetLoanAmount();
    local target = current - amount;
    if (target < 0) target = 0;

    if (AICompany.SetLoanAmount(target)) {
        this.WriteReply("DONE:RPY:" + target);
    } else {
        this.WriteReply("ERR:RPY:FAILED");
    }
}

function SquirrelAI::RepayAllLoan() {
    AILog.Info("RepayAllLoan");

    if (AICompany.SetLoanAmount(0)) {
        this.WriteReply("DONE:RPA");
    } else {
        this.WriteReply("ERR:RPA:FAILED");
    }
}
