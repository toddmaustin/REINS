// Actual parameterized controller at a qualified-platform/abstract-verifier boundary.
// Inputs are symbolic; configuration/hash are assumed qualified constants, not OTP verification.
module r11_controller(input logic clk,por,reset,cold,fault,abort_job,begin_run,nonce_valid,submit,complete,tick,
    input logic [1:0] slot,pass_id, input logic [7:0] code, input logic [63:0] now);
    wire  restart_ready_o; // Observed actual controller output.
    wire  stop_request_o; // Observed actual controller output.
    wire  run_end_o; // Observed actual controller output.
    wire [7:0] state_o; // Observed actual controller output.
    wire  fault_o; // Observed actual controller output.
    wire  permit_o; // Observed actual controller output.
    wire [63:0] run_generation_o; // Observed actual controller output.
    wire [63:0] round_o; // Observed actual controller output.
    wire [63:0] job_generation_o; // Observed actual controller output.
    wire  pending_o; // Observed actual controller output.
    wire  request_valid_o; // Observed actual controller output.
    wire [1023:0] request_o; // Observed actual controller output.
    wire [63:0] issue_o; // Observed actual controller output.
    wire [63:0] deadline_o; // Observed actual controller output.
    wire [63:0] proposed_expiry_o; // Observed actual controller output.
    wire [2:0] votes_o; // Observed actual controller output.
    wire  draw_valid_o; // Observed actual controller output.
    wire [63:0] draw_round_o; // Observed actual controller output.
    wire [63:0] draw_issue_o; // Observed actual controller output.
    wire  nonce_ready_o; // Observed actual controller output.
    wire  submit_ready_o; // Observed actual controller output.
    wire  job_valid_o; // Observed actual controller output.
    wire  job_active_o; // Observed actual controller output.
    wire [63:0] job_token_o; // Observed actual controller output.
    wire [63:0] job_run_o; // Observed actual controller output.
    wire [63:0] job_round_o; // Observed actual controller output.
    wire [63:0] job_epoch_o; // Observed actual controller output.
    wire [1:0] job_slot_o; // Observed actual controller output.
    wire [1023:0] job_request_o; // Observed actual controller output.
    wire [2175:0] job_configuration_o; // Observed actual controller output.
    wire [255:0] job_config_digest_o; // Observed actual controller output.
    wire  cancel_valid_o; // Observed actual controller output.
    wire [63:0] cancel_token_o; // Observed actual controller output.
    wire  completion_ready_o; // Observed actual controller output.
    wire  result_valid_o; // Observed actual controller output.
    wire [63:0] result_token_o; // Observed actual controller output.
    wire [1:0] result_code_o; // Observed actual controller output.
    wire  vote_event_o; // Observed actual controller output.
    wire  commit_event_o; // Observed actual controller output.
    wire  lease_valid_o; // Observed actual controller output.
    wire [63:0] committed_issue_o; // Observed actual controller output.
    wire [63:0] lease_expiry_o; // Observed actual controller output.
    wire [63:0] remaining_o; // Observed actual controller output.
    reins_controller #(.ID_WIDTH(4),.ROUND_WIDTH(4),.TIME_WIDTH(8)) control(
        .clk_i(clk),
        .por_ni(por),
        .logic_reset_i(reset),
        .cold_clear_i(cold),
        .config_closed_i(1'b1),
        .config_valid_i(1'b1),
        .configuration_i(2176'd0),
        .config_digest_i(256'd0),
        .lease_i(64'd20),
        .period_i(64'd8),
        .window_i(64'd6),
        .fault_i(fault),
        .entropy_failure_i(1'b0),
        .grant_enable_i(1'b1),
        .now_i(now),
        .tick_i(tick),
        .run_begin_i(begin_run),
        .platform_generation_i(64'd1),
        .restart_ready_o(restart_ready_o),
        .stop_ack_i(1'b1),
        .stop_request_o(stop_request_o),
        .run_end_o(run_end_o),
        .state_o(state_o),
        .fault_o(fault_o),
        .permit_o(permit_o),
        .run_generation_o(run_generation_o),
        .round_o(round_o),
        .job_generation_o(job_generation_o),
        .pending_o(pending_o),
        .request_valid_o(request_valid_o),
        .request_slot_i(slot),
        .request_o(request_o),
        .issue_o(issue_o),
        .deadline_o(deadline_o),
        .proposed_expiry_o(proposed_expiry_o),
        .votes_o(votes_o),
        .draw_valid_o(draw_valid_o),
        .draw_ready_i(1'b1),
        .draw_round_o(draw_round_o),
        .draw_issue_o(draw_issue_o),
        .nonce_valid_i(nonce_valid),
        .nonce_ready_o(nonce_ready_o),
        .nonce_i(256'd1),.nonce_audit_i(~256'd1),
        .nonce_round_i(round_o),
        .nonce_issue_i(issue_o),
        .nonce_generation_i(run_generation_o),
        .submit_valid_i(submit),
        .submit_ready_o(submit_ready_o),
        .submit_slot_i(slot),
        .abort_valid_i(abort_job),
        .abort_token_i(job_token_o),
        .job_valid_o(job_valid_o),
        .job_ready_i(1'b1),
        .job_active_o(job_active_o),
        .job_token_o(job_token_o),
        .job_run_o(job_run_o),
        .job_round_o(job_round_o),
        .job_epoch_o(job_epoch_o),
        .job_slot_o(job_slot_o),
        .job_request_o(job_request_o),
        .job_configuration_o(job_configuration_o),
        .job_config_digest_o(job_config_digest_o),
        .cancel_valid_o(cancel_valid_o),
        .cancel_token_o(cancel_token_o),
        .completion_valid_i(complete),
        .completion_ready_o(completion_ready_o),
        .completion_token_i(job_token_o),
        .completion_run_i(job_run_o),
        .completion_round_i(job_round_o),
        .completion_epoch_i(job_epoch_o),
        .completion_slot_i(job_slot_o),
        .completion_pass_i(pass_id),
        .completion_request_i(job_request_o),
        .completion_config_digest_i(job_config_digest_o),
        .completion_code_i(code),
        .result_valid_o(result_valid_o),
        .result_token_o(result_token_o),
        .result_code_o(result_code_o),
        .vote_event_o(vote_event_o),
        .commit_event_o(commit_event_o),
        .lease_valid_o(lease_valid_o),
        .committed_issue_o(committed_issue_o),
        .lease_expiry_o(lease_expiry_o),
        .remaining_o(remaining_o)
    );
endmodule
