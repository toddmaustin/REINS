// Copyright (c) 2026 Todd Austin.
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// License: https://polyformproject.org/licenses/noncommercial/1.0.0/

// SIMULATION ONLY: exact production device, physical OTP model, external sinks and passive observations.
`default_nettype none
module device_integration_top (
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
    output logic restart_ready_o, // Qualified stop boundary permits requesting PLATFORM startup.
    output logic stop_request_o, // Complete physical stop / pulse canceling PLATFORM's old run.
    output logic [7:0] state_o, // Sparse public diagnostic state (documented in CONTROLLER guide).
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
    output logic completion_ready_o, // Always drain stale results; no ownership implied.
    output logic result_valid_o, // Completed/canceled own job status, including rejection.
    output logic [63:0] result_token_o, // Token whose status completed on result_valid_o.
    output logic [1:0] result_code_o, // 0 verified, 1 rejected, 2 canceled.
    output logic vote_event_o, // Semantic diagnostics, not acceptance bypasses.
    output logic commit_event_o, // Semantic diagnostics, not acceptance bypasses.
    output logic [63:0] committed_issue_o, // I_c of the actual committed lease.
    output logic [63:0] remaining_o, // Saturating remaining down-counter, not an arrival-relative lease.
    output logic permit_o, // Combined controller/PLATFORM qualified lease permit.
    output logic fault_o, // Immediate or stored controller/platform general fault.
    output logic [63:0] lease_expiry_o, // Fixed committed expiry, owned by CONTROLLER.
    input logic sclk_i, // Untrusted asynchronous SPI mode-0 clock.
    input logic cs_ni, // Untrusted active-low SPI selection.
    input logic mosi_i, // Untrusted MSB-first MOSI data.
    output logic miso_o, // Pad data; output enable is separate for technology-specific tri-state.
    output logic miso_oe_o, // Pad enable; low asynchronously whenever CS_N is high.
    output logic [63:0] receive_token_o, // SPI receive token; separate from the internal verifier token.
    output logic [13:0] receive_total_o, // Exact canonical owned reply length.
    output logic [13:0] receive_offset_o, // Accepted contiguous byte offset; changes only after a valid transaction.
    output logic receive_owned_o, // One owner across receiving and both verifier passes.
    output logic sealed_o, // Checked receive-memory seal.
    output logic receive_integrity_o, // Receive/SPI internal integrity alarm; fed directly into the general fault path.
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
    output logic enforcement_fault_o, profile_compatible_o, // Fail-off enforcement / supported timing profile.
    output logic job_ready_o, // Passive actual hardware-verifier admission; never an authorization input.
    output logic [7:0] verifier_state_o,
    output logic [15:0] verifier_lane_state_o,
    output logic [31:0] verifier_starts_o, verifier_completions_o, verifier_expected_o,
    output logic [5:0] verifier_physical_start_o, verifier_physical_complete_o,
    output logic [3:0] verifier_read_owner_o,
    output logic verifier_fault_o,
    input logic [2175:0] factory_image_i,
    input logic [7:0] fault_i,
    output logic [191:0] effect_count_o,
    output logic [2:0] stale_effect_o,
    output logic [5:0] core_start_o, core_end_o,
    output logic [511:0] core_block_o [0:5],
    output logic [255:0] core_state_o [0:5],
    output logic [1:0] stage_valid_o,
    output logic [127:0] stage_value_o [0:1],
    output logic completion_valid_o,
    output logic [1:0] completion_pass_o,
    output logic [7:0] completion_code_o
);
    logic macro_write_o;
    logic macro_close_o;
    logic [8:0] macro_address_o;
    logic [7:0] macro_write_data_o;
    logic [7:0] macro_read_data_i;
    logic [1:0] macro_lifecycle_i;
    logic macro_complete_i;
    reins_otp_model otp (
        .clk_i(clk_i),.factory_valid_i(1'b1),.factory_image_i(factory_image_i),.factory_lifecycle_i(2'b11),
        .physical_enable_i(physical_enable_i),.stopped_i(stop_complete_o),.write_i(macro_write_o),.close_i(macro_close_o),
        .address_i(macro_address_o),.data_i(macro_write_data_o),.model_bad_close_i(1'b0),.model_bad_code_i(1'b0),
        .read_data_o(macro_read_data_i),.lifecycle_o(macro_lifecycle_i),.complete_o(macro_complete_i));
    reins_device device (.raw_clock_i({3{clk_i}}),.*);
    assign completion_valid_o=device.completion_valid_i;
    assign completion_pass_o=device.completion_pass_i;
    assign completion_code_o=device.completion_code_i;
assign core_start_o[0]=device.verifier.passes[0].engine.merkle.hasher.core.req_valid_i && device.verifier.passes[0].engine.merkle.hasher.core.req_ready_o;
assign core_end_o[0]=device.verifier.passes[0].engine.merkle.hasher.core.rsp_valid_o && device.verifier.passes[0].engine.merkle.hasher.core.rsp_ready_i;
assign core_block_o[0]=device.verifier.passes[0].engine.merkle.hasher.core.req_block_i;
assign core_state_o[0]=device.verifier.passes[0].engine.merkle.hasher.core.req_state_i;
assign core_start_o[1]=device.verifier.passes[0].engine.slh.core.hash.backend.core.req_valid_i && device.verifier.passes[0].engine.slh.core.hash.backend.core.req_ready_o;
assign core_end_o[1]=device.verifier.passes[0].engine.slh.core.hash.backend.core.rsp_valid_o && device.verifier.passes[0].engine.slh.core.hash.backend.core.rsp_ready_i;
assign core_block_o[1]=device.verifier.passes[0].engine.slh.core.hash.backend.core.req_block_i;
assign core_state_o[1]=device.verifier.passes[0].engine.slh.core.hash.backend.core.req_state_i;
assign core_start_o[2]=device.verifier.passes[0].engine.slh.core.wots.hash.backend.core.req_valid_i && device.verifier.passes[0].engine.slh.core.wots.hash.backend.core.req_ready_o;
assign core_end_o[2]=device.verifier.passes[0].engine.slh.core.wots.hash.backend.core.rsp_valid_o && device.verifier.passes[0].engine.slh.core.wots.hash.backend.core.rsp_ready_i;
assign core_block_o[2]=device.verifier.passes[0].engine.slh.core.wots.hash.backend.core.req_block_i;
assign core_state_o[2]=device.verifier.passes[0].engine.slh.core.wots.hash.backend.core.req_state_i;
assign stage_valid_o[0]=device.verifier.passes[0].engine.stage_valid;
assign stage_value_o[0]=device.verifier.passes[0].engine.stage_value;
assign core_start_o[3]=device.verifier.passes[1].engine.merkle.hasher.core.req_valid_i && device.verifier.passes[1].engine.merkle.hasher.core.req_ready_o;
assign core_end_o[3]=device.verifier.passes[1].engine.merkle.hasher.core.rsp_valid_o && device.verifier.passes[1].engine.merkle.hasher.core.rsp_ready_i;
assign core_block_o[3]=device.verifier.passes[1].engine.merkle.hasher.core.req_block_i;
assign core_state_o[3]=device.verifier.passes[1].engine.merkle.hasher.core.req_state_i;
assign core_start_o[4]=device.verifier.passes[1].engine.slh.core.hash.backend.core.req_valid_i && device.verifier.passes[1].engine.slh.core.hash.backend.core.req_ready_o;
assign core_end_o[4]=device.verifier.passes[1].engine.slh.core.hash.backend.core.rsp_valid_o && device.verifier.passes[1].engine.slh.core.hash.backend.core.rsp_ready_i;
assign core_block_o[4]=device.verifier.passes[1].engine.slh.core.hash.backend.core.req_block_i;
assign core_state_o[4]=device.verifier.passes[1].engine.slh.core.hash.backend.core.req_state_i;
assign core_start_o[5]=device.verifier.passes[1].engine.slh.core.wots.hash.backend.core.req_valid_i && device.verifier.passes[1].engine.slh.core.wots.hash.backend.core.req_ready_o;
assign core_end_o[5]=device.verifier.passes[1].engine.slh.core.wots.hash.backend.core.rsp_valid_o && device.verifier.passes[1].engine.slh.core.wots.hash.backend.core.rsp_ready_i;
assign core_block_o[5]=device.verifier.passes[1].engine.slh.core.wots.hash.backend.core.req_block_i;
assign core_state_o[5]=device.verifier.passes[1].engine.slh.core.wots.hash.backend.core.req_state_i;
assign stage_valid_o[1]=device.verifier.passes[1].engine.stage_valid;
assign stage_value_o[1]=device.verifier.passes[1].engine.stage_value;
    for (genvar endpoint=0;endpoint<3;endpoint++) begin : sinks
        always_ff @(posedge clk_i) begin
            if (!por_ni) begin effect_count_o[endpoint*64 +: 64]<=0; stale_effect_o[endpoint]<=0; end
            else if (outbound_valid_o[endpoint] && outbound_ready_i[endpoint]) begin
                effect_count_o[endpoint*64 +: 64]<=effect_count_o[endpoint*64 +: 64]+64'd1;
                if (outbound_data_o[endpoint*136+72 +: 64]!=run_generation_o || outbound_data_o[endpoint*136 +: 8]!=8'(endpoint)) stale_effect_o[endpoint]<=1;
            end
        end
    end
logic [7:0] previous_fault;
always @(posedge clk_i) begin
if (fault_i!=previous_fault) begin
case(previous_fault)
8'd1: begin release device.verifier.passes[0].engine.slh.core.hash.backend.core.req_ready_o; end
8'd2: begin release device.verifier.passes[1].engine.slh.core.hash.backend.core.req_ready_o; end
8'd3: begin release device.verifier.capture_q; release device.verifier.capture_inv_q; end
8'd4: begin release device.verifier.read_address_o; release device.verifier.read_address_inverse_o; end
default: begin end
endcase
case(fault_i)
8'd1: begin force device.verifier.passes[0].engine.slh.core.hash.backend.core.req_ready_o=1'b0; end
8'd2: begin force device.verifier.passes[1].engine.slh.core.hash.backend.core.req_ready_o=1'b0; end
8'd3: begin force device.verifier.capture_q=8'h96; force device.verifier.capture_inv_q=~8'h96; end
8'd4: begin force device.verifier.read_address_o=14'd0; force device.verifier.read_address_inverse_o=~14'd0; end
default: begin end
endcase
end
previous_fault<=fault_i;
end
endmodule
`default_nettype wire
