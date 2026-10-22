// Four-entry always-on outbound queue and one-outstanding bundled-data mailbox.
// The protected producer holds data until its synchronized request is acknowledged.
// Purge does not need a protected clock or OS acknowledgement. No storage follows
// the two independent final transaction cuts in the enclosing endpoint.
`default_nettype none
module reins_endpoint_queue (
    input logic clk_i, por_ni, run_i,    // Always-on egress clock / power / queue admission and purge control.
    input logic request_i,             // Protected producer's asynchronous request toggle.
    input logic [135:0] data_i,         // Stable bundled data, held through acknowledgement.
    output logic acknowledge_o,        // Toggle echoed only after capture (or while purging).
    input logic pop_i,                 // Actual final receiver handshake, after both cuts.
    output logic valid_o, empty_o, fault_o,
    output logic [2:0] queued_o,        // Diagnostic occupancy; no authorization implied.
    output logic [135:0] data_o         // Current head, stable under receiver backpressure.
);
    (* ASYNC_REG="TRUE" *) logic [1:0] request_sync_q;
    // All pending effect storage is upstream of both final isolation cuts.
    logic [135:0] memory_q[0:3];
    // Range/complement-protected metadata controls admission; corruption never exposes a valid head.
    logic [1:0] head_q, tail_q, head_inverse_q, tail_inverse_q;
    logic [2:0] count_q, count_inverse_q;
    logic push;
    assign fault_o=por_ni && (count_q!=~count_inverse_q || head_q!=~head_inverse_q ||
        tail_q!=~tail_inverse_q || count_q>4);
    assign valid_o=por_ni && run_i && !fault_o && count_q!=0;
    assign empty_o=por_ni && !fault_o && count_q==0;
    assign queued_o=count_q;
    assign data_o=valid_o ? memory_q[head_q] : 136'd0;
    assign push=run_i && !fault_o && count_q<4 && request_sync_q[1]!=acknowledge_o;
    always_ff @(posedge clk_i or negedge por_ni) begin
        if (!por_ni) begin
            request_sync_q<=0; acknowledge_o<=0; head_q<=0; tail_q<=0;
            head_inverse_q<='1; tail_inverse_q<='1; count_q<=0; count_inverse_q<='1;
        end else begin
            request_sync_q<={request_sync_q[0],request_i};
            if (!run_i || fault_o) begin
                acknowledge_o<=request_sync_q[1]; head_q<=0; tail_q<=0;
                head_inverse_q<='1; tail_inverse_q<='1; count_q<=0; count_inverse_q<='1;
            end else begin
                if (push) begin
                    memory_q[tail_q]<=data_i; acknowledge_o<=request_sync_q[1];
                    tail_q<=tail_q+2'd1; tail_inverse_q<=tail_inverse_q-2'd1;
                end
                if (pop_i && valid_o) begin head_q<=head_q+2'd1; head_inverse_q<=head_inverse_q-2'd1; end
                case ({push,(pop_i && valid_o)})
                    2'b10: begin count_q<=count_q+3'd1; count_inverse_q<=count_inverse_q-3'd1; end
                    2'b01: begin count_q<=count_q-3'd1; count_inverse_q<=count_inverse_q+3'd1; end
                    default: ;
                endcase
            end
        end
    end
endmodule
`default_nettype wire
