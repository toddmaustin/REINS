// Copyright (c) 2026 Todd Austin.
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// License: https://polyformproject.org/licenses/noncommercial/1.0.0/

// Protected transaction adapter: audits bytes, exact real compression counts,
// completion identity and a separate digest hand-off around the real SHA backend.
`default_nettype none
// MAX_BYTES bounds a body; OFFSET_BITS must represent every admitted offset.
// SLH components keeps defaults; SLH verifier uses 8500/14 for official algorithm messages.
module slh_hash_transaction #(parameter int MAX_BYTES=582, OFFSET_BITS=10) (
    input logic clk_i, rst_ni, cancel_i,       // Trusted synchronous reset; cancellation wins over completion.
    input logic req_valid_i,                 // Capture one stable hash descriptor on valid/ready.
    output logic req_ready_o,
    input logic [1:0] mode_i,                  // See slh_sha256_stream; caller keeps descriptor stable until ready.
    input logic [31:0] length_i, tag_i,
    input logic [255:0] prefix_state_i,        // Protected fresh public-seed state, mode 1 only.
    output logic [OFFSET_BITS-1:0] byte_offset_o,
    input logic [7:0] byte_i, audit_byte_i,     // Independently constructed primary/audit bytes at byte_offset_o.
    output logic rsp_valid_o,                 // Digest/error retained until acknowledgment or cancellation.
    input logic rsp_ready_i,
    output logic [255:0] digest_o,
    output logic [1:0] error_o,
    output logic fault_o,                     // Sticky local integrity alarm, preserved by cancellation.
    output logic start_o, complete_o,          // Direct physical core events, separately counted below.
    output logic [7:0] starts_o, completions_o
);
    localparam logic [7:0] IDLE=8'h0f,START=8'h33,BYTES=8'h55,WAIT_HASH=8'h69,COMMIT=8'h96,RESULT=8'haa;
    logic [7:0] state_q, state_inv_q, starts_q, ends_q, starts_inv_q, ends_inv_q;
    logic [OFFSET_BITS-1:0] offset_q, offset_inv_q;
    logic [31:0] length_q, tag_q, length_inv_q, tag_inv_q;
    logic [1:0] mode_q, mode_inv_q;
    logic [255:0] prefix_inv_q;
    logic [255:0] prefix_q, capture_q, capture_inv_q, hash_digest;
    logic [31:0] hash_tag;
    logic [1:0] hash_error;
    logic hash_ready, byte_ready, hash_valid, failed_q, bad, active;
    logic [7:0] expected;
    assign active=state_q!=IDLE && state_q!=RESULT;
    assign expected=mode_q==2 ? 8'd1 : 8'((length_q+32'd72)>>6);
    assign bad=state_q!=~state_inv_q || length_q!=~length_inv_q || tag_q!=~tag_inv_q || mode_q!=~mode_inv_q || prefix_q!=~prefix_inv_q || offset_q!=~offset_inv_q || starts_q!=~starts_inv_q || ends_q!=~ends_inv_q ||
        capture_q!=~capture_inv_q || !(state_q==IDLE || state_q==START || state_q==BYTES || state_q==WAIT_HASH || state_q==COMMIT || state_q==RESULT) ||
        (state_q==BYTES && (byte_i!=audit_byte_i || offset_q>OFFSET_BITS'(length_q))) ||
        (active && (starts_q>expected || ends_q>starts_q));
    assign fault_o=rst_ni && (failed_q || bad);
    assign req_ready_o=rst_ni && !cancel_i && state_q==IDLE && !fault_o;
    assign rsp_valid_o=rst_ni && !cancel_i && state_q==RESULT && !bad;
    assign digest_o=rsp_valid_o && error_o==0 ? capture_q : 256'd0;
    assign byte_offset_o=offset_q;
    assign starts_o=starts_q; assign completions_o=ends_q;
    slh_sha256_stream #(.MAX_BYTES(MAX_BYTES)) backend (
        .clk_i(clk_i),.rst_ni(rst_ni && active && !failed_q),.cancel_i(cancel_i),
        .req_valid_i(state_q==START),.req_ready_o(hash_ready),.req_mode_i(mode_q),
        .req_length_i(length_q),.req_tag_i(tag_q),.req_state_i(prefix_q),
        .byte_valid_i(state_q==BYTES),.byte_ready_o(byte_ready),.byte_i(byte_i),
        .rsp_valid_o(hash_valid),.rsp_ready_i(state_q==COMMIT),.rsp_digest_o(hash_digest),
        .rsp_tag_o(hash_tag),.rsp_error_o(hash_error),.compression_start_o(start_o),.compression_complete_o(complete_o)
    );
    // Clear transaction scratch; sticky failure is owned by trusted reset, not cancel; no parameters.
    task automatic erase();
        state_q<=IDLE; state_inv_q<=~IDLE; starts_q<=0; ends_q<=0; starts_inv_q<='1; ends_inv_q<='1;
        offset_q<=0; offset_inv_q<='1; capture_q<=0; capture_inv_q<='1; length_q<=0; tag_q<=0; mode_q<=0; prefix_q<=0; length_inv_q<='1; tag_inv_q<='1; mode_inv_q<='1; prefix_inv_q<='1;
    endtask
    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin erase(); failed_q<=0; error_o<=0; end
        else if (cancel_i) begin erase(); error_o<=0; end
        else if (bad) begin erase(); state_q<=RESULT; state_inv_q<=~RESULT; failed_q<=1; error_o<=3; end
        else begin
            if (active && start_o) begin starts_q<=starts_q+1; starts_inv_q<=starts_inv_q-1; end
            if (active && complete_o) begin ends_q<=ends_q+1; ends_inv_q<=ends_inv_q-1; end
            case (state_q)
            IDLE: if (req_valid_i && req_ready_o) begin
                erase(); state_q<=START; state_inv_q<=~START; length_q<=length_i; tag_q<=tag_i;
                mode_q<=mode_i; prefix_q<=prefix_state_i; length_inv_q<=~length_i; tag_inv_q<=~tag_i; mode_inv_q<=~mode_i; prefix_inv_q<=~prefix_state_i; error_o<=0;
            end
            START: if (hash_ready) begin
                state_q<=length_q==0 ? WAIT_HASH : BYTES; state_inv_q<=~(length_q==0 ? WAIT_HASH : BYTES);
                if (mode_q>2 || length_q>32'(MAX_BYTES) || (mode_q==2 && length_q!=64)) begin error_o<=1; state_q<=RESULT; state_inv_q<=~RESULT; end
            end
            BYTES: if (byte_ready) begin
                offset_q<=offset_q+1; offset_inv_q<=offset_inv_q-1;
                if (offset_q+1==OFFSET_BITS'(length_q)) begin state_q<=WAIT_HASH; state_inv_q<=~WAIT_HASH; end
            end
            WAIT_HASH: if (hash_valid) begin capture_q<=hash_digest; capture_inv_q<=~hash_digest; state_q<=COMMIT; state_inv_q<=~COMMIT; end
            COMMIT: begin
                state_q<=RESULT; state_inv_q<=~RESULT;
                if (!hash_valid || hash_error!=0 || hash_tag!=tag_q || hash_digest!=capture_q || starts_q!=expected || ends_q!=expected) begin
                    capture_q<=0; capture_inv_q<='1; error_o<=3; failed_q<=1;
                end
            end
            RESULT: if (rsp_ready_i) begin erase(); error_o<=0; end
            default: begin erase(); failed_q<=1; error_o<=3; state_q<=RESULT; state_inv_q<=~RESULT; end
            endcase
        end
    end
endmodule
`default_nettype wire
