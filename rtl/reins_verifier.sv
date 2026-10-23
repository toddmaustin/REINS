// The production verifier bank owns exactly two independently sequenced complete
// passes. It shares only sealed SRAM through a checked mux and protected input
// provenance; neither pass consumes the other's root, scratch, digits or digest.
`default_nettype none
module reins_verifier (
    // Always-on monitor, trusted reset and highest-priority cancellation.
    input logic clk_i, rst_ni, cancel_i,
    input logic context_valid_i, live_i, // Registered owned context / independent immediate final health/deadline gate.
    input logic job_valid_i,
    output logic job_ready_o,
    // Checked platform image and immutable controller job remain the original source for both lanes.
    input logic [2175:0] configuration_i,
    input logic [255:0] configuration_digest_i,
    input logic [1023:0] request_i,
    input logic [63:0] run_i, round_i, token_i, epoch_i,
    input logic [1:0] slot_i,
    input logic [13:0] reply_length_i,
    // Exclusive physical read path into the one sealed receive SRAM.
    output logic read_valid_o,
    output logic [13:0] read_address_o, read_address_inverse_o,
    input logic read_valid_i,
    input logic [7:0] read_data_i,
    // Held sparse result and complete provenance; final live gating precedes the R06 edge checks.
    output logic completion_valid_o,
    input logic completion_ready_i,
    output logic [63:0] completion_run_o, completion_round_o, completion_token_o, completion_epoch_o,
    output logic [1:0] completion_slot_o, completion_pass_o,
    output logic [1023:0] completion_request_o,
    output logic [255:0] completion_config_o,
    output logic [7:0] completion_code_o,
    output logic [2:0] completion_reason_o,
    output logic fault_o,
    output logic [7:0] state_o,
    output logic [15:0] lane_state_o,
    output logic [31:0] starts_o, completions_o, expected_o,
    output logic [5:0] physical_start_o, physical_complete_o,
    output logic [3:0] read_owner_o // Sparse physical reader ownership: lane 1=3, lane 2=c, idle=0.
);
    typedef struct packed {
        logic [63:0] run_id, round_id, token, epoch;
        logic [1:0] slot;
        logic [13:0] length;
        logic [1023:0] request_body;
        logic [255:0] config_hash;
    } context_t;
    localparam logic [7:0] IDLE=8'h0f,START1=8'h33,WAIT1=8'h55,OUT1=8'h69,
        START2=8'h96,WAIT2=8'haa,OUT2=8'hcc;
    logic [7:0] state_q, state_inv_q, capture_q, capture_inv_q;
    context_t context_q, context_inv_q;
    logic [1:0] ready, valid, fault;
    logic [7:0] code [0:1], lane_state [0:1];
    logic [1:0] error [0:1];
    logic [13:0] address [0:1], inverse_address [0:1], intended [0:1];
    logic [1:0] read_request;
    logic [15:0] starts [0:1], ends [0:1], expected [0:1];
    logic [2:0] physical_start [0:1], physical_end [0:1];
    logic [5:0] unused_stages [0:1];
    logic [8:0] unused_chains [0:1];
    logic [127:0] unused_root [0:1];
    logic [255:0] unused_leaf [0:1], unused_batch_root [0:1];
    logic owned, second, bad, failed_q, live_same;
    assign owned=state_q!=IDLE;
    assign second=state_q==START2 || state_q==WAIT2 || state_q==OUT2;
    assign live_same=context_q=={run_i,round_i,token_i,epoch_i,slot_i,reply_length_i,request_i,configuration_digest_i};
    assign bad=state_q!=~state_inv_q || context_q!=~context_inv_q || capture_q!=~capture_inv_q ||
        (owned && context_valid_i && !cancel_i && !live_same) ||
        !(state_q==IDLE || state_q==START1 || state_q==WAIT1 || state_q==OUT1 || state_q==START2 || state_q==WAIT2 || state_q==OUT2) ||
        (read_valid_o && ((read_owner_o==4'h3 && (read_address_o!=intended[0] || read_address_inverse_o!=~intended[0])) ||
                         (read_owner_o==4'hc && (read_address_o!=intended[1] || read_address_inverse_o!=~intended[1])) ||
                         !(read_owner_o==4'h3 || read_owner_o==4'hc))) ||
        (state_q==OUT1 && !cancel_i && context_valid_i && live_same && (!valid[0] || capture_q!=code[0] || (capture_q!=0 && capture_q!=8'h96))) ||
        (state_q==OUT2 && !cancel_i && context_valid_i && live_same && (!valid[1] || capture_q!=code[1] || (capture_q!=0 && capture_q!=8'h69))) ||
        (owned && read_request[0] && read_request[1]);
    assign fault_o=rst_ni && (failed_q || bad || (|fault));
    assign job_ready_o=rst_ni && !cancel_i && context_valid_i && live_i && state_q==IDLE && (&ready) && !fault_o;
    assign completion_valid_o=rst_ni && !cancel_i && context_valid_i && live_i && live_same && !fault_o && (state_q==OUT1 || state_q==OUT2);
    assign completion_code_o=completion_valid_o ? capture_q : 8'd0;
    assign completion_pass_o=second ? 2'd2 : 2'd1;
    assign completion_run_o=context_q.run_id; assign completion_round_o=context_q.round_id;
    assign completion_token_o=context_q.token; assign completion_epoch_o=context_q.epoch;
    assign completion_slot_o=context_q.slot; assign completion_request_o=context_q.request_body;
    assign completion_config_o=context_q.config_hash;
    assign completion_reason_o=(second ? error[1] : error[0])==1 ? 3'd1 : 3'd2;
    assign read_valid_o=rst_ni && !cancel_i && owned && (second ? read_request[1] : read_request[0]);
    assign read_address_o=second ? address[1] : address[0];
    assign read_address_inverse_o=second ? inverse_address[1] : inverse_address[0];
    assign read_owner_o=read_valid_o ? (second ? 4'hc : 4'h3) : 4'd0;
    assign state_o=state_q; assign lane_state_o={lane_state[1],lane_state[0]};
    assign starts_o={starts[1],starts[0]}; assign completions_o={ends[1],ends[0]}; assign expected_o={expected[1],expected[0]};
    assign physical_start_o={physical_start[1],physical_start[0]}; assign physical_complete_o={physical_end[1],physical_end[0]};
    for (genvar lane=0;lane<2;lane++) begin : passes
        reins_verifier_pass #(.PASS_ID(lane+1)) engine (
            .clk_i(clk_i),.rst_ni(rst_ni),.cancel_i(cancel_i || (!owned && lane_state[lane]!=8'h0f)),.context_valid_i(context_valid_i),
            .req_valid_i(lane==0 ? state_q==START1 : state_q==START2),.req_ready_o(ready[lane]),
            .configuration_i(configuration_i),.configuration_digest_i(configuration_digest_i),.request_i(request_i),
            .run_i(run_i),.round_i(round_i),.token_i(token_i),.epoch_i(epoch_i),.slot_i(slot_i),.reply_length_i(reply_length_i),
            .read_valid_o(read_request[lane]),.read_address_o(address[lane]),.read_address_inverse_o(inverse_address[lane]),.intended_address_o(intended[lane]),
            .read_valid_i(read_valid_i && read_owner_o==(lane==0 ? 4'h3 : 4'hc)),.read_data_i(read_data_i),
            .rsp_valid_o(valid[lane]),.rsp_ready_i(completion_valid_o && completion_ready_i && completion_pass_o==2'(lane+1)),
            .accept_code_o(code[lane]),.error_o(error[lane]),.fault_o(fault[lane]),.state_o(lane_state[lane]),
            .starts_o(starts[lane]),.completions_o(ends[lane]),.expected_o(expected[lane]),
            .observed_stages_o(unused_stages[lane]),.observed_chains_o(unused_chains[lane]),.root_o(unused_root[lane]),
            .leaf_o(unused_leaf[lane]),.batch_root_o(unused_batch_root[lane]),.physical_start_o(physical_start[lane]),.physical_complete_o(physical_end[lane]));
    end
    // Erase only bank provenance/capture. Lane scratch and failures have their own reset/cancel ownership; no parameters.
    task automatic erase_bank();
        state_q<=IDLE; state_inv_q<=~IDLE; context_q<='0; context_inv_q<='1; capture_q<=0; capture_inv_q<='1;
    endtask
    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin erase_bank(); failed_q<=0; end
        else if (cancel_i || !context_valid_i || (owned && (!live_i || !live_same))) begin
            erase_bank(); failed_q<=failed_q || bad || (|fault);
        end else if (bad || (|fault)) begin failed_q<=1; end
        else case (state_q)
        IDLE: if (job_valid_i && job_ready_o) begin
            context_q<={run_i,round_i,token_i,epoch_i,slot_i,reply_length_i,request_i,configuration_digest_i};
            context_inv_q<=~{run_i,round_i,token_i,epoch_i,slot_i,reply_length_i,request_i,configuration_digest_i};
            state_q<=START1; state_inv_q<=~START1;
        end
        START1: if (ready[0]) begin state_q<=WAIT1; state_inv_q<=~WAIT1; end
        WAIT1: if (valid[0]) begin capture_q<=code[0]; capture_inv_q<=~code[0]; state_q<=OUT1; state_inv_q<=~OUT1; end
        OUT1: if (completion_valid_o && completion_ready_i) begin state_q<=START2; state_inv_q<=~START2; capture_q<=0; capture_inv_q<='1; end
        START2: if (ready[1]) begin state_q<=WAIT2; state_inv_q<=~WAIT2; end
        WAIT2: if (valid[1]) begin capture_q<=code[1]; capture_inv_q<=~code[1]; state_q<=OUT2; state_inv_q<=~OUT2; end
        OUT2: if (completion_valid_o && completion_ready_i) erase_bank();
        default: begin erase_bank(); failed_q<=1; end
        endcase
    end
endmodule
`default_nettype wire
