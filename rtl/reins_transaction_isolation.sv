// TECHNOLOGY WRAPPER: one independently controlled isolation cell, placed after
// all outbound storage. Two preserved instances are in series, with no queue or
// common decoded final enable between/after them. A post-cell wire short and
// physical merging/bypassing of the cells are not qualified by this RTL model.
`default_nettype none
(* keep_hierarchy="yes", dont_touch="yes" *) module reins_transaction_isolation #(
    parameter bit COMPLEMENT_COMPARE=1'b0 // B uses complemented tag equality, separately decoded from A.
) (
    input logic allow_i, valid_i,        // This path's own control / predecessor's transaction.
    input logic [135:0] data_i,         // Held generation/sequence/endpoint bundle; never interpreted as control.
    input logic [63:0] generation_i,    // Fresh trusted run identity; queued old-run effects cannot escape on rearm.
    output logic valid_o, closed_o,     // Isolated valid / modeled physical-cell readback.
    output logic [135:0] data_o          // Zero when isolated.
);
    logic tag_matches;
    if (COMPLEMENT_COMPARE) begin : complemented_tag
        assign tag_matches=(~data_i[135:72])==(~generation_i);
    end else begin : true_tag
        assign tag_matches=data_i[135:72]==generation_i;
    end
    assign valid_o=allow_i && tag_matches ? valid_i : 1'b0;
    assign data_o=allow_i && tag_matches ? data_i : 136'd0;
    assign closed_o=!allow_i;
endmodule
`default_nettype wire
