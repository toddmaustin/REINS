// Three modeled protected endpoints: CPU, accelerator and DMA/bus master. All
// queues precede independent serial isolation cells. Only actual closed-cell and
// empty-queue feedback can acknowledge stop; an untrusted host has no ACK port.
`default_nettype none
module reins_enforcement_bank (
    input logic clk_i, source_clock_i, por_ni, // Always-on 4 MHz supervision / source / recognized monitor POR.
    input logic endpoint_por_ni,              // Separate asynchronous fail-off reset distribution to local domains.
    input logic reset_i, cold_clear_i,        // Cancel source; trusted cold clear is allowed only when stopped.
    input logic tick_i,                      // Qualified source progress; never a host/SPI clock.
    input logic authorize_a_i, authorize_b_i, // Independent lease/health qualifications for the two rails.
    input logic stop_request_i,              // Trusted R06 stop, not an acknowledgement or host command.
    input logic profile_valid_i, profile_alarm_i, // Checked OTP matches the documented clock/delay profile.
    input logic [63:0] generation_i,          // Trusted R06 run identity, used only in outbound test work.
    output logic permit_a_o, permit_b_o, epoch_o, // Internal protected fan-out sources / fresh ARM toggle.
    input logic [2:0] routed_a_i, routed_b_i, // Technology-local routes, not externally accessible pins.
    input logic [2:0] guard_clock_a_i, guard_clock_b_i, // Six local independent always-on clock branches.
    input logic [2:0] raw_clock_i,            // Three protected raw clocks; stopping these never stops guards.
    input logic [2:0] outbound_ready_i,        // External receiver backpressure.
    output logic [2:0] outbound_valid_o,
    output logic [407:0] outbound_data_o,      // Three packed generation/sequence/endpoint bundles.
    output logic [191:0] work_count_o,         // Three representative useful-work counters.
    output logic [8:0] queued_o,              // Per-endpoint occupancy, three bits each.
    output logic [2:0] queue_empty_o, closed_a_o, closed_b_o,
    output logic [2:0] open_a_o, open_b_o, protected_clock_o,
    output logic stop_complete_o, fault_o      // Trusted stop certificate / sticky enforcement failure.
);
    // Sequencing is distinct from authorization: neither rail can run on active_q alone.
    logic active_q, previous_authorization_q, failed_q;
    logic [6:0] grace_q;
    logic [13:0] qualification_q;
    // Only actual closed-cell/empty feedback can advance the protected quiet certificate.
    logic [2:0] quiet_q, quiet_inverse_q;
    // Drain any transition/epoch already in flight before trusting an initially
    // closed actuator. 200 monitor cycles = 50 us exceeds 40 us routing plus
    // local synchronization/opening and closure-feedback observation. This runs
    // in parallel with ordinary guard timeout/actuation, never extending a lease.
    logic [7:0] route_quiet_q, route_quiet_inverse_q;
    logic source_fault, requested, all_quiet, bad, qualified_alarm;
    logic [2:0] guard_alarm_a, guard_alarm_b, endpoint_fault;
    logic [2:0] guard_epoch_a, guard_epoch_b;
    (* ASYNC_REG="TRUE" *) logic [8:0] closure_sync1_q, closure_sync2_q;
    (* ASYNC_REG="TRUE" *) logic [5:0] alarm_sync1_q, alarm_sync2_q;
    (* ASYNC_REG="TRUE" *) logic [5:0] open_sync1_q, open_sync2_q;
    assign requested=authorize_a_i && authorize_b_i && profile_valid_i && !stop_request_i && !reset_i;
    assign all_quiet=&closure_sync2_q;
    assign bad=quiet_q!=~quiet_inverse_q || quiet_q>4 ||
        route_quiet_q!=~route_quiet_inverse_q || route_quiet_q>200;
    // Old-epoch guard alarms may persist through a stop. The 16 us diagnostic
    // grace exceeds the qualified epoch round trip; it never opens any gate.
    assign qualified_alarm=active_q && grace_q>=64 && ((|alarm_sync2_q) || qualification_q>=8191);
    assign fault_o=por_ni && (failed_q || bad || source_fault || profile_alarm_i || (|endpoint_fault));
    assign stop_complete_o=por_ni && endpoint_por_ni && !bad && quiet_q==4 && route_quiet_q==200 && !active_q && !authorize_a_i && !authorize_b_i;
    reins_permit_source source (
        .clk_i(source_clock_i), .por_ni(endpoint_por_ni), .reset_i(reset_i), .tick_i(tick_i),
        .run_i(active_q && !fault_o), .stop_i(stop_request_i),
        .authorize_a_i(authorize_a_i), .authorize_b_i(authorize_b_i && profile_valid_i),
        .permit_a_o(permit_a_o), .permit_b_o(permit_b_o), .fault_o(source_fault)
    );
    for (genvar endpoint=0;endpoint<3;endpoint++) begin : endpoints
        logic [7:0] code_a, code_b;
        reins_permit_guard_a guard_a (
            .clk_i(guard_clock_a_i[endpoint]), .por_ni(endpoint_por_ni), .permit_i(routed_a_i[endpoint]), .epoch_i(epoch_o),
            .code_o(code_a), .epoch_o(guard_epoch_a[endpoint]), .alarm_o(guard_alarm_a[endpoint])
        );
        reins_permit_guard_b guard_b (
            .clk_i(guard_clock_b_i[endpoint]), .por_ni(endpoint_por_ni), .permit_i(routed_b_i[endpoint]), .epoch_i(epoch_o),
            .code_o(code_b), .epoch_o(guard_epoch_b[endpoint]), .alarm_o(guard_alarm_b[endpoint])
        );
        reins_protected_endpoint #(.ENDPOINT_ID(endpoint)) protected_endpoint (
            .egress_clock_i(clk_i), .raw_clock_i(raw_clock_i[endpoint]), .por_ni(endpoint_por_ni),
            .guard_clock_a_i(guard_clock_a_i[endpoint]), .guard_clock_b_i(guard_clock_b_i[endpoint]),
            .epoch_a_i(guard_epoch_a[endpoint]), .epoch_b_i(guard_epoch_b[endpoint]), .code_a_i(code_a), .code_b_i(code_b),
            .generation_i(generation_i), .outbound_ready_i(outbound_ready_i[endpoint]),
            .outbound_valid_o(outbound_valid_o[endpoint]), .outbound_data_o(outbound_data_o[endpoint*136 +: 136]),
            .work_count_o(work_count_o[endpoint*64 +: 64]), .queue_empty_o(queue_empty_o[endpoint]),
            .queued_o(queued_o[endpoint*3 +: 3]), .closed_a_o(closed_a_o[endpoint]), .closed_b_o(closed_b_o[endpoint]),
            .open_a_o(open_a_o[endpoint]), .open_b_o(open_b_o[endpoint]),
            .protected_clock_o(protected_clock_o[endpoint]), .fault_o(endpoint_fault[endpoint])
        );
    end
    always_ff @(posedge clk_i) begin
        if (!por_ni) begin
            closure_sync1_q<=0; closure_sync2_q<=0; alarm_sync1_q<=0; alarm_sync2_q<=0;
            open_sync1_q<=0; open_sync2_q<=0; active_q<=0; previous_authorization_q<=0; epoch_o<=0;
            failed_q<=0; grace_q<=0; qualification_q<=0; quiet_q<=0; quiet_inverse_q<='1;
            route_quiet_q<=0; route_quiet_inverse_q<='1;
        end else begin
            closure_sync1_q<={closed_a_o,closed_b_o,queue_empty_o}; closure_sync2_q<=closure_sync1_q;
            alarm_sync1_q<={guard_alarm_a,guard_alarm_b}; alarm_sync2_q<=alarm_sync1_q;
            open_sync1_q<={open_a_o,open_b_o}; open_sync2_q<=open_sync1_q;
            previous_authorization_q<=requested;
            if (active_q || requested) begin route_quiet_q<=0; route_quiet_inverse_q<='1; end
            else if (route_quiet_q<200) begin
                route_quiet_q<=route_quiet_q+8'd1; route_quiet_inverse_q<=route_quiet_inverse_q-8'd1;
            end
            if (all_quiet && !active_q && !requested) begin
                if (quiet_q<4) begin quiet_q<=quiet_q+3'd1; quiet_inverse_q<=quiet_inverse_q-3'd1; end
            end else begin quiet_q<=0; quiet_inverse_q<='1; end
            if (fault_o || qualified_alarm) begin failed_q<=1; active_q<=0; end
            else if (requested && !previous_authorization_q) begin
                if (quiet_q==4) begin active_q<=1; epoch_o<=~epoch_o; grace_q<=0; qualification_q<=0; end
                else begin failed_q<=1; active_q<=0; end
            end else if (!requested) active_q<=0;
            else if (active_q) begin
                if (grace_q<64) grace_q<=grace_q+7'd1;
                if (&open_sync2_q) qualification_q<=0;
                else if (qualification_q<8191) qualification_q<=qualification_q+14'd1;
            end
`ifndef SYNTHESIS
            // A synchronized certificate must never hide a late opening or pending external effect.
            if (stop_complete_o) begin
                trusted_certificate_contains_endpoints: assert ((&closed_a_o) && (&closed_b_o) && (&queue_empty_o) &&
                    protected_clock_o==0 && outbound_valid_o==0) else $fatal(1,"premature endpoint stop certificate");
            end
`endif
            if (cold_clear_i && stop_complete_o && !source_fault && !(|endpoint_fault) && !profile_alarm_i && !bad) failed_q<=0;
        end
    end
endmodule
`default_nettype wire
