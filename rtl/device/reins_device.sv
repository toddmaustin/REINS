// Copyright (c) 2026 Todd Austin.
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// License: https://polyformproject.org/licenses/noncommercial/1.0.0/

// Production device: authorization comes from two complete real-SHA passes.
// Port-group labels distinguish the external role of each interface:
//   DEVICE  - Functional platform, commissioning, SPI and enforcement connections.
//   HEALTH  - Functional fault/health inputs or alarms used by protection logic.
//   STATUS  - Public integration/status mirrors of internally checked state.
//   OBSERVE - Detailed passive observations for verification and debugging.
//   DEMO    - Effects of the three representative protected endpoint workloads.
// Output labels describe external use: STATUS/OBSERVE signals may also carry
// internal handshakes or safety feedback. Leaving an exported observation open
// does not remove that internal wiring or disable its checks.
// There are NO simulation fault-injection, software-verdict or host stop-ACK
// inputs here. Test-only stimulus/injection controls belong in rtl/test/.
// Port names, types and declaration order are retained for existing integrations.
`default_nettype none
module reins_device (
    // ---------------------------------------------------------------------
    // DEVICE: trusted clocks, independently distributed reset and startup.
    // These come from the qualified platform, not the untrusted SPI host.
    // ---------------------------------------------------------------------
    input logic endpoint_por_ni, // Independently distributed asynchronous fail-off endpoint reset on real power loss.
    input logic clk_i, // Always-on monitor clock; must keep progressing while protected endpoints stop.
    input logic por_ni, // Active-low actual power-loss reset for the always-on device state.
    input logic cold_reset_i, // Technology-recognized cold reset; subject to retained-history policy.
    input logic warm_reset_i, // Warm reset indication; cannot clear sticky entropy hold.
    input logic startup_i, // Trusted startup attempt; admitted only after internally certified stop.

    // DEVICE: physically enabled commissioning; not runtime host commands.
    // Accepted writes/closure also require the internal actual-stop interlock.
    input logic physical_enable_i, // Physical commissioning enable, independent of untrusted management software.
    input logic config_write_i, // Attempt to program one byte at config_address_i.
    input logic config_check_i, // Request full schema/key/hash validation of the sensed OTP image.
    input logic config_close_i, // Attempt permanent lifecycle closure after the required checks.
    input logic [8:0] config_address_i, // Programming byte offset, 0..271.
    input logic [7:0] config_data_i, // Public commissioning byte.
    output logic config_write_accepted_o, // Actual admitted programming transaction.

    // DEVICE / HEALTH: technology OTP-macro interface, required in hardware.
    // A behavioral OTP model supplies this interface only in the test wrapper.
    output logic macro_write_o, // Qualified byte-write strobe to the physical OTP wrapper.
    output logic macro_close_o, // Qualified irreversible-close strobe to the physical OTP wrapper.
    output logic [8:0] macro_address_o, // Read/check cursor or programming byte address.
    output logic [7:0] macro_write_data_o, // Payload of an admitted write.
    input logic [7:0] macro_read_data_i, // Sensed logical byte at macro_address_o.
    input logic [1:0] macro_lifecycle_i, // Retained lifecycle code: 00 open, 11 closed, other codes invalid.
    input logic macro_complete_i, // Physical wrapper reports that the full logical image is present.
    input logic macro_integrity_i, // Physical sensing/ECC/lock health; low is a real configuration fault.

    // STATUS / OBSERVE: commissioning results and checked configuration mirrors.
    // These are exported observations, not alternate configuration inputs.
    output logic config_busy_o, // Configuration checker currently owns its read/hash transaction.
    output logic config_done_o, // Configuration check completion pulse; consult valid/error separately.
    output logic config_valid_o, // Checked image/hash/schema are valid under the current lifecycle and health.
    output logic [2:0] config_error_o, // reins_config's retained check diagnostic.
    output logic [2175:0] configuration_o, // Full checked public image, meaningful when valid.
    output logic [255:0] configuration_digest_o, // Exact C_cfg; meaningful with config_valid_o.
    output logic [63:0] lease_length_o, // Checked lease length L in trusted local ticks.
    output logic [63:0] period_o, // Checked round issue period P in trusted local ticks.
    output logic [63:0] window_o, // Checked response window W in local ticks.

    // DEVICE / HEALTH: qualified time progress and physical health inputs.
    // Tests may drive these to model failures; they remain essential operational
    // protection inputs, not simulation injection enables or optional debug pins.
    input logic reference_a_i, // Synchronized progress event from independent timing reference A.
    input logic reference_b_i, // Synchronized progress event from dissimilar timing reference B.
    input logic timing_healthy_i, // High while the qualified platform timing checks are healthy.
    input logic sensor_healthy_i, // High while required physical sensors/environment checks are healthy.
    input logic integrity_alarm_i, // Active-high qualified integrity alarm; withdraws authorization.

    // DEVICE: independent raw entropy-source acquisition interfaces.
    // The platform supplies actual fresh samples and trusted acquisition times;
    // deterministic sources used by simulation do not establish physical entropy.
    input logic source_a_available_i, // Physical source A is available for fresh sample acquisition.
    input logic source_b_available_i, // Independent physical source B is available for fresh sample acquisition.
    input logic source_a_valid_i, // One fresh source-A sample event; bit/time qualify this event.
    input logic source_a_bit_i, // Raw binary value of the source-A sample event.
    input logic [63:0] source_a_time_i, // Trusted A acquisition tick, before any queue.
    input logic source_b_valid_i, // One fresh source-B sample event; bit/time qualify this event.
    input logic source_b_bit_i, // Raw binary value of the source-B sample event.
    input logic [63:0] source_b_time_i, // Trusted B acquisition tick, before any queue.
    output logic source_a_request_o, // Startup or active fresh-draw demand.
    output logic source_b_request_o, // Startup or active fresh-draw demand.

    // STATUS / HEALTH: entropy/startup policy and trusted-time observations.
    // A platform run is not itself an active execution lease; use permit_o below.
    output logic [8:0] source_a_count_o, // Accepted source-A nonce bits; a count is not an entropy assessment.
    output logic [8:0] source_b_count_o, // Accepted source-B nonce bits; a count is not an entropy assessment.
    output logic entropy_hold_o, // Sticky hold blocks new grants; an existing healthy lease lasts to its expiry.
    output logic cold_eligible_o, // Recognized cold-start eligibility under retained entropy-history policy.
    output logic history_valid_o, // Retained previous-nonce history exists for repeat detection.
    output logic checking_o, // Platform startup qualification is in progress.
    output logic run_active_o, // Platform run phase; this is not a lease-permission indication.
    output logic startup_complete_o, // Platform, configuration and fresh first-nonce qualification are complete.
    output logic new_grants_o, // Current platform/entropy state allows admission of new grants.
    output logic invalidate_o, // Immediate/stored platform fault invalidating current pending work.
    output logic [63:0] now_o, // Trusted local tick; advances independently of SPI and verification work.
    output logic [63:0] generation_o, // Nonwrapping platform run generation, not a wire/session field.

    // DEVICE / STATUS: trusted stop/startup sequencing, produced internally.
    output logic restart_ready_o, // Qualified stop boundary permits requesting PLATFORM startup.
    output logic stop_request_o, // Controller requests actual endpoint stop and termination of the old platform run.

    // OBSERVE: controller state, round and coherent pending-request publication.
    // The management host reads protocol requests through SPI. These parallel
    // outputs mirror local state for integration/debug and independent scoreboards.
    output logic [7:0] state_o, // Sparse public diagnostic state (documented in CONTROLLER guide).
    output logic [63:0] run_generation_o, // Powered run identity; never a wire/session field.
    output logic [63:0] round_o, // Current protocol round, starting at one.
    output logic [63:0] job_generation_o, // Powered monotonic job epoch.
    output logic pending_o, // One pending round context exists, including before its fresh nonce is ready.
    output logic request_valid_o, // request_o is coherently published for the current pending context.
    output logic [1023:0] request_o, // Exact 128 bytes, byte zero in bits 1023:1016.
    output logic [63:0] issue_o, // Pending round's fixed issue I=(round-1)*P.
    output logic [63:0] deadline_o, // Pending response deadline B=I+W; completion must be strictly earlier.
    output logic [63:0] proposed_expiry_o, // Pending lease's fixed expiry E=I+L, not arrival-relative.
    output logic [2:0] votes_o, // Distinct pending slots; zero when the round closes.

    // OBSERVE: exported mirrors of the internal controller/verifier job path.
    // The actual ready/completion connections stay inside this module. External
    // logic cannot inject a verdict or authorize a vote through these outputs.
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

    // STATUS / OBSERVE: job outcomes, vote/commit events and committed lease.
    output logic result_valid_o, // Completed/canceled own job status, including rejection.
    output logic [63:0] result_token_o, // Token whose status completed on result_valid_o.
    output logic [1:0] result_code_o, // 0 verified, 1 rejected, 2 canceled.
    output logic vote_event_o, // Semantic diagnostics, not acceptance bypasses.
    output logic commit_event_o, // Semantic diagnostics, not acceptance bypasses.
    output logic [63:0] committed_issue_o, // I_c of the actual committed lease.
    output logic [63:0] remaining_o, // Saturating remaining down-counter, not an arrival-relative lease.

    // DEVICE / HEALTH: high-level execution authorization and general alarm.
    // permit_o is active-high qualified lease status. Enforcement below uses
    // both dynamic permit rails and independent local guards, not this bit alone.
    output logic permit_o, // High only for a valid unexpired lease with current platform/controller permission.
    output logic fault_o, // Immediate or stored controller/platform protection fault; not an injection control.
    output logic [63:0] lease_expiry_o, // Fixed committed expiry, owned by CONTROLLER.

    // DEVICE: untrusted mode-0 SPI management/relay connection.
    // This path stays live while protected endpoints are stopped. The pad wrapper
    // uses miso_oe_o to implement the technology-specific external tri-state.
    input logic sclk_i, // Untrusted asynchronous SPI mode-0 clock.
    input logic cs_ni, // Untrusted active-low SPI selection.
    input logic mosi_i, // Untrusted MSB-first MOSI data.
    output logic miso_o, // Pad data; output enable is separate for technology-specific tri-state.
    output logic miso_oe_o, // Pad enable; low asynchronously whenever CS_N is high.

    // STATUS / HEALTH: receive-job ownership, seal and real integrity alarm.
    // These mirror the sole receive store; they are not a second payload port.
    output logic [63:0] receive_token_o, // SPI receive token; separate from the internal verifier token.
    output logic [13:0] receive_total_o, // Exact canonical owned reply length.
    output logic [13:0] receive_offset_o, // Accepted contiguous byte offset; changes only after a valid transaction.
    output logic receive_owned_o, // One owner across receiving and both verifier passes.
    output logic sealed_o, // Checked receive-memory seal.
    output logic receive_integrity_o, // Actual receive/SPI fault, fed internally into general fault handling.

    // OBSERVE: checked receive data and physical write accounting.
    // The verifier consumes these internal checked reads; exported copies let
    // scoreboards observe them without a memory-write or data-substitution input.
    output logic read_valid_o, // ECC/address/owner checked sealed read result.
    output logic [7:0] read_data_o, // Verified-memory byte; zero when the read is denied or corrupt.
    output logic write_event_o, // Passive observation of the sole physical payload write port.

    // OBSERVE: decoded SPI transaction taps, useful for pin-level scoreboards.
    output logic spi_start_o, // Passive synchronized SPI selection event.
    output logic spi_byte_valid_o, // Passive complete MOSI-byte event.
    output logic spi_end_o, // Passive final transaction-boundary event, including invalid exchanges.
    output logic [8:0] spi_byte_index_o, // Passive zero-based complete-byte index.
    output logic [8:0] spi_bytes_o, // Passive final complete-byte count.
    output logic [7:0] spi_byte_o, // Passive received MOSI byte.
    output logic spi_frame_error_o, // Passive final partial/timing/timeout/framing diagnostic.

    // DEVICE: local enforcement clocks and endpoint-facing backpressure.
    // Endpoint indices are CPU=0, accelerator=1, DMA/bus master=2. The current
    // top includes representative workload generators behind real RTL guards,
    // queues and serial clock/transaction cuts; it does not contain a full CPU.
    input logic [2:0] guard_clock_a_i, // One independent always-on A-path guard clock per endpoint.
        guard_clock_b_i, // One dissimilar always-on B-path guard clock per endpoint.
    input logic [2:0] raw_clock_i, // Protected workload clocks; these may stop while guard/management clocks continue.
    input logic [2:0] outbound_ready_i, // Receiver backpressure; it cannot extend the lease or postpone stopping.

    // DEMO: externally visible transactions from the representative endpoints.
    // valid/data have passed both local cuts. These payloads demonstrate bounded
    // effects; a platform integration must connect its actual protected endpoints.
    output logic [2:0] outbound_valid_o, // One permitted outbound transaction indication per endpoint.
    output logic [407:0] outbound_data_o, // Three 136-bit bundles: generation[64] || sequence[64] || endpoint[8].

    // DEMO / OBSERVE: activity, queues and actual local guard/cut feedback.
    // Closure/empty feedback also forms the trusted internal stop certificate.
    output logic [191:0] work_count_o, // Three 64-bit representative useful-work counters; not lease counters.
    output logic [8:0] queued_o, // Three 3-bit queue occupancies, all storage before both final cuts.
    output logic [2:0] queue_empty_o, // Actual per-endpoint queue-empty indications.
        closed_a_o, // Per-endpoint path A reports completed local isolation/closure.
        closed_b_o, // Per-endpoint path B reports completed local isolation/closure.
    output logic [2:0] open_a_o, // Per-endpoint A-path transaction isolation is open.
        open_b_o, // Per-endpoint B-path transaction isolation is open.
        protected_clock_o, // Actual clocks after both independently controlled serial clock cuts.

    // DEVICE / HEALTH: dynamic permission and trusted enforcement status.
    // Both permit rails must keep making correctly spaced transitions. They
    // hold their last levels on withdrawal; a static high does not mean ACTIVE.
    output logic permit_a_o, // Independently qualified A rail; nominally toggles every 500 trusted ticks.
        permit_b_o, // Independently qualified B rail; current top also routes both rails to its local guards.
    output logic enforcement_epoch_o, // Fresh ARM epoch toggle used internally by guards; not a wire/session field.
    output logic stop_complete_o, // Internally certified actual endpoint closure/queue stop; never a host ACK.
    output logic enforcement_fault_o, // Actual local enforcement integrity/timing failure.
        profile_compatible_o, // Checked configuration meets the modeled guard/stop timing profile.

    // OBSERVE: internal real-verifier admission, sequencer and work observations.
    // These feed test scoreboards and integration diagnostics; no test control
    // or external completion/success flag is accepted at this production boundary.
    output logic job_ready_o, // Actual internal verifier admission readiness; externally observation only.
    output logic [7:0] verifier_state_o, // Protected two-pass bank's sparse sequencer state.
    output logic [15:0] verifier_lane_state_o, // Lane 1 state in [15:8], lane 0 state in [7:0].
    output logic [31:0] verifier_starts_o, // Observed compression-start counts: lane 1 [31:16], lane 0 [15:0].
        verifier_completions_o, // Observed completion counts with the same lane packing.
        verifier_expected_o, // Independently derived exact expected work with the same lane packing.
    output logic [5:0] verifier_physical_start_o, // Physical Merkle/main-SLH/WOTS starts for both lanes.
        verifier_physical_complete_o, // Matching physical completion observations; not forced test completions.
    output logic [3:0] verifier_read_owner_o, // Checked sealed-read owner code: 0 none, 3 lane 0, c lane 1.

    // HEALTH: this is a real alarm despite its placement next to verifier taps.
    output logic verifier_fault_o // Actual bank/lane integrity fault; internally feeds general fault handling.
);
    logic job_ready_i;
    logic completion_valid_i;
    logic [63:0] completion_token_i;
    logic [63:0] completion_run_i;
    logic [63:0] completion_round_i;
    logic [63:0] completion_epoch_i;
    logic [1:0] completion_slot_i;
    logic [1:0] completion_pass_i;
    logic [1023:0] completion_request_i;
    logic [255:0] completion_config_digest_i;
    logic [7:0] completion_code_i;
    logic [2:0] completion_reason_i;
    logic read_valid_i;
    logic [13:0] read_address_i;
    logic [13:0] read_address_inverse_i;
    logic context_q, final_live;
    logic [1:0] completion_pass;
    logic [7:0] completion_code;
    // Registered context breaks the alarm/read request path; immediate final gates
    // and the controller's edge/deadline/fault checks still dominate acceptance.
    always_ff @(posedge clk_i) begin
        if (!por_ni || cold_reset_i || warm_reset_i) context_q<=0;
        else context_q<=job_active_o && receive_owned_o && sealed_o && config_valid_o;
    end
    assign final_live=job_active_o && receive_owned_o && sealed_o && config_valid_o &&
        !cold_reset_i && !warm_reset_i && !invalidate_o && !entropy_hold_o && timing_healthy_i && sensor_healthy_i &&
        !integrity_alarm_i && !receive_integrity_o && now_o<deadline_o;
    assign job_ready_i=job_ready_o;
    assign completion_pass_i=completion_pass;
    assign completion_code_i=completion_code;
    reins_device_enforced control (
        .integrity_alarm_i(integrity_alarm_i || verifier_fault_o), .*
    );
    reins_verifier verifier (
        .clk_i(clk_i),.rst_ni(por_ni && !cold_reset_i && !warm_reset_i),.cancel_i(cancel_valid_o),
        .context_valid_i(context_q),.live_i(final_live),.job_valid_i(job_valid_o),.job_ready_o(job_ready_o),
        .configuration_i(configuration_o),.configuration_digest_i(job_config_digest_o),.request_i(job_request_o),
        .run_i(job_run_o),.round_i(job_round_o),.token_i(job_token_o),.epoch_i(job_epoch_o),.slot_i(job_slot_o),.reply_length_i(receive_total_o),
        .read_valid_o(read_valid_i),.read_address_o(read_address_i),.read_address_inverse_o(read_address_inverse_i),
        .read_valid_i(read_valid_o),.read_data_i(read_data_o),
        .completion_valid_o(completion_valid_i),.completion_ready_i(completion_ready_o),
        .completion_run_o(completion_run_i),.completion_round_o(completion_round_i),.completion_token_o(completion_token_i),.completion_epoch_o(completion_epoch_i),
        .completion_slot_o(completion_slot_i),.completion_pass_o(completion_pass),.completion_request_o(completion_request_i),
        .completion_config_o(completion_config_digest_i),.completion_code_o(completion_code),.completion_reason_o(completion_reason_i),
        .fault_o(verifier_fault_o),.state_o(verifier_state_o),.lane_state_o(verifier_lane_state_o),
        .starts_o(verifier_starts_o),.completions_o(verifier_completions_o),.expected_o(verifier_expected_o),
        .physical_start_o(verifier_physical_start_o),.physical_complete_o(verifier_physical_complete_o),.read_owner_o(verifier_read_owner_o));
endmodule
`default_nettype wire
