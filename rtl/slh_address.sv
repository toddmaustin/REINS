// Copyright (c) 2026 Todd Austin.
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// License: https://polyformproject.org/licenses/noncommercial/1.0.0/

// FIPS 205 32-byte ADRS and SHA2-128s 22-byte ADRSc. Never silently
// truncate a noncanonical high word; callers must gate work on valid_o.
`default_nettype none
module slh_address (
    input logic [31:0] layer_i,             // Selected profile: layers 0..6.
    input logic [95:0] tree_i,              // Full FIPS field; only the selected layer's tree bits are legal.
    input logic [31:0] type_i,              // WOTS_HASH=0, WOTS_PK=1, TREE=2, FORS_TREE=3, FORS_ROOTS=4, PRFs=5/6.
    input logic [31:0] keypair_i,           // XMSS leaf 0..511; TREE addresses require zero.
    input logic [31:0] word6_i, word7_i,    // Chain/hash or height/index; type-specific unused words must be zero.
    output logic [255:0] address_o,         // Eight big-endian 32-bit words, including all 96 tree bits.
    output logic [175:0] compressed_o,      // layer[7:0] || tree[63:0] || type[7:0] || final three words.
    output logic valid_o
);
    logic fields_ok;
    always_comb begin
        fields_ok=0;
        case (type_i)
        0: fields_ok=keypair_i<512 && word6_i<35 && word7_i<15;
        1,4: fields_ok=keypair_i<512 && word6_i==0 && word7_i==0;
        2: fields_ok=keypair_i==0 && word6_i>=1 && word6_i<=9 && word7_i<(32'd512>>word6_i);
        3: fields_ok=keypair_i<512 && word6_i<=12 && word7_i<(32'd57344>>word6_i);
        5: fields_ok=keypair_i<512 && word6_i<35 && word7_i==0;
        6: fields_ok=keypair_i<512 && word6_i==0 && word7_i<57344;
        default: ;
        endcase
    end
    assign address_o={layer_i,tree_i,type_i,keypair_i,word6_i,word7_i};
    assign compressed_o={layer_i[7:0],tree_i[63:0],type_i[7:0],keypair_i,word6_i,word7_i};
    assign valid_o=layer_i<7 && type_i<7 && fields_ok &&
        (tree_i>>(9*(6-layer_i)))==0;
endmodule
`default_nettype wire
