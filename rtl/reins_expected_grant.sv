// Construct the complete grant from protected local fields. No reply body exists.
// The caller independently checks its local request snapshot and OTP provenance.
`default_nettype none
module reins_expected_grant (
    input logic [255:0] identity_i,      // Device D || policy C, freshly read from checked OTP bytes 16..47.
    input logic [7:0] request_kind_i,      // Only local ARM_REQUEST=1 or RENEW_REQUEST=3.
    input logic [1:0] slot_i,             // Local provisioned slot, fixed implementation 0..2.
    input logic [63:0] round_i,           // Nonzero protected pending round.
    input logic [255:0] nonce_i,          // Protected current-round nonce, never received from the reply.
    output logic [1023:0] grant_o,        // Exactly 128 bytes; first byte is bits 1023:1016.
    output logic valid_o                 // Construction preconditions only, never signature acceptance.
);
    logic [7:0] grant_kind;
    assign grant_kind=request_kind_i==8'd1 ? 8'd2 : request_kind_i==8'd3 ? 8'd4 : 8'd0;
    assign valid_o=grant_kind!=0 && slot_i<3 && round_i!=0;
    assign grant_o={32'h5245494e,8'd2,grant_kind,{6'd0,slot_i},8'd0,
        identity_i,256'd0,round_i,nonce_i,128'd0};
endmodule
`default_nettype wire
