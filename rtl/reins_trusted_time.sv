// Digital progress monitors for two already-synchronized technology references.
// The always-on monitor clock and absolute-frequency health input require platform qualification.
`default_nettype none
module reins_trusted_time #(
    parameter int unsigned WIDTH=64,           // Production width; reduced instance only in tests.
    parameter int unsigned MAX_GAP=16,         // Missing-reference bound in monitor clocks.
    parameter int unsigned START_EDGES=4       // Both references must progress before startup.
) (
    input logic clk_i, rst_ni,                 // Always-on monitor clock; volatile reset.
    input logic monitor_i, restart_i,          // Enable checks / restart digital qualification.
    input logic run_start_i,                   // Establish local tick zero after startup checks.
    input logic reference_a_i, reference_b_i,  // Independent one-monitor-cycle edge events.
    input logic absolute_healthy_i,            // Qualified platform floor/environment status.
    output logic qualified_o, alarm_o,         // Startup progress / immediate-or-latched failure.
    output logic [WIDTH-1:0] now_o             // Ticks advance from A independently of crypto/host.
);
    logic running_q, failed_q;
    logic [31:0] gap_a_q, gap_b_q;             // Consecutive monitor clocks without each event.
    logic [31:0] edges_a_q, edges_b_q;         // Saturating startup edge accounting.
    logic missing, overflow;
    assign missing=monitor_i &&
        ((!reference_a_i && gap_a_q>=MAX_GAP-1) || (!reference_b_i && gap_b_q>=MAX_GAP-1));
    assign overflow=running_q && reference_a_i && (&now_o);
    assign alarm_o=failed_q || (monitor_i && !absolute_healthy_i) || missing || overflow;
    assign qualified_o=monitor_i && !alarm_o && edges_a_q>=START_EDGES && edges_b_q>=START_EDGES;
    always_ff @(posedge clk_i) begin
        if (!rst_ni || restart_i) begin
            gap_a_q<='0; gap_b_q<='0; edges_a_q<='0; edges_b_q<='0;
            now_o<='0; running_q<=1'b0; failed_q<=1'b0;
        end else begin
            if (alarm_o) failed_q<=1'b1;
            if (monitor_i) begin
                if (reference_a_i) begin gap_a_q<='0; if (edges_a_q<START_EDGES) edges_a_q<=edges_a_q+1; end
                else if (gap_a_q<MAX_GAP) gap_a_q<=gap_a_q+1;
                if (reference_b_i) begin gap_b_q<='0; if (edges_b_q<START_EDGES) edges_b_q<=edges_b_q+1; end
                else if (gap_b_q<MAX_GAP) gap_b_q<=gap_b_q+1;
            end
            if (run_start_i && qualified_o) begin running_q<=1'b1; now_o<='0; end
            else if (running_q && reference_a_i && !alarm_o) now_o<=now_o+1'b1;
        end
    end
`ifndef SYNTHESIS
    initial begin
        assert (WIDTH>0 && WIDTH<=64 && MAX_GAP>1 && START_EDGES>0) else $fatal(1,"invalid time profile");
    end
    assert property (@(posedge clk_i) disable iff (!rst_ni || restart_i)
        alarm_o && !restart_i |=> alarm_o);
`endif
endmodule
`default_nettype wire
