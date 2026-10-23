// Dissimilar local path B uses a down-counter and a faster, independent clock.
// Its own synchronizers, qualification, watchdog and codeword never consume A.
`default_nettype none
module reins_permit_guard_b (
    input logic clk_i, por_ni,         // Independent endpoint-B clock, period 720..880 ns in the profile.
    input logic permit_i, epoch_i,    // Protected B fan-out / trusted new-ARM toggle.
    output logic [7:0] code_o,        // 0xa5 healthy, 0x5a denied; no common A/B allow decoder.
    output logic epoch_o, alarm_o     // Acknowledged epoch / sticky failure for this epoch.
);
    (* ASYNC_REG="TRUE" *) logic [1:0] permit_sync_q, epoch_sync_q;
    // No A-path state is shared: edge qualification and failure belong to this clock domain.
    logic level_q, listening_q, first_q, qualified_q, failed_q;
    // Dissimilar down-counter plus complement bounds missing edges without trusting the source clock.
    logic [9:0] remaining_q, remaining_inverse_q;
    logic bad, changed;
    assign bad=remaining_q!=~remaining_inverse_q || remaining_q>10'd1000;
    assign changed=permit_sync_q[1]^level_q;
    assign code_o=por_ni && qualified_q && !failed_q && !bad ? 8'ha5 : 8'h5a;
    assign alarm_o=por_ni && (failed_q || bad);
    always_ff @(posedge clk_i or negedge por_ni) begin
        if (!por_ni) begin
            permit_sync_q<=0; epoch_sync_q<=0; epoch_o<=0; level_q<=0;
            listening_q<=0; first_q<=0; qualified_q<=0; failed_q<=0;
            remaining_q<=1000; remaining_inverse_q<=~10'd1000;
        end else begin
            permit_sync_q<={permit_sync_q[0],permit_i}; epoch_sync_q<={epoch_sync_q[0],epoch_i};
            level_q<=permit_sync_q[1];
            if (epoch_sync_q[1]!=epoch_o) begin
                epoch_o<=epoch_sync_q[1]; listening_q<=1; first_q<=0; qualified_q<=0; failed_q<=0;
                remaining_q<=1000; remaining_inverse_q<=~10'd1000;
            end else if (bad) begin failed_q<=1; qualified_q<=0; end
            else if (listening_q && !failed_q) begin
                if (remaining_q<=1) begin failed_q<=1; qualified_q<=0; end
                else if (changed) begin
                    if (first_q && remaining_q>601) begin failed_q<=1; qualified_q<=0; end
                    else begin first_q<=1; qualified_q<=first_q; remaining_q<=1000; remaining_inverse_q<=~10'd1000; end
                end else begin remaining_q<=remaining_q-10'd1; remaining_inverse_q<=remaining_inverse_q+10'd1; end
            end
        end
    end
`ifdef FORMAL
    // The dissimilar down-counter must deny on local timeout, including a simultaneous edge.
    logic formal_past=1'b0;
    always @(posedge clk_i) begin
        formal_past<=1'b1;
        if (!formal_past) assume(!por_ni);
        if (formal_past && por_ni) begin
            assert(code_o==8'h5a || code_o==8'ha5);
            if (alarm_o) assert(code_o==8'h5a);
            if ($past(por_ni && failed_q && epoch_sync_q[1]==epoch_o)) assert(!qualified_q);
            if ($past(por_ni && listening_q && !failed_q && !bad && remaining_q<=1 && epoch_sync_q[1]==epoch_o)) assert(failed_q && !qualified_q);
            if ($past(por_ni && listening_q && !failed_q && !bad && remaining_q>1 && !changed && epoch_sync_q[1]==epoch_o)) assert(remaining_q==$past(remaining_q)-10'd1);
        end
    end
`endif
endmodule
`default_nettype wire
