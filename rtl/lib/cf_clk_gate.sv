// cf_clk_gate.sv: clock-enable cell (ADR 0006). The enable is latched while clk is low, so gclk
// never glitches; gclk follows clk in cycles where en was high before the rising edge.
// Vendor-neutral behavioural model; an FPGA build maps it to a BUFGCE-style primitive.
`default_nettype none
module cf_clk_gate (
  input  logic clk,
  input  logic en,
  output logic gclk
);
  logic en_l;
  /* verilator lint_off LATCH */
  always_latch begin
    if (!clk) en_l = en;
  end
  /* verilator lint_on LATCH */
  assign gclk = clk & en_l;
endmodule
`default_nettype wire
