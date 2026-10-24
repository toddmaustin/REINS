// Copyright (c) 2026 Todd Austin.
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// License: https://polyformproject.org/licenses/noncommercial/1.0.0/

// Full-width symbolic arithmetic; unconstrained r/P/W/L/time values, no truncation to a test width.
module timer_arithmetic_properties (
    input logic [63:0] r,p,w,l,now,issue,expiry,remaining,
    input logic valid,
    output logic schedule_valid,permit,fault
);
    wire [63:0] actual_i,actual_b,actual_e,actual_next;
    wire [63:0] predecessor=r-64'd1;
    wire [127:0] product={64'd0,predecessor}*{64'd0,p};
    wire [128:0] b={1'b0,product}+{65'd0,w};
    wire [128:0] e={1'b0,product}+{65'd0,l};
    wire [128:0] next_i={1'b0,product}+{65'd0,p};
    reins_round_schedule schedule(r,p,w,l,schedule_valid,actual_i,actual_b,actual_e,actual_next);
    reins_lease_check lease_checker(valid,now,l,issue,~issue,expiry,remaining,~remaining,fault,permit);
    always @* begin
        assert(schedule_valid==(r!=0 && w!=0 && w<=p && p<l && product[127:64]==0 && b[128:64]==0 && e[128:64]==0 && next_i[128:64]==0));
        if (schedule_valid) begin
            assert(actual_i==product[63:0]); assert(actual_b==b[63:0]); assert(actual_e==e[63:0]);
        end
        if (permit) begin assert(valid && !fault && now<expiry && remaining!=0 && now>=issue && now-issue<l); end
        if (valid && now>=expiry) assert(!permit);
    end
endmodule
