// SHA2-128s WOTS+ chain and public-key reconstruction. One fresh public-seed
// compression per request, then one real compression per F step. The 560-byte
// endpoint workspace is not another receive memory. No signature acceptance output.
`default_nettype none
// Algorithm-only parents may pass a signature without a REINS index/proof; the production gate forbids that extent.
module slh_wots #(parameter bit ALLOW_SIGNATURE_ONLY=1'b0) (
    input logic clk_i, rst_ni, cancel_i,      // Rising clock; synchronous trusted reset; cancel invalidates even a held result.
    input logic req_valid_i,                 // Descriptor is immutable after valid/ready capture.
    output logic req_ready_o,                // One healthy owned request at a time.
    input logic req_public_key_i,             // 0=one bounded chain; 1=all 35 chains and T_l.
    input logic [127:0] seed_i, message_i, value_i, // Public seed, WOTS message, or single-chain input.
    input logic [31:0] layer_i, keypair_i, chain_i, // Layer 0..6, leaf 0..511, standalone chain 0..34.
    input logic [95:0] tree_i,                // Full FIPS address field; high/unused bits must be canonical.
    input logic [4:0] start_i, steps_i,        // Chain mode: 0<=start<=15 and start+steps<=15.
    input logic [13:0] signature_offset_i, signature_length_i, sealed_length_i, // Exact bounded slice and actual sealed extent.
    input logic [31:0] tag_i,                 // Caller provenance returned only for this request.
    output logic read_valid_o,               // Sole read request; no write path exists in this component.
    output logic [13:0] read_address_o, read_address_inverse_o,
    input logic read_valid_i,
    input logic [7:0] read_data_i,            // Already owner/ECC/seal checked; sampled twice before use.
    output logic rsp_valid_o,                // Held candidate/error; cancellation or integrity can withdraw it.
    input logic rsp_ready_i,
    output logic [1:0] error_o,               // 0=candidate value, 1=shape, 2=read stall, 3=integrity.
    output logic fault_o,                    // Sticky read/control/integrity alarm, independent of response consumption.
    output logic [31:0] tag_o,
    output logic [127:0] value_o,             // Chain endpoint or compressed WOTS public key, never batch root.
    output logic [255:0] seed_state_o,         // Passive public-prefix evidence; not reused across requests.
    output logic [255:0] address_o,           // Passive current full/compressed FIPS address.
    output logic [175:0] compressed_address_o,
    output logic [5:0] chain_o,
    output logic [4:0] hash_step_o,
    output logic chain_start_o, chain_complete_o,
    output logic [127:0] chain_value_o,
    output logic [7:0] stage_o, state_o,
    output logic start_o, complete_o,         // Actual physical compression events for independent observation.
    output logic [15:0] starts_o, completions_o, chain_steps_o
);
    typedef struct packed {
        logic full;
        logic [127:0] seed, message, value;
        logic [31:0] layer, keypair, chain, tag;
        logic [95:0] tree;
        logic [4:0] start, steps;
        logic [13:0] offset, signature_length, sealed_length;
    } context_t;
    context_t context_q, context_inverse_q;    // Immutable public inputs, exact slice and provenance; complementary capture.
    localparam logic [7:0] IDLE=8'h0f,CHECK=8'h33,HASH_START=8'h55,WAIT_HASH=8'h69,TAKE=8'h96,
        READ=8'haa,SET_CHAIN=8'hcc,NEXT_CHAIN=8'hf0,RESULT=8'h3c;
    localparam logic [7:0] PREFIX=8'h69,CHAIN=8'h96,PK=8'haa;
    logic [7:0] state_q, state_inv_q, phase_q, phase_inv_q;
    logic [127:0] value_q, value_inv_q;
    logic [255:0] prefix_q, prefix_inv_q, capture_q, capture_inv_q, digest;
    logic [4479:0] endpoints_q, endpoints_inv_q;
    logic [5:0] chain_q, chain_inv_q;
    logic [4:0] step_q, step_inv_q, remaining_q, remaining_inv_q;
    logic [3:0] byte_q, byte_inv_q;
    logic [7:0] sample_q, sample_inv_q;
    logic repeat_q;
    logic [10:0] stall_q;
    logic [15:0] starts_q, ends_q, steps_q, starts_inv_q, ends_inv_q, steps_inv_q;
    logic [139:0] digits;
    logic [15:0] unused_checksum;
    logic [3:0] digit;
    logic address_valid, ready, valid, hash_fault, failed_q, bad, active;
    logic [1:0] hash_error;
    logic [7:0] unused_hash_starts, unused_hash_ends;
    logic [9:0] offset;
    logic [7:0] primary_byte, audit_byte;
    logic [31:0] address_type, address_chain, address_hash, hash_length;
    logic [13:0] intended_address;
    logic [15:0] expected_steps, expected_work;
    // Independently derive the aggregate chain budget from message nibbles and checksum; no RTL digits input.
    function automatic logic [15:0] count_steps(input logic [127:0] message);
        int sum, checksum;
        sum=0;
        for (int i=0;i<32;i++) sum=sum+int'(message[127-i*4 -: 4]);
        checksum=480-sum;
        return 16'(525-sum-((checksum>>8)&15)-((checksum>>4)&15)-(checksum&15));
    endfunction
    assign expected_steps=context_q.full ? count_steps(context_q.message) : {11'd0,context_q.steps};
    assign expected_work=expected_steps+(context_q.full ? 16'd11 : 16'd1);
    slh_wots_digits decode (.message_i(context_q.message),.digits_o(digits),.checksum_o(unused_checksum));
    assign digit=chain_q<35 ? digits[139-int'(chain_q)*4 -: 4] : 4'd0;
    assign address_type=phase_q==PK ? 32'd1 : 32'd0;
    assign address_chain=phase_q==PK ? 32'd0 : {26'd0,chain_q};
    assign address_hash=phase_q==CHAIN && (state_q==HASH_START || state_q==WAIT_HASH || state_q==TAKE) ? {27'd0,step_q} : 32'd0;
    slh_address address_builder (
        .layer_i(context_q.layer),.tree_i(context_q.tree),.type_i(address_type),.keypair_i(context_q.keypair),
        .word6_i(address_chain),.word7_i(address_hash),.address_o(address_o),.compressed_o(compressed_address_o),.valid_o(address_valid)
    );
    assign hash_length=phase_q==PREFIX ? 32'd64 : phase_q==CHAIN ? 32'd38 : 32'd582;
    // Return primary stream byte at position using the compressed address generator.
    function automatic logic [7:0] framed_byte(input int position);
        if (phase_q==PREFIX) begin
            if (position<16) return context_q.seed[127-position*8 -: 8];
            return 0;
        end
        if (position<22) return compressed_address_o[175-position*8 -: 8];
        if (phase_q==CHAIN && position<38) return value_q[127-(position-22)*8 -: 8];
        if (phase_q==PK && position<582) return endpoints_q[4479-(position-22)*8 -: 8];
        return 0;
    endfunction
    assign primary_byte=framed_byte(int'(offset));
    // Independently construct compressed-address byte at position from typed local fields.
    function automatic logic [7:0] checked_address_byte(input int position);
        if (position==0) return context_q.layer[7:0];
        if (position<9) return context_q.tree[63-(position-1)*8 -: 8];
        if (position==9) return phase_q==PK ? 8'd1 : 8'd0;
        if (position<14) return context_q.keypair[31-(position-10)*8 -: 8];
        if (phase_q==PK) return 0;
        if (position<18) return 8'({26'd0,chain_q}>>(8*(17-position)));
        return 8'({27'd0,step_q}>>(8*(21-position)));
    endfunction
    // Audit byte at position without relying on the primary address framer.
    function automatic logic [7:0] checked_byte(input int position);
        if (phase_q==PREFIX) begin
            if (position<16) return context_q.seed[127-position*8 -: 8];
            return 0;
        end
        if (position<22) return checked_address_byte(position);
        if (phase_q==CHAIN && position<38) return value_q[127-(position-22)*8 -: 8];
        if (phase_q==PK && position<582) return endpoints_q[4479-(position-22)*8 -: 8];
        return 0;
    endfunction
    assign audit_byte=checked_byte(int'(offset));
    assign intended_address=context_q.offset+14'(chain_q)*14'd16+{10'd0,byte_q};
    assign read_address_o=intended_address;
    assign read_address_inverse_o=~(context_q.offset+{10'd0,byte_q}+14'(chain_q)*14'd16);
    assign active=state_q!=IDLE && state_q!=RESULT;
    assign bad=state_q!=~state_inv_q || phase_q!=~phase_inv_q || context_q!=~context_inverse_q ||
        value_q!=~value_inv_q || prefix_q!=~prefix_inv_q || capture_q!=~capture_inv_q || endpoints_q!=~endpoints_inv_q ||
        chain_q!=~chain_inv_q || step_q!=~step_inv_q || remaining_q!=~remaining_inv_q || byte_q!=~byte_inv_q || sample_q!=~sample_inv_q ||
        starts_q!=~starts_inv_q || ends_q!=~ends_inv_q || steps_q!=~steps_inv_q ||
        !(state_q==IDLE || state_q==CHECK || state_q==HASH_START || state_q==WAIT_HASH || state_q==TAKE || state_q==READ || state_q==SET_CHAIN || state_q==NEXT_CHAIN || state_q==RESULT) ||
        !(phase_q==PREFIX || phase_q==CHAIN || phase_q==PK) ||
        (state_q==READ && (read_address_o!=intended_address || read_address_inverse_o!=~intended_address ||
            // Independently decode row/column: comparing two aliases of the same
            // physical address wire cannot detect coherent address/complement substitution.
            read_address_o[3:0]!=byte_q || read_address_o[13:4]!=(context_q.offset[13:4]+{4'd0,chain_q}) ||
            read_address_o>=context_q.signature_length || read_address_o>=context_q.sealed_length)) ||
        (active && state_q!=CHECK && !address_valid) ||
        (phase_q==CHAIN && (state_q==HASH_START || state_q==WAIT_HASH || state_q==TAKE) &&
            ({1'b0,step_q}+{1'b0,remaining_q}!=(context_q.full ? 6'd15 : {1'b0,context_q.start}+{1'b0,context_q.steps}))) ||
        (state_q==RESULT && error_o==0 && (starts_q!=expected_work || ends_q!=expected_work || steps_q!=expected_steps));
    assign fault_o=rst_ni && (failed_q || bad || hash_fault);
    assign req_ready_o=rst_ni && !cancel_i && state_q==IDLE && !fault_o;
    assign rsp_valid_o=rst_ni && !cancel_i && state_q==RESULT && !bad && (error_o!=0 || !fault_o);
    assign read_valid_o=rst_ni && !cancel_i && state_q==READ && !fault_o;
    assign value_o=rsp_valid_o && error_o==0 ? value_q : 128'd0;
    assign seed_state_o=rsp_valid_o && error_o==0 ? prefix_q : 256'd0;
    assign chain_o=chain_q;
    assign hash_step_o=state_q==SET_CHAIN ? (context_q.full ? {1'b0,digit} : context_q.start) : step_q;
    assign stage_o=phase_q; assign state_o=state_q; assign tag_o=context_q.tag;
    assign chain_start_o=state_q==SET_CHAIN;
    assign chain_complete_o=state_q==NEXT_CHAIN;
    assign chain_value_o=value_q;
    assign starts_o=starts_q; assign completions_o=ends_q; assign chain_steps_o=steps_q;
    slh_hash_transaction hash (
        .clk_i(clk_i),.rst_ni(rst_ni),.cancel_i(cancel_i || state_q==IDLE || state_q==RESULT),
        .req_valid_i(state_q==HASH_START),.req_ready_o(ready),.mode_i(phase_q==PREFIX ? 2'd2 : 2'd1),
        .length_i(hash_length),.tag_i({8'h10,phase_q,5'd0,chain_q,step_q}),.prefix_state_i(prefix_q),
        .byte_offset_o(offset),.byte_i(primary_byte),.audit_byte_i(audit_byte),.rsp_valid_o(valid),.rsp_ready_i(state_q==TAKE),
        .digest_o(digest),.error_o(hash_error),.fault_o(hash_fault),.start_o(start_o),.complete_o(complete_o),
        .starts_o(unused_hash_starts),.completions_o(unused_hash_ends)
    );
    // Erase all per-request data and prefix cache; cancellation never clears sticky failure; no parameters.
    task automatic erase();
        state_q<=IDLE; state_inv_q<=~IDLE; phase_q<=PREFIX; phase_inv_q<=~PREFIX;
        context_q<='0; context_inverse_q<='1; value_q<=0; value_inv_q<='1; prefix_q<=0; prefix_inv_q<='1;
        capture_q<=0; capture_inv_q<='1; endpoints_q<=0; endpoints_inv_q<='1;
        chain_q<=0; chain_inv_q<='1; step_q<=0; step_inv_q<='1; remaining_q<=0; remaining_inv_q<='1;
        byte_q<=0; byte_inv_q<='1; sample_q<=0; sample_inv_q<='1; repeat_q<=0; stall_q<=0;
        starts_q<=0; ends_q<=0; steps_q<=0; starts_inv_q<='1; ends_inv_q<='1; steps_inv_q<='1;
    endtask
    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin erase(); failed_q<=0; error_o<=0; end
        else if (cancel_i) begin erase(); error_o<=0; end
        else if (bad || hash_fault) begin erase(); state_q<=RESULT; state_inv_q<=~RESULT; failed_q<=1; error_o<=3; end
        else begin
            if (start_o) begin starts_q<=starts_q+1; starts_inv_q<=starts_inv_q-1; end
            if (complete_o) begin ends_q<=ends_q+1; ends_inv_q<=ends_inv_q-1; end
            case (state_q)
            IDLE: if (req_valid_i && req_ready_o) begin
                erase(); state_q<=CHECK; state_inv_q<=~CHECK; error_o<=0;
                context_q<={req_public_key_i,seed_i,message_i,value_i,layer_i,keypair_i,chain_i,tag_i,tree_i,start_i,steps_i,signature_offset_i,signature_length_i,sealed_length_i};
                context_inverse_q<=~{req_public_key_i,seed_i,message_i,value_i,layer_i,keypair_i,chain_i,tag_i,tree_i,start_i,steps_i,signature_offset_i,signature_length_i,sealed_length_i};
                chain_q<=req_public_key_i ? 6'd0 : 6'(chain_i); chain_inv_q<=~(req_public_key_i ? 6'd0 : 6'(chain_i));
            end
            CHECK: begin
                if (!address_valid || (!context_q.full && (context_q.chain>=35 || context_q.start>15 || context_q.steps>15 || {1'b0,context_q.start}+{1'b0,context_q.steps}>15)) ||
                    (context_q.full && (context_q.signature_length!=7856 || context_q.offset!=14'd2928+14'(context_q.layer)*14'd704 ||
                        (!(ALLOW_SIGNATURE_ONLY && context_q.sealed_length==7856) &&
                            (context_q.sealed_length<7860 || context_q.sealed_length>8500 || (context_q.sealed_length-14'd7860)%32!=0)) ||
                        {1'b0,context_q.offset}+15'd560>{1'b0,context_q.signature_length}))) begin
                    error_o<=1; state_q<=RESULT; state_inv_q<=~RESULT;
                end else begin state_q<=HASH_START; state_inv_q<=~HASH_START; end
            end
            HASH_START: if (ready) begin state_q<=WAIT_HASH; state_inv_q<=~WAIT_HASH; end
            WAIT_HASH: if (valid) begin capture_q<=digest; capture_inv_q<=~digest; state_q<=TAKE; state_inv_q<=~TAKE; end
            TAKE: begin
                if (!valid || hash_error!=0 || capture_q!=digest) begin failed_q<=1; error_o<=3; state_q<=RESULT; state_inv_q<=~RESULT; end
                else if (phase_q==PREFIX) begin
                    prefix_q<=capture_q; prefix_inv_q<=~capture_q; value_q<=context_q.full ? 128'd0 : context_q.value; value_inv_q<=~(context_q.full ? 128'd0 : context_q.value);
                    state_q<=context_q.full ? READ : SET_CHAIN; state_inv_q<=~(context_q.full ? READ : SET_CHAIN);
                end else if (phase_q==CHAIN) begin
                    value_q<=capture_q[255:128]; value_inv_q<=~capture_q[255:128];
                    steps_q<=steps_q+1; steps_inv_q<=steps_inv_q-1;
                    remaining_q<=remaining_q-1; remaining_inv_q<=remaining_inv_q+1;
                    step_q<=step_q+1; step_inv_q<=step_inv_q-1;
                    state_q<=remaining_q==1 ? NEXT_CHAIN : HASH_START; state_inv_q<=~(remaining_q==1 ? NEXT_CHAIN : HASH_START);
                end else begin value_q<=capture_q[255:128]; value_inv_q<=~capture_q[255:128]; state_q<=RESULT; state_inv_q<=~RESULT; end
            end
            READ: if (!read_valid_i) begin
                if (stall_q==1023) begin failed_q<=1; error_o<=2; state_q<=RESULT; state_inv_q<=~RESULT; end
                else stall_q<=stall_q+1;
            end else begin
                stall_q<=0;
                if (!repeat_q) begin sample_q<=read_data_i; sample_inv_q<=~read_data_i; repeat_q<=1; end
                else if (sample_q!=read_data_i) begin failed_q<=1; error_o<=3; state_q<=RESULT; state_inv_q<=~RESULT; end
                else begin
                    repeat_q<=0; value_q<={value_q[119:0],sample_q}; value_inv_q<=~{value_q[119:0],sample_q};
                    byte_q<=byte_q+1; byte_inv_q<=byte_inv_q-1;
                    if (byte_q==15) begin state_q<=SET_CHAIN; state_inv_q<=~SET_CHAIN; end
                end
            end
            SET_CHAIN: begin
                phase_q<=CHAIN; phase_inv_q<=~CHAIN;
                step_q<=context_q.full ? {1'b0,digit} : context_q.start; step_inv_q<=~(context_q.full ? {1'b0,digit} : context_q.start);
                remaining_q<=context_q.full ? 5'd15-{1'b0,digit} : context_q.steps; remaining_inv_q<=~(context_q.full ? 5'd15-{1'b0,digit} : context_q.steps);
                state_q<=(context_q.full ? digit==15 : context_q.steps==0) ? NEXT_CHAIN : HASH_START;
                state_inv_q<=~((context_q.full ? digit==15 : context_q.steps==0) ? NEXT_CHAIN : HASH_START);
            end
            NEXT_CHAIN: begin
                if (!context_q.full) begin state_q<=RESULT; state_inv_q<=~RESULT; end
                else begin
                    endpoints_q[4479-int'(chain_q)*128 -: 128]<=value_q; endpoints_inv_q[4479-int'(chain_q)*128 -: 128]<=~value_q;
                    if (chain_q==34) begin phase_q<=PK; phase_inv_q<=~PK; state_q<=HASH_START; state_inv_q<=~HASH_START; end
                    else begin chain_q<=chain_q+1; chain_inv_q<=chain_inv_q-1; value_q<=0; value_inv_q<='1; state_q<=READ; state_inv_q<=~READ; end
                end
            end
            RESULT: if (rsp_ready_i) begin erase(); error_o<=0; end
            default: begin erase(); failed_q<=1; error_o<=3; state_q<=RESULT; state_inv_q<=~RESULT; end
            endcase
        end
    end
endmodule
`default_nettype wire
