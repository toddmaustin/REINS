// Representative CPU/accelerator/DMA endpoint. Two local actuation paths each
// own a distinct serial clock cell AND a distinct outbound cut after all queues.
// The shared producer reset and queue-admission control are not final enables:
// tying either permissive cannot bypass those independent physical paths.
`default_nettype none
module reins_protected_endpoint #(
    parameter int unsigned ENDPOINT_ID=0
) (
    input logic egress_clock_i, raw_clock_i, por_ni, // Always-on queue clock / protected raw clock / power reset.
    input logic guard_clock_a_i, guard_clock_b_i,    // Physically independent local guard clocks.
    input logic epoch_a_i, epoch_b_i,               // Each local guard's acknowledged fresh-arm epoch.
    input logic [7:0] code_a_i, code_b_i,           // Separate local sparse codes; no joined final enable.
    input logic [63:0] generation_i,                // Trusted run identity for stale-queue observations.
    input logic outbound_ready_i,                  // Untrusted downstream backpressure.
    output logic outbound_valid_o,
    output logic [135:0] outbound_data_o,           // generation[64] || sequence[64] || endpoint[8].
    output logic [63:0] work_count_o,               // Representative useful-work state, cleared by isolation.
    output logic queue_empty_o,
    output logic [2:0] queued_o,
    output logic closed_a_o, closed_b_o,            // Actual cell readbacks plus completed local actuation.
    output logic open_a_o, open_b_o,                // Passive diagnostics for independently controlled cuts.
    output logic protected_clock_o, fault_o         // Passive actual clock / queue or actuator integrity alarm.
);
    logic clock_open_a, clock_open_b, act_closed_a, act_closed_b, act_fault_a, act_fault_b;
    logic intermediate_clock, clock_closed_a, clock_closed_b, cut_closed_a, cut_closed_b;
    logic compute_reset_ni, queue_run, queue_fault, acknowledge, request_q;
    logic [1:0] acknowledge_sync_q;
    logic [135:0] producer_data_q, queue_data, cut_a_data;
    logic queue_valid, cut_a_valid, queue_pop;
    reins_endpoint_actuator actuator_a (
        .clk_i(guard_clock_a_i), .por_ni(por_ni), .epoch_i(epoch_a_i), .code_i(code_a_i),
        .isolation_open_o(open_a_o), .clock_open_o(clock_open_a), .closed_o(act_closed_a), .fault_o(act_fault_a)
    );
    reins_endpoint_actuator #(.OPEN_CODE(8'ha5),.DENY_CODE(8'h5a),.ACTUATION_CYCLES(125)) actuator_b (
        .clk_i(guard_clock_b_i), .por_ni(por_ni), .epoch_i(epoch_b_i), .code_i(code_b_i),
        .isolation_open_o(open_b_o), .clock_open_o(clock_open_b), .closed_o(act_closed_b), .fault_o(act_fault_b)
    );
    (* dont_touch="yes", keep_hierarchy="yes" *) reins_clock_isolation clock_cut_a (
        .raw_clock_i(raw_clock_i), .por_ni(por_ni), .allow_i(clock_open_a),
        .clock_o(intermediate_clock), .closed_o(clock_closed_a)
    );
    (* dont_touch="yes", keep_hierarchy="yes" *) reins_clock_isolation clock_cut_b (
        .raw_clock_i(intermediate_clock), .por_ni(por_ni), .allow_i(clock_open_b),
        .clock_o(protected_clock_o), .closed_o(clock_closed_b)
    );
    // This shared reset aids quiescence; the two separately driven serial clock cells remain final barriers.
    assign compute_reset_ni=por_ni && open_a_o && open_b_o;
    always_ff @(posedge protected_clock_o or negedge compute_reset_ni) begin
        if (!compute_reset_ni) begin work_count_o<=0; request_q<=0; producer_data_q<=0; acknowledge_sync_q<=0; end
        else begin
            work_count_o<=work_count_o+64'(2*ENDPOINT_ID+1);
            acknowledge_sync_q<={acknowledge_sync_q[0],acknowledge};
            if (work_count_o[3:0]==0 && request_q==acknowledge_sync_q[1]) begin
                producer_data_q<={generation_i,work_count_o,8'(ENDPOINT_ID)}; request_q<=~request_q;
            end
        end
    end
    // Admission/purge is deliberately separate from either final transaction cut.
    assign queue_run=open_a_o && open_b_o;
    assign queue_pop=outbound_valid_o && outbound_ready_i;
    reins_endpoint_queue queue (
        .clk_i(egress_clock_i), .por_ni(por_ni), .run_i(queue_run), .request_i(request_q), .data_i(producer_data_q),
        .acknowledge_o(acknowledge), .pop_i(queue_pop), .valid_o(queue_valid), .empty_o(queue_empty_o),
        .fault_o(queue_fault), .queued_o(queued_o), .data_o(queue_data)
    );
    (* dont_touch="yes", keep_hierarchy="yes" *) reins_transaction_isolation transaction_cut_a (
        .allow_i(open_a_o), .valid_i(queue_valid), .data_i(queue_data), .generation_i(generation_i),
        .valid_o(cut_a_valid), .data_o(cut_a_data), .closed_o(cut_closed_a)
    );
    (* dont_touch="yes", keep_hierarchy="yes" *) reins_transaction_isolation #(.COMPLEMENT_COMPARE(1'b1)) transaction_cut_b (
        .allow_i(open_b_o), .valid_i(cut_a_valid), .data_i(cut_a_data), .generation_i(generation_i),
        .valid_o(outbound_valid_o), .data_o(outbound_data_o), .closed_o(cut_closed_b)
    );
    assign closed_a_o=act_closed_a && clock_closed_a && cut_closed_a;
    assign closed_b_o=act_closed_b && clock_closed_b && cut_closed_b;
    assign fault_o=act_fault_a || act_fault_b || queue_fault;
endmodule
`default_nettype wire
