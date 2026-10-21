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
    input logic draw_valid_i,                  // Trusted R06 request for a subsequent round.
    output logic draw_ready_o, draw_rejected_o,// Capture availability / invalid schedule diagnostic.
    input logic [63:0] draw_round_i, draw_issue_i, // Caller supplies the fixed R06 issue schedule.
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
    output logic [63:0] nonce_round_o, nonce_issue_o, nonce_generation_o,
    output logic history_valid_o,             // Inspection: retained preceding sampled nonce exists.
    output logic invalidate_o                  // One-cycle invalidation of downstream pending work.
);
    localparam logic [127:0] LABEL="REINS-ENTROPY-v1";
    typedef enum logic [2:0] {IDLE, WAIT_ISSUE, ACQUIRE, HASH_REQUEST, HASH_BYTES, HASH_RESULT, PUBLISHED} phase_t;
    phase_t phase_q;                          // One live draw; no queued or prefetched candidates.
    logic hold_q, cold_pending_q, active_q, nonce_valid_q; // Stored hold, clearing eligibility, run, result.
    logic [383:0] raw_a_q, raw_b_q;             // Fixed fresh buffers, MSB-first accepted bits.
    logic [255:0] previous_q;                  // Repeat history survives warm AND recognized cold.
    logic [63:0] capture_start_q, deadline_q;   // Actual acquisition start and fixed I+W deadline.
    logic [7:0] index_q;                       // Cursor over the 124-byte conditioner frame.
    logic [64:0] proposed_deadline;            // Widened I+W detects carry before storing B.
    logic new_draw, schedule_valid, draw_expired;
    logic sha_req_ready, sha_byte_ready, sha_rsp_valid;
    logic [255:0] sha_digest;
    logic [31:0] sha_tag;
    logic [1:0] sha_error;

    // A fresh draw must finish within its fixed window. Detect expiration at
    // the live boundary as well as storing it, including a concurrent reset.
    assign draw_expired=active_q && phase_q!=IDLE && phase_q!=PUBLISHED && now_i>=deadline_q;
    assign hold_o=hold_q || (monitor_i && source_failure_i) || draw_expired;
    assign cold_eligible_o=cold_pending_q;
    assign startup_allowed_o=!hold_q || cold_pending_q;
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
    // Dedicated conditioner SHA; reset atomically cancels any old draw's completion.
    sha256_message #(.MAX_MESSAGE_BYTES(124)) conditioner (
        .clk_i(clk_i), .rst_ni(por_ni && !cold_reset_i && !warm_reset_i && !cancel_i && !run_start_i && !new_draw &&
            (!hold_q || cold_pending_q) && !(monitor_i && source_failure_i) && !draw_expired),
        .req_valid_i(phase_q==HASH_REQUEST), .req_ready_o(sha_req_ready),
        .req_length_i(32'd124), .req_tag_i(32'h454e5431),
        .byte_valid_i(phase_q==HASH_BYTES), .byte_ready_o(sha_byte_ready), .byte_i(frame_byte(index_q)),
        .rsp_valid_o(sha_rsp_valid), .rsp_ready_i(phase_q==HASH_RESULT),
        .rsp_digest_o(sha_digest), .rsp_tag_o(sha_tag), .rsp_error_o(sha_error)
    );
    always_ff @(posedge clk_i) begin
        if (!por_ni) begin
            phase_q<=IDLE; hold_q<=1'b1; cold_pending_q<=1'b1; active_q<=1'b0;
            raw_a_q<='0; raw_b_q<='0; previous_q<='0; history_valid_o<=1'b0;
            a_count_o<='0; b_count_o<='0; capture_start_q<='0; deadline_q<='0; index_q<='0;
            nonce_valid_q<=1'b0; nonce_o<='0; nonce_round_o<='0; nonce_issue_o<='0;
            nonce_generation_o<='0; invalidate_o<=1'b1; draw_rejected_o<=1'b0;
        end else begin
            invalidate_o<=1'b0; draw_rejected_o<=1'b0;
            if (cold_reset_i || warm_reset_i || cancel_i) begin
                phase_q<=IDLE; active_q<=1'b0; nonce_valid_q<=1'b0;
                raw_a_q<='0; raw_b_q<='0; a_count_o<='0; b_count_o<='0; index_q<='0;
                invalidate_o<=1'b1;
                cold_pending_q<=cold_reset_i;
                if (cold_reset_i) hold_q<=1'b1;
                else if ((monitor_i && source_failure_i) || draw_expired) hold_q<=1'b1;
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
                    HASH_RESULT: if (sha_rsp_valid) begin
                        if (sha_error!=0 || sha_tag!=32'h454e5431 || (history_valid_o && sha_digest==previous_q)) begin
                            hold_q<=1'b1; cold_pending_q<=1'b0; nonce_valid_q<=1'b0; invalidate_o<=1'b1; phase_q<=IDLE;
                            raw_a_q<='0; raw_b_q<='0; a_count_o<='0; b_count_o<='0;
                        end else begin
                            previous_q<=sha_digest; history_valid_o<=1'b1; nonce_o<=sha_digest;
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
