// Copyright (c) 2026 Todd Austin.
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// License: https://polyformproject.org/licenses/noncommercial/1.0.0/

// Mode-0, MSB-first slave oversampled by the independent monitor clock.
// These are logical pad signals: a technology wrapper drives Z when miso_oe_o=0.
`default_nettype none
module reins_spi_slave #(
    parameter int unsigned MIN_PHASE=20, // 5 us at the documented 4 MHz monitor profile.
    parameter int unsigned MIN_GAP=40    // 10 us deselected at that profile.
) (
    input logic clk_i, por_ni, reset_i, // Always-on clock, power loss, canceling logic reset.
    input logic trusted_tick_i,         // Independent nominal 1 MHz events, including while compute is off.
    input logic sclk_i, cs_ni, mosi_i,  // Asynchronous mode-0 pad inputs.
    output logic miso_o, miso_oe_o,     // Registered transmit bit; asynchronous deselect disables pad output.
    input logic [7:0] tx_byte_i,        // Mailbox byte selected by tx_index_o before each falling edge.
    output logic [8:0] tx_index_o,      // Number of fully clocked bytes, saturating at 511.
    output logic start_o, byte_valid_o, end_o, // Monitor-clock events, never clocks for enforcement.
    output logic [8:0] byte_index_o, bytes_o,  // Captured receive-byte index / final complete-byte count.
    output logic [8:0] byte_index_inverse_o, // Independently captured complementary byte counter for address checks.
    output logic [7:0] byte_o,          // One complete MOSI byte, header included.
    output logic frame_error_o,        // Partial bits, electrical sequencing, overflow, reset or timeout.
    output logic integrity_alarm_o     // Protected counter/control mismatch; distinct from malformed traffic.
);
    (* ASYNC_REG="TRUE" *) logic [1:0] cs_sync_q, sclk_sync_q, mosi_sync_q;
    logic cs_previous_q, sclk_previous_q, active_q, bad_q;
    logic [2:0] bits_q, bits_inverse_q;
    logic [8:0] bytes_q, bytes_inverse_q;
    logic [6:0] shift_q;               // Previous seven received bits; the eighth comes directly from MOSI.
    logic [31:0] age_q, age_inverse_q, phase_q, gap_q;
    logic selected, deselected, rising, falling, control_bad, timed_out;
    assign selected=cs_previous_q && !cs_sync_q[1];
    assign deselected=!cs_previous_q && cs_sync_q[1];
    assign rising=!sclk_previous_q && sclk_sync_q[1];
    assign falling=sclk_previous_q && !sclk_sync_q[1];
    assign control_bad=bits_q!=~bits_inverse_q || bytes_q!=~bytes_inverse_q || age_q!=~age_inverse_q;
    // Exactly 100,000 elapsed trusted ticks is within the specified maximum.
    assign timed_out=active_q && trusted_tick_i && age_q>=32'd100000;
    assign integrity_alarm_o=por_ni && !reset_i && control_bad;
    assign miso_oe_o=por_ni && !reset_i && !cs_ni;
    assign tx_index_o=bytes_q;
    always_ff @(posedge clk_i) begin
        if (!por_ni) begin
            cs_sync_q<=2'b11; sclk_sync_q<='0; mosi_sync_q<='0;
            cs_previous_q<=1'b1; sclk_previous_q<=1'b0;
        end else begin
            cs_sync_q<={cs_sync_q[0],cs_ni}; sclk_sync_q<={sclk_sync_q[0],sclk_i};
            mosi_sync_q<={mosi_sync_q[0],mosi_i};
            cs_previous_q<=cs_sync_q[1]; sclk_previous_q<=sclk_sync_q[1];
        end
        start_o<=1'b0; byte_valid_o<=1'b0; end_o<=1'b0;
        if (!por_ni || reset_i) begin
            active_q<=1'b0; bad_q<=1'b0; bits_q<='0; bits_inverse_q<='1;
            bytes_q<='0; bytes_inverse_q<='1; shift_q<='0; miso_o<=1'b0;
            age_q<='0; age_inverse_q<='1; phase_q<='0; gap_q<='0;
            frame_error_o<=1'b1; byte_o<='0; byte_index_o<='0; byte_index_inverse_o<='1; bytes_o<='0;
        end else begin
            if (cs_sync_q[1]) begin
                if (gap_q<MIN_GAP) gap_q<=gap_q+32'd1;
            end else gap_q<='0;
            if (phase_q<MIN_PHASE) phase_q<=phase_q+32'd1;
            if (rising || falling || selected) phase_q<='0;
            if (selected) begin
                active_q<=1'b1; start_o<=1'b1;
                bad_q<=sclk_sync_q[1] || gap_q<MIN_GAP;
                bits_q<='0; bits_inverse_q<='1; bytes_q<='0; bytes_inverse_q<='1;
                age_q<='0; age_inverse_q<='1; shift_q<='0; miso_o<=1'b0; frame_error_o<=1'b0;
            end else if (active_q) begin
                if (trusted_tick_i) begin age_q<=age_q+32'd1; age_inverse_q<=age_inverse_q-32'd1; end
                if (timed_out || control_bad || deselected) begin
                    active_q<=1'b0; end_o<=1'b1; bytes_o<=bytes_q;
                    frame_error_o<=bad_q || bits_q!=0 || timed_out || control_bad || sclk_sync_q[1];
                    miso_o<=1'b0;
                end else if (rising) begin
                    if (phase_q<MIN_PHASE-1) bad_q<=1'b1;
                    shift_q<={shift_q[5:0],mosi_sync_q[1]};
                    bits_q<=bits_q+3'd1; bits_inverse_q<=bits_inverse_q-3'd1;
                    if (bits_q==7) begin
                        byte_valid_o<=1'b1; byte_o<={shift_q,mosi_sync_q[1]}; byte_index_o<=bytes_q;
                        byte_index_inverse_o<=bytes_inverse_q;
                        if (bytes_q==511) bad_q<=1'b1;
                        else begin bytes_q<=bytes_q+9'd1; bytes_inverse_q<=bytes_inverse_q-9'd1; end
                    end
                end else if (falling) begin
                    if (phase_q<MIN_PHASE-1) bad_q<=1'b1;
                    miso_o<=tx_byte_i[3'd7-bits_q];
                end
            end
        end
    end
`ifndef SYNTHESIS
    initial assert (MIN_PHASE>=4 && MIN_GAP>=MIN_PHASE) else $fatal(1,"invalid SPI monitor profile");
`endif
endmodule
`default_nettype wire
