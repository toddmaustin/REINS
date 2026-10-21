// SIMULATION ONLY: technology OTP model with retention across every logic/power reset.
// Initialization is a factory test fixture, not a production programming/debug port.
`default_nettype none
module reins_otp_model (
    input logic clk_i,
    input logic factory_valid_i,              // Examined at the FIRST clock edge only.
    input logic [2175:0] factory_image_i,      // Public pre-existing OTP fixture.
    input logic [1:0] factory_lifecycle_i,     // Allows testing already-invalid/closed devices.
    input logic physical_enable_i, stopped_i,
    input logic write_i, close_i,
    input logic [8:0] address_i,
    input logic [7:0] data_i,
    input logic model_bad_close_i, model_bad_code_i, // Emulate partial fuse programming (01/10).
    output logic [7:0] read_data_o,
    output logic [1:0] lifecycle_o,
    output logic complete_o
);
    logic initialized_q=1'b0;
    logic [2175:0] memory_q='0;               // Represents nonvolatile public storage, not SRAM.
    logic [271:0] written_q='0;
    initial lifecycle_o=2'b00;
    assign read_data_o=address_i<272 ? memory_q[2175-8*int'(address_i) -: 8] : 8'd0;
    assign complete_o=&written_q;
    always_ff @(posedge clk_i) begin
        if (!initialized_q) begin
            initialized_q<=1'b1;
            if (factory_valid_i) begin memory_q<=factory_image_i; lifecycle_o<=factory_lifecycle_i; written_q<='1; end
        end else if (lifecycle_o==0 && physical_enable_i && stopped_i) begin
            if (close_i && complete_o) lifecycle_o<=model_bad_close_i ? (model_bad_code_i ? 2'b10 : 2'b01) : 2'b11;
            else if (write_i && address_i<272) begin
                memory_q[2175-8*int'(address_i) -: 8]<=data_i; written_q[address_i]<=1'b1;
            end
        end
    end
endmodule
`default_nettype wire
