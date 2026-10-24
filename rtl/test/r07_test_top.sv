// Copyright (c) 2026 Todd Austin.
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// License: https://polyformproject.org/licenses/noncommercial/1.0.0/

// SIMULATION ONLY: qualified platform inputs, actual R06/R07, software verifier boundary.
`default_nettype none
module r07_test_top (
    input logic clk_i, // Always-on monitor clock / actual retention loss.
    input logic por_ni, // Always-on monitor clock / actual retention loss.
    input logic logic_reset_i, // Cancel authorization / trusted cold fault requalification.
    input logic cold_clear_i, // Cancel authorization / trusted cold fault requalification.
    input logic config_valid_i, // Retained closure / completely checked R05 snapshot.
    input logic [2175:0] configuration_i, // Exact public OTP, immutable throughout a run.
    input logic [255:0] config_digest_i, // Actual R05 C_cfg, checked against captured copies.
    input logic [63:0] lease_i, // Checked L/P/W in local ticks.
    input logic [63:0] period_i, // Checked L/P/W in local ticks.
    input logic [63:0] window_i, // Checked L/P/W in local ticks.
    input logic fault_i, // General alarm / effective hold / R05 grants gate.
    input logic entropy_failure_i, // General alarm / effective hold / R05 grants gate.
    input logic grant_enable_i, // General alarm / effective hold / R05 grants gate.
    input logic [63:0] now_i, // Current trusted time BEFORE the clock edge.
    input logic tick_i, // This edge advances R05 time by one; deadlines include it.
    input logic run_begin_i, // R05 established new tick zero/generation after qualification.
    input logic [63:0] platform_generation_i, // R05's powered run generation; strictly increases on admission.
    output logic restart_ready_o, // Qualified stop boundary permits requesting R05 startup.
    input logic stop_ack_i, // Trusted enforcement acknowledgement, never a host command.
    output logic stop_request_o, // Complete physical stop / pulse canceling R05's old run.
    output logic run_end_o, // Complete physical stop / pulse canceling R05's old run.
    output logic [7:0] state_o, // Sparse public diagnostic state (documented in R06 guide).
    output logic fault_o, // Immediate-or-sticky fault / independently gated lease.
    output logic permit_o, // Immediate-or-sticky fault / independently gated lease.
    output logic [63:0] run_generation_o, // Powered run identity retained across logic resets; never a wire/session field.
    output logic [63:0] round_o, // Current 64-bit protocol round, starting at one.
    output logic [63:0] job_generation_o, // Powered monotonic internal receive/verifier epoch.
    output logic pending_o, // One context / coherent current request publication.
    output logic request_valid_o, // One context / coherent current request publication.
    output logic [1023:0] request_o, // Exact 128 bytes, byte zero in bits 1023:1016.
    output logic [63:0] issue_o, // Fixed pending I/B/E, never arrival-relative.
    output logic [63:0] deadline_o, // Fixed pending I/B/E, never arrival-relative.
    output logic [63:0] proposed_expiry_o, // Fixed pending I/B/E, never arrival-relative.
    output logic [2:0] votes_o, // Distinct pending slots; zero when the round closes.
    output logic draw_valid_o, // R05 draw for a subsequent fixed scheduled round.
    input logic draw_ready_i, // R05 accepts draw_round/issue on this edge.
    output logic [63:0] draw_round_o, // Round whose fresh nonce is requested from R05.
    output logic [63:0] draw_issue_o, // Fixed issue tick; acquisition must not predate this boundary.
    input logic nonce_valid_i, // R05 conditioned result, with complete captured identity.
    output logic nonce_ready_o, // Accept only a fresh nonce tagged for the pending issue/run/round.
    input logic [255:0] nonce_i, // R05 conditioned 256-bit nonce, not a host-supplied response field.
    input logic [63:0] nonce_round_i, // Round tag captured by the R05 conditioner.
    input logic [63:0] nonce_issue_i, // Fixed issue tag captured before fresh-sample acquisition.
    input logic [63:0] nonce_generation_i, // Powered run tag captured by the R05 conditioner.
    output logic submit_ready_o, // Only one live job and one immutable context snapshot.
    output logic job_valid_o, // Immutable request to the trusted verifier; held until ready.
    input logic job_ready_i, // Trusted verifier accepts a sealed immutable job on valid/ready.
    output logic job_active_o, // One internal verifier ownership remains live.
    output logic [63:0] job_token_o, // Internal R06 token, separate from the public SPI receive token.
    output logic [63:0] job_run_o, // Captured powered run identity for both verifier passes.
    output logic [63:0] job_round_o, // Captured protocol round for both verifier passes.
    output logic [63:0] job_epoch_o, // Captured job epoch; stale generations cannot vote.
    output logic [1:0] job_slot_o, // Captured fixed OTP authority/key slot 0..2.
    output logic [1023:0] job_request_o, // Exact immutable 128-byte locally constructed request.
    output logic [2175:0] job_configuration_o, // Complete immutable 272-byte public configuration for both passes.
    output logic [255:0] job_config_digest_o, // Captured C_cfg, independently checked by the trusted verifier.
    output logic cancel_valid_o, // Actual formerly-owned token canceled at this edge.
    output logic [63:0] cancel_token_o, // Internal token canceled at this event, never a newly admitted token.
    input logic completion_valid_i, // One independently sequenced verifier pass result.
    output logic completion_ready_o, // Always drain stale results; no ownership implied.
    input logic [63:0] completion_token_i, // Echo the captured internal verifier token.
    input logic [63:0] completion_run_i, // Echo the captured powered run identity.
    input logic [63:0] completion_round_i, // Echo the captured protocol round.
    input logic [63:0] completion_epoch_i, // Echo the captured internal job epoch.
    input logic [1:0] completion_slot_i, // Echo the captured fixed authority/key slot.
    input logic [1:0] completion_pass_i, // Independently sequenced pass 1 or 2; pass 2 requires observed pass 1.
    input logic [1023:0] completion_request_i, // Echo immutable checked inputs, not a returned wire body.
    input logic [255:0] completion_config_digest_i, // Echo independently checked C_cfg for the immutable job.
    input logic [7:0] completion_code_i, // Pass 1 accepts 0x96; pass 2 accepts 0x69; all else fail.
    output logic result_valid_o, // Completed/canceled own job status, including rejection.
    output logic [63:0] result_token_o, // Internal token whose asynchronous result completed.
    output logic [1:0] result_code_o, // 0 verified, 1 rejected, 2 canceled.
    output logic vote_event_o, // Semantic diagnostics, not acceptance bypasses.
    output logic commit_event_o, // Semantic diagnostics, not acceptance bypasses.
    output logic lease_valid_o, // R06 owns a qualified committed lease; this is not a host grant.
    output logic [63:0] committed_issue_o, // Original issue I_c of the committed execution lease.
    output logic [63:0] lease_expiry_o, // Fixed expiry I_c+L; no traffic or crypto work moves it.
    output logic [63:0] remaining_o, // Saturating remaining counter, cross-checked against independent issue age.
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
    input logic [1:0] lifecycle_i, // Public lifecycle: 0 open, 1 closed, 2 invalid.
    input logic trusted_tick_i // Independent trusted time event, including while the run is inactive.
);
    wire [255:0] nonce_audit_i=~nonce_i; // Trusted abstract R05 model; production has independent conditioner rails.
    reins_spi_control device (.*);
endmodule
`default_nettype wire
