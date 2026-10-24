// Copyright (c) 2026 Todd Austin.
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// License: https://polyformproject.org/licenses/noncommercial/1.0.0/

// One 9,216-byte payload array; address/owner tags and SECDED bits are overhead.
// No reset scrubs payload. The full token in every word rejects stale old rows.
// This portable array is a simulation technology wrapper, not a qualified macro.
`default_nettype none
module reins_receive_sram (
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
    localparam logic [7:0] FREE=8'h0f, RECEIVING=8'h33, SEALED=8'h55;
    logic [115:0] memory_q [0:2303] /* verilator public_flat_rw */; // Test backdoor only, never a hardware port.
    logic [7:0] state_q /* verilator public_flat_rw */;
    logic [7:0] state_inverse_q /* verilator public_flat_rw */;
    logic [63:0] owner_q, owner_inverse_q;
    logic failed_q, control_bad, write_bad, read_bad, store;
    logic [107:0] write_payload, old_payload, read_payload;
    logic [115:0] write_word, read_word;
    logic read_ok;
    logic [7:0] read_byte;

    // Encode data's payload/address/owner with seven Hamming checks and overall parity.
    function automatic logic [115:0] encode(input logic [107:0] data);
        logic [115:0] code;
        logic parity;
        int index;
        code='0; index=0;
        for (int position=1;position<=115;position++) if ((position & (position-1))!=0) begin
            code[position-1]=data[index]; index++;
        end
        for (int bit_number=0;bit_number<7;bit_number++) begin
            parity=1'b0;
            for (int position=1;position<=115;position++)
                if ((position & (1<<bit_number))!=0) parity^=code[position-1];
            code[(1<<bit_number)-1]=parity;
        end
        code[115]=^code[114:0];
        encode=code;
    endfunction
    // Extract code's data bits; callers independently reject every nonzero syndrome/parity.
    function automatic logic [107:0] decode(input logic [115:0] code);
        logic [107:0] data;
        int index;
        data='0; index=0;
        for (int position=1;position<=115;position++) if ((position & (position-1))!=0) begin
            data[index]=code[position-1]; index++;
        end
        decode=data;
    endfunction
    // Detect any single/double codeword fault in code; never silently correct bytes.
    function automatic logic corrupt(input logic [115:0] code);
        logic [6:0] syndrome;
        syndrome='0;
        for (int position=1;position<=115;position++) if (code[position-1]) syndrome^=7'(position);
        corrupt=(syndrome!=0) || (^code);
    endfunction

    assign control_bad=state_q!=~state_inverse_q || owner_q!=~owner_inverse_q ||
        !(state_q==FREE || state_q==RECEIVING || state_q==SEALED) || token_i!=~token_inverse_i ||
        (state_q!=FREE && (token_i!=owner_q || token_i==0));
    assign sealed_o=por_ni && !reset_i && state_q==SEALED && !control_bad && !failed_q;
    always_comb begin
        write_word='0; old_payload='0; write_payload='0; write_bad=1'b0;
        if (write_valid_i && !reset_i) begin
            write_bad=state_q!=RECEIVING || write_code_i!=8'hc3 ||
                write_address_i!=~write_address_inverse_i || write_address_i>=14'd9216 || control_bad;
            if (!write_bad) begin
                // First byte initializes a new row; retries may overwrite only its uncommitted suffix.
                if (write_address_i[1:0]!=0) begin
                    write_word=memory_q[write_address_i[13:2]];
                    old_payload=decode(write_word);
                    write_bad=corrupt(write_word) || old_payload[107:44]!=owner_q ||
                        old_payload[43:32]!=write_address_i[13:2];
                end
                write_payload={owner_q,write_address_i[13:2],old_payload[31:0]};
                write_payload[32'(write_address_i[1:0])*8 +: 8]=write_data_i;
            end
        end
    end
    always_comb begin
        read_word='0; read_payload='0; read_bad=1'b0; read_byte='0; read_ok=1'b0;
        if (read_valid_i && !reset_i) begin
            read_bad=!sealed_o || read_address_i!=~read_address_inverse_i || read_address_i>=14'd9216;
            if (!read_bad) begin
                read_word=memory_q[read_address_i[13:2]]; read_payload=decode(read_word);
                read_bad=corrupt(read_word) || read_payload[107:44]!=owner_q || read_payload[43:32]!=read_address_i[13:2];
                if (!read_bad) begin
                    read_byte=read_payload[32'(read_address_i[1:0])*8 +: 8]; read_ok=1'b1;
                end
            end
        end
    end
    assign read_valid_o=read_ok && !release_i && !failed_q;
    assign read_data_o=read_valid_o ? read_byte : 8'd0;
    assign fault_o=por_ni && !reset_i && (failed_q || control_bad || write_bad || read_bad);
    assign store=por_ni && !reset_i && !release_i && !seal_i && state_q==RECEIVING &&
        write_valid_i && !fault_o && write_code_i==8'hc3;
    always_ff @(posedge clk_i) begin
        write_event_o<=store;
        if (!por_ni || reset_i) begin
            state_q<=FREE; state_inverse_q<=~FREE; owner_q<='0; owner_inverse_q<='1; failed_q<=1'b0;
        end else if (fault_o) failed_q<=1'b1;
        else if (release_i) begin state_q<=FREE; state_inverse_q<=~FREE; end
        else if (acquire_i) begin
            if (state_q!=FREE || acquire_token_i==0 || acquire_token_i!=~acquire_token_inverse_i) failed_q<=1'b1;
            else begin state_q<=RECEIVING; state_inverse_q<=~RECEIVING; owner_q<=acquire_token_i; owner_inverse_q<=acquire_token_inverse_i; end
        end else if (seal_i) begin
            if (state_q!=RECEIVING) failed_q<=1'b1;
            else begin state_q<=SEALED; state_inverse_q<=~SEALED; end
        end else if (store) memory_q[write_address_i[13:2]]<=encode(write_payload);
    end
`ifndef SYNTHESIS
    assert property (@(posedge clk_i) disable iff (!por_ni || reset_i) sealed_o |-> !store);
`endif
`ifdef FORMAL
    // These properties observe the real sole store enable; payload/ECC data is outside this proof.
    logic formal_past=1'b0;
    always @(posedge clk_i) begin
        formal_past<=1'b1;
        if (!formal_past) assume(!por_ni);
        if (por_ni && !reset_i && sealed_o) assert(!store);
        if (formal_past && $past(!por_ni || reset_i || release_i || seal_i || sealed_o)) assert(!write_event_o);
    end
`endif
endmodule
`default_nettype wire
