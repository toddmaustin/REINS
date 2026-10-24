// Copyright (c) 2026 Todd Austin.
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// License: https://polyformproject.org/licenses/noncommercial/1.0.0/

// Complete SHA2-128s algorithm component. Signature bytes come from the sole sealed
// receive store. The separate public payload port is context||message (external)
// or message (internal). REINS exposes only slh_verify_reins, never this mode bit.
`default_nettype none
module slh_verify (
    input logic clk_i, rst_ni, cancel_i, // Trusted synchronous reset; cancellation dominates completion.
    input logic req_valid_i,
    output logic req_ready_o,
    input logic [255:0] public_key_i, // PK.seed || PK.root; root is distinct from the signed batch root.
    input logic internal_i, // FIPS internal algorithm interface; external means pure framing 00||ctxlen.
    input logic [7:0] context_length_i,
    input logic [13:0] message_length_i, signature_length_i, sealed_length_i,
    input logic [31:0] tag_i, // Immutable caller ownership, echoed only for this job.
    output logic read_valid_o,
    output logic [13:0] read_address_o, read_address_inverse_o,
    input logic read_valid_i,
    input logic [7:0] read_data_i, // Owner, seal and ECC checked upstream; local reads sampled twice.
    output logic [13:0] payload_address_o,
    input logic [7:0] payload_byte_i, // Stable context||message at payload_address_o for the owned request.
    output logic rsp_valid_o,
    input logic rsp_ready_i,
    output logic verified_o, fault_o,
    output logic [1:0] error_o, // 0=completed cryptographic comparison (may be false), 1=shape, 2=stall, 3=integrity.
    output logic [31:0] tag_o,
    output logic [127:0] reconstructed_root_o,
    output logic [7:0] state_o, phase_o,
    output logic [3:0] fors_tree_o, height_o, layer_o,
    output logic stage_valid_o, // FORS tree roots, FORS public key, WOTS keys, and XMSS roots at TAKE/TAKE_WOTS.
    output logic [127:0] stage_value_o,
    output logic start_o, complete_o, // Actual compression starts/completions across the two exclusively owned engines.
    output logic [15:0] starts_o, completions_o,
    output logic chain_start_o, // Independently observed chain launch, before any F evaluation.
    output logic [5:0] chain_index_o,
    output logic [4:0] chain_digit_o,
    output logic [1:0] sha_start_o, sha_complete_o // Independent physical main/WOTS events, not sequencer intent.
);
    typedef struct packed {
        logic [255:0] key;
        logic internal_mode;
        logic [7:0] context_length;
        logic [13:0] message_length, signature_length, sealed_length;
        logic [31:0] tag;
    } context_t;
    typedef struct packed {
        logic [7:0] state, phase;
        logic [127:0] randomizer, node, sibling; // R plus current node and one authentication sibling.
        logic [255:0] prefix, inner, capture; // Fresh public seed state, H_msg inner digest, checked stage hand-off.
        logic [167:0] md; // Fourteen 12-bit FORS indices in network bit order.
        logic [53:0] tree; // Remaining hypertree address bits, shifted by nine after each layer.
        logic [8:0] leaf;
        logic [11:0] index;
        logic [15:0] global_index;
        logic [1791:0] roots; // Fourteen FORS roots, 224 bytes; never a signature copy.
        logic [3:0] forest, height, layer, byte_index;
        logic [13:0] cursor; // Absolute signature cursor; independently checked against section position.
        logic [7:0] sample;
        logic repeat_read;
        logic [10:0] stall;
        logic [15:0] starts, ends, expected;
        logic [1:0] error;
    } work_t;
    localparam logic [7:0] IDLE=8'h0f,CHECK=8'h33,READ=8'h55,LAUNCH=8'h69,WAIT_HASH=8'h96,
        TAKE=8'haa,LAUNCH_WOTS=8'hcc,WAIT_WOTS=8'hf0,TAKE_WOTS=8'h3c,RESULT=8'hc3;
    localparam logic [7:0] RANDOM=8'h0f,INNER=8'h33,MASK=8'h55,PREFIX=8'h69,
        FORS_LEAF=8'h96,FORS_PATH=8'haa,FORS_PK=8'hcc,WOTS=8'hf0,TREE=8'h3c;
    context_t context_q, context_inv_q;
    (* keep="true", dont_touch="true" *) work_t w, wi;
    work_t n, audit_w, audit_n;
    context_t audit_context;
    logic [31:0] audit_hash_length;
    logic [15:0] audit_wots_work; // Full complementary sequencer/scratch encoding, checked before every state transition.
    logic failed_q, bad, hash_ready, hash_valid, hash_fault, wots_ready, wots_valid, wots_fault;
    logic [1:0] hash_error, wots_error;
    logic [255:0] digest, unused_wots_prefix;
    logic [127:0] wots_value;
    logic [31:0] wots_tag;
    logic [13:0] hash_offset, wots_address, wots_address_inverse;
    logic [31:0] hash_length, address_type, address_kp, address_height, address_index;
    logic [175:0] compressed_address;
    logic [255:0] unused_address, unused_wots_address;
    logic [175:0] unused_wots_compressed;
    logic address_valid, wots_read, hash_start, hash_end, wots_start, wots_end;
    logic [7:0] unused_starts, unused_ends, primary_byte, audit_byte;
    logic [1:0] hash_mode;
    logic [7:0] unused_wots_stage, unused_wots_state;
    logic [5:0] unused_chain;
    logic [4:0] unused_step;
    logic unused_chain_start, unused_chain_end;
    logic [127:0] unused_chain_value;
    logic [15:0] wots_starts, wots_ends, unused_steps;
    logic [13:0] expected_cursor;
    logic [15:0] wots_work;
    // Derive the WOTS work from message nibbles and a separately computed integer
    // checksum. This accounting path does not reuse the child's digit decoder.
    function automatic logic [15:0] count_wots(input logic [127:0] message);
        int chain_work, check_value;
        chain_work=0;
        for (int i=0;i<32;i++) chain_work+=15-int'(message[127-i*4 -: 4]);
        check_value=chain_work;
        for (int i=0;i<3;i++) chain_work+=15-((check_value>>(i*4))&15);
        return 16'(11+chain_work);
    endfunction
    assign wots_work=count_wots(w.node);
    assign audit_w=~wi;
    // During the second capture phase use the held source ports directly;
    // subsequent transitions consume only the independently captured inverse.
    assign audit_context=wi.state==~CHECK ? context_t'({public_key_i,internal_i,context_length_i,message_length_i,signature_length_i,sealed_length_i,tag_i}) : ~context_inv_q;
    assign audit_hash_length=audit_w.phase==INNER ? 32'd48+32'(audit_context.message_length)+(audit_context.internal_mode ? 0 : 32'd2+32'(audit_context.context_length)) :
        audit_w.phase==MASK ? 32'd68 : audit_w.phase==PREFIX ? 32'd64 : audit_w.phase==FORS_LEAF ? 32'd38 : audit_w.phase==FORS_PK ? 32'd246 : 32'd54;
    assign audit_wots_work=count_wots(audit_w.node);
    assign state_o=w.state; assign phase_o=w.phase;
    assign fors_tree_o=w.forest; assign height_o=w.height; assign layer_o=w.layer;
    assign starts_o=w.starts; assign completions_o=w.ends;
    assign tag_o=context_q.tag;
    assign bad=w!=~wi || (w.state!=CHECK && context_q!=~context_inv_q) ||
        (w.state==CHECK && context_q!={public_key_i,internal_i,context_length_i,message_length_i,signature_length_i,sealed_length_i,tag_i}) ||
        !(w.state==IDLE || w.state==CHECK || w.state==READ || w.state==LAUNCH || w.state==WAIT_HASH || w.state==TAKE || w.state==LAUNCH_WOTS || w.state==WAIT_WOTS || w.state==TAKE_WOTS || w.state==RESULT) ||
        !(w.phase==RANDOM || w.phase==INNER || w.phase==MASK || w.phase==PREFIX || w.phase==FORS_LEAF || w.phase==FORS_PATH || w.phase==FORS_PK || w.phase==WOTS || w.phase==TREE) ||
        w.starts>w.expected || w.ends>w.starts || w.forest>13 || w.height>12 || w.layer>6 ||
        (w.state==READ && (w.cursor!=expected_cursor || read_address_o!=w.cursor || read_address_inverse_o!=~w.cursor || read_address_o>=7856)) ||
        ((w.state==LAUNCH || w.state==WAIT_HASH || w.state==TAKE) && (w.phase==FORS_LEAF || w.phase==FORS_PATH || w.phase==FORS_PK || w.phase==TREE) && !address_valid) ||
        (w.state==RESULT && w.error==0 && (w.cursor!=7856 || w.starts!=w.expected || w.ends!=w.expected || w.layer!=6 || w.height!=9 || w.tree!=0));
    assign fault_o=rst_ni && (failed_q || bad || hash_fault || wots_fault);
    assign req_ready_o=rst_ni && !cancel_i && w.state==IDLE && !fault_o;
    assign rsp_valid_o=rst_ni && !cancel_i && w.state==RESULT && !bad && (w.error!=0 || !fault_o);
    assign verified_o=rsp_valid_o && !fault_o && w.error==0 && w.node==context_q.key[127:0];
    assign reconstructed_root_o=rsp_valid_o && !fault_o && w.error==0 ? w.node : 128'd0;
    assign error_o=w.error;
    assign read_valid_o=rst_ni && !cancel_i && !fault_o && (w.state==READ || wots_read);
    assign read_address_o=w.state==READ ? w.cursor : wots_address;
    assign read_address_inverse_o=w.state==READ ? ~w.cursor : wots_address_inverse;
    // Position is derived independently from section/tree/height, rather than trusting the mutable cursor.
    assign expected_cursor=w.phase==RANDOM ? {10'd0,w.byte_index} :
        w.phase==FORS_LEAF ? 14'd16+14'(w.forest)*14'd208+{10'd0,w.byte_index} :
        w.phase==FORS_PATH ? 14'd32+14'(w.forest)*14'd208+14'(w.height)*14'd16+{10'd0,w.byte_index} :
        14'd3488+14'(w.layer)*14'd704+14'(w.height)*14'd16+{10'd0,w.byte_index};
    assign address_type=w.phase==FORS_PK ? 32'd4 : w.phase==TREE ? 32'd2 : 32'd3;
    assign address_kp=w.phase==TREE ? 0 : {23'd0,w.leaf};
    assign address_height=w.phase==FORS_PK ? 0 : w.phase==FORS_LEAF ? 0 : {28'd0,w.height}+1;
    assign address_index=w.phase==FORS_PK ? 0 : w.phase==TREE ? (32'(w.leaf)>>(w.height+1)) :
        w.phase==FORS_LEAF ? {16'd0,w.global_index} : (32'(w.global_index)>>1);
    slh_address address_builder(.layer_i({28'd0,w.layer}),.tree_i({42'd0,w.tree}),.type_i(address_type),
        .keypair_i(address_kp),.word6_i(address_height),.word7_i(address_index),
        .address_o(unused_address),.compressed_o(compressed_address),.valid_o(address_valid));
    assign hash_length=w.phase==INNER ? 32'd48+32'(context_q.message_length)+(context_q.internal_mode ? 0 : 32'd2+32'(context_q.context_length)) :
        w.phase==MASK ? 32'd68 : w.phase==PREFIX ? 32'd64 : w.phase==FORS_LEAF ? 32'd38 : w.phase==FORS_PK ? 32'd246 : 32'd54;
    assign hash_mode=w.phase==PREFIX ? 2'd2 : (w.phase==INNER || w.phase==MASK) ? 2'd0 : 2'd1;
    assign payload_address_o=hash_offset-14'd48-(context_q.internal_mode ? 14'd0 : 14'd2);
    // Construct hash byte at position. audit chooses the independently assembled compressed address fields.
    // Build position's audit byte exclusively from complemented context/workspace
    // and a fresh address expression; no primary byte or address mux is consumed.
    function automatic logic [7:0] audit_verify_byte(input int position);
        logic [175:0] adr;
        logic swap_nodes;
        logic [7:0] selected_type;
        logic [31:0] selected_kp,selected_height,selected_index;
        selected_type=audit_w.phase==FORS_PK ? 8'd4 : audit_w.phase==TREE ? 8'd2 : 8'd3;
        selected_kp=audit_w.phase==TREE ? 0 : {23'd0,audit_w.leaf};
        selected_height=audit_w.phase==FORS_PK || audit_w.phase==FORS_LEAF ? 0 : {28'd0,audit_w.height}+1;
        selected_index=audit_w.phase==FORS_PK ? 0 : audit_w.phase==TREE ? (32'(audit_w.leaf)>>(audit_w.height+1)) :
            audit_w.phase==FORS_LEAF ? {16'd0,audit_w.global_index} : (32'(audit_w.global_index)>>1);
        adr={8'(audit_w.layer),64'(audit_w.tree),8'(selected_type),selected_kp,selected_height,selected_index};
        swap_nodes=audit_w.phase==TREE ? ((audit_w.leaf>>audit_w.height)&1)!=0 : ((audit_w.index>>audit_w.height)&1)!=0;
        if (audit_w.phase==PREFIX) return position<16 ? audit_context.key[255-position*8 -: 8] : 8'd0;
        if (audit_w.phase==INNER) begin
            if (position<16) return audit_w.randomizer[127-position*8 -: 8];
            if (position<48) return audit_context.key[255-(position-16)*8 -: 8];
            if (!audit_context.internal_mode && position==48) return 0;
            if (!audit_context.internal_mode && position==49) return audit_context.context_length;
            return payload_byte_i;
        end
        if (audit_w.phase==MASK) begin
            if (position<16) return audit_w.randomizer[127-position*8 -: 8];
            if (position<32) return audit_context.key[255-(position-16)*8 -: 8];
            if (position<64) return audit_w.inner[255-(position-32)*8 -: 8];
            return 0; // MGF1 counter zero, 30 output bytes required for SHA2-128s.
        end
        if (position<22) return adr[175-position*8 -: 8];
        if (audit_w.phase==FORS_PK) return audit_w.roots[1791-(position-22)*8 -: 8];
        if (audit_w.phase==FORS_LEAF) return audit_w.node[127-(position-22)*8 -: 8];
        if (position<38) return swap_nodes ? audit_w.sibling[127-(position-22)*8 -: 8] : audit_w.node[127-(position-22)*8 -: 8];
        return swap_nodes ? audit_w.node[127-(position-38)*8 -: 8] : audit_w.sibling[127-(position-38)*8 -: 8];
    endfunction
    function automatic logic [7:0] verify_byte(input int position, input logic audit);
        logic [175:0] adr;
        logic swap_nodes;
        if (audit) return audit_verify_byte(position);
        adr=audit ? {8'(w.layer),64'(w.tree),8'(address_type),address_kp,address_height,address_index} : compressed_address;
        swap_nodes=w.phase==TREE ? ((w.leaf>>w.height)&1)!=0 : ((w.index>>w.height)&1)!=0;
        if (w.phase==PREFIX) return position<16 ? context_q.key[255-position*8 -: 8] : 8'd0;
        if (w.phase==INNER) begin
            if (position<16) return w.randomizer[127-position*8 -: 8];
            if (position<48) return context_q.key[255-(position-16)*8 -: 8];
            if (!context_q.internal_mode && position==48) return 0;
            if (!context_q.internal_mode && position==49) return context_q.context_length;
            return payload_byte_i;
        end
        if (w.phase==MASK) begin
            if (position<16) return w.randomizer[127-position*8 -: 8];
            if (position<32) return context_q.key[255-(position-16)*8 -: 8];
            if (position<64) return w.inner[255-(position-32)*8 -: 8];
            return 0; // MGF1 counter zero, 30 output bytes required for SHA2-128s.
        end
        if (position<22) return adr[175-position*8 -: 8];
        if (w.phase==FORS_PK) return w.roots[1791-(position-22)*8 -: 8];
        if (w.phase==FORS_LEAF) return w.node[127-(position-22)*8 -: 8];
        if (position<38) return swap_nodes ? w.sibling[127-(position-22)*8 -: 8] : w.node[127-(position-22)*8 -: 8];
        return swap_nodes ? w.node[127-(position-38)*8 -: 8] : w.sibling[127-(position-38)*8 -: 8];
    endfunction
    assign primary_byte=verify_byte(int'(hash_offset),0);
    assign audit_byte=verify_byte(int'(hash_offset),1);
    slh_hash_transaction #(.MAX_BYTES(8500),.OFFSET_BITS(14)) hash (
        .clk_i(clk_i),.rst_ni(rst_ni),.cancel_i(cancel_i || w.state==IDLE || w.state==RESULT),
        .req_valid_i(w.state==LAUNCH && !fault_o),.req_ready_o(hash_ready),.mode_i(hash_mode),
        .length_i(hash_length),.tag_i({8'h1b,w.phase,4'd0,w.forest,w.height,w.layer}),.prefix_state_i(w.prefix),
        .byte_offset_o(hash_offset),.byte_i(primary_byte),.audit_byte_i(audit_byte),.rsp_valid_o(hash_valid),
        .rsp_ready_i(w.state==TAKE),.digest_o(digest),.error_o(hash_error),.fault_o(hash_fault),
        .start_o(hash_start),.complete_o(hash_end),.starts_o(unused_starts),.completions_o(unused_ends));
    slh_wots #(.ALLOW_SIGNATURE_ONLY(1'b1)) wots (
        .clk_i(clk_i),.rst_ni(rst_ni),.cancel_i(cancel_i || w.state==IDLE || w.state==RESULT),
        .req_valid_i(w.state==LAUNCH_WOTS && !fault_o),.req_ready_o(wots_ready),.req_public_key_i(1'b1),
        .seed_i(context_q.key[255:128]),.message_i(w.node),.value_i(128'd0),.layer_i({28'd0,w.layer}),
        .keypair_i({23'd0,w.leaf}),.chain_i(32'd0),.tree_i({42'd0,w.tree}),.start_i(5'd0),.steps_i(5'd0),
        .signature_offset_i(14'd2928+14'(w.layer)*14'd704),.signature_length_i(context_q.signature_length),
        // Algorithm cases may have no protocol index/proof. The parent production gate requires canonical sealed replies.
        .sealed_length_i(context_q.sealed_length),.tag_i(context_q.tag),
        .read_valid_o(wots_read),.read_address_o(wots_address),.read_address_inverse_o(wots_address_inverse),
        .read_valid_i(read_valid_i && w.state==WAIT_WOTS),.read_data_i(read_data_i),.rsp_valid_o(wots_valid),.rsp_ready_i(w.state==TAKE_WOTS),
        .error_o(wots_error),.fault_o(wots_fault),.tag_o(wots_tag),.value_o(wots_value),.seed_state_o(unused_wots_prefix),
        .address_o(unused_wots_address),.compressed_address_o(unused_wots_compressed),.chain_o(unused_chain),.hash_step_o(unused_step),
        .chain_start_o(unused_chain_start),.chain_complete_o(unused_chain_end),.chain_value_o(unused_chain_value),
        .stage_o(unused_wots_stage),.state_o(unused_wots_state),.start_o(wots_start),.complete_o(wots_end),
        .starts_o(wots_starts),.completions_o(wots_ends),.chain_steps_o(unused_steps));
    assign sha_start_o={wots_start,hash_start}; assign sha_complete_o={wots_end,hash_end};
    assign chain_start_o=unused_chain_start; assign chain_index_o=unused_chain; assign chain_digit_o=unused_step;
    assign start_o=hash_start || wots_start; assign complete_o=hash_end || wots_end;
    assign stage_valid_o=!fault_o && ((w.state==TAKE && (w.phase==FORS_PK || (w.phase==FORS_PATH && w.height==11) || (w.phase==TREE && w.height==8))) || w.state==TAKE_WOTS);
    assign stage_value_o=w.state==TAKE_WOTS ? wots_value : w.capture[255:128];
    // Compute the next protected sequencer state from the checked current state; no parameters.
    always_comb begin
        n=w;
        if (start_o) n.starts=w.starts+1;
        if (complete_o) n.ends=w.ends+1;
        case (w.state)
        CHECK: begin
            if (context_q.signature_length!=7856 || context_q.message_length>8192 ||
                (context_q.internal_mode && context_q.context_length!=0) || context_q.sealed_length<7856 || context_q.sealed_length>8500 ||
                (context_q.sealed_length!=7856 && (context_q.sealed_length<7860 || (context_q.sealed_length-14'd7860)%32!=0))) begin n.error=1; n.state=RESULT; end
            else n.state=READ;
        end
        // R, each FORS secret/path, and each XMSS path are streamed one double-sampled byte at a time.
        READ: begin
            if (!read_valid_i) begin
                n.stall=w.stall+1;
                if (w.stall==1023) begin n.error=2; n.state=RESULT; end
            end else begin
                n.stall=0;
                if (!w.repeat_read) begin n.sample=read_data_i; n.repeat_read=1; end
                else if (read_data_i!=w.sample) begin n.error=3; n.state=RESULT; end
                else begin
                    n.repeat_read=0; n.cursor=w.cursor+1; n.byte_index=w.byte_index+1;
                    if (w.phase==RANDOM) n.randomizer={w.randomizer[119:0],w.sample};
                    else if (w.phase==FORS_LEAF) n.node={w.node[119:0],w.sample};
                    else n.sibling={w.sibling[119:0],w.sample};
                    if (w.byte_index==15) begin
                        if (w.phase==RANDOM) n.phase=INNER;
                        n.state=LAUNCH;
                    end
                end
            end
        end
        LAUNCH: if (hash_ready) begin
            n.expected=w.expected+(w.phase==PREFIX ? 16'd1 : 16'((hash_length+32'd72)>>6)); n.state=WAIT_HASH;
        end
        WAIT_HASH: if (hash_valid) begin n.capture=digest; n.state=TAKE; end
        // The child retains its response while this independent capture is compared before use.
        TAKE: begin
            if (!hash_valid || hash_error!=0 || w.capture!=digest) begin n.error=3; n.state=RESULT; end
            else case (w.phase)
            INNER: begin n.inner=w.capture; n.phase=MASK; n.state=LAUNCH; end
            // FIPS consumes only 30 mask bytes; discard the specified unused high tree/leaf bits.
            MASK: begin
                n.md=w.capture[255:88]; n.tree=w.capture[85:32]; n.leaf=w.capture[24:16];
                n.index=w.capture[255:244]; n.global_index={4'd0,w.capture[255:244]}; n.phase=PREFIX; n.state=LAUNCH;
            end
            PREFIX: begin n.prefix=w.capture; n.phase=FORS_LEAF; n.state=READ; end
            FORS_LEAF: begin n.node=w.capture[255:128]; n.phase=FORS_PATH; n.state=READ; end
            // Finish a tree before adding its root to the protected fourteen-entry workspace.
            FORS_PATH: begin
                n.node=w.capture[255:128]; n.global_index=w.global_index>>1;
                if (w.height==11) begin
                    n.roots[1791-int'(w.forest)*128 -: 128]=w.capture[255:128]; n.height=0;
                    if (w.forest==13) begin n.phase=FORS_PK; n.state=LAUNCH; end
                    else begin
                        n.forest=w.forest+1; n.index=w.md[167-(int'(w.forest)+1)*12 -: 12];
                        n.global_index={w.forest+4'd1,w.md[167-(int'(w.forest)+1)*12 -: 12]}; n.phase=FORS_LEAF; n.state=READ;
                    end
                end else begin n.height=w.height+1; n.state=READ; end
            end
            FORS_PK: begin n.node=w.capture[255:128]; n.phase=WOTS; n.state=LAUNCH_WOTS; end
            // A completed XMSS root becomes the next layer message; advance its address by nine bits.
            TREE: begin
                n.node=w.capture[255:128]; n.height=w.height+1;
                if (w.height==8) begin
                    if (w.layer==6) begin n.state=RESULT; end
                    else begin n.layer=w.layer+1; n.leaf=w.tree[8:0]; n.tree=w.tree>>9; n.height=0; n.phase=WOTS; n.state=LAUNCH_WOTS; end
                end else n.state=READ;
            end
            default: begin n.error=3; n.state=RESULT; end
            endcase
        end
        LAUNCH_WOTS: if (wots_ready) begin n.expected=w.expected+wots_work; n.state=WAIT_WOTS; end
        WAIT_WOTS: if (wots_valid) begin n.capture={wots_value,128'd0}; n.state=TAKE_WOTS; end
        TAKE_WOTS: begin
            if (!wots_valid || wots_error!=0 || wots_tag!=context_q.tag || wots_value!=w.capture[255:128] || wots_starts!=wots_ends) begin n.error=3; n.state=RESULT; end
            else begin n.node=w.capture[255:128]; n.cursor=w.cursor+560; n.phase=TREE; n.state=READ; end
        end
        default: begin end
        endcase
    end
    // Separate next-state derivation reads only the encoded workspace/context,
    // with inverse counters decremented independently of primary increments.
    always_comb begin
        audit_n=audit_w;
        if (start_o) audit_n.starts=~(wi.starts-16'(1));
        if (complete_o) audit_n.ends=~(wi.ends-16'(1));
        case (audit_w.state)
        CHECK: begin
            if (audit_context.signature_length!=7856 || audit_context.message_length>8192 ||
                (audit_context.internal_mode && audit_context.context_length!=0) || audit_context.sealed_length<7856 || audit_context.sealed_length>8500 ||
                (audit_context.sealed_length!=7856 && (audit_context.sealed_length<7860 || (audit_context.sealed_length-14'd7860)%32!=0))) begin audit_n.error=1; audit_n.state=RESULT; end
            else audit_n.state=READ;
        end
        // R, each FORS secret/path, and each XMSS path are streamed one double-sampled byte at a time.
        READ: begin
            if (!read_valid_i) begin
                audit_n.stall=~(wi.stall-11'(1));
                if (audit_w.stall==1023) begin audit_n.error=2; audit_n.state=RESULT; end
            end else begin
                audit_n.stall=0;
                if (!audit_w.repeat_read) begin audit_n.sample=read_data_i; audit_n.repeat_read=1; end
                else if (read_data_i!=audit_w.sample) begin audit_n.error=3; audit_n.state=RESULT; end
                else begin
                    audit_n.repeat_read=0; audit_n.cursor=~(wi.cursor-14'(1)); audit_n.byte_index=~(wi.byte_index-4'(1));
                    if (audit_w.phase==RANDOM) audit_n.randomizer={audit_w.randomizer[119:0],audit_w.sample};
                    else if (audit_w.phase==FORS_LEAF) audit_n.node={audit_w.node[119:0],audit_w.sample};
                    else audit_n.sibling={audit_w.sibling[119:0],audit_w.sample};
                    if (audit_w.byte_index==15) begin
                        if (audit_w.phase==RANDOM) audit_n.phase=INNER;
                        audit_n.state=LAUNCH;
                    end
                end
            end
        end
        LAUNCH: if (hash_ready) begin
            audit_n.expected=~(wi.expected-16'((audit_w.phase==PREFIX ? 16'd1 : 16'((audit_hash_length+32'd72)>>6)))); audit_n.state=WAIT_HASH;
        end
        WAIT_HASH: if (hash_valid) begin audit_n.capture=digest; audit_n.state=TAKE; end
        // The child retains its response while this independent capture is compared before use.
        TAKE: begin
            if (!hash_valid || hash_error!=0 || audit_w.capture!=digest) begin audit_n.error=3; audit_n.state=RESULT; end
            else case (audit_w.phase)
            INNER: begin audit_n.inner=audit_w.capture; audit_n.phase=MASK; audit_n.state=LAUNCH; end
            // FIPS consumes only 30 mask bytes; discard the specified unused high tree/leaf bits.
            MASK: begin
                audit_n.md=audit_w.capture[255:88]; audit_n.tree=audit_w.capture[85:32]; audit_n.leaf=audit_w.capture[24:16];
                audit_n.index=audit_w.capture[255:244]; audit_n.global_index={4'd0,audit_w.capture[255:244]}; audit_n.phase=PREFIX; audit_n.state=LAUNCH;
            end
            PREFIX: begin audit_n.prefix=audit_w.capture; audit_n.phase=FORS_LEAF; audit_n.state=READ; end
            FORS_LEAF: begin audit_n.node=audit_w.capture[255:128]; audit_n.phase=FORS_PATH; audit_n.state=READ; end
            // Finish a tree before adding its root to the protected fourteen-entry workspace.
            FORS_PATH: begin
                audit_n.node=audit_w.capture[255:128]; audit_n.global_index=audit_w.global_index>>1;
                if (audit_w.height==11) begin
                    audit_n.roots[1791-int'(audit_w.forest)*128 -: 128]=audit_w.capture[255:128]; audit_n.height=0;
                    if (audit_w.forest==13) begin audit_n.phase=FORS_PK; audit_n.state=LAUNCH; end
                    else begin
                        audit_n.forest=~(wi.forest-4'(1)); audit_n.index=audit_w.md[167-(int'(audit_w.forest)+1)*12 -: 12];
                        audit_n.global_index={audit_w.forest+4'd1,audit_w.md[167-(int'(audit_w.forest)+1)*12 -: 12]}; audit_n.phase=FORS_LEAF; audit_n.state=READ;
                    end
                end else begin audit_n.height=~(wi.height-4'(1)); audit_n.state=READ; end
            end
            FORS_PK: begin audit_n.node=audit_w.capture[255:128]; audit_n.phase=WOTS; audit_n.state=LAUNCH_WOTS; end
            // A completed XMSS root becomes the next layer message; advance its address by nine bits.
            TREE: begin
                audit_n.node=audit_w.capture[255:128]; audit_n.height=~(wi.height-4'(1));
                if (audit_w.height==8) begin
                    if (audit_w.layer==6) begin audit_n.state=RESULT; end
                    else begin audit_n.layer=~(wi.layer-4'(1)); audit_n.leaf=audit_w.tree[8:0]; audit_n.tree=audit_w.tree>>9; audit_n.height=0; audit_n.phase=WOTS; audit_n.state=LAUNCH_WOTS; end
                end else audit_n.state=READ;
            end
            default: begin audit_n.error=3; audit_n.state=RESULT; end
            endcase
        end
        LAUNCH_WOTS: if (wots_ready) begin audit_n.expected=~(wi.expected-16'(audit_wots_work)); audit_n.state=WAIT_WOTS; end
        WAIT_WOTS: if (wots_valid) begin audit_n.capture={wots_value,128'd0}; audit_n.state=TAKE_WOTS; end
        TAKE_WOTS: begin
            if (!wots_valid || wots_error!=0 || wots_tag!=audit_context.tag || wots_value!=audit_w.capture[255:128] || wots_starts!=wots_ends) begin audit_n.error=3; audit_n.state=RESULT; end
            else begin audit_n.node=audit_w.capture[255:128]; audit_n.cursor=~(wi.cursor-14'(560)); audit_n.phase=TREE; audit_n.state=READ; end
        end
        default: begin end
        endcase
    end
    // Trusted reset clears sticky failure. Cancellation/result consumption erase only owned request state.
    // Complementary scratch/context has independent state admission and a
    // later capture edge. It does not consume primary req_ready or next scratch.
    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin wi<='1; wi.state<=~IDLE; wi.phase<=~RANDOM; context_inv_q<='1; end
        else if (cancel_i || (wi.state==~RESULT && rsp_ready_i)) begin
            wi<='1; wi.state<=~IDLE; wi.phase<=~RANDOM; context_inv_q<='1;
        end else if (bad || hash_fault || wots_fault) begin
            wi<='1; wi.state<=~RESULT; wi.phase<=~RANDOM; wi.error<=~2'd3;
        end else if (req_valid_i && wi.state==~IDLE && !failed_q && !cancel_i) wi.state<=~CHECK;
        else begin
            wi<=~audit_n;
            if (wi.state==~CHECK) context_inv_q<=~{public_key_i,internal_i,context_length_i,message_length_i,signature_length_i,sealed_length_i,tag_i};
        end
    end
    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin w<='0; w.state<=IDLE; w.phase<=RANDOM; context_q<='0; failed_q<=0; end
        else if (cancel_i || (w.state==RESULT && rsp_ready_i)) begin
            w<='0; w.state<=IDLE; w.phase<=RANDOM; context_q<='0;
            failed_q<=failed_q || bad || hash_fault || wots_fault;
        end else if (bad || hash_fault || wots_fault) begin
            w<='0; w.state<=RESULT; w.phase<=RANDOM; w.error<=3; failed_q<=1;
        end else if (req_valid_i && req_ready_o) begin
            w.state<=CHECK;
            context_q<={public_key_i,internal_i,context_length_i,message_length_i,signature_length_i,sealed_length_i,tag_i};

        end else begin
            w<=n;
            if (n.error==2 || n.error==3 || audit_n.error==2 || audit_n.error==3) failed_q<=1;
        end
    end
endmodule
`default_nettype wire
