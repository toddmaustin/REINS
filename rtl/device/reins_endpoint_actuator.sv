// Copyright (c) 2026 Todd Austin.
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// License: https://polyformproject.org/licenses/noncommercial/1.0.0/

// One independently decoded physical actuation path. Denial first clamps I/O
// and asserts reset; clock removal follows after a bounded local-clock delay.
// Closing cannot be canceled by a late good code; reopening needs a new epoch.
`default_nettype none
module reins_endpoint_actuator #(
    parameter logic [7:0] OPEN_CODE=8'h96, DENY_CODE=8'h69,
    parameter int unsigned ACTUATION_CYCLES=100
) (
    input logic clk_i, por_ni,        // This path's own always-on local guard clock / fail-off power reset.
    input logic epoch_i,             // Local guard's acknowledged arm epoch.
    input logic [7:0] code_i,         // Only this path's sparse health code, never a combined A/B enable.
    output logic isolation_open_o,   // This path's separate output cut and reset-release control.
    output logic clock_open_o,       // This path's separate clock-gate control.
    output logic closed_o, fault_o   // Completed local actuation / immediate or sticky invalid-control alarm.
);
    localparam logic [7:0] CLOSED=8'h0f, OPEN=8'h33, CLOSING=8'h55;
    // Sparse state and complementary storage make invalid local controls fail off.
    logic [7:0] state_q, state_inverse_q;
    logic [15:0] age_q, age_inverse_q;
    // A fresh epoch arms one opening only; denial irrevocably starts closing for that epoch.
    logic seen_epoch_q, armed_q, failed_q, bad;
    assign bad=state_q!=~state_inverse_q || age_q!=~age_inverse_q ||
        !(state_q==CLOSED || state_q==OPEN || state_q==CLOSING);
    assign fault_o=por_ni && (failed_q || bad || (code_i!=OPEN_CODE && code_i!=DENY_CODE));
    assign isolation_open_o=por_ni && !fault_o && state_q==OPEN;
    assign clock_open_o=por_ni && !fault_o && (state_q==OPEN || state_q==CLOSING);
    assign closed_o=por_ni && !fault_o && state_q==CLOSED;
    always_ff @(posedge clk_i or negedge por_ni) begin
        if (!por_ni) begin
            state_q<=CLOSED; state_inverse_q<=~CLOSED; age_q<=0; age_inverse_q<='1;
            seen_epoch_q<=0; armed_q<=0; failed_q<=0;
        end else if (fault_o) failed_q<=1;
        else if (epoch_i!=seen_epoch_q) begin
            seen_epoch_q<=epoch_i;
            if (state_q==CLOSED) armed_q<=1;
            else failed_q<=1;
        end else if (state_q==CLOSED && armed_q && code_i==OPEN_CODE) begin
            state_q<=OPEN; state_inverse_q<=~OPEN; armed_q<=0;
        end else if (state_q==OPEN && code_i!=OPEN_CODE) begin
            state_q<=CLOSING; state_inverse_q<=~CLOSING; age_q<=0; age_inverse_q<='1;
        end else if (state_q==CLOSING) begin
            if (age_q>=16'(ACTUATION_CYCLES-1)) begin state_q<=CLOSED; state_inverse_q<=~CLOSED; end
            else begin age_q<=age_q+16'd1; age_inverse_q<=age_inverse_q-16'd1; end
        end
    end
`ifndef SYNTHESIS
    initial assert (ACTUATION_CYCLES>0 && ACTUATION_CYCLES<=65535) else $fatal(1,"invalid actuation profile");
`endif
endmodule
`default_nettype wire
