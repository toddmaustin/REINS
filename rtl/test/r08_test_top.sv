// Copyright (c) 2026 Todd Austin.
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// License: https://polyformproject.org/licenses/noncommercial/1.0.0/

// SIMULATION ONLY: real enforcement bank, pin-level clock domains and explicit fault sites.
`default_nettype none
module r08_test_top (
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
    output logic stop_complete_o, fault_o,     // Trusted stop certificate / sticky enforcement failure.
    input logic [2:0] permissive_a_i, permissive_b_i, // Simulation-only persistent local checker faults.
    input logic [2:0] queue_run_tie_i, reset_tie_i, // Simulation-only common-control faults, never production ports.
    output logic [191:0] effect_count_o, // Independent external sink accounting, retained through logical resets.
    output logic [2:0] stale_effect_o // Sticky independent tag/endpoint mismatch observation.
);
    reins_enforcement_bank bank (
        .clk_i(clk_i),
        .source_clock_i(source_clock_i),
        .por_ni(por_ni),
        .endpoint_por_ni(endpoint_por_ni),
        .reset_i(reset_i),
        .cold_clear_i(cold_clear_i),
        .tick_i(tick_i),
        .authorize_a_i(authorize_a_i),
        .authorize_b_i(authorize_b_i),
        .stop_request_i(stop_request_i),
        .profile_valid_i(profile_valid_i),
        .profile_alarm_i(profile_alarm_i),
        .generation_i(generation_i),
        .permit_a_o(permit_a_o),
        .permit_b_o(permit_b_o),
        .epoch_o(epoch_o),
        .routed_a_i(routed_a_i),
        .routed_b_i(routed_b_i),
        .guard_clock_a_i(guard_clock_a_i),
        .guard_clock_b_i(guard_clock_b_i),
        .raw_clock_i(raw_clock_i),
        .outbound_ready_i(outbound_ready_i),
        .outbound_valid_o(outbound_valid_o),
        .outbound_data_o(outbound_data_o),
        .work_count_o(work_count_o),
        .queued_o(queued_o),
        .queue_empty_o(queue_empty_o),
        .closed_a_o(closed_a_o),
        .closed_b_o(closed_b_o),
        .open_a_o(open_a_o),
        .open_b_o(open_b_o),
        .protected_clock_o(protected_clock_o),
        .stop_complete_o(stop_complete_o),
        .fault_o(fault_o)
    );
    for (genvar endpoint=0;endpoint<3;endpoint++) begin : fault_sites
        // A fault makes one entire local checker permissive; the other path is untouched.
        always @(permissive_a_i) begin
            if (permissive_a_i[endpoint]) force bank.endpoints[endpoint].code_a=8'h96;
            else release bank.endpoints[endpoint].code_a;
        end
        always @(permissive_b_i) begin
            if (permissive_b_i[endpoint]) force bank.endpoints[endpoint].code_b=8'ha5;
            else release bank.endpoints[endpoint].code_b;
        end
        always @(queue_run_tie_i) begin
            if (queue_run_tie_i[endpoint]) force bank.endpoints[endpoint].protected_endpoint.queue_run=1'b1;
            else release bank.endpoints[endpoint].protected_endpoint.queue_run;
        end
        always @(reset_tie_i) begin
            if (reset_tie_i[endpoint]) force bank.endpoints[endpoint].protected_endpoint.compute_reset_ni=1'b1;
            else release bank.endpoints[endpoint].protected_endpoint.compute_reset_ni;
        end
        always_ff @(posedge clk_i) begin
            if (!por_ni) begin effect_count_o[endpoint*64 +: 64]<=0; stale_effect_o[endpoint]<=0; end
            else if (outbound_valid_o[endpoint] && outbound_ready_i[endpoint]) begin
                effect_count_o[endpoint*64 +: 64]<=effect_count_o[endpoint*64 +: 64]+64'd1;
                if (outbound_data_o[endpoint*136+72 +: 64]!=generation_i || outbound_data_o[endpoint*136 +: 8]!=8'(endpoint))
                    stale_effect_o[endpoint]<=1;
            end
        end
    end
endmodule
`default_nettype wire
