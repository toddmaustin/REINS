// Copyright (c) 2026 Todd Austin.
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// License: https://polyformproject.org/licenses/noncommercial/1.0.0/

// Reduced counter only for tractable bounded unrolling of the actual time monitor.
module r03_time (
    input logic clk_i,rst_ni,monitor_i,restart_i,run_start_i,reference_a_i,reference_b_i,absolute_healthy_i,
    output logic qualified_o,alarm_o,
    output logic [3:0] now_o
);
    reins_trusted_time #(.WIDTH(4),.MAX_GAP(4),.START_EDGES(2)) timekeeper (.*);
endmodule
