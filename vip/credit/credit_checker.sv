// credit_checker.sv: protocol checker for a credit-based flit link. Bind or instantiate it on
// any credit link; DEPTH is the receiver buffer depth (the sender's initial credit count).
// Failures are recorded in vip_common_pkg::vip_checker_db and reported as UVM errors unless a
// violation self-test set expect_violations. Rules (vip/credit/README.md):
//   CREDIT-R01  a flit sent while the sender held no credit (receiver overflow)
//   CREDIT-R02  more credits returned than flits sent (credit count above DEPTH)
//   CREDIT-R03  valid or credit high during reset
module credit_checker #(
  parameter int DW    = 48,
  parameter int DEPTH = 4
) (
  input logic          clk,
  input logic          rst_n,
  input logic          valid,
  input logic [DW-1:0] data,
  input logic          credit
);
  import uvm_pkg::*;
  `include "uvm_macros.svh"

  int unsigned violations = 0;
  int          held = DEPTH;      // credits the sender holds
  int unsigned n_flits = 0, n_full = 0;
  bit          in_reset_prev = 0;

  function automatic void fail(string rule, string msg);
    violations++;
    vip_common_pkg::vip_checker_db::record(rule);
    if (!vip_common_pkg::vip_checker_db::expect_violations) `uvm_error("CREDIT_SVA", $sformatf("%s: %s", rule, msg))
    else `uvm_info("CREDIT_SVA", $sformatf("(expected) %s: %s", rule, msg), UVM_LOW)
  endfunction

  always @(posedge clk) begin
    if (!rst_n) begin
      // sampled on the cycle after reset asserts, like AXIS-R03
      if (in_reset_prev && (valid || credit)) fail("CREDIT-R03", $sformatf("valid=%0b credit=%0b in reset", valid, credit));
      held = DEPTH;
      in_reset_prev = 1;
    end else begin
      in_reset_prev = 0;
      if (valid) begin
        n_flits++;
        if (held <= 0) fail("CREDIT-R01", $sformatf("flit %0h sent with no credit", data));
      end
      held = held - int'(valid) + int'(credit);
      if (held == 0) n_full++;
      if (held > DEPTH) begin
        fail("CREDIT-R02", $sformatf("credit returned for no flit (sender holds %0d > depth %0d)", held, DEPTH));
        held = DEPTH;
      end
    end
  end

  // ---------------------------------------------------------------- covers
  c_back_to_back: cover property (@(posedge clk) disable iff (!rst_n) valid ##1 valid);
  c_credit_and_flit: cover property (@(posedge clk) disable iff (!rst_n) valid && credit);
endmodule
