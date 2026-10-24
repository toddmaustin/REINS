// Copyright (c) 2026 Todd Austin.
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// License: https://polyformproject.org/licenses/noncommercial/1.0.0/

// SIMULATION ONLY: isolated instance of the exact production memory wrapper.
`default_nettype none
module receive_memory_unit_top (
    input logic clk_i, por_ni, reset_i, // Always-on clock, actual power loss, volatile ownership reset.
    input logic acquire_i, release_i, seal_i, // Trusted mailbox transitions; release dominates all writes.
    input logic [63:0] acquire_token_i, acquire_token_inverse_i, // Separate proposed owner avoids alarm/grant feedback.
    input logic [63:0] token_i, token_inverse_i, // Matching powered ownership, with independent complement.
    input logic write_valid_i,         // Sole write port, used only for uncommitted receiving bytes.
    input logic [7:0] write_code_i,     // Exact 0xc3 authorization code, not a host-controlled byte.
    input logic [13:0] write_address_i, write_address_inverse_i, // Absolute byte address and complement.
    input logic [7:0] write_data_i,     // Untrusted candidate byte; never proof of acceptance.
    output logic write_event_o,        // Actual write-enable observation for independent test accounting.
    input logic read_valid_i,          // Trusted verifier read, valid only across the sealed two-pass job.
    input logic [13:0] read_address_i, read_address_inverse_i, // Checked byte address and complement.
    output logic read_valid_o,         // Data valid only after ECC/address/owner/control checks.
    output logic [7:0] read_data_o,     // Zero on any denied or corrupt read.
    output logic sealed_o, fault_o     // Checked lock / immediate or sticky general integrity alarm.
);
    reins_receive_sram memory (.*);
endmodule
`default_nettype wire
