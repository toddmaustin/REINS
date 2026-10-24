// Copyright (c) 2026 Todd Austin.
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// License: https://polyformproject.org/licenses/noncommercial/1.0.0/

// Four-state Icarus check of actual local guards/actuators, independent of Verilator's two-state execution.
`timescale 1ns/1ps
module r11_reset_tb;
    logic clk=0,por=1'bx,rail=1'bx,epoch=1'bx;
    wire [7:0] a,b;
    wire ea,eb,aa,ab,ia,ib,ca,cb,closed_a,closed_b,fa,fb;
    reins_permit_guard_a ga(clk,por,rail,epoch,a,ea,aa);
    reins_permit_guard_b gb(clk,por,rail,epoch,b,eb,ab);
    reins_endpoint_actuator pa(clk,por,ea,a,ia,ca,closed_a,fa);
    reins_endpoint_actuator #(.OPEN_CODE(8'ha5),.DENY_CODE(8'h5a)) pb(clk,por,eb,b,ib,cb,closed_b,fb);
    always #5 clk=~clk;
    // Require reset-established denials without coercing unknown values to two-state zero.
    task check_closed;
        if (a!==8'h69 || b!==8'h5a || ia!==0 || ib!==0 || ca!==0 || cb!==0)
            $fatal(1,"four-state reset did not establish denied guards/cuts");
    endtask
    initial begin
        #7; por=0; #13; check_closed();
        rail=0; epoch=0; #3; por=1; repeat(8) @(negedge clk); check_closed();
        // X/Z controls cannot qualify a permit; this bounded check does not prove a general X-safe system.
        rail=1'bx; epoch=1'bz; repeat(16) @(negedge clk); check_closed();
        por=0; #1; check_closed(); rail=0; epoch=0; #2; por=1;
        repeat(8) @(negedge clk); check_closed();
        epoch=1; repeat(8) @(negedge clk);
        // A static high/low rail still supplies no two correctly spaced qualification transitions.
        rail=1; repeat(1100) @(negedge clk);
        if (ia!==0 || ib!==0 || ca!==0 || cb!==0) $fatal(1,"static rail opened an isolation cut");
        por=0; #1; check_closed();
        $display("PASS: four-state power/reset, X/Z controls and static-rail local denial (bounded)");
        $finish;
    end
endmodule
