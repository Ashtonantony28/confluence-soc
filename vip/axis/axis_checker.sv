// axis_checker.sv: AXI4-Stream protocol checker (ARM IHI 0051A chapter 2). Bind or
// instantiate it on any AXI4-Stream port. Every failure is recorded in
// vip_common_pkg::vip_checker_db and, unless a violation self-test set expect_violations,
// reported as a UVM error. Rule IDs (AXIS-Rnn) are listed in vip/axis/README.md.
// The base protocol puts no constraint on TKEEP (null bytes may appear anywhere, also as
// whole null transfers), on TID/TDEST changing between transfers (streams may interleave)
// or on TREADY. R04 checks the optional "continuous aligned stream" profile and is only
// active while check_packed is high. Absent optional signals (width parameter 0) are ignored.
module axis_checker #(
  parameter int DW    = 32,
  parameter int IDW   = 0,
  parameter int DESTW = 0,
  parameter int UW    = 0,
  localparam int KW    = DW / 8,
  localparam int IDW_I = (IDW > 0) ? IDW : 1,
  localparam int DSW_I = (DESTW > 0) ? DESTW : 1,
  localparam int UW_I  = (UW > 0) ? UW : 1
) (
  input logic             aclk,
  input logic             aresetn,
  input logic             check_packed,   // enable R04 (continuous aligned stream)
  input logic [DW-1:0]    tdata,
  input logic [KW-1:0]    tkeep,
  input logic             tlast,
  input logic [UW_I-1:0]  tuser,
  input logic [IDW_I-1:0] tid,
  input logic [DSW_I-1:0] tdest,
  input logic             tvalid,
  input logic             tready
);
  import uvm_pkg::*;
  `include "uvm_macros.svh"

  localparam int PLW = DW + KW + 1 + UW_I + IDW_I + DSW_I;

  int unsigned violations = 0;

  function automatic void fail(string rule, string msg);
    violations++;
    vip_common_pkg::vip_checker_db::record(rule);
    if (!vip_common_pkg::vip_checker_db::expect_violations) `uvm_error("AXIS_SVA", $sformatf("%s: %s", rule, msg))
    else `uvm_info("AXIS_SVA", $sformatf("(expected) %s: %s", rule, msg), UVM_LOW)
  endfunction

  // Payload with absent optional signals masked out.
  logic [PLW-1:0] payload;
  assign payload = {tdata, tkeep, tlast,
                    (UW > 0) ? tuser : {UW_I{1'b0}},
                    (IDW > 0) ? tid : {IDW_I{1'b0}},
                    (DESTW > 0) ? tdest : {DSW_I{1'b0}}};

  // R01: once TVALID is high it stays high until TREADY.
  a_valid_hold: assert property (@(posedge aclk) disable iff (!aresetn) (tvalid && !tready) |=> tvalid)
    else fail("AXIS-R01", "tvalid dropped before tready");
  // R02: TDATA, TKEEP, TLAST, TUSER, TID, TDEST stable while TVALID && !TREADY.
  a_payload_hold: assert property (@(posedge aclk) disable iff (!aresetn) (tvalid && !tready) |=> $stable(payload))
    else fail("AXIS-R02", "payload changed while tvalid && !tready");
  // R03: TVALID low while in reset (sampled on the cycle after reset asserts).
  a_reset: assert property (@(posedge aclk) !aresetn |=> !aresetn -> !tvalid)
    else fail("AXIS-R03", "tvalid high during reset");
  // R04 (optional profile): TKEEP all ones except on the last transfer of a packet, where it
  // is a non-empty run of ones from lane 0.
  logic keep_contig;
  assign keep_contig = (tkeep != '0) && ((tkeep & (tkeep + 1'b1)) == '0);
  a_packed: assert property (@(posedge aclk) disable iff (!aresetn)
      (tvalid && check_packed) |-> (tlast ? keep_contig : (tkeep == '1)))
    else fail("AXIS-R04", $sformatf("tkeep %0h not packed (tlast=%0b)", tkeep, tlast));

  // ---------------------------------------------------------------- covers
  c_stall:         cover property (@(posedge aclk) tvalid && !tready ##1 tvalid && tready);
  c_back_to_back:  cover property (@(posedge aclk) tvalid && tready && tlast ##1 tvalid && tready);
endmodule
