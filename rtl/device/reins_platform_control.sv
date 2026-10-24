// Copyright (c) 2026 Todd Austin.
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// License: https://polyformproject.org/licenses/noncommercial/1.0.0/

// PLATFORM configuration/startup/time/entropy integration for digital simulation profile 1.
// lease_* are TRUSTED INTERNAL inputs from the future CONTROLLER quorum/lease controller.
// This component cannot authorize execution by itself and is not a chip top.
`default_nettype none
module reins_platform_control (
    input logic clk_i, por_ni,                 // Independent always-on monitor clock / real power reset.
    input logic cold_reset_i, warm_reset_i,    // Technology-recognized resets, never host commands.
    input logic startup_i, run_end_i,          // Trusted startup request / completed stop or context loss.
    input logic physical_enable_i, stopped_i,  // Physical commissioning and actual-stop interlocks.
    input logic config_write_i, config_check_i, config_close_i, // Physical byte/check/commit attempts.
    input logic [8:0] config_address_i,         // Programming byte offset, 0..271.
    input logic [7:0] config_data_i,            // Public commissioning byte.
    output logic config_write_accepted_o,      // Actual admitted programming transaction.
    output logic macro_write_o, macro_close_o, // Admitted irreversible-wrapper transactions.
    output logic [8:0] macro_address_o,        // Read/check cursor or programming byte address.
    output logic [7:0] macro_write_data_o,     // Payload of an admitted write.
    input logic [7:0] macro_read_data_i,       // Sensed logical byte at macro_address_o.
    input logic [1:0] macro_lifecycle_i,        // Technology-retained 00/11/invalid lifecycle.
    input logic macro_complete_i, macro_integrity_i, // Completeness and sensing/ECC/lock health.
    output logic config_busy_o, config_done_o, config_valid_o, // Check ownership/completion/success.
    output logic [2:0] config_error_o,         // reins_config's retained check diagnostic.
    output logic [2175:0] configuration_o,      // Full checked public image, meaningful when valid.
    output logic [255:0] configuration_digest_o, // Exact C_cfg; meaningful with config_valid_o.
    output logic [63:0] lease_length_o, period_o, window_o, // Checked L/P/W in local ticks.
    input logic reference_a_i, reference_b_i,   // Dissimilar synchronized progress events.
    input logic timing_healthy_i, sensor_healthy_i, integrity_alarm_i, // Qualified platform alarms.
    input logic source_a_available_i, source_b_available_i, // Independent source availability.
    input logic source_a_valid_i, source_a_bit_i, // One fresh raw A event and binary value.
    input logic [63:0] source_a_time_i,         // Trusted A acquisition tick, before any queue.
    input logic source_b_valid_i, source_b_bit_i, // One fresh raw B event and binary value.
    input logic [63:0] source_b_time_i,         // Trusted B acquisition tick, before any queue.
    output logic source_a_request_o, source_b_request_o, // Startup or active fresh-draw demand.
    output logic [8:0] source_a_count_o, source_b_count_o, // Actual accepted nonce bits, not entropy.
    input logic draw_valid_i,                 // Trusted CONTROLLER subsequent-round schedule proposal.
    output logic draw_ready_o, draw_rejected_o, // Proposal availability / invalid-command pulse.
    input logic [63:0] draw_round_i, draw_issue_i, // Increasing CONTROLLER round and scheduled I.
    output logic nonce_valid_o,               // Retained, timely conditioned nonce response.
    input logic nonce_ready_i,                // Trusted CONTROLLER consumer captures response.
    output logic [255:0] nonce_o,             // Actual dedicated-SHA result; never host supplied.
    output logic [255:0] nonce_audit_o,       // Independent complemented conditioner result, for protected consumers.
    output logic [63:0] nonce_round_o, nonce_issue_o, nonce_generation_o, // Captured draw identity.
    output logic entropy_hold_o, cold_eligible_o, history_valid_o, // Hold, clearing policy, history.
    output logic checking_o, run_active_o, startup_complete_o, new_grants_o, // Startup/new-grant gates.
    output logic fatal_o, invalidate_o,        // Immediate/stored general fault / cancel pending work.
    output logic [63:0] now_o, generation_o,   // Trusted local tick and nonwrapping run identity.
    input logic lease_valid_i,                  // CONTROLLER's independently authorized committed lease.
    input logic [63:0] lease_expiry_i, lease_generation_i, // Original committed expiry/context.
    output logic lease_permission_o            // PLATFORM qualification/health/time gate on that lease.
);
    typedef enum logic [7:0] {STOPPED=8'h0f, CHECKING=8'h33, RUN=8'h55} phase_t;
    phase_t phase_q;                           // Startup progress; not the future armed/quorum FSM.
    (* keep="true", dont_touch="true" *) logic [7:0] phase_inverse_q;
    (* keep="true", dont_touch="true" *) logic [63:0] generation_inverse_q;
    logic protected_bad, entropy_integrity, config_integrity;
    logic fatal_q, first_nonce_q;              // Sticky general fault / first-round qualification.
    logic logic_reset_n, start_accepted, run_start, monitored, general_alarm;
    logic time_qualified, time_alarm, a_qualified, b_qualified, a_failed, b_failed;
    logic entropy_a_request, entropy_b_request, entropy_invalidate;
    logic entropy_start_allowed;
    logic [31:0] unused_a_startup_samples, unused_b_startup_samples;
    logic [63:0] entropy_generation;

    assign logic_reset_n=por_ni && !cold_reset_i && !warm_reset_i && !run_end_i;
    assign checking_o=phase_q==CHECKING;
    assign run_active_o=phase_q==RUN;
    assign monitored=checking_o || run_active_o;
    assign protected_bad=phase_q!=~phase_inverse_q || !(phase_q==STOPPED || phase_q==CHECKING || phase_q==RUN) ||
        generation_o!=~generation_inverse_q;
    assign general_alarm=protected_bad || entropy_integrity || config_integrity || !macro_integrity_i || (macro_lifecycle_i!=0 && macro_lifecycle_i!=3) ||
        (macro_lifecycle_i==3 && !macro_complete_i) || (monitored && macro_lifecycle_i!=3) ||
        !timing_healthy_i || !sensor_healthy_i || integrity_alarm_i || time_alarm;
    assign fatal_o=fatal_q || general_alarm;
    assign start_accepted=startup_i && phase_q==STOPPED && macro_lifecycle_i==3 &&
        !fatal_o && entropy_start_allowed && logic_reset_n;
    assign run_start=checking_o && config_valid_o && time_qualified && a_qualified && b_qualified &&
        !fatal_o && (!entropy_hold_o || cold_eligible_o) && generation_o!=64'hffffffffffffffff;
    assign entropy_generation=run_start ? generation_o+64'd1 : generation_o;
    assign source_a_request_o=checking_o || entropy_a_request;
    assign source_b_request_o=checking_o || entropy_b_request;
    assign startup_complete_o=logic_reset_n && run_active_o && first_nonce_q && config_valid_o &&
        macro_lifecycle_i==3 && macro_complete_i && !fatal_o;
    assign new_grants_o=startup_complete_o && !entropy_hold_o;
    // Entropy hold deliberately does not withdraw an already healthy committed lease.
    assign lease_permission_o=startup_complete_o && !run_end_i && lease_valid_i &&
        lease_generation_i==generation_o && now_o<lease_expiry_i;

    reins_config config_checker (
        .clk_i(clk_i), .rst_ni(logic_reset_n), .physical_enable_i(physical_enable_i), .stopped_i(stopped_i),
        .write_i(config_write_i), .write_address_i(config_address_i), .write_data_i(config_data_i),
        .write_accepted_o(config_write_accepted_o),
        .check_i(start_accepted || (config_check_i && physical_enable_i && stopped_i && macro_lifecycle_i==0)), .close_i(config_close_i),
        .macro_write_o(macro_write_o), .macro_close_o(macro_close_o), .macro_address_o(macro_address_o),
        .macro_write_data_o(macro_write_data_o), .macro_read_data_i(macro_read_data_i),
        .macro_lifecycle_i(macro_lifecycle_i), .macro_complete_i(macro_complete_i), .macro_integrity_i(macro_integrity_i),
        .busy_o(config_busy_o), .done_o(config_done_o), .valid_o(config_valid_o), .error_o(config_error_o),
        .image_o(configuration_o), .digest_o(configuration_digest_o), .lease_o(lease_length_o), .period_o(period_o), .window_o(window_o),
        .integrity_fault_o(config_integrity)
    );
    reins_trusted_time timekeeper (
        .clk_i(clk_i), .rst_ni(logic_reset_n), .monitor_i(monitored), .restart_i(start_accepted),
        .run_start_i(run_start), .reference_a_i(reference_a_i), .reference_b_i(reference_b_i),
        .absolute_healthy_i(timing_healthy_i), .qualified_o(time_qualified), .alarm_o(time_alarm), .now_o(now_o)
    );
    reins_source_health health_a (
        .clk_i(clk_i), .rst_ni(logic_reset_n), .restart_i(start_accepted), .enabled_i(monitored),
        .required_i(source_a_request_o), .available_i(source_a_available_i),
        .valid_i(source_a_valid_i), .bit_i(source_a_bit_i), .qualified_o(a_qualified), .failed_o(a_failed),
        .samples_o(unused_a_startup_samples)
    );
    reins_source_health health_b (
        .clk_i(clk_i), .rst_ni(logic_reset_n), .restart_i(start_accepted), .enabled_i(monitored),
        .required_i(source_b_request_o), .available_i(source_b_available_i),
        .valid_i(source_b_valid_i), .bit_i(source_b_bit_i), .qualified_o(b_qualified), .failed_o(b_failed),
        .samples_o(unused_b_startup_samples)
    );
    reins_entropy entropy (
        .clk_i(clk_i), .por_ni(por_ni), .cold_reset_i(cold_reset_i), .warm_reset_i(warm_reset_i),
        .cancel_i(run_end_i || fatal_o), .monitor_i(monitored), .source_failure_i(a_failed || b_failed),
        .run_start_i(run_start), .now_i(now_o), .generation_i(entropy_generation), .window_i(window_o),
        .tick_i(reference_a_i && run_active_o && !time_alarm),
        .draw_valid_i(draw_valid_i && run_active_o), .draw_ready_o(draw_ready_o), .draw_rejected_o(draw_rejected_o),
        .draw_round_i(draw_round_i), .draw_issue_i(draw_issue_i),
        .a_valid_i(source_a_valid_i), .a_bit_i(source_a_bit_i), .a_time_i(source_a_time_i),
        .b_valid_i(source_b_valid_i), .b_bit_i(source_b_bit_i), .b_time_i(source_b_time_i),
        .a_request_o(entropy_a_request), .b_request_o(entropy_b_request),
        .a_count_o(source_a_count_o), .b_count_o(source_b_count_o),
        .hold_o(entropy_hold_o), .cold_eligible_o(cold_eligible_o), .nonce_valid_o(nonce_valid_o), .nonce_ready_i(nonce_ready_i),
        .startup_allowed_o(entropy_start_allowed),
        .nonce_o(nonce_o), .nonce_audit_o(nonce_audit_o), .nonce_round_o(nonce_round_o), .nonce_issue_o(nonce_issue_o), .nonce_generation_o(nonce_generation_o),
        .history_valid_o(history_valid_o), .invalidate_o(entropy_invalidate), .integrity_fault_o(entropy_integrity)
    );

    // Separate inverse decode and decrementing generation path; cold/warm reset
    // retains both powered-generation copies, while real power loss clears them.
    always_ff @(posedge clk_i) begin
        if (!por_ni) begin phase_inverse_q<=~STOPPED; generation_inverse_q<='1; end
        else if (cold_reset_i || warm_reset_i || run_end_i || general_alarm ||
            (phase_inverse_q==~CHECKING && config_done_o && !config_valid_o) ||
            (phase_inverse_q==~CHECKING && generation_inverse_q==0)) phase_inverse_q<=~STOPPED;
        else if (startup_i && phase_inverse_q==~STOPPED && macro_lifecycle_i==3 &&
            !fatal_o && entropy_start_allowed && logic_reset_n) phase_inverse_q<=~CHECKING;
        else if (phase_inverse_q==~CHECKING && entropy_hold_o && !cold_eligible_o) phase_inverse_q<=~STOPPED;
        else if (phase_inverse_q==~CHECKING && config_valid_o && time_qualified && a_qualified && b_qualified &&
            !fatal_o && (!entropy_hold_o || cold_eligible_o) && generation_inverse_q!=0) begin
            phase_inverse_q<=~RUN; generation_inverse_q<=generation_inverse_q-64'd1;
        end
    end
    always_ff @(posedge clk_i) begin
        if (!por_ni) begin phase_q<=STOPPED; fatal_q<=1'b0; first_nonce_q<=1'b0; generation_o<='0; invalidate_o<=1'b1; end
        else begin
            invalidate_o<=entropy_invalidate;
            if (cold_reset_i || warm_reset_i || run_end_i) begin
                phase_q<=STOPPED; first_nonce_q<=1'b0; invalidate_o<=1'b1;
                if (cold_reset_i) fatal_q<=1'b0;
                else if (general_alarm) fatal_q<=1'b1;
            end else if (general_alarm || (checking_o && config_done_o && !config_valid_o) ||
                (checking_o && generation_o==64'hffffffffffffffff)) begin
                fatal_q<=1'b1; phase_q<=STOPPED; first_nonce_q<=1'b0; invalidate_o<=1'b1;
            end else if (start_accepted) begin phase_q<=CHECKING; first_nonce_q<=1'b0; end
            else if (checking_o && entropy_hold_o && !cold_eligible_o) begin phase_q<=STOPPED; invalidate_o<=1'b1; end
            else if (run_start) begin phase_q<=RUN; generation_o<=generation_o+64'd1; end
            else if (run_active_o && nonce_valid_o && nonce_round_o==1) first_nonce_q<=1'b1;
        end
    end
`ifndef SYNTHESIS
    assert property (@(posedge clk_i) disable iff (!por_ni)
        lease_permission_o |-> config_valid_o && run_active_o && first_nonce_q && !fatal_o);
`endif
endmodule
`default_nettype wire
