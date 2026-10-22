// R05/R06/R07/R08 composition. Only internal endpoint feedback acknowledges stop.
// Verifier and technology ports are trusted boundaries; SPI remains the live,
// restricted management path while protected compute and outbound effects stop.
`default_nettype none
module reins_device_enforced (
    input logic endpoint_por_ni, // Independently distributed asynchronous fail-off endpoint reset on real power loss.
    input logic clk_i, // Independent always-on monitor clock / real power reset.
    input logic por_ni, // Independent always-on monitor clock / real power reset.
    input logic cold_reset_i, // Technology-recognized resets, never host commands.
    input logic warm_reset_i, // Technology-recognized resets, never host commands.
    input logic startup_i, // Trusted startup request / completed stop or context loss.
    input logic physical_enable_i, // Physical commissioning and actual-stop interlocks.
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
    output logic spi_frame_error_o, // Passive final partial/timing/timeout/framing diagnostic.
    input logic [2:0] guard_clock_a_i, guard_clock_b_i, // Six independent local always-on timing paths.
    input logic [2:0] raw_clock_i, // Protected CPU/accelerator/DMA raw clocks; not guard/management clocks.
    input logic [2:0] outbound_ready_i, // Downstream backpressure cannot extend authorization or stop.
    output logic [2:0] outbound_valid_o,
    output logic [407:0] outbound_data_o, // Three internal generation/sequence/endpoint bundles.
    output logic [191:0] work_count_o, // Representative protected useful-work counters.
    output logic [8:0] queued_o, // Three bounded outbound queues, all before both final cuts.
    output logic [2:0] queue_empty_o, closed_a_o, closed_b_o,
    output logic [2:0] open_a_o, open_b_o, protected_clock_o,
    output logic permit_a_o, permit_b_o, // Separate dynamic internal rails; not host-synthesizable enables.
    output logic enforcement_epoch_o, // Trusted fresh ARM toggle, not a protocol session field.
    output logic stop_complete_o, // Trusted actual endpoint closure/queue certificate, never a host ACK.
    output logic enforcement_fault_o, profile_compatible_o // Fail-off enforcement / supported timing profile.
);
    logic profile_alarm, secondary_authorized;
    logic [64:0] checked_expiry;
    logic [2:0] routed_a, routed_b;
    assign checked_expiry={1'b0,committed_issue_o}+{1'b0,lease_length_o};
    // This path does not consume permit_o. A static/permissive primary permit
    // cannot keep B transitions alive after the independently observed expiry.
    assign secondary_authorized=profile_compatible_o && state_o==8'h66 && !fault_o &&
        !cold_reset_i && !warm_reset_i && timing_healthy_i && sensor_healthy_i && !integrity_alarm_i &&
        !enforcement_fault_o && !checked_expiry[64] && checked_expiry[63:0]==lease_expiry_o &&
        committed_issue_o<=now_o && now_o<lease_expiry_o && remaining_o!=0;
    assign routed_a={3{permit_a_o}};
    assign routed_b={3{permit_b_o}};
    reins_enforcement_profile profile (
        .config_valid_i(config_valid_o), .configuration_i(configuration_o),
        .compatible_o(profile_compatible_o), .alarm_o(profile_alarm)
    );
    reins_enforcement_bank enforcement (
        .clk_i(clk_i), .source_clock_i(clk_i), .por_ni(por_ni), .endpoint_por_ni(endpoint_por_ni),
        .reset_i(cold_reset_i || warm_reset_i), .cold_clear_i(cold_reset_i), .tick_i(reference_a_i),
        .authorize_a_i(permit_o), .authorize_b_i(secondary_authorized), .stop_request_i(stop_request_o),
        .profile_valid_i(profile_compatible_o), .profile_alarm_i(profile_alarm), .generation_i(run_generation_o),
        .permit_a_o(permit_a_o), .permit_b_o(permit_b_o), .epoch_o(enforcement_epoch_o),
        .routed_a_i(routed_a), .routed_b_i(routed_b),
        .guard_clock_a_i(guard_clock_a_i), .guard_clock_b_i(guard_clock_b_i), .raw_clock_i(raw_clock_i),
        .outbound_ready_i(outbound_ready_i), .outbound_valid_o(outbound_valid_o), .outbound_data_o(outbound_data_o),
        .work_count_o(work_count_o), .queued_o(queued_o), .queue_empty_o(queue_empty_o),
        .closed_a_o(closed_a_o), .closed_b_o(closed_b_o), .open_a_o(open_a_o), .open_b_o(open_b_o),
        .protected_clock_o(protected_clock_o), .stop_complete_o(stop_complete_o), .fault_o(enforcement_fault_o)
    );
    reins_device_spi controller (
        .clk_i(clk_i),
        .por_ni(por_ni),
        .cold_reset_i(cold_reset_i),
        .warm_reset_i(warm_reset_i),
        .startup_i(startup_i),
        .physical_enable_i(physical_enable_i),
        .stopped_i(stop_complete_o),
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
        .integrity_alarm_i(integrity_alarm_i || enforcement_fault_o),
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
        .stop_ack_i(stop_complete_o),
        .stop_request_o(stop_request_o),
        .state_o(state_o),
        .run_generation_o(run_generation_o),
        .round_o(round_o),
        .job_generation_o(job_generation_o),
        .pending_o(pending_o),
        .request_valid_o(request_valid_o),
        .request_o(request_o),
        .issue_o(issue_o),
        .deadline_o(deadline_o),
        .proposed_expiry_o(proposed_expiry_o),
        .votes_o(votes_o),
        .submit_ready_o(submit_ready_o),
        .job_valid_o(job_valid_o),
        .job_ready_i(job_ready_i),
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
        .completion_valid_i(completion_valid_i),
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
        .lease_expiry_o(lease_expiry_o),
        .sclk_i(sclk_i),
        .cs_ni(cs_ni),
        .mosi_i(mosi_i),
        .miso_o(miso_o),
        .miso_oe_o(miso_oe_o),
        .completion_reason_i(completion_reason_i),
        .receive_token_o(receive_token_o),
        .receive_total_o(receive_total_o),
        .receive_offset_o(receive_offset_o),
        .receive_owned_o(receive_owned_o),
        .sealed_o(sealed_o),
        .receive_integrity_o(receive_integrity_o),
        .read_valid_i(read_valid_i),
        .read_address_i(read_address_i),
        .read_address_inverse_i(read_address_inverse_i),
        .read_valid_o(read_valid_o),
        .read_data_o(read_data_o),
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
