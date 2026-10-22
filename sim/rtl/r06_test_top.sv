// SIMULATION ONLY: software-backed verifier and qualified-platform stimulus ports.
// small_i selects a separate reduced-limit instance for reachable overflow tests.
// Neither this selector nor host verification is part of the production composition.
`default_nettype none
module r06_test_top (
    input logic small_i,
    input logic lease_probe_valid_i,
    input logic [63:0] lease_probe_now_i, lease_probe_length_i, lease_probe_issue_i,
    input logic [63:0] lease_probe_issue_inverse_i, lease_probe_expiry_i,
    input logic [63:0] lease_probe_remaining_i, lease_probe_remaining_inverse_i,
    output logic lease_probe_fault_o, lease_probe_permit_o,
    input logic [63:0] math_round_i, math_period_i, math_window_i, math_lease_i,
    output logic math_valid_o,
    output logic [63:0] math_issue_o, math_deadline_o, math_expiry_o, math_next_o,
    input logic  clk_i, // Always-on monitor clock / actual retention loss.
    input logic  por_ni, // Always-on monitor clock / actual retention loss.
    input logic  logic_reset_i, // Cancel authorization / trusted cold fault requalification.
    input logic  cold_clear_i, // Cancel authorization / trusted cold fault requalification.
    input logic  config_closed_i, // Retained closure / completely checked R05 snapshot.
    input logic  config_valid_i, // Retained closure / completely checked R05 snapshot.
    input logic [2175:0] configuration_i, // Exact public OTP, immutable throughout a run.
    input logic [255:0] config_digest_i, // Actual R05 C_cfg, checked against captured copies.
    input logic [63:0] lease_i, // Checked L/P/W in local ticks.
    input logic [63:0] period_i, // Checked L/P/W in local ticks.
    input logic [63:0] window_i, // Checked L/P/W in local ticks.
    input logic  fault_i, // General alarm / effective hold / R05 grants gate.
    input logic  entropy_failure_i, // General alarm / effective hold / R05 grants gate.
    input logic  grant_enable_i, // General alarm / effective hold / R05 grants gate.
    input logic [63:0] now_i, // Current trusted time BEFORE the clock edge.
    input logic  tick_i, // This edge advances R05 time by one; deadlines include it.
    input logic  run_begin_i, // R05 established new tick zero/generation after qualification.
    input logic [63:0] platform_generation_i, // R05's strictly increasing generation; interrupted runs may leave gaps.
    output logic  restart_ready_o, // Qualified stop boundary permits requesting R05 startup.
    input logic  stop_ack_i, // Trusted enforcement acknowledgement, never a host command.
    output logic  stop_request_o, // Complete physical stop / pulse canceling R05's old run.
    output logic  run_end_o, // Complete physical stop / pulse canceling R05's old run.
    output logic [7:0] state_o, // Sparse public diagnostic state (documented in R06 guide).
    output logic  fault_o, // Immediate-or-sticky fault / independently gated lease.
    output logic  permit_o, // Immediate-or-sticky fault / independently gated lease.
    output logic [63:0] run_generation_o, // Powered run identity; never a wire/session field.
    output logic [63:0] round_o, // Current protocol round, starting at one.
    output logic [63:0] job_generation_o, // Powered monotonic job epoch.
    output logic  pending_o, // One context / coherent current request publication.
    output logic  request_valid_o, // One context / coherent current request publication.
    input logic [1:0] request_slot_i, // Read slot 0..2; invalid slot never publishes.
    output logic [1023:0] request_o, // Exact 128 bytes, byte zero in bits 1023:1016.
    output logic [63:0] issue_o, // Fixed pending I/B/E, never arrival-relative.
    output logic [63:0] deadline_o, // Fixed pending I/B/E, never arrival-relative.
    output logic [63:0] proposed_expiry_o, // Fixed pending I/B/E, never arrival-relative.
    output logic [2:0] votes_o, // Distinct pending slots; zero when the round closes.
    output logic  draw_valid_o, // R05 draw for a subsequent fixed scheduled round.
    input logic  draw_ready_i, // R05 accepts draw_round/issue on this edge.
    output logic [63:0] draw_round_o, // Scheduled round sent to the trusted entropy source.
    output logic [63:0] draw_issue_o, // Fixed issue tick for that draw.
    input logic  nonce_valid_i, // R05 conditioned result, with complete captured identity.
    output logic  nonce_ready_o, // Capture only a matching timely nonce.
    input logic [255:0] nonce_i, // Qualified conditioned result in this fast-platform model.
    input logic [63:0] nonce_round_i, // Entropy result's captured round.
    input logic [63:0] nonce_issue_i, // Entropy result's captured issue.
    input logic [63:0] nonce_generation_i, // Entropy result's captured run generation.
    input logic  submit_valid_i, // R07 sealed-buffer admission, not an authenticated vote.
    output logic  submit_ready_o, // Only one live job and one immutable context snapshot.
    input logic [1:0] submit_slot_i, // Locally selects fixed OTP authority key / slot request.
    input logic  abort_valid_i, // RX_ABORT cancels only its matching job, preserving prior votes.
    input logic [63:0] abort_token_i, // Only this owned token may be aborted.
    output logic  job_valid_o, // Immutable request to the trusted verifier; held until ready.
    input logic  job_ready_i, // Trusted verifier accepts the immutable job.
    output logic  job_active_o, // The single receive/verifier ownership is live.
    output logic [63:0] job_token_o, // Unique nonzero powered-context token.
    output logic [63:0] job_run_o, // Captured run identity.
    output logic [63:0] job_round_o, // Captured protocol round.
    output logic [63:0] job_epoch_o, // Captured internal job epoch.
    output logic [1:0] job_slot_o, // Captured OTP key/authority slot.
    output logic [1023:0] job_request_o, // Captured exact local request bytes.
    output logic [2175:0] job_configuration_o, // Immutable public OTP for both verification passes.
    output logic [255:0] job_config_digest_o, // Captured C_cfg, independently recomputed by the verifier.
    output logic  cancel_valid_o, // Actual formerly-owned token canceled at this edge.
    output logic [63:0] cancel_token_o, // Formerly owned token, not the identity of a new job.
    input logic  completion_valid_i, // One independently sequenced verifier pass result.
    output logic  completion_ready_o, // Always drain stale results; no ownership implied.
    input logic [63:0] completion_token_i, // Echo of the captured job token.
    input logic [63:0] completion_run_i, // Echo of the captured run identity.
    input logic [63:0] completion_round_i, // Echo of the captured round.
    input logic [63:0] completion_epoch_i, // Echo of the captured job epoch.
    input logic [1:0] completion_slot_i, // Echo of the captured key/authority slot.
    input logic [1:0] completion_pass_i, // Pass number 1 or 2; pass 2 requires observed pass 1.
    input logic [1023:0] completion_request_i, // Echo immutable checked inputs, not a returned wire body.
    input logic [255:0] completion_config_digest_i, // Echo of the independently checked configuration digest.
    input logic [7:0] completion_code_i, // Pass 1 accepts 0x96; pass 2 accepts 0x69; all else fail.
    output logic  result_valid_o, // Completed/canceled own job status, including rejection.
    output logic [63:0] result_token_o, // Token whose status completed on result_valid_o.
    output logic [1:0] result_code_o, // 0 verified, 1 rejected, 2 canceled.
    output logic  vote_event_o, // Semantic diagnostics, not acceptance bypasses.
    output logic  commit_event_o, // Semantic diagnostics, not acceptance bypasses.
    output logic  lease_valid_o, // Healthy committed lease exists.
    output logic [63:0] committed_issue_o, // I_c of the actual committed lease.
    output logic [63:0] lease_expiry_o, // Fixed committed expiry, never arrival-relative.
    output logic [63:0] remaining_o // Saturating remaining down-counter, not an arrival-relative lease.
);
    logic  full_restart_ready_o, small_restart_ready_o;
    assign restart_ready_o=small_i ? small_restart_ready_o : full_restart_ready_o;
    logic  full_stop_request_o, small_stop_request_o;
    assign stop_request_o=small_i ? small_stop_request_o : full_stop_request_o;
    logic  full_run_end_o, small_run_end_o;
    assign run_end_o=small_i ? small_run_end_o : full_run_end_o;
    logic [7:0] full_state_o, small_state_o;
    assign state_o=small_i ? small_state_o : full_state_o;
    logic  full_fault_o, small_fault_o;
    assign fault_o=small_i ? small_fault_o : full_fault_o;
    logic  full_permit_o, small_permit_o;
    assign permit_o=small_i ? small_permit_o : full_permit_o;
    logic [63:0] full_run_generation_o, small_run_generation_o;
    assign run_generation_o=small_i ? small_run_generation_o : full_run_generation_o;
    logic [63:0] full_round_o, small_round_o;
    assign round_o=small_i ? small_round_o : full_round_o;
    logic [63:0] full_job_generation_o, small_job_generation_o;
    assign job_generation_o=small_i ? small_job_generation_o : full_job_generation_o;
    logic  full_pending_o, small_pending_o;
    assign pending_o=small_i ? small_pending_o : full_pending_o;
    logic  full_request_valid_o, small_request_valid_o;
    assign request_valid_o=small_i ? small_request_valid_o : full_request_valid_o;
    logic [1023:0] full_request_o, small_request_o;
    assign request_o=small_i ? small_request_o : full_request_o;
    logic [63:0] full_issue_o, small_issue_o;
    assign issue_o=small_i ? small_issue_o : full_issue_o;
    logic [63:0] full_deadline_o, small_deadline_o;
    assign deadline_o=small_i ? small_deadline_o : full_deadline_o;
    logic [63:0] full_proposed_expiry_o, small_proposed_expiry_o;
    assign proposed_expiry_o=small_i ? small_proposed_expiry_o : full_proposed_expiry_o;
    logic [2:0] full_votes_o, small_votes_o;
    assign votes_o=small_i ? small_votes_o : full_votes_o;
    logic  full_draw_valid_o, small_draw_valid_o;
    assign draw_valid_o=small_i ? small_draw_valid_o : full_draw_valid_o;
    logic [63:0] full_draw_round_o, small_draw_round_o;
    assign draw_round_o=small_i ? small_draw_round_o : full_draw_round_o;
    logic [63:0] full_draw_issue_o, small_draw_issue_o;
    assign draw_issue_o=small_i ? small_draw_issue_o : full_draw_issue_o;
    logic  full_nonce_ready_o, small_nonce_ready_o;
    assign nonce_ready_o=small_i ? small_nonce_ready_o : full_nonce_ready_o;
    logic  full_submit_ready_o, small_submit_ready_o;
    assign submit_ready_o=small_i ? small_submit_ready_o : full_submit_ready_o;
    logic  full_job_valid_o, small_job_valid_o;
    assign job_valid_o=small_i ? small_job_valid_o : full_job_valid_o;
    logic  full_job_active_o, small_job_active_o;
    assign job_active_o=small_i ? small_job_active_o : full_job_active_o;
    logic [63:0] full_job_token_o, small_job_token_o;
    assign job_token_o=small_i ? small_job_token_o : full_job_token_o;
    logic [63:0] full_job_run_o, small_job_run_o;
    assign job_run_o=small_i ? small_job_run_o : full_job_run_o;
    logic [63:0] full_job_round_o, small_job_round_o;
    assign job_round_o=small_i ? small_job_round_o : full_job_round_o;
    logic [63:0] full_job_epoch_o, small_job_epoch_o;
    assign job_epoch_o=small_i ? small_job_epoch_o : full_job_epoch_o;
    logic [1:0] full_job_slot_o, small_job_slot_o;
    assign job_slot_o=small_i ? small_job_slot_o : full_job_slot_o;
    logic [1023:0] full_job_request_o, small_job_request_o;
    assign job_request_o=small_i ? small_job_request_o : full_job_request_o;
    logic [2175:0] full_job_configuration_o, small_job_configuration_o;
    assign job_configuration_o=small_i ? small_job_configuration_o : full_job_configuration_o;
    logic [255:0] full_job_config_digest_o, small_job_config_digest_o;
    assign job_config_digest_o=small_i ? small_job_config_digest_o : full_job_config_digest_o;
    logic  full_cancel_valid_o, small_cancel_valid_o;
    assign cancel_valid_o=small_i ? small_cancel_valid_o : full_cancel_valid_o;
    logic [63:0] full_cancel_token_o, small_cancel_token_o;
    assign cancel_token_o=small_i ? small_cancel_token_o : full_cancel_token_o;
    logic  full_completion_ready_o, small_completion_ready_o;
    assign completion_ready_o=small_i ? small_completion_ready_o : full_completion_ready_o;
    logic  full_result_valid_o, small_result_valid_o;
    assign result_valid_o=small_i ? small_result_valid_o : full_result_valid_o;
    logic [63:0] full_result_token_o, small_result_token_o;
    assign result_token_o=small_i ? small_result_token_o : full_result_token_o;
    logic [1:0] full_result_code_o, small_result_code_o;
    assign result_code_o=small_i ? small_result_code_o : full_result_code_o;
    logic  full_vote_event_o, small_vote_event_o;
    assign vote_event_o=small_i ? small_vote_event_o : full_vote_event_o;
    logic  full_commit_event_o, small_commit_event_o;
    assign commit_event_o=small_i ? small_commit_event_o : full_commit_event_o;
    logic  full_lease_valid_o, small_lease_valid_o;
    assign lease_valid_o=small_i ? small_lease_valid_o : full_lease_valid_o;
    logic [63:0] full_committed_issue_o, small_committed_issue_o;
    assign committed_issue_o=small_i ? small_committed_issue_o : full_committed_issue_o;
    logic [63:0] full_lease_expiry_o, small_lease_expiry_o;
    assign lease_expiry_o=small_i ? small_lease_expiry_o : full_lease_expiry_o;
    logic [63:0] full_remaining_o, small_remaining_o;
    assign remaining_o=small_i ? small_remaining_o : full_remaining_o;
    reins_controller full_width (
        .clk_i(clk_i),
        .por_ni(por_ni),
        .logic_reset_i(logic_reset_i),
        .cold_clear_i(cold_clear_i),
        .config_closed_i(config_closed_i),
        .config_valid_i(config_valid_i),
        .configuration_i(configuration_i),
        .config_digest_i(config_digest_i),
        .lease_i(lease_i),
        .period_i(period_i),
        .window_i(window_i),
        .fault_i(fault_i),
        .entropy_failure_i(entropy_failure_i),
        .grant_enable_i(grant_enable_i),
        .now_i(now_i),
        .tick_i(tick_i),
        .run_begin_i(run_begin_i),
        .platform_generation_i(platform_generation_i),
        .restart_ready_o(full_restart_ready_o),
        .stop_ack_i(stop_ack_i),
        .stop_request_o(full_stop_request_o),
        .run_end_o(full_run_end_o),
        .state_o(full_state_o),
        .fault_o(full_fault_o),
        .permit_o(full_permit_o),
        .run_generation_o(full_run_generation_o),
        .round_o(full_round_o),
        .job_generation_o(full_job_generation_o),
        .pending_o(full_pending_o),
        .request_valid_o(full_request_valid_o),
        .request_slot_i(request_slot_i),
        .request_o(full_request_o),
        .issue_o(full_issue_o),
        .deadline_o(full_deadline_o),
        .proposed_expiry_o(full_proposed_expiry_o),
        .votes_o(full_votes_o),
        .draw_valid_o(full_draw_valid_o),
        .draw_ready_i(draw_ready_i),
        .draw_round_o(full_draw_round_o),
        .draw_issue_o(full_draw_issue_o),
        .nonce_valid_i(nonce_valid_i),
        .nonce_ready_o(full_nonce_ready_o),
        .nonce_i(nonce_i),
        .nonce_round_i(nonce_round_i),
        .nonce_issue_i(nonce_issue_i),
        .nonce_generation_i(nonce_generation_i),
        .submit_valid_i(submit_valid_i),
        .submit_ready_o(full_submit_ready_o),
        .submit_slot_i(submit_slot_i),
        .abort_valid_i(abort_valid_i),
        .abort_token_i(abort_token_i),
        .job_valid_o(full_job_valid_o),
        .job_ready_i(job_ready_i),
        .job_active_o(full_job_active_o),
        .job_token_o(full_job_token_o),
        .job_run_o(full_job_run_o),
        .job_round_o(full_job_round_o),
        .job_epoch_o(full_job_epoch_o),
        .job_slot_o(full_job_slot_o),
        .job_request_o(full_job_request_o),
        .job_configuration_o(full_job_configuration_o),
        .job_config_digest_o(full_job_config_digest_o),
        .cancel_valid_o(full_cancel_valid_o),
        .cancel_token_o(full_cancel_token_o),
        .completion_valid_i(completion_valid_i),
        .completion_ready_o(full_completion_ready_o),
        .completion_token_i(completion_token_i),
        .completion_run_i(completion_run_i),
        .completion_round_i(completion_round_i),
        .completion_epoch_i(completion_epoch_i),
        .completion_slot_i(completion_slot_i),
        .completion_pass_i(completion_pass_i),
        .completion_request_i(completion_request_i),
        .completion_config_digest_i(completion_config_digest_i),
        .completion_code_i(completion_code_i),
        .result_valid_o(full_result_valid_o),
        .result_token_o(full_result_token_o),
        .result_code_o(full_result_code_o),
        .vote_event_o(full_vote_event_o),
        .commit_event_o(full_commit_event_o),
        .lease_valid_o(full_lease_valid_o),
        .committed_issue_o(full_committed_issue_o),
        .lease_expiry_o(full_lease_expiry_o),
        .remaining_o(full_remaining_o)
    );
    reins_controller #(.ID_WIDTH(3),.ROUND_WIDTH(3),.TIME_WIDTH(8)) reduced_limits (
        .clk_i(clk_i),
        .por_ni(por_ni),
        .logic_reset_i(logic_reset_i),
        .cold_clear_i(cold_clear_i),
        .config_closed_i(config_closed_i),
        .config_valid_i(config_valid_i),
        .configuration_i(configuration_i),
        .config_digest_i(config_digest_i),
        .lease_i(lease_i),
        .period_i(period_i),
        .window_i(window_i),
        .fault_i(fault_i),
        .entropy_failure_i(entropy_failure_i),
        .grant_enable_i(grant_enable_i),
        .now_i(now_i),
        .tick_i(tick_i),
        .run_begin_i(run_begin_i),
        .platform_generation_i(platform_generation_i),
        .restart_ready_o(small_restart_ready_o),
        .stop_ack_i(stop_ack_i),
        .stop_request_o(small_stop_request_o),
        .run_end_o(small_run_end_o),
        .state_o(small_state_o),
        .fault_o(small_fault_o),
        .permit_o(small_permit_o),
        .run_generation_o(small_run_generation_o),
        .round_o(small_round_o),
        .job_generation_o(small_job_generation_o),
        .pending_o(small_pending_o),
        .request_valid_o(small_request_valid_o),
        .request_slot_i(request_slot_i),
        .request_o(small_request_o),
        .issue_o(small_issue_o),
        .deadline_o(small_deadline_o),
        .proposed_expiry_o(small_proposed_expiry_o),
        .votes_o(small_votes_o),
        .draw_valid_o(small_draw_valid_o),
        .draw_ready_i(draw_ready_i),
        .draw_round_o(small_draw_round_o),
        .draw_issue_o(small_draw_issue_o),
        .nonce_valid_i(nonce_valid_i),
        .nonce_ready_o(small_nonce_ready_o),
        .nonce_i(nonce_i),
        .nonce_round_i(nonce_round_i),
        .nonce_issue_i(nonce_issue_i),
        .nonce_generation_i(nonce_generation_i),
        .submit_valid_i(submit_valid_i),
        .submit_ready_o(small_submit_ready_o),
        .submit_slot_i(submit_slot_i),
        .abort_valid_i(abort_valid_i),
        .abort_token_i(abort_token_i),
        .job_valid_o(small_job_valid_o),
        .job_ready_i(job_ready_i),
        .job_active_o(small_job_active_o),
        .job_token_o(small_job_token_o),
        .job_run_o(small_job_run_o),
        .job_round_o(small_job_round_o),
        .job_epoch_o(small_job_epoch_o),
        .job_slot_o(small_job_slot_o),
        .job_request_o(small_job_request_o),
        .job_configuration_o(small_job_configuration_o),
        .job_config_digest_o(small_job_config_digest_o),
        .cancel_valid_o(small_cancel_valid_o),
        .cancel_token_o(small_cancel_token_o),
        .completion_valid_i(completion_valid_i),
        .completion_ready_o(small_completion_ready_o),
        .completion_token_i(completion_token_i),
        .completion_run_i(completion_run_i),
        .completion_round_i(completion_round_i),
        .completion_epoch_i(completion_epoch_i),
        .completion_slot_i(completion_slot_i),
        .completion_pass_i(completion_pass_i),
        .completion_request_i(completion_request_i),
        .completion_config_digest_i(completion_config_digest_i),
        .completion_code_i(completion_code_i),
        .result_valid_o(small_result_valid_o),
        .result_token_o(small_result_token_o),
        .result_code_o(small_result_code_o),
        .vote_event_o(small_vote_event_o),
        .commit_event_o(small_commit_event_o),
        .lease_valid_o(small_lease_valid_o),
        .committed_issue_o(small_committed_issue_o),
        .lease_expiry_o(small_lease_expiry_o),
        .remaining_o(small_remaining_o)
    );
    reins_lease_check lease_probe (
        .valid_i(lease_probe_valid_i), .now_i(lease_probe_now_i), .length_i(lease_probe_length_i),
        .issue_i(lease_probe_issue_i), .issue_inverse_i(lease_probe_issue_inverse_i), .expiry_i(lease_probe_expiry_i),
        .remaining_i(lease_probe_remaining_i), .remaining_inverse_i(lease_probe_remaining_inverse_i),
        .fault_o(lease_probe_fault_o), .permit_o(lease_probe_permit_o)
    );
    reins_round_schedule arithmetic_probe (
        .round_i(math_round_i), .period_i(math_period_i), .window_i(math_window_i), .lease_i(math_lease_i),
        .valid_o(math_valid_o), .issue_o(math_issue_o), .deadline_o(math_deadline_o),
        .expiry_o(math_expiry_o), .next_issue_o(math_next_o)
    );
endmodule
`default_nettype wire
