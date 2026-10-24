// Copyright (c) 2026 Todd Austin.
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// License: https://polyformproject.org/licenses/noncommercial/1.0.0/

// SIMULATION ONLY: actual R05 through R09, independent Merkle datapaths and sealed SRAM; only SLH-DSA remains software.
`default_nettype none
module r09_integration_top (
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
    input logic [2175:0] factory_image_i, // Simulation-only factory OTP, never a production debug port.
    input logic endpoint_por_ni, // Separate async endpoint reset distribution.
    input logic [2:0] guard_clock_a_i, guard_clock_b_i, // Six independent guard clocks, driven in nanoseconds.
    input logic [2:0] outbound_ready_i,
    output logic [2:0] outbound_valid_o,
    output logic [407:0] outbound_data_o,
    output logic [191:0] work_count_o, effect_count_o,
    output logic [8:0] queued_o,
    output logic [2:0] queue_empty_o, closed_a_o, closed_b_o, open_a_o, open_b_o, protected_clock_o,
    output logic permit_a_o, permit_b_o, enforcement_epoch_o, stop_complete_o,
    output logic enforcement_fault_o, profile_compatible_o,
    output logic [2:0] stale_effect_o,
    input logic merkle_req_valid_i, merkle_cancel_i,
    input logic [1:0] merkle_req_pass_i,
    output logic merkle_req_ready_o, merkle_rsp_valid_o,
    input logic merkle_rsp_ready_i,
    output logic [1:0] merkle_error_o, merkle_pass_o, merkle_slot_o,
    output logic [63:0] merkle_run_o, merkle_round_o, merkle_token_o, merkle_epoch_o,
    output logic [255:0] merkle_config_o, merkle_leaf_o, merkle_root_o, merkle_key_o,
    output logic [367:0] merkle_message_o,
    output logic [1023:0] merkle_grant_o,
    output logic [15:0] merkle_state_o, merkle_stage_o,
    output logic [1:0] merkle_compression_start_o, merkle_compression_complete_o,
    output logic [15:0] merkle_starts_o, merkle_completions_o,
    output logic merkle_fault_o

);
    logic macro_write_o, macro_close_o, macro_complete_i;
    logic [8:0] macro_address_o;
    logic [7:0] macro_write_data_o, macro_read_data_i;
    logic [1:0] macro_lifecycle_i;
    reins_otp_model otp (
        .clk_i(clk_i), .factory_valid_i(1'b1), .factory_image_i(factory_image_i), .factory_lifecycle_i(2'b11),
        .physical_enable_i(physical_enable_i), .stopped_i(stop_complete_o), .write_i(macro_write_o), .close_i(macro_close_o),
        .address_i(macro_address_o), .data_i(macro_write_data_o), .model_bad_close_i(1'b0), .model_bad_code_i(1'b0),
        .read_data_o(macro_read_data_i), .lifecycle_o(macro_lifecycle_i), .complete_o(macro_complete_i)
    );
    logic merkle_read, shared_read_valid, merkle_context_q;
    logic [13:0] merkle_address, merkle_address_inverse;
    logic [7:0] shared_read_data;
    // Break the alarm/read-request combinational path. R06's live final gate and
    // registered cancellation dominate any result during this one-clock observation latency.
    always_ff @(posedge clk_i) begin
        if (!por_ni || cold_reset_i || warm_reset_i) merkle_context_q<=0;
        else merkle_context_q<=job_active_o && receive_owned_o && sealed_o && config_valid_o && !fault_o;
    end
    assign read_valid_o=shared_read_valid && !merkle_read;
    assign read_data_o=read_valid_o ? shared_read_data : 8'd0;
    reins_device_enforced device (
        .raw_clock_i({3{clk_i}}), .integrity_alarm_i(integrity_alarm_i || merkle_fault_o),
        .read_valid_i(merkle_read || read_valid_i), .read_address_i(merkle_read ? merkle_address : read_address_i),
        .read_address_inverse_i(merkle_read ? merkle_address_inverse : read_address_inverse_i),
        .read_valid_o(shared_read_valid), .read_data_o(shared_read_data), .*);
    // Each lane independently captures the current R05 checked OTP and immutable R06 job context.
    reins_merkle_pair merkle (
        .clk_i(clk_i), .rst_ni(por_ni && !cold_reset_i && !warm_reset_i),
        .cancel_i(merkle_cancel_i || cancel_valid_o), .context_valid_i(merkle_context_q),
        .req_valid_i(merkle_req_valid_i), .req_pass_i(merkle_req_pass_i), .req_ready_o(merkle_req_ready_o),
        .configuration_i(configuration_o), .configuration_digest_i(job_config_digest_o), .request_i(job_request_o),
        .run_i(job_run_o), .round_i(job_round_o), .token_i(job_token_o), .epoch_i(job_epoch_o),
        .slot_i(job_slot_o), .reply_length_i(receive_total_o),
        .read_valid_o(merkle_read), .read_address_o(merkle_address), .read_address_inverse_o(merkle_address_inverse),
        .read_valid_i(shared_read_valid && merkle_read), .read_data_i(shared_read_data),
        .rsp_valid_o(merkle_rsp_valid_o), .rsp_ready_i(merkle_rsp_ready_i), .rsp_error_o(merkle_error_o), .fault_o(merkle_fault_o),
        .pass_o(merkle_pass_o), .run_o(merkle_run_o), .round_o(merkle_round_o), .token_o(merkle_token_o), .epoch_o(merkle_epoch_o),
        .slot_o(merkle_slot_o), .configuration_digest_o(merkle_config_o), .leaf_o(merkle_leaf_o), .root_o(merkle_root_o),
        .public_key_o(merkle_key_o), .root_message_o(merkle_message_o), .grant_o(merkle_grant_o),
        .state_o(merkle_state_o), .stage_o(merkle_stage_o), .compression_start_o(merkle_compression_start_o),
        .compression_complete_o(merkle_compression_complete_o), .observed_starts_o(merkle_starts_o), .observed_completions_o(merkle_completions_o)
    );
    for (genvar endpoint=0;endpoint<3;endpoint++) begin : external_sinks
        always_ff @(posedge clk_i) begin
            if (!por_ni) begin effect_count_o[endpoint*64 +: 64]<=0; stale_effect_o[endpoint]<=0; end
            else if (outbound_valid_o[endpoint] && outbound_ready_i[endpoint]) begin
                effect_count_o[endpoint*64 +: 64]<=effect_count_o[endpoint*64 +: 64]+64'd1;
                if (outbound_data_o[endpoint*136+72 +: 64]!=run_generation_o || outbound_data_o[endpoint*136 +: 8]!=8'(endpoint))
                    stale_effect_o[endpoint]<=1;
            end
        end
    end
endmodule
`default_nettype wire
