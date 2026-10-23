// FIPS 205 SHA2-128s H_msg, plus a separate bounded MGF1 component entry.
// H_msg is the REINS production gate: pure mode, empty context, 46-byte batch
// message. MGF1 entry is an algorithm component, never signature acceptance.
`default_nettype none
module slh_message_hash (
    input logic clk_i, rst_ni, cancel_i,       // Rising clock; synchronous active-low trusted reset; cancel withdraws held evidence.
    input logic req_valid_i,                 // Hold the descriptor until valid/ready capture.
    output logic req_ready_o,                // Only idle, healthy ownership can accept another request.
    input logic req_mgf_i,                    // 0=production H_msg, 1=standalone MGF1-SHA256.
    input logic [127:0] randomizer_i,         // Signature R[16], supplied only after bounded signature slicing.
    input logic [255:0] public_key_i,         // PK.seed[16] || expected PK.root[16], distinct from batch root.
    input logic [367:0] batch_message_i,      // Exactly ASCII REINS-BATCH-v2 || batch_root[32].
    input logic pure_i,
    input logic [7:0] context_length_i, profile_i, // H_msg requires empty context and profile 2.
    input logic [13:0] signature_length_i,    // H_msg requires exactly 7856 signature bytes.
    input logic [511:0] mgf_seed_i,           // Standalone MGF1 seed, exactly 64 bytes.
    input logic [6:0] mgf_length_i,           // Standalone requested mask bytes, 0..64.
    input logic [31:0] tag_i,                 // Caller provenance captured with all public inputs.
    output logic rsp_valid_o,                // Held candidate/error until consumed or canceled; never a vote.
    input logic rsp_ready_i,
    output logic [1:0] error_o,               // 0=candidate, 1=unsupported shape, 3=integrity.
    output logic fault_o,                    // Sticky integrity alarm; cancel cannot clear it.
    output logic [31:0] tag_o,
    output logic [383:0] pure_message_o,      // 00 || 00 || application message: FIPS pure/empty-context framing.
    output logic [255:0] inner_digest_o,
    output logic [511:0] mask_o,              // Requested mask bytes at MSB; unused bytes zero.
    output logic [167:0] fors_digest_o,
    output logic [53:0] tree_o,
    output logic [8:0] leaf_o,
    output logic [127:0] expected_pk_root_o,
    output logic [7:0] stage_o,               // 0=inner SHA, 1=MGF1 counters; passive observation.
    output logic start_o, complete_o,         // Actual physical compression events, not sequencer intent.
    output logic [15:0] starts_o, completions_o
);
    localparam logic [7:0] IDLE=8'h0f,CHECK=8'h33,START=8'h55,WAIT_HASH=8'h69,TAKE=8'h96,RESULT=8'haa;
    logic [7:0] state_q, inverse_q;
    logic mgf_q, phase_q, counter_q, phase_inv_q, counter_inv_q, failed_q, bad;
    logic [1334:0] metadata_inverse_q;
    logic [127:0] random_q;
    logic [255:0] key_q, inner_q, inner_inv_q, capture_q, capture_inv_q, digest;
    logic [367:0] message_q;
    logic [511:0] seed_q, mask_q, mask_inv_q;
    logic [6:0] length_q;
    logic pure_q;
    logic [7:0] context_q, profile_q;
    logic [13:0] signature_q;
    logic [31:0] tag_q;
    logic [15:0] starts_q, ends_q, starts_inv_q, ends_inv_q;
    logic ready, valid, hash_fault;
    logic [1:0] hash_error;
    logic [7:0] unused_hash_starts, unused_hash_ends;
    logic [9:0] offset;
    logic [767:0] frame;
    logic [7:0] byte_value, audit_value;
    logic [511:0] selected_seed;
    logic [31:0] counter_word;
    assign selected_seed=mgf_q ? seed_q : {random_q,key_q[255:128],inner_q};
    assign counter_word={31'd0,counter_q};
    assign frame=!phase_q ? {random_q,key_q,16'd0,message_q} : {selected_seed,counter_word,224'd0};
    assign byte_value=offset<96 ? frame[767-int'(offset)*8 -: 8] : 8'd0;
    // Independently construct byte at position from typed fields; do not reuse frame.
    function automatic logic [7:0] audit(input int position);
        if (!phase_q) begin
            if (position<16) return random_q[127-position*8 -: 8];
            if (position<48) return key_q[255-(position-16)*8 -: 8];
            if (position<50) return 0;
            if (position<96) return message_q[367-(position-50)*8 -: 8];
        end else if (position<64) begin
            if (mgf_q) return seed_q[511-position*8 -: 8];
            if (position<16) return random_q[127-position*8 -: 8];
            if (position<32) return key_q[255-(position-16)*8 -: 8];
            return inner_q[255-(position-32)*8 -: 8];
        end else if (position<68) return 8'(counter_word>>(8*(67-position)));
        return 0;
    endfunction
    assign audit_value=audit(int'(offset));
    assign bad=state_q!=~inverse_q || phase_q!=~phase_inv_q || counter_q!=~counter_inv_q || (counter_q && length_q<=32) ||
        {mgf_q,random_q,key_q,message_q,seed_q,length_q,pure_q,context_q,profile_q,signature_q,tag_q}!=~metadata_inverse_q || inner_q!=~inner_inv_q || mask_q!=~mask_inv_q || capture_q!=~capture_inv_q ||
        starts_q!=~starts_inv_q || ends_q!=~ends_inv_q ||
        !(state_q==IDLE || state_q==CHECK || state_q==START || state_q==WAIT_HASH || state_q==TAKE || state_q==RESULT) ||
        (state_q==RESULT && error_o==0 && (starts_q!=(mgf_q ? (length_q==0 ? 16'd0 : length_q<=32 ? 16'd2 : 16'd4) : 16'd4) || ends_q!=starts_q));
    assign fault_o=rst_ni && (failed_q || bad || hash_fault);
    assign req_ready_o=rst_ni && !cancel_i && state_q==IDLE && !fault_o;
    assign rsp_valid_o=rst_ni && !cancel_i && state_q==RESULT && !bad && (error_o!=0 || !fault_o);
    assign mask_o=rsp_valid_o && error_o==0 ? mask_q : 512'd0;
    assign inner_digest_o=rsp_valid_o && error_o==0 ? inner_q : 256'd0;
    assign pure_message_o=rsp_valid_o && error_o==0 && !mgf_q ? {16'd0,message_q} : 384'd0;
    assign expected_pk_root_o=rsp_valid_o && error_o==0 && !mgf_q ? key_q[127:0] : 128'd0;
    assign fors_digest_o=mask_o[511:344]; assign tree_o=mask_o[341:288]; assign leaf_o=mask_o[280:272];
    assign tag_o=tag_q; assign stage_o={7'd0,phase_q}; assign starts_o=starts_q; assign completions_o=ends_q;
    slh_hash_transaction hash (
        .clk_i(clk_i),.rst_ni(rst_ni),.cancel_i(cancel_i || state_q==IDLE || state_q==RESULT),
        .req_valid_i(state_q==START),.req_ready_o(ready),.mode_i(2'd0),.length_i(phase_q ? 32'd68 : 32'd96),
        .tag_i({16'h10a1,14'd0,phase_q,counter_q}),.prefix_state_i(256'd0),
        .byte_offset_o(offset),.byte_i(byte_value),.audit_byte_i(audit_value),.rsp_valid_o(valid),.rsp_ready_i(state_q==TAKE),
        .digest_o(digest),.error_o(hash_error),.fault_o(hash_fault),.start_o(start_o),.complete_o(complete_o),
        .starts_o(unused_hash_starts),.completions_o(unused_hash_ends)
    );
    // Erase captured inputs and intermediates on reset/cancel/consumption; no parameters.
    task automatic erase();
        state_q<=IDLE; inverse_q<=~IDLE; mgf_q<=0; phase_q<=0; counter_q<=0; phase_inv_q<=1; counter_inv_q<=1; metadata_inverse_q<='1;
        random_q<=0; key_q<=0; inner_q<=0; inner_inv_q<='1; message_q<=0; seed_q<=0;
        mask_q<=0; mask_inv_q<='1; capture_q<=0; capture_inv_q<='1;
        length_q<=0; pure_q<=0; context_q<=0; profile_q<=0; signature_q<=0; tag_q<=0;
        starts_q<=0; ends_q<=0; starts_inv_q<='1; ends_inv_q<='1;
    endtask
    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin erase(); failed_q<=0; error_o<=0; end
        else if (cancel_i) begin erase(); error_o<=0; end
        else if (bad || hash_fault) begin erase(); state_q<=RESULT; inverse_q<=~RESULT; failed_q<=1; error_o<=3; end
        else begin
            if (start_o) begin starts_q<=starts_q+1; starts_inv_q<=starts_inv_q-1; end
            if (complete_o) begin ends_q<=ends_q+1; ends_inv_q<=ends_inv_q-1; end
            case (state_q)
            IDLE: if (req_valid_i && req_ready_o) begin
                erase(); state_q<=CHECK; inverse_q<=~CHECK; mgf_q<=req_mgf_i; phase_q<=req_mgf_i; phase_inv_q<=~req_mgf_i;
                metadata_inverse_q<=~{req_mgf_i,randomizer_i,public_key_i,batch_message_i,mgf_seed_i,(req_mgf_i ? mgf_length_i : 7'd30),pure_i,context_length_i,profile_i,signature_length_i,tag_i};
                random_q<=randomizer_i; key_q<=public_key_i; message_q<=batch_message_i;
                seed_q<=mgf_seed_i; length_q<=req_mgf_i ? mgf_length_i : 7'd30;
                pure_q<=pure_i; context_q<=context_length_i; profile_q<=profile_i; signature_q<=signature_length_i; tag_q<=tag_i; error_o<=0;
            end
            CHECK: begin
                if ((mgf_q && length_q>64) || (!mgf_q && (!pure_q || context_q!=0 || profile_q!=2 || signature_q!=7856 || message_q[367:256]!=112'("REINS-BATCH-v2")))) begin
                    error_o<=1; state_q<=RESULT; inverse_q<=~RESULT;
                end else begin state_q<=mgf_q && length_q==0 ? RESULT : START; inverse_q<=~(mgf_q && length_q==0 ? RESULT : START); end
            end
            START: if (ready) begin state_q<=WAIT_HASH; inverse_q<=~WAIT_HASH; end
            WAIT_HASH: if (valid) begin capture_q<=digest; capture_inv_q<=~digest; state_q<=TAKE; inverse_q<=~TAKE; end
            TAKE: begin
                if (!valid || hash_error!=0 || capture_q!=digest) begin failed_q<=1; error_o<=3; state_q<=RESULT; inverse_q<=~RESULT; end
                else if (!phase_q) begin inner_q<=capture_q; inner_inv_q<=~capture_q; phase_q<=1; phase_inv_q<=0; state_q<=START; inverse_q<=~START; end
                else begin
                    for (int i=0;i<32;i++) if ((counter_q ? 32 : 0)+i<int'(length_q)) begin
                        mask_q[511-((counter_q ? 32 : 0)+i)*8 -: 8]<=capture_q[255-i*8 -: 8];
                        mask_inv_q[511-((counter_q ? 32 : 0)+i)*8 -: 8]<=~capture_q[255-i*8 -: 8];
                    end
                    if (!counter_q && length_q>32) begin counter_q<=1; counter_inv_q<=0; state_q<=START; inverse_q<=~START; end
                    else begin state_q<=RESULT; inverse_q<=~RESULT; end
                end
            end
            RESULT: if (rsp_ready_i) begin erase(); error_o<=0; end
            default: begin erase(); failed_q<=1; error_o<=3; state_q<=RESULT; inverse_q<=~RESULT; end
            endcase
        end
    end
endmodule
`default_nettype wire
