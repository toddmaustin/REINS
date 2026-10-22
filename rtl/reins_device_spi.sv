// Actual R05 + R06 + R07 composition; technology wrappers and real verifier remain internal boundaries.
// No SPI opcode can supply a completion, program OTP, or acknowledge a physical stop.
`default_nettype none
module reins_device_spi (
    input logic clk_i, // Independent always-on monitor clock / real power reset.
    input logic por_ni, // Independent always-on monitor clock / real power reset.
    input logic cold_reset_i, // Technology-recognized resets, never host commands.
    input logic warm_reset_i, // Technology-recognized resets, never host commands.
    input logic startup_i, // Trusted startup request / completed stop or context loss.
    input logic physical_enable_i, // Physical commissioning and actual-stop interlocks.
    input logic stopped_i, // Physical commissioning and actual-stop interlocks.
    input logic config_write_i, // Physical byte/check/commit attempts.
    input logic config_check_i, // Physical byte/check/commit attempts.
    input logic config_close_i, // Physical byte/check/commit attempts.
    input logic [8:0] config_address_i, // Programming byte offset, 0..271.
    input logic [7:0] config_data_i, // Public commissioning byte.
    output logic config_write_accepted_o, // Actual admitted programming transaction.
    output logic macro_write_o, // Admitted irreversible-wrapper transactions.
    output logic macro_close_o, // Admitted irreversible-wrapper transactions.
    output logic [8:0] macro_address_o, // Read/check cursor or programming byte address.
    output logic [7:0] macro_write_data_o, // Payload of an admitted write.
    input logic [7:0] macro_read_data_i, // Sensed logical byte at macro_address_o.
    input logic [1:0] macro_lifecycle_i, // Technology-retained 00/11/invalid lifecycle.
    input logic macro_complete_i, // Completeness and sensing/ECC/lock health.
    input logic macro_integrity_i, // Completeness and sensing/ECC/lock health.
    output logic config_busy_o, // Check ownership/completion/success.
    output logic config_done_o, // Check ownership/completion/success.
    output logic config_valid_o, // Check ownership/completion/success.
    output logic [2:0] config_error_o, // reins_config's retained check diagnostic.
    output logic [2175:0] configuration_o, // Full checked public image, meaningful when valid.
    output logic [255:0] configuration_digest_o, // Exact C_cfg; meaningful with config_valid_o.
    output logic [63:0] lease_length_o, // Checked L/P/W in local ticks.
    output logic [63:0] period_o, // Checked L/P/W in local ticks.
    output logic [63:0] window_o, // Checked L/P/W in local ticks.
    input logic reference_a_i, // Dissimilar synchronized progress events.
    input logic reference_b_i, // Dissimilar synchronized progress events.
    input logic timing_healthy_i, // Qualified platform alarms.
    input logic sensor_healthy_i, // Qualified platform alarms.
    input logic integrity_alarm_i, // Qualified platform alarms.
    input logic source_a_available_i, // Independent source availability.
    input logic source_b_available_i, // Independent source availability.
    input logic source_a_valid_i, // One fresh raw A event and binary value.
    input logic source_a_bit_i, // One fresh raw A event and binary value.
    input logic [63:0] source_a_time_i, // Trusted A acquisition tick, before any queue.
    input logic source_b_valid_i, // One fresh raw B event and binary value.
    input logic source_b_bit_i, // One fresh raw B event and binary value.
    input logic [63:0] source_b_time_i, // Trusted B acquisition tick, before any queue.
    output logic source_a_request_o, // Startup or active fresh-draw demand.
    output logic source_b_request_o, // Startup or active fresh-draw demand.
    output logic [8:0] source_a_count_o, // Actual accepted nonce bits, not entropy.
    output logic [8:0] source_b_count_o, // Actual accepted nonce bits, not entropy.
    output logic entropy_hold_o, // Hold, clearing policy, history.
    output logic cold_eligible_o, // Hold, clearing policy, history.
    output logic history_valid_o, // Hold, clearing policy, history.
    output logic checking_o, // Startup/new-grant gates.
    output logic run_active_o, // Startup/new-grant gates.
    output logic startup_complete_o, // Startup/new-grant gates.
    output logic new_grants_o, // Startup/new-grant gates.
    output logic invalidate_o, // Immediate/stored general fault / cancel pending work.
    output logic [63:0] now_o, // Trusted local tick and nonwrapping run identity.
    output logic [63:0] generation_o, // Trusted local tick and nonwrapping run identity.
    output logic restart_ready_o, // Qualified stop boundary permits requesting R05 startup.
    input logic stop_ack_i, // Trusted enforcement acknowledgement, never a host command.
    output logic stop_request_o, // Complete physical stop / pulse canceling R05's old run.
    output logic [7:0] state_o, // Sparse public diagnostic state (documented in R06 guide).
    output logic [63:0] run_generation_o, // Powered run identity; never a wire/session field.
    output logic [63:0] round_o, // Current protocol round, starting at one.
    output logic [63:0] job_generation_o, // Powered monotonic job epoch.
    output logic pending_o, // One context / coherent current request publication.
    output logic request_valid_o, // One context / coherent current request publication.
    output logic [1023:0] request_o, // Exact 128 bytes, byte zero in bits 1023:1016.
    output logic [63:0] issue_o, // Fixed pending I/B/E, never arrival-relative.
    output logic [63:0] deadline_o, // Fixed pending I/B/E, never arrival-relative.
    output logic [63:0] proposed_expiry_o, // Fixed pending I/B/E, never arrival-relative.
    output logic [2:0] votes_o, // Distinct pending slots; zero when the round closes.
    output logic submit_ready_o, // Only one live job and one immutable context snapshot.
    output logic job_valid_o, // Immutable request to the trusted verifier; held until ready.
    input logic job_ready_i, // Trusted verifier accepts the immutable job.
    output logic job_active_o, // The single receive/verifier ownership is live.
    output logic [63:0] job_token_o, // Unique nonzero powered-context token.
    output logic [63:0] job_run_o, // Captured run identity.
    output logic [63:0] job_round_o, // Captured protocol round.
    output logic [63:0] job_epoch_o, // Captured internal job epoch.
    output logic [1:0] job_slot_o, // Captured OTP key/authority slot.
    output logic [1023:0] job_request_o, // Captured exact local request bytes.
    output logic [2175:0] job_configuration_o, // Immutable public OTP for both verification passes.
    output logic [255:0] job_config_digest_o, // Captured C_cfg, independently recomputed by the verifier.
    output logic cancel_valid_o, // Actual formerly-owned token canceled at this edge.
    output logic [63:0] cancel_token_o, // Formerly owned token, not the identity of a new job.
    input logic completion_valid_i, // One independently sequenced verifier pass result.
    output logic completion_ready_o, // Always drain stale results; no ownership implied.
    input logic [63:0] completion_token_i, // Echo of the captured job token.
    input logic [63:0] completion_run_i, // Echo of the captured run identity.
    input logic [63:0] completion_round_i, // Echo of the captured round.
    input logic [63:0] completion_epoch_i, // Echo of the captured job epoch.
    input logic [1:0] completion_slot_i, // Echo of the captured key/authority slot.
    input logic [1:0] completion_pass_i, // Pass number 1 or 2; pass 2 requires observed pass 1.
    input logic [1023:0] completion_request_i, // Echo immutable checked inputs, not a returned wire body.
    input logic [255:0] completion_config_digest_i, // Echo of the independently checked configuration digest.
    input logic [7:0] completion_code_i, // Pass 1 accepts 0x96; pass 2 accepts 0x69; all else fail.
    output logic result_valid_o, // Completed/canceled own job status, including rejection.
    output logic [63:0] result_token_o, // Token whose status completed on result_valid_o.
    output logic [1:0] result_code_o, // 0 verified, 1 rejected, 2 canceled.
    output logic vote_event_o, // Semantic diagnostics, not acceptance bypasses.
    output logic commit_event_o, // Semantic diagnostics, not acceptance bypasses.
    output logic [63:0] committed_issue_o, // I_c of the actual committed lease.
    output logic [63:0] remaining_o, // Saturating remaining down-counter, not an arrival-relative lease.
    output logic permit_o, // Combined controller/R05 qualified lease permit.
    output logic fault_o, // Immediate or stored controller/platform general fault.
    output logic [63:0] lease_expiry_o, // Fixed committed expiry, owned by R06.
    input logic sclk_i, // Untrusted asynchronous SPI mode-0 clock.
    input logic cs_ni, // Untrusted active-low SPI selection.
    input logic mosi_i, // Untrusted MSB-first MOSI data.
    output logic miso_o, // Pad data; output enable is separate for technology-specific tri-state.
    output logic miso_oe_o, // Pad enable; low asynchronously whenever CS_N is high.
    input logic [2:0] completion_reason_i, // Trusted diagnostic: format=1, signature/proof=2; cannot authorize a vote.
    output logic [63:0] receive_token_o, // SPI receive token; separate from the internal verifier token.
    output logic [13:0] receive_total_o, // Exact canonical owned reply length.
    output logic [13:0] receive_offset_o, // Accepted contiguous byte offset; changes only after a valid transaction.
    output logic receive_owned_o, // One owner across receiving and both verifier passes.
    output logic sealed_o, // Checked receive-memory seal.
    output logic receive_integrity_o, // Receive/SPI internal integrity alarm; fed directly into the general fault path.
    input logic read_valid_i, // Internal trusted verifier read request, never a host/SPI write bypass.
    input logic [13:0] read_address_i, // Absolute byte address within the sealed payload.
    input logic [13:0] read_address_inverse_i, // Independent complement of the verifier read address.
    output logic read_valid_o, // ECC/address/owner checked sealed read result.
    output logic [7:0] read_data_o, // Verified-memory byte; zero when the read is denied or corrupt.
    output logic write_event_o, // Passive observation of the sole physical payload write port.
    output logic spi_start_o, // Passive synchronized SPI selection event.
    output logic spi_byte_valid_o, // Passive complete MOSI-byte event.
    output logic spi_end_o, // Passive final transaction-boundary event, including invalid exchanges.
    output logic [8:0] spi_byte_index_o, // Passive zero-based complete-byte index.
    output logic [8:0] spi_bytes_o, // Passive final complete-byte count.
    output logic [7:0] spi_byte_o, // Passive received MOSI byte.
    output logic spi_frame_error_o // Passive final partial/timing/timeout/framing diagnostic.
);
    logic mailbox_integrity, verifier_allowed, controller_job_valid;
    logic [1:0] request_slot, submit_slot;
    logic submit_valid, abort_valid;
    logic [63:0] abort_token;
    assign receive_integrity_o=mailbox_integrity;
    assign job_valid_o=controller_job_valid && verifier_allowed;
    reins_device_control controller (
        .clk_i(clk_i),
        .por_ni(por_ni),
        .cold_reset_i(cold_reset_i),
        .warm_reset_i(warm_reset_i),
        .startup_i(startup_i),
        .physical_enable_i(physical_enable_i),
        .stopped_i(stopped_i),
        .config_write_i(config_write_i),
        .config_check_i(config_check_i),
        .config_close_i(config_close_i),
        .config_address_i(config_address_i),
        .config_data_i(config_data_i),
        .config_write_accepted_o(config_write_accepted_o),
        .macro_write_o(macro_write_o),
        .macro_close_o(macro_close_o),
        .macro_address_o(macro_address_o),
        .macro_write_data_o(macro_write_data_o),
        .macro_read_data_i(macro_read_data_i),
        .macro_lifecycle_i(macro_lifecycle_i),
        .macro_complete_i(macro_complete_i),
        .macro_integrity_i(macro_integrity_i),
        .config_busy_o(config_busy_o),
        .config_done_o(config_done_o),
        .config_valid_o(config_valid_o),
        .config_error_o(config_error_o),
        .configuration_o(configuration_o),
        .configuration_digest_o(configuration_digest_o),
        .lease_length_o(lease_length_o),
        .period_o(period_o),
        .window_o(window_o),
        .reference_a_i(reference_a_i),
        .reference_b_i(reference_b_i),
        .timing_healthy_i(timing_healthy_i),
        .sensor_healthy_i(sensor_healthy_i),
        .integrity_alarm_i(integrity_alarm_i || mailbox_integrity),
        .source_a_available_i(source_a_available_i),
        .source_b_available_i(source_b_available_i),
        .source_a_valid_i(source_a_valid_i),
        .source_a_bit_i(source_a_bit_i),
        .source_a_time_i(source_a_time_i),
        .source_b_valid_i(source_b_valid_i),
        .source_b_bit_i(source_b_bit_i),
        .source_b_time_i(source_b_time_i),
        .source_a_request_o(source_a_request_o),
        .source_b_request_o(source_b_request_o),
        .source_a_count_o(source_a_count_o),
        .source_b_count_o(source_b_count_o),
        .entropy_hold_o(entropy_hold_o),
        .cold_eligible_o(cold_eligible_o),
        .history_valid_o(history_valid_o),
        .checking_o(checking_o),
        .run_active_o(run_active_o),
        .startup_complete_o(startup_complete_o),
        .new_grants_o(new_grants_o),
        .invalidate_o(invalidate_o),
        .now_o(now_o),
        .generation_o(generation_o),
        .restart_ready_o(restart_ready_o),
        .stop_ack_i(stop_ack_i),
        .stop_request_o(stop_request_o),
        .state_o(state_o),
        .run_generation_o(run_generation_o),
        .round_o(round_o),
        .job_generation_o(job_generation_o),
        .pending_o(pending_o),
        .request_valid_o(request_valid_o),
        .request_slot_i(request_slot),
        .request_o(request_o),
        .issue_o(issue_o),
        .deadline_o(deadline_o),
        .proposed_expiry_o(proposed_expiry_o),
        .votes_o(votes_o),
        .submit_valid_i(submit_valid),
        .submit_ready_o(submit_ready_o),
        .submit_slot_i(submit_slot),
        .abort_valid_i(abort_valid),
        .abort_token_i(abort_token),
        .job_valid_o(controller_job_valid),
        .job_ready_i(job_ready_i && verifier_allowed),
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
        .completion_valid_i(completion_valid_i && verifier_allowed),
        .completion_ready_o(completion_ready_o),
        .completion_token_i(completion_token_i),
        .completion_run_i(completion_run_i),
        .completion_round_i(completion_round_i),
        .completion_epoch_i(completion_epoch_i),
        .completion_slot_i(completion_slot_i),
        .completion_pass_i(completion_pass_i),
        .completion_request_i(completion_request_i),
        .completion_config_digest_i(completion_config_digest_i),
        .completion_code_i(completion_code_i),
        .result_valid_o(result_valid_o),
        .result_token_o(result_token_o),
        .result_code_o(result_code_o),
        .vote_event_o(vote_event_o),
        .commit_event_o(commit_event_o),
        .committed_issue_o(committed_issue_o),
        .remaining_o(remaining_o),
        .permit_o(permit_o),
        .fault_o(fault_o),
        .lease_expiry_o(lease_expiry_o)
    );
    reins_spi_mailbox transport (
        .clk_i(clk_i),
        .por_ni(por_ni),
        .reset_i(warm_reset_i || cold_reset_i),
        .trusted_tick_i(reference_a_i),
        .cold_clear_i(cold_reset_i),
        .sclk_i(sclk_i),
        .cs_ni(cs_ni),
        .mosi_i(mosi_i),
        .miso_o(miso_o),
        .miso_oe_o(miso_oe_o),
        .lifecycle_i(macro_lifecycle_i==0 ? 2'd0 : (macro_lifecycle_i==3 ? 2'd1 : 2'd2)),
        .config_valid_i(config_valid_o),
        .entropy_hold_i(entropy_hold_o),
        .fault_i(fault_o),
        .configuration_i(configuration_o),
        .config_digest_i(configuration_digest_o),
        .state_i(state_o),
        .pending_i(pending_o),
        .request_valid_i(request_valid_o),
        .request_slot_o(request_slot),
        .request_i(request_o),
        .run_i(run_generation_o),
        .round_i(round_o),
        .epoch_i(job_generation_o),
        .now_i(now_o),
        .deadline_i(deadline_o),
        .run_tick_i(reference_a_i && run_active_o && !fault_o),
        .submit_valid_o(submit_valid),
        .submit_ready_i(submit_ready_o),
        .submit_slot_o(submit_slot),
        .abort_valid_o(abort_valid),
        .abort_token_o(abort_token),
        .job_active_i(job_active_o),
        .job_token_i(job_token_o),
        .job_run_i(job_run_o),
        .job_round_i(job_round_o),
        .job_slot_i(job_slot_o),
        .job_request_i(job_request_o),
        .result_valid_i(result_valid_o),
        .result_token_i(result_token_o),
        .result_code_i(result_code_o),
        .vote_event_i(vote_event_o),
        .commit_event_i(commit_event_o),
        .completion_reason_i(completion_reason_i),
        .verifier_allowed_o(verifier_allowed),
        .receive_token_o(receive_token_o),
        .receive_total_o(receive_total_o),
        .receive_offset_o(receive_offset_o),
        .receive_owned_o(receive_owned_o),
        .sealed_o(sealed_o),
        .read_valid_i(read_valid_i),
        .read_address_i(read_address_i),
        .read_address_inverse_i(read_address_inverse_i),
        .read_valid_o(read_valid_o),
        .read_data_o(read_data_o),
        .integrity_alarm_o(mailbox_integrity),
        .write_event_o(write_event_o),
        .spi_start_o(spi_start_o),
        .spi_byte_valid_o(spi_byte_valid_o),
        .spi_end_o(spi_end_o),
        .spi_byte_index_o(spi_byte_index_o),
        .spi_bytes_o(spi_bytes_o),
        .spi_byte_o(spi_byte_o),
        .spi_frame_error_o(spi_frame_error_o)
    );
endmodule
`default_nettype wire
