// Copyright (c) 2026 Todd Austin.
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// License: https://polyformproject.org/licenses/noncommercial/1.0.0/

// Iterative FIPS 180-4 SHA-256 compression, one round per clock.
// First-party REINS implementation; distributed under the repository LICENSE.
// A request captures all eight chaining words and all sixteen message words.
// The response appears 64 rising edges after acceptance and remains until taken.
`default_nettype none
module sha256_compress (
    input  logic         clk_i,        // All transfers occur on the rising edge.
    input  logic         rst_ni,       // Synchronous active-low reset cancels work/results.
    input  logic         req_valid_i,  // Producer holds payload stable until ready.
    output logic         req_ready_o,  // One request at a time; no completion bypass.
    input  logic [255:0] req_state_i,  // H0 in bits 255:224, through H7 in 31:0.
    input  logic [511:0] req_block_i,  // First message byte in bits 511:504 (big endian).
    input  logic [31:0]  req_tag_i,    // Opaque caller identity, captured with the block.
    output logic         rsp_valid_o,  // Result is retained while rsp_ready_i is low.
    input  logic         rsp_ready_i,  // Consumer accepts the result on valid && ready.
    output logic [255:0] rsp_state_o,  // Input state plus the 64-round working state.
    output logic [31:0]  rsp_tag_o,    // Captured request identity, unchanged by hashing.
    output logic         start_o,      // One-cycle acceptance diagnostic, not protection.
    output logic         complete_o    // One-cycle result-production diagnostic.
);
    // FIPS 180-4 section 4.2.2 constants; these are mathematical algorithm data.
    localparam logic [31:0] K [0:63] = '{
        32'h428a2f98,32'h71374491,32'hb5c0fbcf,32'he9b5dba5,32'h3956c25b,32'h59f111f1,32'h923f82a4,32'hab1c5ed5,
        32'hd807aa98,32'h12835b01,32'h243185be,32'h550c7dc3,32'h72be5d74,32'h80deb1fe,32'h9bdc06a7,32'hc19bf174,
        32'he49b69c1,32'hefbe4786,32'h0fc19dc6,32'h240ca1cc,32'h2de92c6f,32'h4a7484aa,32'h5cb0a9dc,32'h76f988da,
        32'h983e5152,32'ha831c66d,32'hb00327c8,32'hbf597fc7,32'hc6e00bf3,32'hd5a79147,32'h06ca6351,32'h14292967,
        32'h27b70a85,32'h2e1b2138,32'h4d2c6dfc,32'h53380d13,32'h650a7354,32'h766a0abb,32'h81c2c92e,32'h92722c85,
        32'ha2bfe8a1,32'ha81a664b,32'hc24b8b70,32'hc76c51a3,32'hd192e819,32'hd6990624,32'hf40e3585,32'h106aa070,
        32'h19a4c116,32'h1e376c08,32'h2748774c,32'h34b0bcb5,32'h391c0cb3,32'h4ed8aa4a,32'h5b9cca4f,32'h682e6ff3,
        32'h748f82ee,32'h78a5636f,32'h84c87814,32'h8cc70208,32'h90befffa,32'ha4506ceb,32'hbef9a3f7,32'hc67178f2
    };
    logic working_q;                  // A captured block is undergoing its 64 rounds.
    logic [5:0] round_q;              // Current round, 0..63; never used as a job identity.
    logic [31:0] base_q [0:7];        // Immutable input state for final feed-forward.
    logic [31:0] work_q [0:7];        // Current a,b,c,d,e,f,g,h working registers.
    logic [31:0] work_d [0:7];        // Next working registers after one round.
    logic [31:0] window_q [0:15];     // Sliding W[t..t+15] message schedule, 512 bits.
    logic [31:0] schedule_next;       // Newly expanded W[t+16].
    logic [31:0] t1, t2;             // Modulo-2^32 FIPS round temporaries.

    // Rotate word right by amount bits; all call sites use fixed nonzero amounts.
    function automatic logic [31:0] rotr(input logic [31:0] word, input int unsigned amount);
        return (word >> amount) | (word << (32-amount));
    endfunction

    assign req_ready_o = rst_ni && !working_q && !rsp_valid_o;
    always_comb begin
        schedule_next = (rotr(window_q[14],17) ^ rotr(window_q[14],19) ^ (window_q[14] >> 10))
                      + window_q[9]
                      + (rotr(window_q[1],7) ^ rotr(window_q[1],18) ^ (window_q[1] >> 3))
                      + window_q[0];
        t1 = work_q[7] + (rotr(work_q[4],6) ^ rotr(work_q[4],11) ^ rotr(work_q[4],25))
           + ((work_q[4] & work_q[5]) ^ (~work_q[4] & work_q[6])) + K[round_q] + window_q[0];
        t2 = (rotr(work_q[0],2) ^ rotr(work_q[0],13) ^ rotr(work_q[0],22))
           + ((work_q[0] & work_q[1]) ^ (work_q[0] & work_q[2]) ^ (work_q[1] & work_q[2]));
        work_d[0]=t1+t2; work_d[1]=work_q[0]; work_d[2]=work_q[1]; work_d[3]=work_q[2];
        work_d[4]=work_q[3]+t1; work_d[5]=work_q[4]; work_d[6]=work_q[5]; work_d[7]=work_q[6];
    end

    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
            working_q<=1'b0; round_q<='0; rsp_valid_o<=1'b0;
            rsp_state_o<='0; rsp_tag_o<='0; start_o<=1'b0; complete_o<=1'b0;
            for (int i=0;i<8;i++) begin base_q[i]<='0; work_q[i]<='0; end
            for (int i=0;i<16;i++) window_q[i]<='0;
        end else begin
            start_o<=1'b0; complete_o<=1'b0;
            if (rsp_valid_o && rsp_ready_i) rsp_valid_o<=1'b0;
            if (req_valid_i && req_ready_o) begin
                working_q<=1'b1; round_q<='0; rsp_tag_o<=req_tag_i; start_o<=1'b1;
                for (int i=0;i<8;i++) begin
                    base_q[i]<=req_state_i[255-32*i -: 32];
                    work_q[i]<=req_state_i[255-32*i -: 32];
                end
                for (int i=0;i<16;i++) window_q[i]<=req_block_i[511-32*i -: 32];
            end else if (working_q) begin
                for (int i=0;i<8;i++) work_q[i]<=work_d[i];
                for (int i=0;i<15;i++) window_q[i]<=window_q[i+1];
                window_q[15]<=schedule_next;
                if (round_q==6'd63) begin
                    for (int i=0;i<8;i++) rsp_state_o[255-32*i -: 32]<=base_q[i]+work_d[i];
                    working_q<=1'b0; rsp_valid_o<=1'b1; complete_o<=1'b1;
                end else round_q<=round_q+6'd1;
            end
        end
    end

`ifndef SYNTHESIS
    // Simulation assertion: retained output is checked separately from synthesized logic.
    // Backpressure must not erase or change a produced result, including its tag.
    assert property (@(posedge clk_i) disable iff (!rst_ni)
        rsp_valid_o && !rsp_ready_i |=> rsp_valid_o && $stable({rsp_state_o,rsp_tag_o}));
`endif
endmodule
`default_nettype wire
