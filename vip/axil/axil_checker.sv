// axil_checker.sv: AXI4-Lite protocol checker (ARM IHI 0022, part B). Bind or instantiate it
// on any AXI4-Lite port. Concurrent SVA covers the handshake rules; procedural counters check
// that responses only answer outstanding requests. Every failure is recorded in
// vip_common_pkg::vip_checker_db and, unless a violation self-test set expect_violations,
// reported as a UVM error. Rule IDs (AXIL-Rnn) are listed in vip/axil/README.md.
// Deliberately not checked: an all-zero WSTRB (the spec permits it) and address alignment
// (an unaligned AXI4-Lite address is legal; the strobes say which bytes are written).
module axil_checker #(
  parameter int AW = 32,
  parameter int DW = 32
) (
  input logic           aclk,
  input logic           aresetn,
  input logic [AW-1:0]  awaddr,
  input logic [2:0]     awprot,
  input logic           awvalid,
  input logic           awready,
  input logic [DW-1:0]  wdata,
  input logic [DW/8-1:0] wstrb,
  input logic           wvalid,
  input logic           wready,
  input logic [1:0]     bresp,
  input logic           bvalid,
  input logic           bready,
  input logic [AW-1:0]  araddr,
  input logic [2:0]     arprot,
  input logic           arvalid,
  input logic           arready,
  input logic [DW-1:0]  rdata,
  input logic [1:0]     rresp,
  input logic           rvalid,
  input logic           rready
);
  import uvm_pkg::*;
  `include "uvm_macros.svh"

  localparam logic [1:0] RESP_EXOKAY = 2'b01;
  localparam int         PLW = 256;   // packed payload width used by the hold property

  int unsigned violations = 0;

  function automatic void fail(string rule, string msg);
    violations++;
    vip_common_pkg::vip_checker_db::record(rule);
    if (!vip_common_pkg::vip_checker_db::expect_violations) `uvm_error("AXIL_SVA", $sformatf("%s: %s", rule, msg))
    else `uvm_info("AXIL_SVA", $sformatf("(expected) %s: %s", rule, msg), UVM_LOW)
  endfunction

  // ---------------------------------------------------------------- handshake rules
  // R01-R05: once VALID is high it stays high, with stable payload, until READY.
  property p_hold(logic v, logic r, logic [PLW-1:0] pl);
    @(posedge aclk) disable iff (!aresetn) (v && !r) |=> (v && $stable(pl));
  endproperty
  a_aw_hold: assert property (p_hold(awvalid, awready, PLW'({awaddr, awprot})))
    else fail("AXIL-R01", "AW valid dropped or payload changed before awready");
  a_w_hold:  assert property (p_hold(wvalid, wready, PLW'({wdata, wstrb})))
    else fail("AXIL-R02", "W valid dropped or payload changed before wready");
  a_b_hold:  assert property (p_hold(bvalid, bready, PLW'(bresp)))
    else fail("AXIL-R03", "B valid dropped or payload changed before bready");
  a_ar_hold: assert property (p_hold(arvalid, arready, PLW'({araddr, arprot})))
    else fail("AXIL-R04", "AR valid dropped or payload changed before arready");
  a_r_hold:  assert property (p_hold(rvalid, rready, PLW'({rdata, rresp})))
    else fail("AXIL-R05", "R valid dropped or payload changed before rready");

  // R06: VALIDs low while in reset (sampled on the cycle after reset asserts).
  a_reset: assert property (@(posedge aclk) !aresetn |=> !aresetn -> !(awvalid || wvalid || arvalid || bvalid || rvalid))
    else fail("AXIL-R06", "valid high during reset");

  // ---------------------------------------------------------------- response bookkeeping
  // A response may only follow its request handshakes (the slave sees AW, W / AR before it
  // raises BVALID / RVALID), so responses are checked against the counts before this edge.
  // Blocking updates on purpose: the bookkeeping is a checker model, not hardware. wr_done is
  // declared here and assigned below (an initialiser inside a static always block runs once).
  longint unsigned aw_cnt, w_cnt, b_cnt, ar_cnt, r_cnt;
  longint unsigned wr_done;
  always @(posedge aclk) begin
    if (!aresetn) begin
      aw_cnt = 0; w_cnt = 0; b_cnt = 0; ar_cnt = 0; r_cnt = 0;
    end else begin
      wr_done = (aw_cnt < w_cnt) ? aw_cnt : w_cnt;
      // R07: B only when a write (address and data both accepted) is unanswered.
      if (bvalid && bready) begin
        if (b_cnt >= wr_done) fail("AXIL-R07", "B with no completed write outstanding");
        b_cnt = b_cnt + 1;
      end
      // R08: R only when a read is unanswered.
      if (rvalid && rready) begin
        if (r_cnt >= ar_cnt) fail("AXIL-R08", "R with no read outstanding");
        r_cnt = r_cnt + 1;
      end
      // R09: AXI4-Lite has no exclusive access, so EXOKAY is never a legal response.
      if (bvalid && bresp == RESP_EXOKAY) fail("AXIL-R09", "BRESP EXOKAY on AXI4-Lite");
      if (rvalid && rresp == RESP_EXOKAY) fail("AXIL-R09", "RRESP EXOKAY on AXI4-Lite");
      if (awvalid && awready) aw_cnt = aw_cnt + 1;
      if (wvalid && wready)   w_cnt  = w_cnt + 1;
      if (arvalid && arready) ar_cnt = ar_cnt + 1;
    end
  end

  // ---------------------------------------------------------------- covers
  c_w_before_aw: cover property (@(posedge aclk) wvalid && wready && !(awvalid && awready) && (aw_cnt <= w_cnt));
  c_aw_stall:    cover property (@(posedge aclk) awvalid && !awready ##1 awvalid && awready);
  c_back_to_back_r: cover property (@(posedge aclk) rvalid && rready ##1 rvalid && rready);
endmodule
