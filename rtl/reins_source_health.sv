// Copyright (c) 2026 Todd Austin.
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// License: https://polyformproject.org/licenses/noncommercial/1.0.0/

// Simulation source profile 1: binary RCT and reference-symbol APT plus missing samples.
// Cutoffs are explicit digital test settings, not assessed SP 800-90B parameters.
`default_nettype none
module reins_source_health #(
    parameter int unsigned RCT_CUTOFF=32,
    parameter int unsigned APT_WINDOW=64,
    parameter int unsigned APT_CUTOFF=56,
    parameter int unsigned START_SAMPLES=64,
    parameter int unsigned MAX_GAP=1024
) (
    input logic clk_i, rst_ni, restart_i,       // Volatile reset / new startup health qualification.
    input logic enabled_i, required_i,         // Monitor raw events / require timely acquisition.
    input logic available_i, valid_i, bit_i,   // Technology availability and new raw binary sample.
    output logic qualified_o, failed_o,        // Startup samples passed / immediate-or-sticky failure.
    output logic [31:0] samples_o              // Saturates after START_SAMPLES; never entropy credit.
);
    logic failed_q, previous_q, have_previous_q, reference_q; // Sticky failure / RCT/APT symbols.
    logic [31:0] run_q, window_q, matches_q, gap_q; // RCT run, APT position/count, absence clocks.
    logic [31:0] next_run, next_matches;         // Counts including the currently presented event.
    logic raw_bad;                             // Prospective cutoff: masks acceptance on that edge.
    assign next_run=have_previous_q && bit_i==previous_q ? run_q+1 : 1;
    assign next_matches=window_q==0 ? 1 : matches_q+32'(bit_i==reference_q);
    assign raw_bad=valid_i && (next_run>=RCT_CUTOFF || next_matches>=APT_CUTOFF);
    assign failed_o=failed_q || (enabled_i &&
        (!available_i || raw_bad || (required_i && !valid_i && gap_q>=MAX_GAP-1)));
    assign qualified_o=samples_o>=START_SAMPLES && !failed_o;
    always_ff @(posedge clk_i) begin
        if (!rst_ni || restart_i) begin
            failed_q<=1'b0; previous_q<=1'b0; have_previous_q<=1'b0; reference_q<=1'b0;
            run_q<='0; window_q<='0; matches_q<='0; gap_q<='0; samples_o<='0;
        end else if (enabled_i) begin
            if (failed_o) failed_q<=1'b1;
            if (!required_i || valid_i) gap_q<='0;
            else if (gap_q<MAX_GAP) gap_q<=gap_q+1;
            if (valid_i && !failed_o) begin
                previous_q<=bit_i; have_previous_q<=1'b1; run_q<=next_run;
                if (samples_o<START_SAMPLES) samples_o<=samples_o+1;
                if (window_q==0) reference_q<=bit_i;
                if (window_q==APT_WINDOW-1) begin window_q<='0; matches_q<='0; end
                else begin window_q<=window_q+1; matches_q<=next_matches; end
            end
        end
    end
`ifndef SYNTHESIS
    initial begin
        assert (RCT_CUTOFF>1 && APT_WINDOW>1 && APT_CUTOFF>1 && APT_CUTOFF<=APT_WINDOW &&
            START_SAMPLES>=APT_WINDOW && MAX_GAP>0) else $fatal(1,"invalid source profile");
    end
`endif
endmodule
`default_nettype wire
