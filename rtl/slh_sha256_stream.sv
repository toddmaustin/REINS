// Copyright (c) 2026 Todd Austin.
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// License: https://polyformproject.org/licenses/noncommercial/1.0.0/

// Bounded real-SHA backend for FIPS 205. Mode 0 hashes from the standard IV;
// mode 1 continues after exactly one public-seed block; mode 2 compresses the
// raw 64-byte PK.seed||zero[48] block without adding padding. No software digest input.
`default_nettype none
module slh_sha256_stream #(
    parameter int unsigned MAX_BYTES=582,
    parameter int unsigned MAX_STALL=1024
) (
    input logic clk_i, rst_ni, cancel_i, // Synchronous trusted reset/cancellation; response withdrawal wins.
    input logic req_valid_i,
    output logic req_ready_o,
    input logic [1:0] req_mode_i,        // 0=SHA, 1=continue from protected seed state, 2=raw seed block.
    input logic [31:0] req_length_i, req_tag_i, // Exact body bytes and opaque completion provenance.
    input logic [255:0] req_state_i,     // Mode 1 only; caller owns prefix provenance and integrity.
    input logic byte_valid_i,
    output logic byte_ready_o,
    input logic [7:0] byte_i,
    output logic rsp_valid_o,
    input logic rsp_ready_i,
    output logic [255:0] rsp_digest_o,
    output logic [31:0] rsp_tag_o,
    output logic [1:0] rsp_error_o,      // 0=result, 1=shape, 2=byte stall, 3=control.
    output logic compression_start_o, compression_complete_o
);
    localparam logic [255:0] IV=256'h6a09e667bb67ae853c6ef372a54ff53a510e527f9b05688c1f83d9ab5be0cd19;
    typedef enum logic [7:0] {IDLE=8'h0f, LOAD=8'h33, PAD=8'h55, SUBMIT=8'h69, WAIT_RESULT=8'h96, REPLY=8'haa} state_t;
    state_t state_q;
    (* keep="true", dont_touch="true" *) logic [7:0] state_inverse_q;
    logic [7:0] inverse_next; // Separate complemented transition decode protects a corrupted primary next state.
    logic control_bad, failed_q; // Invalid/mismatched code; sticky cancellation-local failure.
    logic [511:0] block_q;
    logic [255:0] chain_q, core_digest;
    logic [31:0] remaining_q, stall_q, unused_core_tag;
    logic [63:0] bits_q;
    logic [5:0] position_q;
    logic final_q, length_only_q, raw_q, core_ready, core_valid;
    assign control_bad=state_q!=~state_inverse_q || !(state_q==IDLE || state_q==LOAD || state_q==PAD ||
        state_q==SUBMIT || state_q==WAIT_RESULT || state_q==REPLY);
    assign req_ready_o=rst_ni && !cancel_i && state_q==IDLE && !control_bad && !failed_q;
    assign byte_ready_o=rst_ni && !cancel_i && state_q==LOAD && !control_bad && !failed_q;
    assign rsp_valid_o=rst_ni && !cancel_i && state_q==REPLY && !control_bad;
    sha256_compress core (
        .clk_i(clk_i),.rst_ni(rst_ni && !cancel_i && !control_bad && !failed_q),.req_valid_i(state_q==SUBMIT && !control_bad && !failed_q),.req_ready_o(core_ready),
        .req_state_i(chain_q),.req_block_i(block_q),.req_tag_i(rsp_tag_o),.rsp_valid_o(core_valid),
        .rsp_ready_i(state_q==WAIT_RESULT),.rsp_state_o(core_digest),.rsp_tag_o(unused_core_tag),
        .start_o(compression_start_o),.complete_o(compression_complete_o)
    );
    // Derive the inverse transition directly from inverse state and source handshakes.
    always_comb begin
        inverse_next=state_inverse_q;
        case (state_inverse_q)
        ~IDLE: if (req_valid_i && req_ready_o) inverse_next=req_mode_i>2 || req_length_i>MAX_BYTES ||
            (req_mode_i==2 && req_length_i!=64) ? ~REPLY : req_length_i==0 ? ~PAD : ~LOAD;
        ~LOAD: if (byte_valid_i && byte_ready_o) begin
            if (position_q==63) inverse_next=~SUBMIT;
            else if (remaining_q==1) inverse_next=~PAD;
        end else if (stall_q>=MAX_STALL-1) inverse_next=~REPLY;
        ~PAD: inverse_next=~SUBMIT;
        ~SUBMIT: if (core_ready) inverse_next=~WAIT_RESULT;
        ~WAIT_RESULT: if (core_valid) inverse_next=final_q ? ~REPLY : remaining_q!=0 ? ~LOAD : ~PAD;
        ~REPLY: if (rsp_ready_i && !failed_q) inverse_next=~IDLE;
        default: inverse_next=~REPLY;
        endcase
    end
    always_ff @(posedge clk_i) begin
        if (!rst_ni || cancel_i) begin state_inverse_q<=~IDLE; failed_q<=0; end
        else if (control_bad || failed_q) begin state_inverse_q<=~REPLY; failed_q<=1; end
        else state_inverse_q<=inverse_next;
    end
    always_ff @(posedge clk_i) begin
        if (!rst_ni || cancel_i) begin
            state_q<=IDLE; block_q<=0; chain_q<=IV; remaining_q<=0; stall_q<=0; bits_q<=0;
            position_q<=0; final_q<=0; length_only_q<=0; raw_q<=0;
            rsp_digest_o<=0; rsp_tag_o<=0; rsp_error_o<=0;
        end else if (control_bad || failed_q) begin
            state_q<=REPLY; rsp_error_o<=3; rsp_digest_o<=0; block_q<=0; chain_q<=IV;
        end else case (state_q)
        IDLE: if (req_valid_i && req_ready_o) begin
            block_q<=0; chain_q<=req_mode_i==1 ? req_state_i : IV; remaining_q<=req_length_i;
            stall_q<=0; bits_q<=({32'd0,req_length_i}+(req_mode_i==1 ? 64'd64 : 64'd0))<<3;
            position_q<=0; final_q<=0; length_only_q<=0; raw_q<=req_mode_i==2;
            rsp_tag_o<=req_tag_i; rsp_digest_o<=0; rsp_error_o<=0;
            if (req_mode_i>2 || req_length_i>MAX_BYTES || (req_mode_i==2 && req_length_i!=64)) begin
                rsp_error_o<=1; state_q<=REPLY;
            end else state_q<=req_length_i==0 ? PAD : LOAD;
        end
        LOAD: if (byte_valid_i && byte_ready_o) begin
            block_q[511-8*int'(position_q) -: 8]<=byte_i; remaining_q<=remaining_q-1;
            position_q<=position_q+1; stall_q<=0;
            if (position_q==63) begin final_q<=raw_q; state_q<=SUBMIT; end
            else if (remaining_q==1) state_q<=PAD;
        end else if (stall_q>=MAX_STALL-1) begin rsp_error_o<=2; rsp_digest_o<=0; state_q<=REPLY; end
        else stall_q<=stall_q+1;
        PAD: begin
            if (!length_only_q) block_q[511-8*int'(position_q) -: 8]<=8'h80;
            if (length_only_q || position_q<=55) begin block_q[63:0]<=bits_q; final_q<=1; length_only_q<=0; end
            else begin final_q<=0; length_only_q<=1; end
            state_q<=SUBMIT;
        end
        SUBMIT: if (core_ready) state_q<=WAIT_RESULT;
        WAIT_RESULT: if (core_valid) begin
            chain_q<=core_digest; block_q<=0; position_q<=0;
            if (final_q) begin rsp_digest_o<=core_digest; state_q<=REPLY; end
            else state_q<=remaining_q!=0 ? LOAD : PAD;
        end
        REPLY: if (rsp_ready_i) begin state_q<=IDLE; block_q<=0; chain_q<=IV; rsp_digest_o<=0; end
        default: begin rsp_error_o<=3; rsp_digest_o<=0; state_q<=REPLY; end
        endcase
    end
`ifndef SYNTHESIS
    assert property (@(posedge clk_i) disable iff (!rst_ni || cancel_i)
        rsp_valid_o && !rsp_ready_i |=> rsp_valid_o && $stable({rsp_digest_o,rsp_tag_o,rsp_error_o}));
    initial begin assert(MAX_BYTES>=64); assert(MAX_STALL>0); end
`endif
endmodule
`default_nettype wire
