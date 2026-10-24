// Copyright (c) 2026 Todd Austin.
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// License: https://polyformproject.org/licenses/noncommercial/1.0.0/

// Local up-counting path A. A static level is never sufficient: every trusted
// arm epoch needs two fresh, correctly spaced transitions. Loss locks the path
// off for that epoch; late or fast edges cannot resurrect an old authorization.
`default_nettype none
module reins_permit_guard_a (
    input logic clk_i, por_ni,         // Independent endpoint-A clock, period 900..1100 ns in the profile.
    input logic permit_i, epoch_i,    // Protected routed A rail / trusted new-ARM toggle; neither is a host pin.
    output logic [7:0] code_o,        // 0x96 healthy, 0x69 denied; independently decoded by actuator A.
    output logic epoch_o, alarm_o     // Acknowledged epoch / locked timeout, spacing or integrity failure.
);
    (* ASYNC_REG="TRUE" *) logic [1:0] permit_sync_q, epoch_sync_q;
    // Each epoch owns its own listening/first-edge/qualification and sticky failure ledger.
    logic level_q, listening_q, first_q, qualified_q, failed_q;
    // Local elapsed cycles and independently stored complement; no source-clock dependency.
    logic [9:0] age_q, age_inverse_q;
    logic bad, edge_seen;
    assign bad=age_q!=~age_inverse_q || age_q>10'd800;
    assign edge_seen=permit_sync_q[1]!=level_q;
    assign code_o=por_ni && qualified_q && !failed_q && !bad ? 8'h96 : 8'h69;
    assign alarm_o=por_ni && (failed_q || bad);
    always_ff @(posedge clk_i or negedge por_ni) begin
        if (!por_ni) begin
            permit_sync_q<=0; epoch_sync_q<=0; epoch_o<=0; level_q<=0;
            listening_q<=0; first_q<=0; qualified_q<=0; failed_q<=0;
            age_q<=0; age_inverse_q<='1;
        end else begin
            permit_sync_q<={permit_sync_q[0],permit_i}; epoch_sync_q<={epoch_sync_q[0],epoch_i};
            level_q<=permit_sync_q[1];
            if (epoch_sync_q[1]!=epoch_o) begin
                epoch_o<=epoch_sync_q[1]; listening_q<=1; first_q<=0; qualified_q<=0; failed_q<=0;
                age_q<=0; age_inverse_q<='1;
            end else if (bad) begin failed_q<=1; qualified_q<=0; end
            else if (listening_q && !failed_q) begin
                // Timeout dominates an edge at the same exact local-clock boundary.
                if (age_q>=799) begin failed_q<=1; qualified_q<=0; end
                else if (edge_seen) begin
                    if (first_q && age_q<319) begin failed_q<=1; qualified_q<=0; end
                    else begin first_q<=1; qualified_q<=first_q; age_q<=0; age_inverse_q<='1; end
                end else begin age_q<=age_q+10'd1; age_inverse_q<=age_inverse_q-10'd1; end
            end
        end
    end
`ifdef FORMAL
    // Prove local safety steps; clock independence/metastability are physical assumptions.
    logic formal_past=1'b0;
    always @(posedge clk_i) begin
        formal_past<=1'b1;
        if (!formal_past) assume(!por_ni);
        if (formal_past && por_ni) begin
            assert(code_o==8'h69 || code_o==8'h96);
            if (alarm_o) assert(code_o==8'h69);
            if ($past(por_ni && failed_q && epoch_sync_q[1]==epoch_o)) assert(!qualified_q);
            if ($past(por_ni && listening_q && !failed_q && !bad && age_q>=799 && epoch_sync_q[1]==epoch_o)) assert(failed_q && !qualified_q);
            if ($past(por_ni && listening_q && !failed_q && !bad && age_q<799 && !edge_seen && epoch_sync_q[1]==epoch_o)) assert(age_q==$past(age_q)+10'd1);
        end
    end
`endif
endmodule
`default_nettype wire
