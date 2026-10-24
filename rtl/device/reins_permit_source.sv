// Copyright (c) 2026 Todd Austin.
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// License: https://polyformproject.org/licenses/noncommercial/1.0.0/

// Two dynamic rails; neither a shared static run-enable nor either qualifier
// alone can create both streams. Disabled rails hold their last level: revoking
// authorization does not manufacture one last transition by resetting a wire.
`default_nettype none
module reins_permit_source (
    input logic clk_i, por_ni, reset_i, // Always-on source clock, power loss and logical withdrawal.
    input logic tick_i,                // Qualified reference-A progress event, nominally 1 MHz.
    input logic run_i, stop_i,         // Trusted sequencing; run alone is never authorization.
    input logic authorize_a_i,         // R06's checked permit path.
    input logic authorize_b_i,         // Independently derived state/time/remaining/health path.
    output logic permit_a_o, permit_b_o, // Separate protected fan-out rails, nominal 500-tick intervals.
    output logic fault_o              // Immediate/sticky counter-integrity failure; inhibits both rails.
);
    // Rail A counts up; rail B counts down. Neither accepts a combined host-controlled enable.
    logic [9:0] age_q, age_inverse_q;
    logic [9:0] remaining_q, remaining_inverse_q;
    logic failed_q, bad;
    assign bad=age_q!=~age_inverse_q || remaining_q!=~remaining_inverse_q ||
        age_q>10'd499 || remaining_q>10'd499;
    assign fault_o=por_ni && (failed_q || bad);
    always_ff @(posedge clk_i or negedge por_ni) begin
        if (!por_ni) begin
            age_q<=0; age_inverse_q<='1; remaining_q<=499; remaining_inverse_q<=~10'd499;
            permit_a_o<=0; permit_b_o<=0; failed_q<=0;
        end else begin
            if (bad) failed_q<=1;
            if (reset_i || stop_i || !run_i || !authorize_a_i || fault_o) begin age_q<=0; age_inverse_q<='1; end
            else if (tick_i) begin
                if (age_q==499) begin age_q<=0; age_inverse_q<='1; permit_a_o<=~permit_a_o; end
                else begin age_q<=age_q+10'd1; age_inverse_q<=age_inverse_q-10'd1; end
            end
            if (reset_i || stop_i || !run_i || !authorize_b_i || fault_o) begin remaining_q<=499; remaining_inverse_q<=~10'd499; end
            else if (tick_i) begin
                if (remaining_q==0) begin remaining_q<=499; remaining_inverse_q<=~10'd499; permit_b_o<=~permit_b_o; end
                else begin remaining_q<=remaining_q-10'd1; remaining_inverse_q<=remaining_inverse_q+10'd1; end
            end
        end
    end
endmodule
`default_nettype wire
