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
    output logic [63:0] lease_o, period_o, window_o, // Big-endian decoded L/P/W; use only when valid.
    output logic integrity_fault_o             // Immediate/sticky internal corruption, separate from invalid OTP fields.
);
    typedef enum logic [7:0] {IDLE=8'h0f, READ_IMAGE=8'h33, READ_AUDIT=8'hcc, CHECK_IMAGE=8'h55,
        HASH_REQUEST=8'h69, HASH_BYTES=8'h96, HASH_RESULT=8'haa, HASH_AUDIT=8'hf0} phase_t;
    phase_t phase_q;                           // Validation owns the macro until completion.
    (* keep="true", dont_touch="true" *) logic [7:0] phase_inverse_q;
    logic [7:0] inverse_next;                 // Independent inverse-state transition decode.
    (* keep="true", dont_touch="true" *) logic [2175:0] image_inverse_q;
    logic [8:0] index_inverse_q;              // Down-counted encoding of the primary byte cursor.
    logic control_bad, failed_q, valid_q;     // Immediate integrity denial / reset-local sticky fault.
    logic [255:0] digest_inverse_q;          // Captured on a later clock from the held SHA response.
    logic [8:0] index_q;                       // Read/hash byte cursor, bounded to 0..271.
    logic fields_valid, audit_fields_valid;    // Independently decoded schema/distinctness predicates.
    (* keep="true", dont_touch="true" *) logic valid_inverse_q;
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
    assign control_bad=phase_q!=~phase_inverse_q || index_q!=~index_inverse_q || valid_q==valid_inverse_q ||
        !(phase_q==IDLE || phase_q==READ_IMAGE || phase_q==READ_AUDIT || phase_q==CHECK_IMAGE ||
          phase_q==HASH_REQUEST || phase_q==HASH_BYTES || phase_q==HASH_RESULT || phase_q==HASH_AUDIT) ||
        ((phase_q==CHECK_IMAGE || phase_q==HASH_REQUEST || phase_q==HASH_BYTES || phase_q==HASH_RESULT || phase_q==HASH_AUDIT || valid_q) && image_o!=~image_inverse_q) ||
        (valid_q && digest_o!=~digest_inverse_q) ||
        (phase_q==CHECK_IMAGE && fields_valid!=audit_fields_valid);
    assign integrity_fault_o=rst_ni && (control_bad || failed_q);
    assign valid_o=valid_q && !valid_inverse_q && audit_fields_valid && !control_bad && !failed_q;
    assign busy_o=phase_q!=IDLE || control_bad || failed_q;
    assign write_accepted_o=rst_ni && write_i && !busy_o && !check_i && !close_i &&
        physical_enable_i && stopped_i && macro_integrity_i && macro_lifecycle_i==2'b00 && write_address_i<272;
    assign macro_write_o=write_accepted_o;
    assign macro_close_o=rst_ni && close_i && !write_i && !check_i && !busy_o && valid_o &&
        physical_enable_i && stopped_i && macro_complete_i && macro_integrity_i && macro_lifecycle_i==2'b00;
    assign macro_address_o=(phase_q==READ_IMAGE || phase_q==READ_AUDIT) ? index_q : write_address_i;
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
    // Audit the encoded image directly: no primary byte decoder, timing outputs
    // or fields_valid enable is reused in the complementary sequencer.
    always_comb begin
        audit_fields_valid=image_inverse_q[2175 -: 96]==~96'h524e4f500002020203020000 &&
            image_inverse_q[2079 -: 32]==~32'd1 &&
            64'(~image_inverse_q[1663 -: 64])!=0 &&
            64'(~image_inverse_q[1663 -: 64])<=64'(~image_inverse_q[1727 -: 64]) &&
            64'(~image_inverse_q[1727 -: 64])<64'(~image_inverse_q[1791 -: 64]) &&
            32'(~image_inverse_q[1567 -: 32])!=0 &&
            32'(~image_inverse_q[1567 -: 32])<=32'(~image_inverse_q[1599 -: 32]) &&
            32'(~image_inverse_q[1535 -: 32])!=0 && 32'(~image_inverse_q[1535 -: 32])<=32'd1000 &&
            32'(~image_inverse_q[1503 -: 32])!=0 && 32'(~image_inverse_q[1503 -: 32])<=32'd2000 &&
            image_inverse_q[1471 -: 32]==~32'd1 && image_inverse_q[1439 -: 288]=={288{1'b1}};
        for (int slot=2;slot>=0;slot--) for (int other=2;other>slot;other--) begin
            if (!(|(image_inverse_q[2175-8*(128+48*slot) -: 128] ^ image_inverse_q[2175-8*(128+48*other) -: 128]))) audit_fields_valid=0;
            if (!(|(image_inverse_q[2175-8*(144+48*slot) -: 256] ^ image_inverse_q[2175-8*(144+48*other) -: 256]))) audit_fields_valid=0;
        end
    end
    // Dedicated configuration SHA: no arbitration or verification-pass sharing.
    logic unused_compression_start, unused_compression_complete; // Passive core events unused by this client.
    sha256_message #(.MAX_MESSAGE_BYTES(272)) hasher (
        .clk_i(clk_i), .rst_ni(rst_ni && macro_integrity_i),
        .req_valid_i(phase_q==HASH_REQUEST), .req_ready_o(sha_req_ready),
        .req_length_i(32'd272), .req_tag_i(32'h43464731),
        .byte_valid_i(phase_q==HASH_BYTES), .byte_ready_o(sha_byte_ready),
        .byte_i(octet({23'b0,index_q})), .rsp_valid_o(sha_rsp_valid),
        .rsp_ready_i(phase_q==HASH_AUDIT), .rsp_digest_o(sha_digest),
        .rsp_tag_o(sha_tag), .rsp_error_o(sha_error),
        .compression_start_o(unused_compression_start), .compression_complete_o(unused_compression_complete)
    );
    // The audit read holds the same physical address across a different clock edge.
    // A primary cursor/capture fault cannot silently load both image rails.
    always_comb begin
        inverse_next=phase_inverse_q;
        case (phase_inverse_q)
        ~IDLE: if (check_i && macro_complete_i) inverse_next=~READ_IMAGE;
        ~READ_IMAGE: inverse_next=~READ_AUDIT;
        ~READ_AUDIT: inverse_next=index_inverse_q==~9'd271 ? ~CHECK_IMAGE : ~READ_IMAGE;
        ~CHECK_IMAGE: inverse_next=audit_fields_valid ? ~HASH_REQUEST : ~IDLE;
        ~HASH_REQUEST: if (sha_req_ready) inverse_next=~HASH_BYTES;
        ~HASH_BYTES: if (sha_byte_ready && index_inverse_q==~9'd271) inverse_next=~HASH_RESULT;
        ~HASH_RESULT: if (sha_rsp_valid) inverse_next=(sha_error!=0 || sha_tag!=32'h43464731) ? ~IDLE : ~HASH_AUDIT;
        ~HASH_AUDIT: inverse_next=~IDLE;
        default: inverse_next=~IDLE;
        endcase
    end
    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin phase_inverse_q<=~IDLE; index_inverse_q<='1; image_inverse_q<='1; digest_inverse_q<='1; valid_inverse_q<=1; failed_q<=0; end
        else if (control_bad || failed_q) begin phase_inverse_q<=~IDLE; valid_inverse_q<=1; failed_q<=1; end
        else if ((phase_inverse_q==~HASH_RESULT && sha_rsp_valid && (sha_error!=0 || sha_tag!=32'h43464731)) ||
            (phase_inverse_q==~HASH_AUDIT && (!sha_rsp_valid || sha_error!=0 || sha_tag!=32'h43464731 || digest_o!=sha_digest))) begin
            phase_inverse_q<=~IDLE; valid_inverse_q<=1; failed_q<=1;
        end
        else if (!macro_integrity_i || (macro_lifecycle_i!=0 && macro_lifecycle_i!=3)) begin phase_inverse_q<=~IDLE; valid_inverse_q<=1; end
        else if (macro_write_o) valid_inverse_q<=1;
        else if (!macro_write_o) begin
            phase_inverse_q<=inverse_next;
            if (phase_inverse_q==~IDLE && check_i) begin index_inverse_q<='1; valid_inverse_q<=1; end
            if (phase_inverse_q==~READ_AUDIT) begin
                image_inverse_q[2175-8*int'(9'(~index_inverse_q)) -: 8]<=~macro_read_data_i;
                if (index_inverse_q!=~9'd271) index_inverse_q<=index_inverse_q-9'd1;
            end
            if (phase_inverse_q==~CHECK_IMAGE && audit_fields_valid) index_inverse_q<='1;
            if (phase_inverse_q==~HASH_BYTES && sha_byte_ready && index_inverse_q!=~9'd271) index_inverse_q<=index_inverse_q-9'd1;
            if (phase_inverse_q==~HASH_AUDIT) begin digest_inverse_q<=~sha_digest; valid_inverse_q<=!audit_fields_valid; end
        end
    end
    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
            phase_q<=IDLE; index_q<='0; image_o<='0; digest_o<='0;
            valid_q<=1'b0; done_o<=1'b0; error_o<='0;
        end else begin
            done_o<=1'b0;
            if (control_bad || failed_q) begin
                valid_q<=0; digest_o<=0; phase_q<=IDLE; error_o<=3; done_o<=1;
            end else if (!macro_integrity_i || (macro_lifecycle_i!=0 && macro_lifecycle_i!=3)) begin
                valid_q<=1'b0; digest_o<='0; phase_q<=IDLE; error_o<=3'd4;
                if (busy_o || check_i) done_o<=1'b1;
            end else if (macro_write_o) begin valid_q<=1'b0; digest_o<='0; end
            else case (phase_q)
                IDLE: if (check_i) begin
                    valid_q<=1'b0; digest_o<='0; index_q<='0; error_o<='0;
                    if (!macro_complete_i) begin done_o<=1'b1; error_o<=3'd1; end
                    else phase_q<=READ_IMAGE;
                end
                READ_IMAGE: begin
                    image_o[2175-8*int'(index_q) -: 8]<=macro_read_data_i;
                    phase_q<=READ_AUDIT;
                end
                READ_AUDIT: begin
                    if (octet(32'(index_q))!=macro_read_data_i) begin valid_q<=0; digest_o<=0; error_o<=4; phase_q<=IDLE; end
                    else if (index_q==271) phase_q<=CHECK_IMAGE;
                    else begin index_q<=index_q+9'd1; phase_q<=READ_IMAGE; end
                end
                CHECK_IMAGE: if (!fields_valid) begin done_o<=1'b1; error_o<=3'd2; phase_q<=IDLE; end
                    else begin index_q<='0; phase_q<=HASH_REQUEST; end
                HASH_REQUEST: if (sha_req_ready) phase_q<=HASH_BYTES;
                HASH_BYTES: if (sha_byte_ready) begin
                    if (index_q==271) phase_q<=HASH_RESULT;
                    else index_q<=index_q+9'd1;
                end
                HASH_RESULT: if (sha_rsp_valid) begin
                    phase_q<=IDLE;
                    if (sha_error!=0 || sha_tag!=32'h43464731) begin done_o<=1; error_o<=3'd3; valid_q<=1'b0; end
                    else begin digest_o<=sha_digest; phase_q<=HASH_AUDIT; end
                end
                HASH_AUDIT: begin
                    done_o<=1; phase_q<=IDLE;
                    if (!sha_rsp_valid || sha_error!=0 || sha_tag!=32'h43464731 || digest_o!=sha_digest) begin valid_q<=0; error_o<=3; end
                    else valid_q<=1;
                end
                default: begin phase_q<=IDLE; valid_q<=1'b0; done_o<=1'b1; error_o<=3'd3; end
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
