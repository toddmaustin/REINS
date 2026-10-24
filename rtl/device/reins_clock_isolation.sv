// Copyright (c) 2026 Todd Austin.
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// License: https://polyformproject.org/licenses/noncommercial/1.0.0/

// TECHNOLOGY WRAPPER: independent clock-blocking cell, with fail-off assertion
// and falling-edge-only release. Reset/isolation is asserted before clock clamp.
// A physical implementation must qualify the async clamp, pulse widths, reset
// ordering and readback, and preserve the two serial cell instances separately.
`default_nettype none
(* keep_hierarchy="yes", dont_touch="yes" *) module reins_clock_isolation (
    input logic raw_clock_i, por_ni, allow_i, // Protected raw clock / fail-off power / only this path's control.
    output logic clock_o, closed_o           // Actual gated clock / modeled cell readback.
);
    logic gate_q;
    always_ff @(negedge raw_clock_i or negedge por_ni or negedge allow_i) begin
        if (!por_ni || !allow_i) gate_q<=0;
        else gate_q<=1;
    end
    assign clock_o=raw_clock_i && gate_q;
    assign closed_o=!gate_q;
endmodule
`default_nettype wire
