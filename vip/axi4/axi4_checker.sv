// axi4_checker.sv: AXI4 protocol checker (ARM IHI 0022 rules most likely to be broken).
// Bind or instantiate it on any AXI4 port. Concurrent SVA covers handshake rules; procedural
// assertions keep per-ID burst bookkeeping (WLAST/RLAST position, responses with nothing
// outstanding). Every failure is recorded in vip_common_pkg::vip_checker_db and, unless a
// violation self-test set expect_violations, reported as a UVM error. Rule IDs in the messages (AXI4-Rnn) are listed in vip/axi4/README.md.
module axi4_checker #(
  parameter int AW  = 32,
  parameter int DW  = 128,
  parameter int IDW = 4,
  parameter int MAX_OUTSTANDING = 64
) (
  input logic           aclk,
  input logic           aresetn,
  input logic [IDW-1:0] awid,
  input logic [AW-1:0]  awaddr,
  input logic [7:0]     awlen,
  input logic [2:0]     awsize,
  input logic [1:0]     awburst,
  input logic           awvalid,
  input logic           awready,
  input logic [DW-1:0]  wdata,
  input logic [DW/8-1:0] wstrb,
  input logic           wlast,
  input logic           wvalid,
  input logic           wready,
  input logic [IDW-1:0] bid,
  input logic [1:0]     bresp,
  input logic           bvalid,
  input logic           bready,
  input logic [IDW-1:0] arid,
  input logic [AW-1:0]  araddr,
  input logic [7:0]     arlen,
  input logic [2:0]     arsize,
  input logic [1:0]     arburst,
  input logic           arvalid,
  input logic           arready,
  input logic [IDW-1:0] rid,
  input logic [DW-1:0]  rdata,
  input logic [1:0]     rresp,
  input logic           rlast,
  input logic           rvalid,
  input logic           rready
);
  import uvm_pkg::*;
  `include "uvm_macros.svh"

  localparam int MAXSIZE = $clog2(DW / 8);
  localparam int NID     = 1 << IDW;
  localparam logic [1:0] BURST_FIXED = 2'd0, BURST_INCR = 2'd1, BURST_WRAP = 2'd2, BURST_RSVD = 2'd3;

  int unsigned violations = 0;

  // Failures go to vip_checker_db; a violation self-test sets its expect_violations flag.
  function automatic void fail(string rule, string msg);
    violations++;
    vip_common_pkg::vip_checker_db::record(rule);
    if (!vip_common_pkg::vip_checker_db::expect_violations) `uvm_error("AXI4_SVA", $sformatf("%s: %s", rule, msg))
    else `uvm_info("AXI4_SVA", $sformatf("(expected) %s: %s", rule, msg), UVM_LOW)
  endfunction

  function automatic bit crosses_4k(logic [AW-1:0] a, logic [7:0] len, logic [2:0] size);
    longint unsigned al = longint'(a) & ~((64'd1 << size) - 1);
    return ((al & 64'hFFF) + ((64'(len) + 1) << size)) > 64'd4096;
  endfunction

  // ---------------------------------------------------------------- handshake rules
  // R01-R05: once VALID is high it stays high, with stable payload, until READY.
  property p_hold(logic v, logic r, logic [511:0] pl);
    @(posedge aclk) disable iff (!aresetn) (v && !r) |=> (v && $stable(pl));
  endproperty
  a_aw_hold: assert property (p_hold(awvalid, awready, 512'({awid, awaddr, awlen, awsize, awburst})))
    else fail("AXI4-R01", "AW valid dropped or payload changed before awready");
  a_w_hold:  assert property (p_hold(wvalid, wready, 512'({wdata, wstrb, wlast})))
    else fail("AXI4-R02", "W valid dropped or payload changed before wready");
  a_b_hold:  assert property (p_hold(bvalid, bready, 512'({bid, bresp})))
    else fail("AXI4-R03", "B valid dropped or payload changed before bready");
  a_ar_hold: assert property (p_hold(arvalid, arready, 512'({arid, araddr, arlen, arsize, arburst})))
    else fail("AXI4-R04", "AR valid dropped or payload changed before arready");
  a_r_hold:  assert property (p_hold(rvalid, rready, 512'({rid, rdata, rresp, rlast})))
    else fail("AXI4-R05", "R valid dropped or payload changed before rready");

  // R06: VALIDs low while in reset (sampled on the cycle after reset asserts).
  a_reset: assert property (@(posedge aclk) !aresetn |=> !aresetn -> !(awvalid || wvalid || arvalid || bvalid || rvalid))
    else fail("AXI4-R06", "valid high during reset");

  // ---------------------------------------------------------------- address legality
  always_ff @(posedge aclk) if (aresetn) begin
    if (awvalid) check_addr("AW", awaddr, awlen, awsize, awburst);
    if (arvalid) check_addr("AR", araddr, arlen, arsize, arburst);
  end

  function automatic void check_addr(string ch, logic [AW-1:0] a, logic [7:0] len, logic [2:0] size,
                                     logic [1:0] burst);
    if (burst == BURST_RSVD) fail("AXI4-R07", $sformatf("%s burst type 2'b11 is reserved", ch));
    if (int'(size) > MAXSIZE) fail("AXI4-R08", $sformatf("%s size %0d wider than %0d-byte bus", ch, size, DW / 8));
    if (burst == BURST_WRAP && !(len inside {8'd1, 8'd3, 8'd7, 8'd15}))
      fail("AXI4-R09", $sformatf("%s WRAP length %0d not 2/4/8/16", ch, int'(len) + 1));
    if (burst == BURST_WRAP && ((longint'(a) & ((64'd1 << size) - 1)) != 0))
      fail("AXI4-R10", $sformatf("%s WRAP start %0h not size-aligned", ch, a));
    if (burst == BURST_FIXED && len > 15) fail("AXI4-R11", $sformatf("%s FIXED length %0d > 16", ch, int'(len) + 1));
    if (burst == BURST_INCR && crosses_4k(a, len, size))
      fail("AXI4-R12", $sformatf("%s INCR burst at %0h len %0d crosses 4 KiB", ch, a, int'(len) + 1));
  endfunction

  // ---------------------------------------------------------------- burst bookkeeping
  int unsigned aw_len_q[$];        // lengths of accepted AW, in order
  int unsigned w_cnt_q[$];         // beat counts of completed W bursts (W may lead AW)
  int unsigned w_beats;            // beats of the W burst in progress
  int unsigned w_beats_prev;
  logic [IDW-1:0] aw_id_q[$];      // AW IDs in order, credited to wr_done when paired with data
  int unsigned wr_done[NID];       // writes with AW + last W, awaiting B, per ID
  int unsigned rd_len_q[NID][$];   // outstanding read lengths per ID
  int unsigned r_beats[NID];       // beats received of the oldest read per ID

  // Blocking updates on purpose: the bookkeeping is a checker model, not hardware.
  // Locals are declared here and assigned below: an initialiser on a declaration inside a
  // static always block would run only once.
  // R18 bookkeeping: address/size/burst of each AW, consumed by its W burst. The strobes of a W
  // burst that leads its AW are kept and checked when the AW arrives.
  typedef struct { longint unsigned addr; int unsigned size, len; logic [1:0] burst; } aw_t;
  aw_t         aw_w_q[$];
  int          w_lane_burst;       // index into aw_w_q of the W burst in progress, -1 = unknown
  int unsigned w_lane_beat;
  logic [DW/8-1:0] led_strb[$];   // strobes of W bursts that completed before their AW, flat
  int unsigned     led_len[$];    // beats of each such burst
  int unsigned     led_cur;       // beats of the led W burst in progress

  // byte lanes beat n of a burst may use (IHI 0022 A3.4.3: narrow and unaligned transfers)
  function automatic logic [DW/8-1:0] lanes(aw_t a, int unsigned n);
    longint unsigned nb = 1 << a.size, ba, lo, aligned, wsz;
    if (a.burst == BURST_FIXED) ba = a.addr;
    else if (a.burst == BURST_WRAP) begin
      wsz = nb * a.len;
      lo  = (a.addr / wsz) * wsz;
      ba  = lo + ((a.addr - lo + n * nb) % wsz);
    end else ba = (n == 0) ? a.addr : ((a.addr / nb) * nb + n * nb);
    aligned = (ba / nb) * nb;
    lanes = '0;
    for (longint unsigned b = ba; b < aligned + nb; b++) lanes[b % (DW / 8)] = 1'b1;
  endfunction

  int unsigned exp_n, got_n, rn, rl, nl;
  logic [DW/8-1:0] ok_lanes, st;
  aw_t         a;
  always @(posedge aclk) begin
    if (!aresetn) begin
      aw_w_q.delete(); w_lane_burst = 0; w_lane_beat = 0; led_strb.delete(); led_len.delete(); led_cur = 0;
      aw_len_q.delete(); w_cnt_q.delete(); aw_id_q.delete(); w_beats = 0;
      for (int i = 0; i < NID; i++) begin wr_done[i] = 0; rd_len_q[i].delete(); r_beats[i] = 0; end
    end else begin
      if (awvalid && awready) begin
        a.addr = longint'(awaddr); a.size = awsize; a.len = int'(awlen) + 1; a.burst = awburst;
        aw_len_q.push_back(int'(awlen) + 1); aw_id_q.push_back(awid);
        if (led_len.size() > 0) begin    // its data already went by
          nl = led_len.pop_front();
          for (int unsigned k = 0; k < nl; k++) begin
            st = led_strb.pop_front();
            ok_lanes = lanes(a, k);
            if ((st & ~ok_lanes) != '0)
              fail("AXI4-R18", $sformatf("beat %0d of write to %0h (size %0d): wstrb %0h outside active lanes %0h",
                   k, a.addr, 1 << a.size, st, ok_lanes));
          end
        end else if (w_lane_burst != 0 && w_lane_beat > 0) begin
          // the AW of the led W burst in progress: check its beats so far, then the rest live
          for (int unsigned k = 0; k < led_cur; k++) begin
            st = led_strb.pop_front();
            ok_lanes = lanes(a, k);
            if ((st & ~ok_lanes) != '0)
              fail("AXI4-R18", $sformatf("beat %0d of write to %0h (size %0d): wstrb %0h outside active lanes %0h",
                   k, a.addr, 1 << a.size, st, ok_lanes));
          end
          led_cur = 0;
          aw_w_q.push_back(a);
          w_lane_burst = 0;
        end else aw_w_q.push_back(a);
      end
      // R18: WSTRB only on the byte lanes the beat's address and size make active.
      if (wvalid && wready) begin
        if (w_lane_beat == 0) w_lane_burst = (aw_w_q.size() > 0) ? 0 : -1;
        if (w_lane_burst != 0) begin led_strb.push_back(wstrb); led_cur++; end
        else begin
          ok_lanes = lanes(aw_w_q[0], w_lane_beat);
          if ((wstrb & ~ok_lanes) != '0)
            fail("AXI4-R18", $sformatf("beat %0d of write to %0h (size %0d): wstrb %0h outside active lanes %0h",
                 w_lane_beat, aw_w_q[0].addr, 1 << aw_w_q[0].size, wstrb, ok_lanes));
        end
        if (wlast) begin
          if (w_lane_burst == 0) void'(aw_w_q.pop_front());
          else begin led_len.push_back(led_cur); led_cur = 0; end
          w_lane_beat = 0;
        end else w_lane_beat++;
      end
      w_beats_prev = w_beats;
      if (wvalid && wready) begin
        if (wlast) begin w_cnt_q.push_back(w_beats + 1); w_beats = 0; end
        else w_beats = w_beats + 1;
      end
      // R13: WLAST exactly on the last beat of the matching AW (paired in order).
      while (aw_len_q.size() > 0 && w_cnt_q.size() > 0) begin
        exp_n = aw_len_q.pop_front();
        got_n = w_cnt_q.pop_front();
        if (exp_n != got_n) fail("AXI4-R13", $sformatf("WLAST after %0d beats, AW length %0d", got_n, exp_n));
        wr_done_push();
      end
      // R14: no W burst may run longer than its AW says (catches a missing WLAST early).
      if (wvalid && wready && !wlast && aw_len_q.size() > 0 && w_cnt_q.size() == 0 &&
          w_beats_prev + 1 >= aw_len_q[0])
        fail("AXI4-R14", $sformatf("W beat %0d without WLAST, AW length %0d", w_beats_prev + 1, aw_len_q[0]));
      // R15: B only for a write whose address and last data beat have been seen.
      if (bvalid && bready) begin
        if (wr_done[bid] == 0) fail("AXI4-R15", $sformatf("B for id %0h with no completed write", bid));
        else wr_done[bid] = wr_done[bid] - 1;
      end
      if (arvalid && arready) rd_len_q[arid].push_back(int'(arlen) + 1);
      // R16: R only for an outstanding read; R17: RLAST exactly on the last beat.
      if (rvalid && rready) begin
        if (rd_len_q[rid].size() == 0) fail("AXI4-R16", $sformatf("R for id %0h with no outstanding read", rid));
        else begin
          rn = r_beats[rid] + 1;
          rl = rd_len_q[rid][0];
          if (rlast != (rn == rl)) fail("AXI4-R17", $sformatf("id %0h RLAST=%0b on beat %0d of %0d", rid, rlast, rn, rl));
          if (rlast || rn >= rl) begin void'(rd_len_q[rid].pop_front()); r_beats[rid] = 0; end
          else r_beats[rid] = rn;
        end
      end
    end
  end

  function automatic void wr_done_push();
    if (aw_id_q.size() > 0) begin
      logic [IDW-1:0] i = aw_id_q.pop_front();
      wr_done[i] = wr_done[i] + 1;
    end
  endfunction

  // ---------------------------------------------------------------- covers
  c_aw_stall: cover property (@(posedge aclk) awvalid && !awready ##1 awvalid && awready);
  c_back_to_back_r: cover property (@(posedge aclk) rvalid && rready ##1 rvalid && rready);

endmodule
