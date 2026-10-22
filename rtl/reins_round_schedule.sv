// Exact v0.3 scheduled arithmetic. This combinational block is also probed
// independently at full 64-bit boundaries in simulation; it never saturates I/B/E.
`default_nettype none
module reins_round_schedule (
    input logic [63:0] round_i, period_i, window_i, lease_i, // r/P/W/L, unsigned local ticks.
    output logic valid_o,                                 // All arithmetic and timing ordering valid.
    output logic [63:0] issue_o, deadline_o, expiry_o, next_issue_o // I/B/E and next scheduled issue.
);
    logic [127:0] product;                               // Full product detects multiplication overflow.
    logic [64:0] deadline_sum, expiry_sum, next_sum;      // Carry must never become a wrapped tick.
    assign product=128'(round_i-64'd1)*128'(period_i);
    assign issue_o=product[63:0];
    assign deadline_sum={1'b0,issue_o}+{1'b0,window_i};
    assign expiry_sum={1'b0,issue_o}+{1'b0,lease_i};
    assign next_sum={1'b0,issue_o}+{1'b0,period_i};
    assign deadline_o=deadline_sum[63:0];
    assign expiry_o=expiry_sum[63:0];
    assign next_issue_o=next_sum[63:0];
    assign valid_o=round_i!=0 && window_i!=0 && window_i<=period_i && period_i<lease_i &&
        product[127:64]==0 && !deadline_sum[64] && !expiry_sum[64] && !next_sum[64];
endmodule
`default_nettype wire
