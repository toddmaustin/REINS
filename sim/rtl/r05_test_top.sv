// R05 simulation top. Factory fixtures, passive taps and reduced-width/unit probes
// are excluded from production reins_platform_control and do not authorize it.
`default_nettype none
module r05_test_top (
    input logic clk_i, por_ni, cold_reset_i, warm_reset_i,
    input logic startup_i, run_end_i, physical_enable_i, stopped_i,
    input logic config_write_i, config_check_i, config_close_i,
    input logic [8:0] config_address_i,
    input logic [7:0] config_data_i,
    input logic factory_valid_i,
    input logic [2175:0] factory_image_i,
    input logic [1:0] factory_lifecycle_i,
    input logic model_bad_close_i, model_bad_code_i,
    input logic macro_integrity_i,
    output logic [1:0] macro_lifecycle_o,
    output logic config_write_accepted_o, config_busy_o, config_done_o, config_valid_o,
    output logic [2:0] config_error_o,
    output logic [2175:0] configuration_o,
    output logic [255:0] configuration_digest_o,
    output logic [63:0] lease_length_o, period_o, window_o,
    input logic reference_a_i, reference_b_i, timing_healthy_i, sensor_healthy_i, integrity_alarm_i,
    input logic source_a_available_i, source_b_available_i,
    input logic source_a_valid_i, source_a_bit_i,
    input logic [63:0] source_a_time_i,
    input logic source_b_valid_i, source_b_bit_i,
    input logic [63:0] source_b_time_i,
    output logic source_a_request_o, source_b_request_o,
    output logic [8:0] source_a_count_o, source_b_count_o,
    input logic draw_valid_i,
    output logic draw_ready_o, draw_rejected_o,
    input logic [63:0] draw_round_i, draw_issue_i,
    output logic nonce_valid_o,
    input logic nonce_ready_i,
    output logic [255:0] nonce_o,
    output logic [63:0] nonce_round_o, nonce_issue_o, nonce_generation_o,
    output logic entropy_hold_o, cold_eligible_o, history_valid_o,
    output logic checking_o, run_active_o, startup_complete_o, new_grants_o, fatal_o, invalidate_o,
    output logic [63:0] now_o, generation_o,
    input logic lease_valid_i,
    input logic [63:0] lease_expiry_i, lease_generation_i,
    output logic lease_permission_o,
    // Passive observations of the ACTUAL SHA message handshakes/bytes/results.
    output logic cfg_hash_start_o, cfg_hash_byte_o, cfg_hash_done_o,
    output logic [7:0] cfg_hash_data_o,
    output logic rng_hash_start_o, rng_hash_byte_o, rng_hash_done_o,
    output logic [7:0] rng_hash_data_o,
    output logic [255:0] rng_hash_digest_o,
    output logic rng_result_pending_o,
    output logic cfg_hash_reset_no, rng_hash_reset_no, // Actual reset/cancellation observations.
    // Isolated 8-bit time instance for practical arithmetic-overflow testing.
    input logic unit_time_reset_ni, unit_time_enable_i, unit_time_start_i,
    output logic [7:0] unit_now_o,
    output logic unit_time_qualified_o, unit_time_alarm_o,
    // Isolated health instance to exercise precise RCT/APT/missing-sample boundaries.
    input logic unit_health_reset_ni, unit_health_required_i, unit_health_valid_i, unit_health_bit_i,
    output logic unit_health_qualified_o, unit_health_failed_o,
    output logic [31:0] unit_health_samples_o
);
    logic macro_write_o, macro_close_o, macro_complete_i;
    logic [8:0] macro_address_o;
    logic [7:0] macro_write_data_o, macro_read_data_i;
    logic [1:0] macro_lifecycle_i;
    assign macro_lifecycle_o=macro_lifecycle_i;
    reins_otp_model otp (
        .clk_i(clk_i), .factory_valid_i(factory_valid_i), .factory_image_i(factory_image_i),
        .factory_lifecycle_i(factory_lifecycle_i), .physical_enable_i(physical_enable_i), .stopped_i(stopped_i),
        .write_i(macro_write_o), .close_i(macro_close_o), .address_i(macro_address_o), .data_i(macro_write_data_o),
        .model_bad_close_i(model_bad_close_i), .model_bad_code_i(model_bad_code_i),
        .read_data_o(macro_read_data_i), .lifecycle_o(macro_lifecycle_i), .complete_o(macro_complete_i)
    );
    reins_platform_control control (.*);
    assign cfg_hash_start_o=control.config_checker.hasher.req_valid_i && control.config_checker.hasher.req_ready_o;
    assign cfg_hash_byte_o=control.config_checker.hasher.byte_valid_i && control.config_checker.hasher.byte_ready_o;
    assign cfg_hash_data_o=control.config_checker.hasher.byte_i;
    assign cfg_hash_done_o=control.config_checker.hasher.rsp_valid_o && control.config_checker.hasher.rsp_ready_i;
    assign rng_hash_start_o=control.entropy.conditioner.req_valid_i && control.entropy.conditioner.req_ready_o;
    assign rng_hash_byte_o=control.entropy.conditioner.byte_valid_i && control.entropy.conditioner.byte_ready_o;
    assign rng_hash_data_o=control.entropy.conditioner.byte_i;
    assign rng_hash_done_o=control.entropy.conditioner.rsp_valid_o && control.entropy.conditioner.rsp_ready_i;
    assign rng_hash_digest_o=control.entropy.conditioner.rsp_digest_o;
    assign rng_result_pending_o=control.entropy.conditioner.rsp_valid_o;
    assign cfg_hash_reset_no=control.config_checker.hasher.rst_ni;
    assign rng_hash_reset_no=control.entropy.conditioner.rst_ni;
    reins_trusted_time #(.WIDTH(8)) overflow_probe (
        .clk_i(clk_i), .rst_ni(unit_time_reset_ni), .monitor_i(unit_time_enable_i), .restart_i(1'b0),
        .run_start_i(unit_time_start_i), .reference_a_i(reference_a_i), .reference_b_i(reference_b_i),
        .absolute_healthy_i(1'b1), .qualified_o(unit_time_qualified_o), .alarm_o(unit_time_alarm_o), .now_o(unit_now_o)
    );
    reins_source_health health_probe (
        .clk_i(clk_i), .rst_ni(unit_health_reset_ni), .restart_i(1'b0), .enabled_i(1'b1),
        .required_i(unit_health_required_i), .available_i(1'b1), .valid_i(unit_health_valid_i), .bit_i(unit_health_bit_i),
        .qualified_o(unit_health_qualified_o), .failed_o(unit_health_failed_o), .samples_o(unit_health_samples_o)
    );
endmodule
`default_nettype wire
