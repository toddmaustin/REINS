// SIMULATION ONLY. Shared protocol for the catalog-generated readback injector.
input logic [15:0] fault_i, fault_probe_i,
input logic [2:0] fault_mode_i,
input logic [4095:0] fault_value_i, fault_mask_i,
output logic [15:0] fault_active_o,
output logic fault_trigger_o, fault_applied_o, fault_effect_o, fault_clean_o, fault_unsupported_o,
output logic [12:0] fault_width_o,
output logic [31:0] fault_activations_o,
output logic [4095:0] fault_before_o, fault_observed_o
