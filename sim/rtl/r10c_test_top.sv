// SIMULATION ONLY: actual R06 controller, full verifier bank and protected SRAM.
// Platform/receive admission is a declared component boundary, never a production port.
`default_nettype none
module r10c_test_top (
    input logic clk_i, por_ni, reset_i, cold_i, cancel_i,
    input logic [2175:0] configuration_i,
    input logic [255:0] configuration_digest_i,
    input logic [63:0] lease_i, period_i, window_i, now_i,
    input logic tick_i, run_begin_i,
    input logic [255:0] nonce_i,
    input logic nonce_valid_i,
    input logic [1:0] slot_i,
    output logic [1023:0] request_o,
    output logic request_valid_o, restart_ready_o,
    input logic submit_i,
    input logic acquire_i, release_i, seal_i, write_valid_i,
    input logic [63:0] memory_token_i,
    input logic [13:0] write_address_i, total_i,
    input logic [7:0] write_data_i,
    output logic sealed_o, memory_fault_o, write_event_o,
    output logic permit_o, fault_o, verifier_fault_o, result_valid_o, vote_event_o, commit_event_o,
    output logic [1:0] result_code_o,
    output logic [2:0] votes_o,
    output logic [63:0] expiry_o, run_o, round_o, epoch_o, token_o,
    output logic [7:0] controller_state_o, verifier_state_o,
    output logic [15:0] lane_state_o,
    output logic [31:0] starts_o, completions_o, expected_o,
    output logic [5:0] physical_start_o, physical_complete_o,
    output logic read_valid_o, output logic [13:0] read_address_o, read_inverse_o,
    output logic [3:0] read_owner_o,
    output logic completion_valid_o, output logic [1:0] completion_pass_o,
    output logic [7:0] completion_code_o,
    output logic [5:0] core_start_o, core_end_o,
    output logic [511:0] core_block_o [0:5],
    output logic [255:0] core_state_o [0:5],
    output logic [1:0] stage_valid_o,
    output logic [127:0] stage_value_o [0:1],
    output logic [7:0] stage_phase_o [0:1],
    `include "fault_ports.svh"
);
    logic job_valid, job_ready, job_active, completion_ready, memory_valid, cancel_valid;
    logic [63:0] job_run, job_round, job_epoch, job_token, unused_cancel_token, completion_run, completion_round, completion_epoch, completion_token;
    logic [1:0] job_slot, completion_slot;
    logic [1023:0] job_request, completion_request;
    logic [2175:0] unused_job_configuration;
    logic [255:0] job_config, completion_config;
    logic [7:0] read_data;
    // Break passive observation aliases so faultable child outputs work on Verilator 5.008.
    logic [13:0] memory_address, memory_inverse;
    assign read_address_o=por_ni ? memory_address : 14'd0;
    assign read_inverse_o=por_ni ? memory_inverse : 14'd0;
    logic [2:0] unused_reason;
    logic unused_stop, unused_draw, unused_submit_ready, unused_lease, unused_run_end;
    logic [63:0] unused_draw_round, unused_draw_issue, unused_result_token;
    logic [63:0] unused_issue, unused_deadline, unused_proposed, unused_committed, unused_remaining, unused_generation;
    logic unused_pending, unused_nonce_ready;
    reins_controller controller (
        .clk_i(clk_i),.por_ni(por_ni),.logic_reset_i(reset_i),.cold_clear_i(cold_i),
        .config_closed_i(1'b1),.config_valid_i(1'b1),.configuration_i(configuration_i),.config_digest_i(configuration_digest_i),
        .lease_i(lease_i),.period_i(period_i),.window_i(window_i),.fault_i(verifier_fault_o || memory_fault_o),
        .entropy_failure_i(1'b0),.grant_enable_i(1'b1),.now_i(now_i),.tick_i(tick_i),.run_begin_i(run_begin_i),.platform_generation_i(64'd1),
        .restart_ready_o(restart_ready_o),.stop_ack_i(1'b1),.stop_request_o(unused_stop),.run_end_o(unused_run_end),
        .state_o(controller_state_o),.fault_o(fault_o),.permit_o(permit_o),.run_generation_o(run_o),.round_o(round_o),.job_generation_o(unused_generation),
        .pending_o(unused_pending),.request_valid_o(request_valid_o),.request_slot_i(slot_i),.request_o(request_o),
        .issue_o(unused_issue),.deadline_o(unused_deadline),.proposed_expiry_o(unused_proposed),.votes_o(votes_o),
        .draw_valid_o(unused_draw),.draw_ready_i(1'b1),.draw_round_o(unused_draw_round),.draw_issue_o(unused_draw_issue),
        .nonce_valid_i(nonce_valid_i),.nonce_ready_o(unused_nonce_ready),.nonce_i(nonce_i),.nonce_audit_i(~nonce_i),.nonce_round_i(round_o),.nonce_issue_i(unused_issue),.nonce_generation_i(run_o),
        .submit_valid_i(submit_i),.submit_ready_o(unused_submit_ready),.submit_slot_i(slot_i),.abort_valid_i(cancel_i),.abort_token_i(job_token),
        .job_valid_o(job_valid),.job_ready_i(job_ready),.job_active_o(job_active),.job_token_o(job_token),.job_run_o(job_run),.job_round_o(job_round),.job_epoch_o(job_epoch),.job_slot_o(job_slot),
        .job_request_o(job_request),.job_configuration_o(unused_job_configuration),.job_config_digest_o(job_config),
        .cancel_valid_o(cancel_valid),.cancel_token_o(unused_cancel_token),.completion_valid_i(completion_valid_o),.completion_ready_o(completion_ready),
        .completion_token_i(completion_token),.completion_run_i(completion_run),.completion_round_i(completion_round),.completion_epoch_i(completion_epoch),.completion_slot_i(completion_slot),
        .completion_pass_i(completion_pass_o),.completion_request_i(completion_request),.completion_config_digest_i(completion_config),.completion_code_i(completion_code_o),
        .result_valid_o(result_valid_o),.result_token_o(unused_result_token),.result_code_o(result_code_o),.vote_event_o(vote_event_o),.commit_event_o(commit_event_o),
        .lease_valid_o(unused_lease),.committed_issue_o(unused_committed),.lease_expiry_o(expiry_o),.remaining_o(unused_remaining));
    assign epoch_o=job_epoch; assign token_o=job_token;
    reins_receive_sram memory (
        .clk_i(clk_i),.por_ni(por_ni),.reset_i(reset_i || cold_i),.acquire_i(acquire_i),.release_i(release_i),.seal_i(seal_i),
        .acquire_token_i(memory_token_i),.acquire_token_inverse_i(~memory_token_i),.token_i(memory_token_i),.token_inverse_i(~memory_token_i),
        .write_valid_i(write_valid_i),.write_code_i(8'hc3),.write_address_i(write_address_i),.write_address_inverse_i(~write_address_i),.write_data_i(write_data_i),.write_event_o(write_event_o),
        .read_valid_i(read_valid_o),.read_address_i(memory_address),.read_address_inverse_i(memory_inverse),.read_valid_o(memory_valid),.read_data_o(read_data),.sealed_o(sealed_o),.fault_o(memory_fault_o));
    reins_verifier verifier (
        .clk_i(clk_i),.rst_ni(por_ni && !reset_i && !cold_i),.cancel_i(cancel_i || cancel_valid),
        .context_valid_i(job_active && sealed_o),.live_i(job_active && sealed_o && !memory_fault_o && !reset_i && !cold_i && now_i<unused_deadline),
        .job_valid_i(job_valid),.job_ready_o(job_ready),.configuration_i(configuration_i),.configuration_digest_i(job_config),.request_i(job_request),
        .run_i(job_run),.round_i(job_round),.token_i(job_token),.epoch_i(job_epoch),.slot_i(job_slot),.reply_length_i(total_i),
        .read_valid_o(read_valid_o),.read_address_o(memory_address),.read_address_inverse_o(memory_inverse),.read_valid_i(memory_valid),.read_data_i(read_data),
        .completion_valid_o(completion_valid_o),.completion_ready_i(completion_ready),.completion_run_o(completion_run),.completion_round_o(completion_round),
        .completion_token_o(completion_token),.completion_epoch_o(completion_epoch),.completion_slot_o(completion_slot),.completion_pass_o(completion_pass_o),
        .completion_request_o(completion_request),.completion_config_o(completion_config),.completion_code_o(completion_code_o),.completion_reason_o(unused_reason),
        .fault_o(verifier_fault_o),.state_o(verifier_state_o),.lane_state_o(lane_state_o),.starts_o(starts_o),.completions_o(completions_o),.expected_o(expected_o),
        .physical_start_o(physical_start_o),.physical_complete_o(physical_complete_o),.read_owner_o(read_owner_o));
assign core_start_o[0]=verifier.passes[0].engine.merkle.hasher.core.req_valid_i && verifier.passes[0].engine.merkle.hasher.core.req_ready_o;
assign core_end_o[0]=verifier.passes[0].engine.merkle.hasher.core.rsp_valid_o && verifier.passes[0].engine.merkle.hasher.core.rsp_ready_i;
assign core_block_o[0]=verifier.passes[0].engine.merkle.hasher.core.req_block_i;
assign core_state_o[0]=verifier.passes[0].engine.merkle.hasher.core.req_state_i;
assign core_start_o[1]=verifier.passes[0].engine.slh.core.hash.backend.core.req_valid_i && verifier.passes[0].engine.slh.core.hash.backend.core.req_ready_o;
assign core_end_o[1]=verifier.passes[0].engine.slh.core.hash.backend.core.rsp_valid_o && verifier.passes[0].engine.slh.core.hash.backend.core.rsp_ready_i;
assign core_block_o[1]=verifier.passes[0].engine.slh.core.hash.backend.core.req_block_i;
assign core_state_o[1]=verifier.passes[0].engine.slh.core.hash.backend.core.req_state_i;
assign core_start_o[2]=verifier.passes[0].engine.slh.core.wots.hash.backend.core.req_valid_i && verifier.passes[0].engine.slh.core.wots.hash.backend.core.req_ready_o;
assign core_end_o[2]=verifier.passes[0].engine.slh.core.wots.hash.backend.core.rsp_valid_o && verifier.passes[0].engine.slh.core.wots.hash.backend.core.rsp_ready_i;
assign core_block_o[2]=verifier.passes[0].engine.slh.core.wots.hash.backend.core.req_block_i;
assign core_state_o[2]=verifier.passes[0].engine.slh.core.wots.hash.backend.core.req_state_i;
assign stage_valid_o[0]=por_ni && verifier.passes[0].engine.stage_valid;
assign stage_value_o[0]=verifier.passes[0].engine.stage_value;
assign stage_phase_o[0]=verifier.passes[0].engine.stage_phase;
assign core_start_o[3]=verifier.passes[1].engine.merkle.hasher.core.req_valid_i && verifier.passes[1].engine.merkle.hasher.core.req_ready_o;
assign core_end_o[3]=verifier.passes[1].engine.merkle.hasher.core.rsp_valid_o && verifier.passes[1].engine.merkle.hasher.core.rsp_ready_i;
assign core_block_o[3]=verifier.passes[1].engine.merkle.hasher.core.req_block_i;
assign core_state_o[3]=verifier.passes[1].engine.merkle.hasher.core.req_state_i;
assign core_start_o[4]=verifier.passes[1].engine.slh.core.hash.backend.core.req_valid_i && verifier.passes[1].engine.slh.core.hash.backend.core.req_ready_o;
assign core_end_o[4]=verifier.passes[1].engine.slh.core.hash.backend.core.rsp_valid_o && verifier.passes[1].engine.slh.core.hash.backend.core.rsp_ready_i;
assign core_block_o[4]=verifier.passes[1].engine.slh.core.hash.backend.core.req_block_i;
assign core_state_o[4]=verifier.passes[1].engine.slh.core.hash.backend.core.req_state_i;
assign core_start_o[5]=verifier.passes[1].engine.slh.core.wots.hash.backend.core.req_valid_i && verifier.passes[1].engine.slh.core.wots.hash.backend.core.req_ready_o;
assign core_end_o[5]=verifier.passes[1].engine.slh.core.wots.hash.backend.core.rsp_valid_o && verifier.passes[1].engine.slh.core.wots.hash.backend.core.rsp_ready_i;
assign core_block_o[5]=verifier.passes[1].engine.slh.core.wots.hash.backend.core.req_block_i;
assign core_state_o[5]=verifier.passes[1].engine.slh.core.wots.hash.backend.core.req_state_i;
assign stage_valid_o[1]=verifier.passes[1].engine.stage_valid;
assign stage_value_o[1]=verifier.passes[1].engine.stage_value;
assign stage_phase_o[1]=verifier.passes[1].engine.stage_phase;
    `include "r10c_fault_sites.svh"
endmodule
`default_nettype wire
