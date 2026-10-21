// Bounded byte-stream SHA-256 framing and padding around sha256_compress.
// Capture length/tag first, then exactly length bytes (MSB-first on the block).
// Padding and chaining are RTL operations; the host supplies no padded blocks.
`default_nettype none
module sha256_message #(
    parameter int unsigned MAX_MESSAGE_BYTES = 9216, // Per-transaction resource bound.
    parameter int unsigned MAX_INPUT_STALL = 1024    // Consecutive missing-byte clocks.
) (
    input  logic         clk_i,        // Rising-edge ready/valid transfers.
    input  logic         rst_ni,       // Synchronous active-low cancellation/reset.
    input  logic         req_valid_i,  // Request length/tag, held until ready.
    output logic         req_ready_o,  // Idle and able to capture a new message.
    input  logic [31:0]  req_length_i, // Byte count; zero hashes the empty message.
    input  logic [31:0]  req_tag_i,    // Opaque identity returned even on errors.
    input  logic         byte_valid_i, // Byte transfer only on valid && ready.
    output logic         byte_ready_o, // Never requests bytes during compression/padding.
    input  logic [7:0]   byte_i,       // Next message byte, in transmission order.
    output logic         rsp_valid_o,  // Held until acknowledged, including error responses.
    input  logic         rsp_ready_i,  // Consumer accepts the response on valid && ready.
    output logic [255:0] rsp_digest_o, // SHA-256 digest, or zero when rsp_error_o != 0.
    output logic [31:0]  rsp_tag_o,    // Captured request identity.
    output logic [1:0]   rsp_error_o   // 0=success, 1=length, 2=input stall, 3=control.
);
    localparam logic [255:0] IV = 256'h6a09e667bb67ae853c6ef372a54ff53a510e527f9b05688c1f83d9ab5be0cd19;
    typedef enum logic [2:0] {IDLE, LOAD, PAD, SUBMIT, WAIT_RESULT, REPLY} state_t;
    state_t state_q;                   // Functional sequencing only; R03 protection deferred.
    logic [511:0] block_q;             // Current partial data block, initially zero-filled.
    logic [255:0] chain_q;             // Chaining state, initialized to the SHA-256 IV.
    logic [31:0] remaining_q;          // Bytes still to receive for the captured message.
    logic [63:0] bit_length_q;         // Captured 32-bit byte count times eight, without wrap.
    logic [5:0] position_q;            // Next byte offset within block_q, 0..63.
    logic [31:0] stall_q;              // Consecutive missing bytes only while LOAD is active.
    logic final_q, length_only_q;      // Final block marker / second padding block pending.
    // Internal block handshake is observed by the simulation top without fault ports.
    logic core_req_ready, core_rsp_valid;
    logic [255:0] core_result;
    logic [31:0] unused_core_tag;     // Identity is already held in the outer request.
    logic unused_core_start, unused_core_done; // Optional diagnostics, not control inputs.

    assign req_ready_o = rst_ni && state_q==IDLE;
    assign byte_ready_o = rst_ni && state_q==LOAD;
    assign rsp_valid_o = rst_ni && state_q==REPLY;
    sha256_compress core (
        .clk_i(clk_i), .rst_ni(rst_ni), .req_valid_i(state_q==SUBMIT),
        .req_ready_o(core_req_ready), .req_state_i(chain_q), .req_block_i(block_q),
        .req_tag_i(rsp_tag_o), .rsp_valid_o(core_rsp_valid), .rsp_ready_i(state_q==WAIT_RESULT),
        .rsp_state_o(core_result), .rsp_tag_o(unused_core_tag),
        .start_o(unused_core_start), .complete_o(unused_core_done)
    );

    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
            state_q<=IDLE; block_q<='0; chain_q<=IV; remaining_q<='0;
            bit_length_q<='0; position_q<='0; stall_q<='0; final_q<=1'b0; length_only_q<=1'b0;
            rsp_digest_o<='0; rsp_tag_o<='0; rsp_error_o<='0;
        end else case (state_q)
            IDLE: if (req_valid_i && req_ready_o) begin
                rsp_tag_o<=req_tag_i; rsp_error_o<='0; rsp_digest_o<='0;
                block_q<='0; chain_q<=IV; remaining_q<=req_length_i;
                bit_length_q<={29'b0,req_length_i,3'b0}; position_q<='0; stall_q<='0;
                final_q<=1'b0; length_only_q<=1'b0;
                if (req_length_i>MAX_MESSAGE_BYTES) begin rsp_error_o<=2'd1; state_q<=REPLY; end
                else state_q<=req_length_i==0 ? PAD : LOAD;
            end
            LOAD: if (byte_valid_i && byte_ready_o) begin
                block_q[511-8*int'(position_q) -: 8]<=byte_i;
                remaining_q<=remaining_q-32'd1; position_q<=position_q+6'd1; stall_q<='0;
                if (position_q==6'd63) state_q<=SUBMIT;
                else if (remaining_q==1) state_q<=PAD;
            end else if (stall_q==MAX_INPUT_STALL-1) begin
                rsp_error_o<=2'd2; rsp_digest_o<='0; state_q<=REPLY;
            end else stall_q<=stall_q+32'd1;
            PAD: begin
                // A 0x80 marker fits in this block; the length may need another.
                if (!length_only_q) block_q[511-8*int'(position_q) -: 8]<=8'h80;
                if (length_only_q || position_q<=6'd55) begin
                    block_q[63:0]<=bit_length_q; final_q<=1'b1; length_only_q<=1'b0;
                end else begin final_q<=1'b0; length_only_q<=1'b1; end
                state_q<=SUBMIT;
            end
            SUBMIT: if (core_req_ready) state_q<=WAIT_RESULT;
            WAIT_RESULT: if (core_rsp_valid) begin
                chain_q<=core_result; block_q<='0; position_q<='0;
                if (final_q) begin rsp_digest_o<=core_result; state_q<=REPLY; end
                else state_q<=remaining_q!=0 ? LOAD : PAD;
            end
            REPLY: if (rsp_ready_i) state_q<=IDLE;
            default: begin rsp_error_o<=2'd3; rsp_digest_o<='0; state_q<=REPLY; end
        endcase
    end

`ifndef SYNTHESIS
    // Simulation checks are excluded from synthesis; this adds no protection hardware.
    // A stalled consumer retains the complete response, including failure identity.
    assert property (@(posedge clk_i) disable iff (!rst_ni)
        rsp_valid_o && !rsp_ready_i |=> rsp_valid_o && $stable({rsp_digest_o,rsp_tag_o,rsp_error_o}));
    assert property (@(posedge clk_i) disable iff (!rst_ni) byte_ready_o |-> remaining_q>0);
    initial begin
        assert (MAX_MESSAGE_BYTES>0) else $fatal(1,"MAX_MESSAGE_BYTES must be positive");
        assert (MAX_INPUT_STALL>0) else $fatal(1,"MAX_INPUT_STALL must be positive");
    end
`endif
endmodule
`default_nettype wire
