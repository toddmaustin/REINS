// Copyright (c) 2026 Todd Austin.
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// License: https://polyformproject.org/licenses/noncommercial/1.0.0/

// ENFORCEMENT implements one documented digital platform, not arbitrary physical clocks.
// PLATFORM accepts the specification's broader schema; this additional platform gate
// prevents an otherwise valid image from claiming tighter delays or a faster
// minimum tick clock than this simulation profile supports. The protocol is unchanged.
`default_nettype none
module reins_enforcement_profile (
    input logic config_valid_i,         // PLATFORM's fully checked, closed public OTP snapshot.
    input logic [2175:0] configuration_i,
    output logic compatible_o, alarm_o  // Qualified platform view / unsupported checked configuration.
);
    // Read four big-endian bytes at offset from the checked public image.
    function automatic logic [31:0] be32(input int offset);
        return configuration_i[2175-offset*8 -: 32];
    endfunction
    assign compatible_o=config_valid_i && be32(12)==1 && be32(72)==1000000 && be32(76)==800000 &&
        be32(80)>=950 && be32(80)<=1000 && be32(84)>=150 && be32(84)<=2000 && be32(88)==1;
    assign alarm_o=config_valid_i && !compatible_o;
endmodule
`default_nettype wire
