// Copyright (c) 2026 Todd Austin.
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// License: https://polyformproject.org/licenses/noncommercial/1.0.0/

// FIPS 205 base_2b/checksum for n=16, lg(w)=4, len1=32, len2=3.
`default_nettype none
module slh_wots_digits (
    input logic [127:0] message_i,       // WOTS message, most significant nibble first.
    output logic [139:0] digits_o,       // 35 nibbles; checksum digits follow all 32 message digits.
    output logic [15:0] checksum_o       // Big-endian two-byte checksum, sum(15-digit)<<4.
);
    logic [8:0] sum;
    always_comb begin
        sum=0;
        for (int i=0;i<32;i++) sum=sum+9'd15-{5'd0,message_i[127-4*i -: 4]};
    end
    assign checksum_o={3'd0,sum,4'd0};
    assign digits_o={message_i,checksum_o[15:4]};
endmodule
`default_nettype wire
