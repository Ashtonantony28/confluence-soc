// apb_checker.sv: APB4 protocol checker (AMBA APB v2.0, IHI 0024C chapter 3 state machine).
// Bind or instantiate it on any APB4 port. Every failure is recorded in
// vip_common_pkg::vip_checker_db and, unless a violation self-test set expect_violations,
// reported as a UVM error. Rule IDs (APB-Rnn) are listed in vip/apb/README.md.
// Deliberately not checked: pslverr / prdata outside the last ACCESS cycle (the spec only
// gives them meaning when psel, penable and pready are high), and pwdata / pstrb stability on
// reads (they carry nothing then).
module apb_checker #(
  parameter int AW = 32,
  parameter int DW = 32
) (
  input logic           pclk,
  input logic           presetn,
  input logic [AW-1:0]  paddr,
  input logic           psel,
  input logic           penable,
  input logic           pwrite,
  input logic [DW-1:0]  pwdata,
  input logic [DW/8-1:0] pstrb,
  input logic [2:0]     pprot,
  input logic           pready,
  input logic [DW-1:0]  prdata,
  input logic           pslverr
);
  import uvm_pkg::*;
  `include "uvm_macros.svh"

  localparam int PLW = AW + 1 + 3 + DW + DW / 8;

  int unsigned violations = 0;

  function automatic void fail(string rule, string msg);
    violations++;
    vip_common_pkg::vip_checker_db::record(rule);
    if (!vip_common_pkg::vip_checker_db::expect_violations) `uvm_error("APB_SVA", $sformatf("%s: %s", rule, msg))
    else `uvm_info("APB_SVA", $sformatf("(expected) %s: %s", rule, msg), UVM_LOW)
  endfunction

  // Address and control that must hold from SETUP to the end of ACCESS (write data and
  // strobes only matter on writes).
  logic [PLW-1:0] ctrl;
  assign ctrl = {paddr, pwrite, pprot, pwrite ? {pwdata, pstrb} : {(DW + DW / 8){1'b0}}};

  logic setup, access;
  assign setup  = psel && !penable;
  assign access = psel && penable;

  // R01: ACCESS only follows SETUP or a wait-state ACCESS (penable never rises without SETUP).
  a_access_after_setup: assert property (@(posedge pclk) disable iff (!presetn)
      access |-> ($past(psel) && (!$past(penable) || !$past(pready))))
    else fail("APB-R01", "ACCESS (psel && penable) without a preceding SETUP cycle");
  // R02: SETUP lasts exactly one cycle and is always followed by ACCESS.
  a_setup_then_access: assert property (@(posedge pclk) disable iff (!presetn) setup |=> access)
    else fail("APB-R02", "SETUP not followed by ACCESS");
  // R03: during a wait state (pready low) the transfer stays in ACCESS with stable signals.
  a_wait_stable: assert property (@(posedge pclk) disable iff (!presetn)
      (access && !pready) |=> (access && $stable(ctrl)))
    else fail("APB-R03", "psel/penable dropped or address/control/data changed during a wait state");
  // R04: address/control/data do not change from SETUP to ACCESS.
  a_setup_stable: assert property (@(posedge pclk) disable iff (!presetn) setup |=> $stable(ctrl))
    else fail("APB-R04", "address/control/data changed between SETUP and ACCESS");
  // R05: penable falls after the completing ACCESS (next state is IDLE or SETUP).
  a_enable_falls: assert property (@(posedge pclk) disable iff (!presetn) (access && pready) |=> !penable)
    else fail("APB-R05", "penable still high after the transfer completed");
  // R06: penable is only high while psel is high.
  a_enable_needs_sel: assert property (@(posedge pclk) disable iff (!presetn) penable |-> psel)
    else fail("APB-R06", "penable high while psel is low");
  // R07: pstrb is all zero on reads (APB4 3.1).
  a_read_strb: assert property (@(posedge pclk) disable iff (!presetn) (psel && !pwrite) |-> (pstrb == '0))
    else fail("APB-R07", "pstrb non-zero on a read transfer");
  // R08: no transfer started while in reset (sampled on the cycle after reset asserts).
  a_reset: assert property (@(posedge pclk) !presetn |=> !presetn -> !(psel || penable))
    else fail("APB-R08", "psel/penable high during reset");

  // ---------------------------------------------------------------- covers
  c_wait:        cover property (@(posedge pclk) access && !pready ##1 access && pready);
  c_back_to_back: cover property (@(posedge pclk) access && pready ##1 setup);
endmodule
