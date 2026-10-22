// Independent committed-age arithmetic versus the saturating remaining counter.
// Ordinary expiry is a denial, not an integrity alarm; disagreement is an alarm.
`default_nettype none
module reins_lease_check (
    input logic valid_i,                     // A committed lease exists.
    input logic [63:0] now_i, length_i,       // Trusted local tick and checked L.
    input logic [63:0] issue_i, issue_inverse_i, expiry_i, // Protected I_c and checked E_c.
    input logic [63:0] remaining_i, remaining_inverse_i,   // Independently decremented R.
    output logic fault_o, permit_o           // Integrity mismatch / strict age-and-R permission.
);
    logic [63:0] age, expected_remaining, difference;
    logic [64:0] checked_expiry;
    assign age=now_i-issue_i;
    assign expected_remaining=now_i>=issue_i && age<length_i ? length_i-age : 64'd0;
    assign difference=remaining_i>expected_remaining ? remaining_i-expected_remaining : expected_remaining-remaining_i;
    assign checked_expiry={1'b0,issue_i}+{1'b0,length_i};
    assign fault_o=valid_i && (length_i==0 || issue_i!=~issue_inverse_i || remaining_i!=~remaining_inverse_i ||
        remaining_i>length_i || now_i<issue_i || checked_expiry[64] || expiry_i!=checked_expiry[63:0] || difference>1);
    assign permit_o=valid_i && !fault_o && age<length_i && now_i<expiry_i && remaining_i!=0;
endmodule
`default_nettype wire
