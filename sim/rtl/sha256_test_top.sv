// Simulation-only top: expose both production interfaces and passive internal taps.
// No fault injection, alternate datapath, or software hash bypass exists in the RTL.
`default_nettype none
module sha256_test_top (
    input logic clk_i, rst_ni,                  // Shared clock and synchronous cancellation.
    input logic block_valid_i,                 // Direct compression request handshake.
    output logic block_ready_o,                // Direct request acceptance availability.
    input logic [255:0] block_state_i,          // Arbitrary initial chaining state.
    input logic [511:0] block_data_i,           // Exactly one unpadded compression block.
    input logic [31:0] block_tag_i,             // Caller identity for the direct operation.
    output logic block_rsp_valid_o,            // Direct compression response handshake.
    input logic block_rsp_ready_i,             // Consumer acknowledgement of direct result.
    output logic [255:0] block_result_o,        // Feed-forward chaining result.
    output logic [31:0] block_rsp_tag_o,        // Echo of captured direct identity.
    output logic block_start_o, block_done_o,   // Diagnostics checked against pin observations.
    input logic msg_valid_i,                   // Complete-message length/tag handshake.
    output logic msg_ready_o,                  // Availability for a new message header.
    input logic [31:0] msg_length_i, msg_tag_i, // Declared bytes and opaque identity.
    input logic byte_valid_i,                  // Message byte-stream handshake.
    output logic byte_ready_o,                 // Message wrapper can capture the next byte.
    input logic [7:0] byte_i,                   // Transmission-order data byte.
    output logic msg_rsp_valid_o,              // Complete-message response handshake.
    input logic msg_rsp_ready_i,               // Consumer acknowledgement of digest/error.
    output logic [255:0] msg_digest_o,          // Digest on success, zero on failure.
    output logic [31:0] msg_rsp_tag_o,           // Captured message identity.
    output logic [1:0] msg_error_o,             // Wrapper's length/stall/control outcome.
    output logic observed_req_valid_o,         // Passive taps on message->compression pins.
    output logic observed_req_ready_o,         // Inner core can accept a block.
    output logic [511:0] observed_block_o,      // Actual block presented to the inner core.
    output logic [255:0] observed_state_o,      // Actual input chaining state.
    output logic observed_rsp_valid_o,         // Actual inner core result validity.
    output logic observed_rsp_ready_o,         // Wrapper's actual result acknowledgement.
    output logic [255:0] observed_result_o      // Actual inner core output state.
);
    sha256_compress compression (
        .clk_i(clk_i), .rst_ni(rst_ni), .req_valid_i(block_valid_i), .req_ready_o(block_ready_o),
        .req_state_i(block_state_i), .req_block_i(block_data_i), .req_tag_i(block_tag_i),
        .rsp_valid_o(block_rsp_valid_o), .rsp_ready_i(block_rsp_ready_i),
        .rsp_state_o(block_result_o), .rsp_tag_o(block_rsp_tag_o),
        .start_o(block_start_o), .complete_o(block_done_o)
    );
    sha256_message message (
        .clk_i(clk_i), .rst_ni(rst_ni), .req_valid_i(msg_valid_i), .req_ready_o(msg_ready_o),
        .req_length_i(msg_length_i), .req_tag_i(msg_tag_i),
        .byte_valid_i(byte_valid_i), .byte_ready_o(byte_ready_o), .byte_i(byte_i),
        .rsp_valid_o(msg_rsp_valid_o), .rsp_ready_i(msg_rsp_ready_i), .rsp_digest_o(msg_digest_o),
        .rsp_tag_o(msg_rsp_tag_o), .rsp_error_o(msg_error_o)
    );
    // Observe actual handshakes and payloads independently of diagnostic pulses.
    assign observed_req_valid_o = message.core.req_valid_i;
    assign observed_req_ready_o = message.core.req_ready_o;
    assign observed_block_o = message.core.req_block_i;
    assign observed_state_o = message.core.req_state_i;
    assign observed_rsp_valid_o = message.core.rsp_valid_o;
    assign observed_rsp_ready_o = message.core.rsp_ready_i;
    assign observed_result_o = message.core.rsp_state_o;
endmodule
`default_nettype wire
