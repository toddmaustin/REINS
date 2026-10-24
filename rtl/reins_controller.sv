// R06 operational controller. Verification ports are TRUSTED INTERNAL hardware
// boundaries, not host/SPI inputs. Only the separate simulation top exposes them
// to host cryptography. Sparse/mirrored checks here do not replace deferred R03
// independent capture, protected datapaths, placement or physical fault evidence.
`default_nettype none
module reins_controller #(
    parameter int unsigned ID_WIDTH=64,       // Powered run/token/job identities; smaller only in isolated tests.
    parameter int unsigned ROUND_WIDTH=64,    // Protocol round remains a 64-bit output.
    parameter int unsigned TIME_WIDTH=64      // Local time remains 64 bits; reduced limit only in tests.
) (
    input logic clk_i, por_ni,               // Always-on monitor clock / actual retention loss.
    input logic logic_reset_i, cold_clear_i, // Cancel authorization / trusted cold fault requalification.
    input logic config_closed_i, config_valid_i, // Retained closure / completely checked R05 snapshot.
    input logic [2175:0] configuration_i,    // Exact public OTP, immutable throughout a run.
    input logic [255:0] config_digest_i,     // Actual R05 C_cfg, checked against captured copies.
    input logic [63:0] lease_i, period_i, window_i, // Checked L/P/W in local ticks.
    input logic fault_i, entropy_failure_i, grant_enable_i, // General alarm / effective hold / R05 grants gate.
    input logic [63:0] now_i,                // Current trusted time BEFORE the clock edge.
    input logic tick_i,                     // This edge advances R05 time by one; deadlines include it.
    input logic run_begin_i,                // R05 established new tick zero/generation after qualification.
    input logic [63:0] platform_generation_i,// R05's powered run generation; strictly increases on admission.
    output logic restart_ready_o,           // Qualified stop boundary permits requesting R05 startup.
    input logic stop_ack_i,                 // Trusted enforcement acknowledgement, never a host command.
    output logic stop_request_o, run_end_o,  // Complete physical stop / pulse canceling R05's old run.
    output logic [7:0] state_o,              // Sparse public diagnostic state (documented in R06 guide).
    output logic fault_o, permit_o,          // Immediate-or-sticky fault / independently gated lease.
    output logic [63:0] run_generation_o, round_o, job_generation_o,
    output logic pending_o, request_valid_o, // One context / coherent current request publication.
    input logic [1:0] request_slot_i,        // Read slot 0..2; invalid slot never publishes.
    output logic [1023:0] request_o,         // Exact 128 bytes, byte zero in bits 1023:1016.
    output logic [63:0] issue_o, deadline_o, proposed_expiry_o, // Fixed pending I/B/E, never arrival-relative.
    output logic [2:0] votes_o,              // Distinct pending slots; zero when the round closes.
    output logic draw_valid_o,              // R05 draw for a subsequent fixed scheduled round.
    input logic draw_ready_i,               // R05 accepts draw_round/issue on this edge.
    output logic [63:0] draw_round_o, draw_issue_o,
    input logic nonce_valid_i,              // R05 conditioned result, with complete captured identity.
    output logic nonce_ready_o,
    input logic [255:0] nonce_i,
    input logic [63:0] nonce_round_i, nonce_issue_i, nonce_generation_i,
    input logic submit_valid_i,             // R07 sealed-buffer admission, not an authenticated vote.
    output logic submit_ready_o,            // Only one live job and one immutable context snapshot.
    input logic [1:0] submit_slot_i,         // Locally selects fixed OTP authority key / slot request.
    input logic abort_valid_i,              // RX_ABORT cancels only its matching job, preserving prior votes.
    input logic [63:0] abort_token_i,
    output logic job_valid_o,               // Immutable request to the trusted verifier; held until ready.
    input logic job_ready_i,
    output logic job_active_o,
    output logic [63:0] job_token_o, job_run_o, job_round_o, job_epoch_o,
    output logic [1:0] job_slot_o,
    output logic [1023:0] job_request_o,
    output logic [2175:0] job_configuration_o,
    output logic [255:0] job_config_digest_o,
    output logic cancel_valid_o,            // Actual formerly-owned token canceled at this edge.
    output logic [63:0] cancel_token_o,
    input logic completion_valid_i,         // One independently sequenced verifier pass result.
    output logic completion_ready_o,        // Always drain stale results; no ownership implied.
    input logic [63:0] completion_token_i, completion_run_i, completion_round_i, completion_epoch_i,
    input logic [1:0] completion_slot_i, completion_pass_i,
    input logic [1023:0] completion_request_i, // Echo immutable checked inputs, not a returned wire body.
    input logic [255:0] completion_config_digest_i,
    input logic [7:0] completion_code_i,     // Pass 1 accepts 0x96; pass 2 accepts 0x69; all else fail.
    output logic result_valid_o,            // Completed/canceled own job status, including rejection.
    output logic [63:0] result_token_o,
    output logic [1:0] result_code_o,        // 0 verified, 1 rejected, 2 canceled.
    output logic vote_event_o, commit_event_o, // Semantic diagnostics, not acceptance bypasses.
    output logic lease_valid_o,
    output logic [63:0] committed_issue_o, lease_expiry_o, remaining_o
);
    localparam logic [7:0] UNPROVISIONED=8'h0f, CLOSED_INIT=8'h33, WAIT_ARM=8'h55,
        RUNNING=8'h66, STOPPING=8'h99, STOPPED=8'haa, FAULT=8'hcc;
    localparam logic [63:0] ID_MAX=64'hffffffffffffffff>>(64-ID_WIDTH);
    localparam logic [63:0] ROUND_MAX=64'hffffffffffffffff>>(64-ROUND_WIDTH);
    localparam logic [63:0] TIME_MAX=64'hffffffffffffffff>>(64-TIME_WIDTH);
    typedef struct packed {
        logic [63:0] round_id, issue, deadline, expiry, run_id;
        logic [255:0] nonce, config_hash;
        logic [7:0] kind;
    } context_t;
    typedef struct packed {
        logic [63:0] token, run_id, round_id, epoch;
        logic [1:0] slot;
        logic [1023:0] request_body;
        logic [255:0] config_hash;
    } job_t;
    logic [7:0] state_q, state_inv_q;         // Dissimilar complemented state plus sparse state code.
    context_t context_q, context_inv_q;       // Exactly one pending context and complemented mirror.
    job_t job_q, job_inv_q;                   // Immutable live job and complemented identity/input mirror.
    logic pending_q, published_q, draw_pending_q, stop_needed_q, reset_active;
    logic active_q, issued_q, pass1_seen_q, pass1_ok_q, eligible_edge;
    logic [2:0] votes_q, votes_inv_q;
    logic pass1_seen_inv_q, pass1_ok_inv_q;
    logic [7:0] pass1_code_q, pass1_code_inv_q; // Protected sparse acceptance evidence, never an unchecked shared success flag.
    logic secondary_identity_ok, secondary_vote_ok, secondary_commit_ok;
    logic [2:0] secondary_voted;
    logic [1:0] secondary_slot;
    logic [7:0] vote_certificate_q [0:2], vote_certificate_inv_q [0:2];
    logic [63:0] vote_token_q [0:2], vote_token_inv_q [0:2];
    logic [2:0] certified_votes;
    logic certificate_bad;
    logic [2:0] secondary_vote_count;
    logic [2175:0] config_q, config_inv_q;     // Complete run-fixed image; no shared mutable host snapshot.
    logic [255:0] digest_q;
    logic [63:0] length_q, period_q, window_q, timing_inv_q [0:2];
    logic [63:0] run_q, run_inv_q, round_q, round_inv_q, next_issue_q, next_issue_inv_q;
    logic [63:0] token_q, epoch_q, token_inv_q, epoch_inv_q;
    logic [63:0] issue_q, issue_inv_q, expiry_q, remaining_q, remaining_inv_q, observed_now_q;
    logic lease_q, running, context_live, match_completion, abort_match, rollover;
    logic state_bad, context_bad, job_bad, config_bad, lease_bad, lease_permit, counters_bad, clock_bad;
    logic [64:0] edge_time;
    logic [63:0] at_edge, age, decremented, candidate_round;
    logic [63:0] schedule_issue, schedule_deadline, schedule_expiry, schedule_next;
    logic schedule_valid, schedule_bad, schedule_limit_bad, run_limit_bad, edge_expired, immediate_fault;
    logic [2:0] voted;
    context_t scheduled;
    job_t proposed_job;

    // Return slot's internal sparse certificate code; these are not protocol or SPI values.
    function automatic logic [7:0] certificate_code(input logic [1:0] slot);
        case (slot)
        0: certificate_code=8'h3c;
        1: certificate_code=8'hc3;
        2: certificate_code=8'h5a;
        default: certificate_code=8'd0;
        endcase
    endfunction
    // Independently authenticate stored votes from separate sparse certificates and unique job tokens.
    always_comb begin
        certificate_bad=0; certified_votes=0;
        for (int i=0;i<3;i++) begin
            if (vote_certificate_q[i]!=~vote_certificate_inv_q[i] || vote_token_q[i]!=~vote_token_inv_q[i] ||
                (vote_certificate_q[i]!=0 && vote_certificate_q[i]!=certificate_code(2'(i))) ||
                ((vote_certificate_q[i]==0)!=(vote_token_q[i]==0)) || vote_token_q[i]>=token_q) certificate_bad=1;
            certified_votes[i]=vote_certificate_q[i]==certificate_code(2'(i)) && vote_token_q[i]!=0;
        end
        if (certified_votes!=votes_q) certificate_bad=1;
        for (int i=0;i<3;i++) for (int j=i+1;j<3;j++)
            if (certified_votes[i] && certified_votes[j] && vote_token_q[i]==vote_token_q[j]) certificate_bad=1;
    end
    // Serialize slot's exact request from the single checked context and run OTP.
    // Body bytes 40..71 and 112..127 stay zero; no session or timing field is added.
    function automatic logic [1023:0] make_request(input logic [1:0] slot);
        logic [1023:0] body;
        body='0;
        body[1023 -: 64]={32'h5245494e,8'd2,context_q.kind,6'b0,slot,8'd0};
        body[959 -: 256]=config_q[2047 -: 256];
        body[447 -: 64]=context_q.round_id;
        body[383 -: 256]=context_q.nonce;
        make_request=body;
    endfunction

    assign running=state_q==WAIT_ARM || state_q==RUNNING;
    assign reset_active=!por_ni || logic_reset_i || cold_clear_i;
    assign edge_time={1'b0,now_i}+65'(tick_i);
    assign at_edge=edge_time[63:0];
    assign age=now_i-issue_q;
    assign decremented=tick_i && remaining_q!=0 ? remaining_q-64'd1 : remaining_q;
    assign state_bad=state_q!=~state_inv_q || !(state_q==UNPROVISIONED || state_q==CLOSED_INIT ||
        state_q==WAIT_ARM || state_q==RUNNING || state_q==STOPPING || state_q==STOPPED || state_q==FAULT);
    assign context_bad=pending_q && context_q!=~context_inv_q;
    assign job_bad=active_q && job_q!=~job_inv_q;
    assign counters_bad=run_q!=~run_inv_q || round_q!=~round_inv_q || token_q!=~token_inv_q || epoch_q!=~epoch_inv_q ||
        next_issue_q!=~next_issue_inv_q || votes_q!=~votes_inv_q || certificate_bad ||
        pass1_seen_q!=~pass1_seen_inv_q || pass1_ok_q!=~pass1_ok_inv_q || pass1_code_q!=~pass1_code_inv_q ||
        (pass1_seen_q && pass1_ok_q!=(pass1_code_q==8'h96));
    assign config_bad=running && (!config_valid_i || !config_closed_i || config_q!=~config_inv_q ||
        config_q!=configuration_i || digest_q!=config_digest_i || length_q!=~timing_inv_q[0] ||
        period_q!=~timing_inv_q[1] || window_q!=~timing_inv_q[2] ||
        length_q!=lease_i || period_q!=period_i || window_q!=window_i);
    // Independent age/subtraction and saturating down-counter checks. A one-tick
    // skew is tolerated, but neither implementation can permit at or past expiry.
    reins_lease_check lease_checker (
        .valid_i(lease_q), .now_i(now_i), .length_i(length_q), .issue_i(issue_q), .issue_inverse_i(issue_inv_q),
        .expiry_i(expiry_q), .remaining_i(remaining_q), .remaining_inverse_i(remaining_inv_q),
        .fault_o(lease_bad), .permit_o(lease_permit)
    );
    assign clock_bad=running && (now_i!=observed_now_q || edge_time[64] || edge_time>65'(TIME_MAX));
    assign immediate_fault=fault_i || state_bad || context_bad || job_bad || counters_bad || config_bad || lease_bad || clock_bad;
    assign fault_o=state_q==FAULT || immediate_fault;
    assign edge_expired=lease_q && (now_i>=expiry_q || at_edge>=expiry_q || decremented==0 || age>=length_q);
    assign rollover=running && at_edge>=next_issue_q;
    assign candidate_round=run_begin_i ? 64'd1 : round_q+64'd1;
    reins_round_schedule schedule (
        .round_i(candidate_round), .period_i(run_begin_i ? period_i : period_q),
        .window_i(run_begin_i ? window_i : window_q), .lease_i(run_begin_i ? lease_i : length_q),
        .valid_o(schedule_valid), .issue_o(schedule_issue), .deadline_o(schedule_deadline),
        .expiry_o(schedule_expiry), .next_issue_o(schedule_next)
    );
    if (TIME_WIDTH<64) begin : reduced_schedule_bound
        assign schedule_limit_bad=schedule_expiry>TIME_MAX || schedule_next>TIME_MAX;
    end else begin : full_schedule_bound
        assign schedule_limit_bad=1'b0;
    end
    if (ID_WIDTH<64) begin : reduced_run_bound
        assign run_limit_bad=platform_generation_i>ID_MAX;
    end else begin : full_run_bound
        assign run_limit_bad=1'b0;
    end
    assign schedule_bad=!schedule_valid || schedule_limit_bad ||
        (!run_begin_i && round_q==ROUND_MAX) ||
        (!run_begin_i && schedule_issue!=next_issue_q);
    always_comb begin
        scheduled='0;
        scheduled.round_id=candidate_round; scheduled.issue=schedule_issue;
        scheduled.deadline=schedule_deadline; scheduled.expiry=schedule_expiry;
        scheduled.run_id=run_begin_i ? platform_generation_i : run_q;
        scheduled.config_hash=run_begin_i ? config_digest_i : digest_q;
        scheduled.kind=state_q==RUNNING && !run_begin_i ? 8'd3 : 8'd1;
        // Field assignments also elaborate in the independent Yosys formal frontend.
        proposed_job.token=token_q; proposed_job.run_id=run_q; proposed_job.round_id=context_q.round_id;
        proposed_job.epoch=epoch_q+64'd1; proposed_job.slot=submit_slot_i;
        proposed_job.request_body=make_request(submit_slot_i); proposed_job.config_hash=digest_q;
    end
    assign restart_ready_o=(state_q==CLOSED_INIT || state_q==STOPPED) && !stop_needed_q && !fault_o && !reset_active;
    assign context_live=running && pending_q && published_q && !reset_active && !fault_o && !entropy_failure_i && grant_enable_i &&
        now_i<context_q.deadline && now_i<next_issue_q && (!lease_q || (now_i<expiry_q && remaining_q!=0));
    assign request_valid_o=context_live && request_slot_i<3 && !logic_reset_i;
    assign request_o=request_valid_o ? make_request(request_slot_i) : 1024'd0;
    assign eligible_edge=context_live && at_edge<context_q.deadline && at_edge<next_issue_q &&
        !edge_expired && !logic_reset_i && !cold_clear_i;
    assign submit_ready_o=eligible_edge && !active_q && submit_slot_i<3;
    assign draw_valid_o=draw_pending_q && pending_q && running && !fault_o && !entropy_failure_i && !reset_active;
    assign draw_round_o=context_q.round_id; assign draw_issue_o=context_q.issue;
    assign nonce_ready_o=running && pending_q && !published_q && !draw_pending_q && !fault_o && !entropy_failure_i &&
        nonce_round_i==context_q.round_id && nonce_issue_i==context_q.issue && nonce_generation_i==run_q &&
        at_edge<context_q.deadline && !reset_active;
    assign job_valid_o=active_q && !issued_q && eligible_edge && !abort_match;
    assign job_active_o=active_q;
    assign job_token_o=job_q.token; assign job_run_o=job_q.run_id;
    assign job_round_o=job_q.round_id; assign job_epoch_o=job_q.epoch; assign job_slot_o=job_q.slot;
    assign job_request_o=job_q.request_body; assign job_config_digest_o=job_q.config_hash;
    assign job_configuration_o=config_q;
    assign completion_ready_o=1'b1;
    assign match_completion=active_q && issued_q && completion_token_i==job_q.token &&
        completion_run_i==job_q.run_id && completion_epoch_i==job_q.epoch && completion_round_i==job_q.round_id &&
        completion_slot_i==job_q.slot && completion_request_i==job_q.request_body && completion_config_digest_i==job_q.config_hash &&
        job_q.run_id==run_q && job_q.round_id==context_q.round_id && job_q.config_hash==context_q.config_hash &&
        job_q.request_body==make_request(job_q.slot);
    // A separately formed identity check consumes the complemented stores and
    // XOR reduction, not the primary equality chain or its match signal.
    assign secondary_identity_ok=!(|({completion_token_i,completion_run_i,completion_round_i,completion_epoch_i,completion_slot_i,completion_request_i,completion_config_digest_i} ^
        ~{job_inv_q.token,job_inv_q.run_id,job_inv_q.round_id,job_inv_q.epoch,job_inv_q.slot,job_inv_q.request_body,job_inv_q.config_hash})) &&
        (~job_inv_q.run_id)==(~run_inv_q) && (~job_inv_q.round_id)==(~context_inv_q.round_id) && (~job_inv_q.config_hash)==(~context_inv_q.config_hash);
    assign secondary_slot=~job_inv_q.slot;
    always_comb begin
        secondary_voted=certified_votes;
        for (int i=0;i<3;i++) if (secondary_slot==2'(i)) secondary_voted[i]=1;
        secondary_vote_count={2'd0,secondary_voted[0]}+{2'd0,secondary_voted[1]}+{2'd0,secondary_voted[2]};
    end
    assign secondary_vote_ok=secondary_identity_ok && pass1_seen_q && pass1_code_q==8'h96 && (~pass1_code_inv_q)==8'h96 &&
        completion_pass_i==2 && completion_code_i==8'h69 && secondary_slot<2'd3 && votes_inv_q[secondary_slot] &&
        at_edge<(~context_inv_q.deadline) && at_edge<(~next_issue_inv_q) &&
        context_q.expiry>at_edge && at_edge>=context_q.issue && (context_q.expiry-context_q.issue)==length_q && !edge_expired;
    assign secondary_commit_ok=secondary_vote_ok && secondary_vote_count>=2 && secondary_voted==voted;
    assign abort_match=abort_valid_i && active_q && abort_token_i==job_q.token;
    assign voted=votes_q | (3'b001<<job_q.slot);
    assign permit_o=state_q==RUNNING && lease_permit && !fault_o && !reset_active;
    assign stop_request_o=stop_needed_q || state_q==STOPPING || state_q==FAULT || fault_o || reset_active;
    assign state_o=state_q; assign run_generation_o=run_q; assign round_o=round_q;
    assign job_generation_o=epoch_q; assign pending_o=pending_q;
    assign issue_o=context_q.issue; assign deadline_o=context_q.deadline; assign proposed_expiry_o=context_q.expiry;
    assign votes_o=pending_q ? votes_q : 3'd0;
    assign lease_valid_o=lease_q && !fault_o && !reset_active;
    assign committed_issue_o=issue_q; assign lease_expiry_o=expiry_q; assign remaining_o=remaining_q;

    // Invalidate pending work before releasing ownership; monotonically advance
    // the job epoch when canceling an active token. No canceled result can vote.
    task automatic cancel_job;
        if (active_q) begin
            cancel_valid_o<=1'b1; cancel_token_o<=job_q.token;
            result_valid_o<=1'b1; result_token_o<=job_q.token; result_code_o<=2'd2;
            if (epoch_q==ID_MAX) begin state_q<=FAULT; state_inv_q<=~FAULT; stop_needed_q<=1'b1; end
            else begin epoch_q<=epoch_q+64'd1; epoch_inv_q<=~(epoch_q+64'd1); end
        end
        active_q<=1'b0; issued_q<=1'b0; pass1_seen_q<=1'b0; pass1_ok_q<=1'b0; pass1_seen_inv_q<=1'b1; pass1_ok_inv_q<=1'b1; pass1_code_q<=0; pass1_code_inv_q<='1;
    endtask
    // Cancel the sole pending context, including all votes and an outstanding draw.
    task automatic close_context;
        pending_q<=1'b0; published_q<=1'b0; draw_pending_q<=1'b0;
        votes_q<='0; votes_inv_q<='1;
        for (int i=0;i<3;i++) begin vote_certificate_q[i]<=0; vote_certificate_inv_q[i]<='1; vote_token_q[i]<=0; vote_token_inv_q[i]<='1; end
        cancel_job();
    endtask
    // Withdraw authorization and request a physical stop; fatal selects FAULT.
    task automatic begin_stop(input logic fatal);
        close_context(); lease_q<=1'b0; remaining_q<='0; remaining_inv_q<='1;
        state_q<=fatal || (active_q && epoch_q==ID_MAX) ? FAULT : STOPPING;
        state_inv_q<=fatal || (active_q && epoch_q==ID_MAX) ? ~FAULT : ~STOPPING;
        stop_needed_q<=1'b1; run_end_o<=1'b1;
    endtask

    always_ff @(posedge clk_i) begin
        if (!por_ni) begin
            state_q<=UNPROVISIONED; state_inv_q<=~UNPROVISIONED; stop_needed_q<=1'b1;
            context_q<='0; context_inv_q<='1; job_q<='0; job_inv_q<='1;
            config_q<='0; config_inv_q<='1; digest_q<='0;
            length_q<='0; period_q<='0; window_q<='0;
            for (int i=0;i<3;i++) timing_inv_q[i]<='1;
            run_q<='0; run_inv_q<='1; round_q<='0; round_inv_q<='1; next_issue_q<='0; next_issue_inv_q<='1;
            token_q<=64'd1; token_inv_q<=~64'd1; epoch_q<='0; epoch_inv_q<='1;
            issue_q<='0; issue_inv_q<='1; expiry_q<='0; remaining_q<='0; remaining_inv_q<='1;
            for (int i=0;i<3;i++) begin vote_certificate_q[i]<=0; vote_certificate_inv_q[i]<='1; vote_token_q[i]<=0; vote_token_inv_q[i]<='1; end
            observed_now_q<='0; lease_q<=1'b0; pending_q<=1'b0; published_q<=1'b0; draw_pending_q<=1'b0;
            active_q<=1'b0; issued_q<=1'b0; pass1_seen_q<=1'b0; pass1_ok_q<=1'b0; pass1_seen_inv_q<=1'b1; pass1_ok_inv_q<=1'b1; pass1_code_q<=0; pass1_code_inv_q<='1; votes_q<='0; votes_inv_q<='1;
            run_end_o<=1'b0; cancel_valid_o<=1'b0; cancel_token_o<='0;
            result_valid_o<=1'b0; result_token_o<='0; result_code_o<='0; vote_event_o<=1'b0; commit_event_o<=1'b0;
        end else begin
            run_end_o<=1'b0; cancel_valid_o<=1'b0; result_valid_o<=1'b0; vote_event_o<=1'b0; commit_event_o<=1'b0;
            if (running) observed_now_q<=at_edge;
            if (lease_q && tick_i && remaining_q!=0) begin
                remaining_q<=remaining_q-64'd1; remaining_inv_q<=remaining_inv_q+64'd1;
            end
            // High-priority inputs precede every publication, admission and vote.
            if (cold_clear_i) begin
                close_context(); lease_q<=1'b0; remaining_q<='0; remaining_inv_q<='1;
                stop_needed_q<=1'b1; state_q<=STOPPING; state_inv_q<=~STOPPING;
            end else if (immediate_fault) begin_stop(1'b1);
            else if (logic_reset_i) begin
                close_context(); lease_q<=1'b0; remaining_q<='0; remaining_inv_q<='1;
                stop_needed_q<=1'b1;
                if (state_q!=FAULT) begin state_q<=STOPPING; state_inv_q<=~STOPPING; end
            end else if (state_q==FAULT) begin
                // Only cold requalification above can leave a latched general fault.
            end else if (edge_expired && state_q==RUNNING) begin_stop(1'b0);
            else if (run_begin_i && restart_ready_o) begin
                if (!config_valid_i || !config_closed_i || run_q==ID_MAX || platform_generation_i<=run_q || run_limit_bad ||
                    schedule_bad || now_i!=0) begin_stop(1'b1);
                else begin
                    close_context(); state_q<=WAIT_ARM; state_inv_q<=~WAIT_ARM;
                    // R05 may have begun a run that reset canceled before this
                    // controller sampled it. Such gaps never reuse an identity.
                    run_q<=platform_generation_i; run_inv_q<=~platform_generation_i;
                    round_q<=64'd1; round_inv_q<=~64'd1; observed_now_q<=at_edge;
                    config_q<=configuration_i; config_inv_q<=~configuration_i; digest_q<=config_digest_i;
                    length_q<=lease_i; period_q<=period_i; window_q<=window_i;
                    timing_inv_q[0]<=~lease_i; timing_inv_q[1]<=~period_i; timing_inv_q[2]<=~window_i;
                    context_q<=scheduled; context_inv_q<=~scheduled; pending_q<=1'b1;
                    next_issue_q<=schedule_next; next_issue_inv_q<=~schedule_next;
                end
            end else if (running) begin
                if (entropy_failure_i) close_context();
                else if (rollover) begin
                    if (schedule_bad) begin_stop(1'b1);
                    else begin
                        close_context(); context_q<=scheduled; context_inv_q<=~scheduled; round_q<=candidate_round; round_inv_q<=~candidate_round;
                        pending_q<=1'b1; draw_pending_q<=1'b1;
                        next_issue_q<=schedule_next; next_issue_inv_q<=~schedule_next;
                    end
                end else if (pending_q && at_edge>=context_q.deadline) close_context();
                else begin
                    if (draw_valid_o && draw_ready_i) draw_pending_q<=1'b0;
                    if (nonce_valid_i && nonce_ready_o) begin
                        context_q.nonce<=nonce_i; context_inv_q.nonce<=~nonce_i; published_q<=1'b1;
                    end
                    if (abort_match) cancel_job();
                    else if (submit_valid_i && submit_ready_o && at_edge<context_q.deadline) begin
                        if (token_q==ID_MAX || epoch_q==ID_MAX) begin_stop(1'b1);
                        else begin
                            job_q<=proposed_job; job_inv_q<=~proposed_job;
                            token_q<=token_q+64'd1; token_inv_q<=~(token_q+64'd1);
                            epoch_q<=epoch_q+64'd1; epoch_inv_q<=~(epoch_q+64'd1);
                            active_q<=1'b1; issued_q<=1'b0; pass1_seen_q<=1'b0; pass1_ok_q<=1'b0; pass1_seen_inv_q<=1'b1; pass1_ok_inv_q<=1'b1; pass1_code_q<=0; pass1_code_inv_q<='1;
                        end
                    end else if (job_valid_o && job_ready_i) issued_q<=1'b1;
                    else if (completion_valid_i && match_completion && context_live && at_edge<context_q.deadline && !edge_expired) begin
                        if (completion_pass_i==1 && !pass1_seen_q) begin
                            pass1_seen_q<=1'b1; pass1_seen_inv_q<=1'b0; pass1_ok_q<=completion_code_i==8'h96; pass1_ok_inv_q<=completion_code_i!=8'h96;
                            pass1_code_q<=completion_code_i; pass1_code_inv_q<=~completion_code_i;
                        end else if (completion_pass_i==2 && pass1_seen_q) begin
                            active_q<=1'b0; issued_q<=1'b0; result_valid_o<=1'b1; result_token_o<=job_q.token;
                            result_code_o<=pass1_ok_q && completion_code_i==8'h69 ? 2'd0 : 2'd1;
                            if (pass1_ok_q && completion_code_i==8'h69 && !votes_q[job_q.slot]) begin
                                if (!secondary_vote_ok) begin_stop(1'b1);
                                else begin
                                votes_q<=voted; votes_inv_q<=~voted; vote_event_o<=1'b1;
                                vote_certificate_q[job_q.slot]<=certificate_code(job_q.slot); vote_certificate_inv_q[job_q.slot]<=~certificate_code(job_q.slot);
                                vote_token_q[job_q.slot]<=job_q.token; vote_token_inv_q[job_q.slot]<=~job_q.token;
                                if ((voted[0] && voted[1]) || (voted[0] && voted[2]) || (voted[1] && voted[2])) begin
                                    if (!secondary_commit_ok) begin_stop(1'b1);
                                    else begin
                                    lease_q<=1'b1; issue_q<=context_q.issue; issue_inv_q<=~context_q.issue; expiry_q<=context_q.expiry;
                                    remaining_q<=length_q-(at_edge-context_q.issue);
                                    remaining_inv_q<=~(length_q-(at_edge-context_q.issue));
                                    state_q<=RUNNING; state_inv_q<=~RUNNING; commit_event_o<=1'b1;
                                    pending_q<=1'b0; published_q<=1'b0; votes_q<='0; votes_inv_q<='1;
                                    for (int i=0;i<3;i++) begin vote_certificate_q[i]<=0; vote_certificate_inv_q[i]<='1; vote_token_q[i]<=0; vote_token_inv_q[i]<='1; end
                                    end
                                end
                                end
                            end
                        end
                    end
                end
            end else if (state_q==UNPROVISIONED && config_closed_i) begin state_q<=CLOSED_INIT; state_inv_q<=~CLOSED_INIT; end
            else if (stop_ack_i && stop_needed_q) begin
                stop_needed_q<=1'b0;
                if (state_q==STOPPING) begin state_q<=STOPPED; state_inv_q<=~STOPPED; end
            end
        end
    end
`ifndef SYNTHESIS
    initial assert (ID_WIDTH>1 && ID_WIDTH<=64 && ROUND_WIDTH>1 && ROUND_WIDTH<=64 && TIME_WIDTH>1 && TIME_WIDTH<=64)
        else $fatal(1,"invalid R06 reduced test widths");
    assert property (@(posedge clk_i) disable iff (!por_ni) permit_o |-> state_q==RUNNING && lease_q && !fault_o);
    assert property (@(posedge clk_i) disable iff (!por_ni) request_valid_o |-> pending_q && published_q && !entropy_failure_i);
`endif
`ifdef FORMAL
    // Qualified-platform/abstract-verifier proofs exercise this actual priority tree, not a replacement FSM.
    logic formal_past=1'b0;
    always @(posedge clk_i) begin
        formal_past<=1'b1;
        if (!formal_past) assume(!por_ni);
        if (formal_past && $past(por_ni)) begin
            if ($past(cold_clear_i || immediate_fault || logic_reset_i || (edge_expired && state_q==RUNNING))) begin
                assert(!commit_event_o); assert(!active_q); assert(!lease_q);
            end
            if ($past(abort_match && running)) begin assert(!commit_event_o); assert(!active_q); end
            if ($past(active_q && !context_live)) assert(!commit_event_o);
        end
        if (formal_past && por_ni && reset_active) assert(!permit_o);
    end
`endif
endmodule
`default_nettype wire
