// Exercise actual ownership/seal/store logic. Read-disabled, aligned first-byte writes prune payload/ECC state.
module r11_seal (
    input logic clk,por,reset,acquire,release_owner,seal,write_enable,
    input logic [63:0] proposed,owner,
    input logic [7:0] data,code
);
    wire write_event,read_valid,sealed_state,fault;
    wire [7:0] unused_data;
    reins_receive_sram memory(clk,por,reset,acquire,release_owner,seal,proposed,~proposed,owner,~owner,
        write_enable,code,14'd0,~14'd0,data,write_event,1'b0,14'd0,~14'd0,read_valid,unused_data,sealed_state,fault);
endmodule
