// Fixed N=3/Q=2 public OTP validation and C_cfg hashing, v0.3 section 5.
// OTP retention/programming physics belong to the external technology macro.
`default_nettype none
module reins_config (
    input logic clk_i, rst_ni,                 // Always-on clock; volatile logic reset only.
    input logic physical_enable_i, stopped_i,  // Trusted commissioning/physical stop interlocks.
    input logic write_i,                       // One public byte programming attempt.
    input logic [8:0] write_address_i,          // Only byte offsets 0..271 are admitted.
    input logic [7:0] write_data_i,             // Public data sent to the OTP wrapper.
    output logic write_accepted_o,             // Actual admitted macro write, not a queued request.
    input logic check_i,                       // Start a complete image check (also used on startup).
    input logic close_i,                       // COMMIT_CLOSE attempt; never a runtime SPI command here.
    output logic macro_write_o, macro_close_o, // Requests to an irreversible technology wrapper.
    output logic [8:0] macro_address_o,        // Combinational read address / admitted write address.
    output logic [7:0] macro_write_data_o,      // Write payload; meaningful only on macro_write_o.
    input logic [7:0] macro_read_data_i,        // Sensed byte at macro_address_o.
    input logic [1:0] macro_lifecycle_i,        // 00 open, 11 closed, 01/10 permanently invalid.
    input logic macro_complete_i,              // All logical bytes sensed/programmed, supplied by wrapper.
    input logic macro_integrity_i,             // Technology ECC/sensing/lock health; not a host assertion.
    output logic busy_o, done_o, valid_o,      // Check status; valid only after complete SHA success.
    output logic [2:0] error_o,                // 0 OK, 1 incomplete, 2 schema, 3 hash, 4 macro health.
    output logic [2175:0] image_o,              // Immutable checked snapshot; byte 0 is bits 2175:2168.
    output logic [255:0] digest_o,             // SHA-256 over exactly the 272 sensed logical bytes.
    output logic [63:0] lease_o, period_o, window_o // Big-endian decoded L/P/W; use only when valid.
);
    typedef enum logic [2:0] {IDLE, READ_IMAGE, CHECK_IMAGE, HASH_REQUEST, HASH_BYTES, HASH_RESULT} phase_t;
    phase_t phase_q;                           // Validation owns the macro until completion.
    logic [8:0] index_q;                       // Read/hash byte cursor, bounded to 0..271.
    logic fields_valid;                        // All fixed-profile field/distinctness predicates.
    logic sha_req_ready, sha_byte_ready, sha_rsp_valid;
    logic [255:0] sha_digest;
    logic [31:0] sha_tag;
    logic [1:0] sha_error;

    // Read address's byte from the captured logical image in wire order.
    function automatic logic [7:0] octet(input int unsigned address);
        return image_o[2175-8*address -: 8];
    endfunction
    // Decode eight bytes beginning at address as an unsigned big-endian value.
    function automatic logic [63:0] be64(input int unsigned address);
        logic [63:0] value;
        value='0;
        for (int i=0;i<8;i++) value={value[55:0],octet(address+32'(i))};
        return value;
    endfunction
    // Decode four bytes beginning at address as an unsigned big-endian value.
    function automatic logic [31:0] be32(input int unsigned address);
        return {octet(address),octet(address+1),octet(address+2),octet(address+3)};
    endfunction
    assign lease_o=be64(48); assign period_o=be64(56); assign window_o=be64(64);
    assign busy_o=phase_q!=IDLE;
    assign write_accepted_o=rst_ni && write_i && !busy_o && !check_i && !close_i &&
        physical_enable_i && stopped_i && macro_integrity_i && macro_lifecycle_i==2'b00 && write_address_i<272;
    assign macro_write_o=write_accepted_o;
    assign macro_close_o=rst_ni && close_i && !write_i && !check_i && !busy_o && valid_o &&
        physical_enable_i && stopped_i && macro_complete_i && macro_integrity_i && macro_lifecycle_i==2'b00;
    assign macro_address_o=phase_q==READ_IMAGE ? index_q : write_address_i;
    assign macro_write_data_o=write_data_i;

    always_comb begin
        fields_valid=image_o[2175 -: 96]==96'h524e4f500002020203020000 && be32(12)==1 &&
            window_o>0 && window_o<=period_o && period_o<lease_o &&
            be32(76)>0 && be32(76)<=be32(72) && be32(80)>0 && be32(80)<=1000 &&
            be32(84)>0 && be32(84)<=2000 && be32(88)==1;
        for (int i=92;i<128;i++) if (octet(32'(i))!=0) fields_valid=1'b0;
        for (int slot=0;slot<3;slot++) begin
            for (int other=0;other<slot;other++) begin
                if (image_o[2175-8*(128+48*slot) -: 128]==image_o[2175-8*(128+48*other) -: 128]) fields_valid=1'b0;
                if (image_o[2175-8*(144+48*slot) -: 256]==image_o[2175-8*(144+48*other) -: 256]) fields_valid=1'b0;
            end
        end
    end
    // Dedicated configuration SHA: no arbitration or verification-pass sharing.
    sha256_message #(.MAX_MESSAGE_BYTES(272)) hasher (
        .clk_i(clk_i), .rst_ni(rst_ni && macro_integrity_i),
        .req_valid_i(phase_q==HASH_REQUEST), .req_ready_o(sha_req_ready),
        .req_length_i(32'd272), .req_tag_i(32'h43464731),
        .byte_valid_i(phase_q==HASH_BYTES), .byte_ready_o(sha_byte_ready),
        .byte_i(octet({23'b0,index_q})), .rsp_valid_o(sha_rsp_valid),
        .rsp_ready_i(phase_q==HASH_RESULT), .rsp_digest_o(sha_digest),
        .rsp_tag_o(sha_tag), .rsp_error_o(sha_error)
    );
    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
            phase_q<=IDLE; index_q<='0; image_o<='0; digest_o<='0;
            valid_o<=1'b0; done_o<=1'b0; error_o<='0;
        end else begin
            done_o<=1'b0;
            if (!macro_integrity_i || (macro_lifecycle_i!=0 && macro_lifecycle_i!=3)) begin
                valid_o<=1'b0; digest_o<='0; phase_q<=IDLE; error_o<=3'd4;
                if (busy_o || check_i) done_o<=1'b1;
            end else if (macro_write_o) begin valid_o<=1'b0; digest_o<='0; end
            else case (phase_q)
                IDLE: if (check_i) begin
                    valid_o<=1'b0; digest_o<='0; index_q<='0; error_o<='0;
                    if (!macro_complete_i) begin done_o<=1'b1; error_o<=3'd1; end
                    else phase_q<=READ_IMAGE;
                end
                READ_IMAGE: begin
                    image_o[2175-8*int'(index_q) -: 8]<=macro_read_data_i;
                    if (index_q==271) phase_q<=CHECK_IMAGE;
                    else index_q<=index_q+9'd1;
                end
                CHECK_IMAGE: if (!fields_valid) begin done_o<=1'b1; error_o<=3'd2; phase_q<=IDLE; end
                    else begin index_q<='0; phase_q<=HASH_REQUEST; end
                HASH_REQUEST: if (sha_req_ready) phase_q<=HASH_BYTES;
                HASH_BYTES: if (sha_byte_ready) begin
                    if (index_q==271) phase_q<=HASH_RESULT;
                    else index_q<=index_q+9'd1;
                end
                HASH_RESULT: if (sha_rsp_valid) begin
                    done_o<=1'b1; phase_q<=IDLE;
                    if (sha_error!=0 || sha_tag!=32'h43464731) begin error_o<=3'd3; valid_o<=1'b0; end
                    else begin digest_o<=sha_digest; valid_o<=1'b1; end
                end
                default: begin phase_q<=IDLE; valid_o<=1'b0; done_o<=1'b1; error_o<=3'd3; end
            endcase
        end
    end
`ifndef SYNTHESIS
    assert property (@(posedge clk_i) disable iff (!rst_ni)
        macro_write_o |-> macro_lifecycle_i==0 && physical_enable_i && stopped_i && !busy_o);
    assert property (@(posedge clk_i) disable iff (!rst_ni)
        macro_close_o |-> valid_o && macro_complete_i && physical_enable_i && stopped_i);
`endif
endmodule
`default_nettype wire
