// Copyright (c) 2026 Todd Austin.
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// License: https://polyformproject.org/licenses/noncommercial/1.0.0/

// Fresh per-round acquisition and SHA-256 conditioning for simulation profile 1.
// No DRBG/pool: both 384-bit buffers are cleared at each draw and cancellation.
// Source counts/cutoffs are digital research settings, not physical entropy claims.
`default_nettype none
module reins_entropy (
    input logic clk_i, por_ni,                  // Power reset loses volatile nonce history.
    input logic cold_reset_i, warm_reset_i,    // Recognized cold may requalify; warm cannot clear hold.
    input logic cancel_i, monitor_i,           // Context loss / source monitoring active.
    input logic source_failure_i,              // Immediate digital health/availability failure.
    input logic run_start_i,                   // Full OTP/time/source startup checks have passed.
    input logic [63:0] now_i, generation_i, window_i, // Trusted local time, identity and W.
    input logic tick_i,                       // This monitor edge advances trusted time by one.
    input logic draw_valid_i,                  // Trusted CONTROLLER request for a subsequent round.
    output logic draw_ready_o, draw_rejected_o,// Capture availability / invalid schedule diagnostic.
    input logic [63:0] draw_round_i, draw_issue_i, // Caller supplies the fixed CONTROLLER issue schedule.
    input logic a_valid_i, a_bit_i,             // New source A event, not a queued host byte.
    input logic [63:0] a_time_i,                // Trusted acquisition tick, stamped before any queue.
    input logic b_valid_i, b_bit_i,             // Independent source B event.
    input logic [63:0] b_time_i,                // Trusted acquisition tick for B.
    output logic a_request_o, b_request_o,     // Acquire fresh events only for the active draw.
    output logic [8:0] a_count_o, b_count_o,    // Accepted raw bits; never an entropy estimate.
    output logic hold_o, cold_eligible_o,       // Sticky effective hold / cold qualification eligibility.
    output logic startup_allowed_o,            // Stored reset policy; independent of live source pins.
    output logic nonce_valid_o,                // Current nonce retained until ready or cancellation.
    input logic nonce_ready_i,                 // Trusted consumer captures the published nonce.
    output logic [255:0] nonce_o,              // Conditioned nonce; no result bypass exists.
    output logic [255:0] nonce_audit_o,        // Complemented result from a separate conditioner and later capture.
    output logic [63:0] nonce_round_o, nonce_issue_o, nonce_generation_o,
    output logic history_valid_o,             // Inspection: retained preceding sampled nonce exists.
    output logic invalidate_o,                 // One-cycle invalidation of downstream pending work.
    output logic integrity_fault_o             // Internal corruption is a general fault, distinct from source hold.
);
    localparam logic [127:0] LABEL="REINS-ENTROPY-v1";
    typedef enum logic [7:0] {IDLE=8'h0f, WAIT_ISSUE=8'h33, ACQUIRE=8'h55, HASH_REQUEST=8'h69,
        HASH_BYTES=8'h96, HASH_RESULT=8'haa, PUBLISHED=8'hcc, HASH_AUDIT=8'hf0} phase_t;
    phase_t phase_q;                          // One live draw; no queued or prefetched candidates.
    (* keep="true", dont_touch="true" *) logic [7:0] phase_inverse_q;
    logic [7:0] inverse_next;                 // Independent audit-phase decoder.
    logic hold_q, cold_pending_q, active_q, nonce_valid_q; // Stored hold, clearing eligibility, run, result.
    logic [383:0] raw_a_q, raw_b_q;             // Fixed fresh buffers, MSB-first accepted bits.
    logic [255:0] previous_q;                  // Repeat history survives warm AND recognized cold.
    logic [63:0] capture_start_q, deadline_q;   // Actual acquisition start and fixed I+W deadline.
    logic [7:0] index_q;                       // Cursor over the 124-byte conditioner frame.
    (* keep="true", dont_touch="true" *) logic [383:0] raw_a_inverse_q, raw_b_inverse_q;
    (* keep="true", dont_touch="true" *) logic [255:0] previous_inverse_q;
    logic [8:0] a_count_inverse_q, b_count_inverse_q;
    logic [7:0] index_inverse_q;
    logic [63:0] capture_start_inverse_q, deadline_inverse_q, round_inverse_q, issue_inverse_q, generation_inverse_q;
    logic hold_inverse_q, cold_inverse_q, active_inverse_q, valid_inverse_q, history_inverse_q;
    logic integrity_q, storage_bad, digest_bad, audit_valid, audit_req_ready, audit_byte_ready;
    logic [255:0] audit_digest;
    logic [31:0] audit_tag;
    logic [1:0] audit_error;
    logic [64:0] proposed_deadline;            // Widened I+W detects carry before storing B.
    logic new_draw, schedule_valid, draw_expired;
    logic sha_req_ready, sha_byte_ready, sha_rsp_valid;
    logic [255:0] sha_digest;
    logic [31:0] sha_tag;
    logic [1:0] sha_error;

    // A fresh draw must finish within its fixed window. Detect expiration at
    // the live boundary as well as storing it, including a concurrent reset.
    assign draw_expired=active_q && phase_q!=IDLE && phase_q!=PUBLISHED &&
        ({1'b0,now_i}+65'(tick_i))>={1'b0,deadline_q};
    assign storage_bad=phase_q!=~phase_inverse_q ||
        !(phase_q==IDLE || phase_q==WAIT_ISSUE || phase_q==ACQUIRE || phase_q==HASH_REQUEST ||
          phase_q==HASH_BYTES || phase_q==HASH_RESULT || phase_q==HASH_AUDIT || phase_q==PUBLISHED) ||
        raw_a_q!=~raw_a_inverse_q || raw_b_q!=~raw_b_inverse_q || previous_q!=~previous_inverse_q ||
        a_count_o!=~a_count_inverse_q || b_count_o!=~b_count_inverse_q || index_q!=~index_inverse_q ||
        capture_start_q!=~capture_start_inverse_q || deadline_q!=~deadline_inverse_q ||
        nonce_round_o!=~round_inverse_q || nonce_issue_o!=~issue_inverse_q || nonce_generation_o!=~generation_inverse_q ||
        hold_q==hold_inverse_q || cold_pending_q==cold_inverse_q || active_q==active_inverse_q ||
        nonce_valid_q==valid_inverse_q || history_valid_o==history_inverse_q ||
        (nonce_valid_q && nonce_o!=~nonce_audit_o);
    assign integrity_fault_o=por_ni && (integrity_q || storage_bad);
    assign digest_bad=sha_error!=0 || audit_error!=0 || sha_tag!=32'h454e5431 || audit_tag!=32'h454e5431 ||
        sha_digest!=audit_digest || (history_valid_o && (sha_digest==previous_q || audit_digest==~previous_inverse_q));
    assign hold_o=hold_q || (monitor_i && source_failure_i) || draw_expired || integrity_fault_o;
    assign cold_eligible_o=cold_pending_q;
    assign startup_allowed_o=(!hold_q || cold_pending_q) && !integrity_fault_o;
    assign draw_ready_o=por_ni && !cold_reset_i && !warm_reset_i && !cancel_i && monitor_i && active_q && !hold_o;
    assign proposed_deadline={1'b0,draw_issue_i}+{1'b0,window_i};
    assign schedule_valid=draw_round_i>nonce_round_o && draw_issue_i>nonce_issue_o &&
        !proposed_deadline[64] && window_i!=0 && now_i<proposed_deadline[63:0];
    assign new_draw=draw_valid_i && draw_ready_o && schedule_valid;
    assign a_request_o=phase_q==ACQUIRE && a_count_o<384 && (!hold_q || cold_pending_q) && !cancel_i && !draw_expired;
    assign b_request_o=phase_q==ACQUIRE && b_count_o<384 && (!hold_q || cold_pending_q) && !cancel_i && !draw_expired;
    assign nonce_valid_o=nonce_valid_q && now_i<deadline_q && !hold_o && !cold_reset_i && !warm_reset_i && !cancel_i && por_ni;

    // Return byte address of the fixed, explicitly domain-separated conditioner frame.
    // Encoding: label[16], BE32(profile=1), BE32(A=384), BE32(B=384), A[48], B[48].
    function automatic logic [7:0] frame_byte(input logic [7:0] address);
        if (address<16) return LABEL[127-8*int'(address) -: 8];
        if (address<20) return address==19 ? 8'd1 : 8'd0;
        if (address<28) begin
            case (address)
                22,26: return 8'h01;
                23,27: return 8'h80;
                default: return 8'h00;
            endcase
        end
        if (address<76) return raw_a_q[383-8*(int'(address)-28) -: 8];
        return raw_b_q[383-8*(int'(address)-76) -: 8];
    endfunction
    // Audit builder reads only separately maintained complemented raw storage/cursor.
    // It does not consume frame_byte's mux, output or byte index.
    function automatic logic [7:0] audit_frame_byte(input logic [7:0] inverse_address);
        logic [7:0] address;
        address=~inverse_address;
        if (address<16) return LABEL[127-8*int'(address) -: 8];
        case (address)
            19: return 8'd1;
            22,26: return 8'h01;
            23,27: return 8'h80;
            default: begin
                if (address<28) return 8'd0;
                if (address<76) return ~raw_a_inverse_q[383-8*(int'(address)-28) -: 8];
                return ~raw_b_inverse_q[383-8*(int'(address)-76) -: 8];
            end
        endcase
    endfunction
    // Dedicated independent conditioners. Physical tools must preserve these
    // marked instances/rails and independent source routes; attributes alone are not signoff.
    logic unused_compression_start, unused_compression_complete; // Passive core events unused by this client.
    (* keep_hierarchy="yes", dont_touch="true" *) sha256_message #(.MAX_MESSAGE_BYTES(124)) conditioner (
        .clk_i(clk_i), .rst_ni(por_ni && !cold_reset_i && !warm_reset_i && !cancel_i && !run_start_i && !new_draw &&
            (!hold_q || cold_pending_q) && !(monitor_i && source_failure_i) && !draw_expired),
        .req_valid_i(phase_q==HASH_REQUEST), .req_ready_o(sha_req_ready),
        .req_length_i(32'd124), .req_tag_i(32'h454e5431),
        .byte_valid_i(phase_q==HASH_BYTES), .byte_ready_o(sha_byte_ready), .byte_i(frame_byte(index_q)),
        .rsp_valid_o(sha_rsp_valid), .rsp_ready_i(phase_q==HASH_AUDIT),
        .rsp_digest_o(sha_digest), .rsp_tag_o(sha_tag), .rsp_error_o(sha_error),
        .compression_start_o(unused_compression_start), .compression_complete_o(unused_compression_complete)
    );
    logic unused_audit_start, unused_audit_end;
    (* keep_hierarchy="yes", dont_touch="true" *) sha256_message #(.MAX_MESSAGE_BYTES(124)) audit_conditioner (
        .clk_i(clk_i),.rst_ni(por_ni && !cold_reset_i && !warm_reset_i && !cancel_i && !run_start_i && !new_draw &&
            (hold_inverse_q || !cold_inverse_q) && !(monitor_i && source_failure_i) && !draw_expired && !integrity_q),
        .req_valid_i(phase_inverse_q==~HASH_REQUEST),.req_ready_o(audit_req_ready),
        .req_length_i(32'd124),.req_tag_i(32'h454e5431),
        .byte_valid_i(phase_inverse_q==~HASH_BYTES),.byte_ready_o(audit_byte_ready),.byte_i(audit_frame_byte(index_inverse_q)),
        .rsp_valid_o(audit_valid),.rsp_ready_i(phase_inverse_q==~HASH_AUDIT),
        .rsp_digest_o(audit_digest),.rsp_tag_o(audit_tag),.rsp_error_o(audit_error),
        .compression_start_o(unused_audit_start),.compression_complete_o(unused_audit_end)
    );
    // Secondary rail evaluates source events, bounds and SHA hand-offs from its
    // own encoded state. No primary request-enable, cursor next value or digest
    // capture register supplies this path's updates.
    always_comb begin
        inverse_next=phase_inverse_q;
        case (phase_inverse_q)
        ~WAIT_ISSUE: if (now_i>=(~issue_inverse_q)) inverse_next=~ACQUIRE;
        ~ACQUIRE: if (a_count_inverse_q==~9'd384 && b_count_inverse_q==~9'd384) inverse_next=~HASH_REQUEST;
        ~HASH_REQUEST: if (audit_req_ready) inverse_next=~HASH_BYTES;
        ~HASH_BYTES: if (audit_byte_ready && index_inverse_q==~8'd123) inverse_next=~HASH_RESULT;
        ~HASH_RESULT: if (audit_valid && sha_rsp_valid) inverse_next=~HASH_AUDIT;
        ~HASH_AUDIT: if (audit_valid && sha_rsp_valid) inverse_next=~PUBLISHED;
        ~PUBLISHED: if (now_i>=(~deadline_inverse_q)) inverse_next=~IDLE;
        default: begin end
        endcase
    end
    always_ff @(posedge clk_i) begin
        if (!por_ni) begin
            phase_inverse_q<=~IDLE; raw_a_inverse_q<='1; raw_b_inverse_q<='1; previous_inverse_q<='1;
            a_count_inverse_q<='1; b_count_inverse_q<='1; index_inverse_q<='1;
            capture_start_inverse_q<='1; deadline_inverse_q<='1; round_inverse_q<='1; issue_inverse_q<='1; generation_inverse_q<='1;
            hold_inverse_q<=0; cold_inverse_q<=0; active_inverse_q<=1; valid_inverse_q<=1; history_inverse_q<=1; nonce_audit_o<='1;
        end else if (cold_reset_i || warm_reset_i || cancel_i) begin
            phase_inverse_q<=~IDLE; active_inverse_q<=1; valid_inverse_q<=1;
            raw_a_inverse_q<='1; raw_b_inverse_q<='1; a_count_inverse_q<='1; b_count_inverse_q<='1; index_inverse_q<='1;
            cold_inverse_q<=!cold_reset_i;
            if (cold_reset_i || (monitor_i && source_failure_i) || draw_expired) hold_inverse_q<=0;
        end else if (integrity_fault_o || (monitor_i && source_failure_i) || draw_expired) begin
            phase_inverse_q<=~IDLE; hold_inverse_q<=0; cold_inverse_q<=1; valid_inverse_q<=1;
            raw_a_inverse_q<='1; raw_b_inverse_q<='1; a_count_inverse_q<='1; b_count_inverse_q<='1;
        end else if (run_start_i || new_draw) begin
            phase_inverse_q<=~WAIT_ISSUE; active_inverse_q<=0; valid_inverse_q<=1;
            raw_a_inverse_q<='1; raw_b_inverse_q<='1; a_count_inverse_q<='1; b_count_inverse_q<='1; index_inverse_q<='1;
            round_inverse_q<=run_start_i ? ~64'd1 : ~draw_round_i;
            issue_inverse_q<=run_start_i ? ~64'd0 : ~draw_issue_i;
            generation_inverse_q<=~generation_i;
            deadline_inverse_q<=run_start_i ? ~window_i : ~(draw_issue_i+window_i);
        end else begin
            phase_inverse_q<=inverse_next;
            if (!valid_inverse_q && nonce_ready_i) valid_inverse_q<=1;
            if (phase_inverse_q==~PUBLISHED && now_i>=(~deadline_inverse_q)) valid_inverse_q<=1;
            case (phase_inverse_q)
            ~WAIT_ISSUE: if (now_i>=(~issue_inverse_q)) capture_start_inverse_q<=~now_i;
            ~ACQUIRE: begin
                if (a_count_inverse_q>~9'd384 && (hold_inverse_q || !cold_inverse_q) && a_valid_i &&
                    a_time_i>=(~capture_start_inverse_q) && a_time_i<=now_i) begin
                    raw_a_inverse_q[383-int'(9'(~a_count_inverse_q))]<=!a_bit_i;
                    a_count_inverse_q<=a_count_inverse_q-9'd1;
                end
                if (b_count_inverse_q>~9'd384 && (hold_inverse_q || !cold_inverse_q) && b_valid_i &&
                    b_time_i>=(~capture_start_inverse_q) && b_time_i<=now_i) begin
                    raw_b_inverse_q[383-int'(9'(~b_count_inverse_q))]<=!b_bit_i;
                    b_count_inverse_q<=b_count_inverse_q-9'd1;
                end
                if (a_count_inverse_q==~9'd384 && b_count_inverse_q==~9'd384) index_inverse_q<='1;
            end
            ~HASH_BYTES: if (audit_byte_ready && index_inverse_q!=~8'd123) index_inverse_q<=index_inverse_q-8'd1;
            ~HASH_RESULT: if (audit_valid && sha_rsp_valid &&
                (audit_error!=0 || sha_error!=0 || audit_tag!=32'h454e5431 || sha_tag!=32'h454e5431 ||
                 (|(audit_digest ^ sha_digest)) || (!history_inverse_q && (|(audit_digest ^ ~previous_inverse_q))==0))) begin
                phase_inverse_q<=~IDLE; hold_inverse_q<=0; cold_inverse_q<=1; valid_inverse_q<=1;
                raw_a_inverse_q<='1; raw_b_inverse_q<='1; a_count_inverse_q<='1; b_count_inverse_q<='1;
            end
            ~HASH_AUDIT: if (audit_valid && sha_rsp_valid) begin
                if (audit_error!=0 || sha_error!=0 || (|(audit_digest ^ nonce_o)) || (|(sha_digest ^ nonce_o)) ||
                    audit_tag!=32'h454e5431 || sha_tag!=32'h454e5431) begin
                    phase_inverse_q<=~IDLE; hold_inverse_q<=0; cold_inverse_q<=1; valid_inverse_q<=1;
                end else begin
                    nonce_audit_o<=~audit_digest; previous_inverse_q<=~audit_digest;
                    history_inverse_q<=0; valid_inverse_q<=0;
                    if (!cold_inverse_q && round_inverse_q==~64'd1) begin hold_inverse_q<=1; cold_inverse_q<=1; end
                end
            end
            default: begin end
            endcase
        end
    end
    always_ff @(posedge clk_i) begin
        if (!por_ni) begin
            phase_q<=IDLE; hold_q<=1'b1; cold_pending_q<=1'b1; active_q<=1'b0;
            raw_a_q<='0; raw_b_q<='0; previous_q<='0; history_valid_o<=1'b0;
            a_count_o<='0; b_count_o<='0; capture_start_q<='0; deadline_q<='0; index_q<='0;
            nonce_valid_q<=1'b0; nonce_o<='0; nonce_round_o<='0; nonce_issue_o<='0;
            nonce_generation_o<='0; invalidate_o<=1'b1; draw_rejected_o<=1'b0; integrity_q<=0;
        end else begin
            invalidate_o<=1'b0; draw_rejected_o<=1'b0;
            if (cold_reset_i || warm_reset_i || cancel_i) begin
                phase_q<=IDLE; active_q<=1'b0; nonce_valid_q<=1'b0;
                raw_a_q<='0; raw_b_q<='0; a_count_o<='0; b_count_o<='0; index_q<='0;
                invalidate_o<=1'b1;
                cold_pending_q<=cold_reset_i;
                if (cold_reset_i) hold_q<=1'b1;
                else if ((monitor_i && source_failure_i) || draw_expired) hold_q<=1'b1;
                if (cold_reset_i) integrity_q<=0;
                else if (storage_bad) integrity_q<=1;
            end else if (integrity_fault_o) begin
                integrity_q<=1; phase_q<=IDLE; hold_q<=1; cold_pending_q<=0; nonce_valid_q<=0;
                raw_a_q<=0; raw_b_q<=0; a_count_o<=0; b_count_o<=0; invalidate_o<=1;
            end else if (monitor_i && source_failure_i) begin
                hold_q<=1'b1; cold_pending_q<=1'b0; phase_q<=IDLE; nonce_valid_q<=1'b0;
                raw_a_q<='0; raw_b_q<='0; a_count_o<='0; b_count_o<='0;
                if (!hold_q || phase_q!=IDLE) invalidate_o<=1'b1;
            end else if (run_start_i || new_draw) begin
                phase_q<=WAIT_ISSUE; active_q<=1'b1; nonce_valid_q<=1'b0;
                raw_a_q<='0; raw_b_q<='0; a_count_o<='0; b_count_o<='0; index_q<='0;
                nonce_round_o<=run_start_i ? 64'd1 : draw_round_i;
                nonce_issue_o<=run_start_i ? 64'd0 : draw_issue_i;
                nonce_generation_o<=generation_i;
                deadline_q<=run_start_i ? window_i : proposed_deadline[63:0];
                invalidate_o<=1'b1;
            end else begin
                if (draw_valid_i && draw_ready_o && !schedule_valid) draw_rejected_o<=1'b1;
                if (nonce_valid_q && nonce_ready_i) nonce_valid_q<=1'b0;
                if (phase_q==PUBLISHED && now_i>=deadline_q) begin
                    nonce_valid_q<=1'b0; phase_q<=IDLE; invalidate_o<=1'b1;
                end
                if (draw_expired) begin
                    hold_q<=1'b1; cold_pending_q<=1'b0; phase_q<=IDLE; nonce_valid_q<=1'b0; invalidate_o<=1'b1;
                    raw_a_q<='0; raw_b_q<='0; a_count_o<='0; b_count_o<='0;
                end else case (phase_q)
                    WAIT_ISSUE: if (now_i>=nonce_issue_o) begin capture_start_q<=now_i; phase_q<=ACQUIRE; end
                    ACQUIRE: begin
                        if (a_request_o && a_valid_i && a_time_i>=capture_start_q && a_time_i<=now_i) begin
                            raw_a_q[383-int'(a_count_o)]<=a_bit_i; a_count_o<=a_count_o+9'd1;
                        end
                        if (b_request_o && b_valid_i && b_time_i>=capture_start_q && b_time_i<=now_i) begin
                            raw_b_q[383-int'(b_count_o)]<=b_bit_i; b_count_o<=b_count_o+9'd1;
                        end
                        if (a_count_o==384 && b_count_o==384) begin index_q<='0; phase_q<=HASH_REQUEST; end
                    end
                    HASH_REQUEST: if (sha_req_ready) phase_q<=HASH_BYTES;
                    HASH_BYTES: if (sha_byte_ready) begin
                        if (index_q==123) phase_q<=HASH_RESULT;
                        else index_q<=index_q+8'd1;
                    end
                    HASH_RESULT: if (sha_rsp_valid && audit_valid) begin
                        if (digest_bad) begin
                            hold_q<=1'b1; cold_pending_q<=1'b0; nonce_valid_q<=1'b0; invalidate_o<=1'b1; phase_q<=IDLE;
                            raw_a_q<='0; raw_b_q<='0; a_count_o<='0; b_count_o<='0;
                            // An actual repeated nonce is entropy hold; independent SHA disagreement is integrity failure.
                            if (sha_error!=0 || audit_error!=0 || sha_tag!=32'h454e5431 || audit_tag!=32'h454e5431 || sha_digest!=audit_digest) integrity_q<=1;
                        end else begin
                            nonce_o<=sha_digest; phase_q<=HASH_AUDIT;
                        end
                    end
                    HASH_AUDIT: if (sha_rsp_valid && audit_valid) begin
                        if (digest_bad || nonce_o!=sha_digest || nonce_o!=audit_digest) begin
                            integrity_q<=1; nonce_valid_q<=0; phase_q<=IDLE; hold_q<=1; cold_pending_q<=0; invalidate_o<=1;
                        end else begin
                            previous_q<=nonce_o; history_valid_o<=1'b1;
                            nonce_valid_q<=1'b1; phase_q<=PUBLISHED;
                            if (cold_pending_q && nonce_round_o==1) begin hold_q<=1'b0; cold_pending_q<=1'b0; end
                        end
                    end
                    default: begin end
                endcase
            end
        end
    end
`ifndef SYNTHESIS
    assert property (@(posedge clk_i) disable iff (!por_ni)
        nonce_valid_o |-> !hold_o && history_valid_o && a_count_o==384 && b_count_o==384);
`endif
endmodule
`default_nettype wire
