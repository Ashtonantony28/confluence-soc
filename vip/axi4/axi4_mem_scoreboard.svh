// axi4_mem_scoreboard.svh: memory-consistency scoreboard for one or more AXI4 monitors that
// address the same memory (one master, or every master port of an interconnect).
//
// AXI4 does not order writes that are in flight at the same time, so the expected value of a
// byte is a *set*. Each byte keeps a history of possible-value sets (a 256-bit bitmap per
// entry). A completed write W makes a byte {W} plus every value written by a write that
// completed while W was in flight. A read R is checked once every write issued before R
// finished has completed; a returned byte must be in the union of the sets that held at any
// time during R's lifetime plus the values of writes whose lifetime overlapped R's.
// Bursts with an error response update nothing and are not data-checked; expect_resp()
// (override per environment) says which response each burst should get.

`uvm_analysis_imp_decl(_req)
`uvm_analysis_imp_decl(_done)

class axi4_byte_hist;
  time         t[$];
  bit [255:0]  v[$];
endclass

class axi4_mem_scoreboard extends uvm_component;
  `uvm_component_utils(axi4_mem_scoreboard)

  uvm_analysis_imp_req  #(axi4_item, axi4_mem_scoreboard) req_export;
  uvm_analysis_imp_done #(axi4_item, axi4_mem_scoreboard) done_export;

  vip_common_pkg::vip_uninit_e uninit = vip_common_pkg::UNINIT_ADDR_HASH;
  bit           enabled = 1;
  axi4_byte_hist hist[bit [63:0]];
  axi4_item     inflight_wr[$];     // address seen, response not yet
  axi4_item     done_wr[$];         // completed writes still relevant to pending checks
  axi4_item     pend_rd[$];         // completed reads waiting for overlapping writes
  int unsigned  n_wr, n_rd, n_err, n_bytes, n_ambiguous;
  time          horizon;            // no open or future check looks earlier than this

  function new(string name, uvm_component parent);
    super.new(name, parent);
    req_export  = new("req_export", this);
    done_export = new("done_export", this);
  endfunction

  // Expected response for a burst; environments override (error regions, decode errors).
  virtual function axi4_resp_e expect_resp(axi4_item t);
    return AXI4_OKAY;
  endfunction

  // ------------------------------------------------------------------ byte helpers
  function bit [255:0] initial_set(bit [63:0] a);
    bit [255:0] s = '0;
    s[(uninit == vip_common_pkg::UNINIT_ZERO) ? 0 : vip_common_pkg::vip_addr_hash(a)] = 1;
    return s;
  endfunction

  function bit [255:0] set_at(bit [63:0] a, time tm);
    bit [255:0] s;
    if (!hist.exists(a)) return initial_set(a);
    s = initial_set(a);
    foreach (hist[a].t[i]) if (hist[a].t[i] <= tm) s = hist[a].v[i];
    return s;
  endfunction

  // Union of every set the byte held during [t0, t1].
  function bit [255:0] sets_during(bit [63:0] a, time t0, time t1);
    bit [255:0] s = set_at(a, t0);
    if (hist.exists(a)) foreach (hist[a].t[i]) if (hist[a].t[i] > t0 && hist[a].t[i] <= t1) s |= hist[a].v[i];
    return s;
  endfunction

  // Calls f for every (address, byte) that the burst carries with strobe set.
  typedef struct { bit [63:0] a; bit [7:0] d; } byte_t;
  function void burst_bytes(axi4_item t, ref byte_t out[$]);
    out.delete();
    for (int unsigned n = 0; n < t.beats() && n < t.data.size(); n++) begin
      int unsigned lo, hi;
      bit [63:0] base = t.beat_addr(n) & ~64'(t.dbytes - 1);
      t.beat_lanes(n, lo, hi);
      for (int unsigned b = lo; b <= hi; b++)
        if (t.dir == AXI4_READ || t.strb[n][b]) begin
          byte_t x; x.a = base + 64'(b); x.d = t.data[n][8*b +: 8]; out.push_back(x);
        end
    end
  endfunction

  function bit ok_resp(axi4_item t);
    axi4_resp_e exp = expect_resp(t);
    foreach (t.resp[i]) if (t.resp[i] != exp) begin
      `uvm_error("MEM_SB", $sformatf("beat %0d resp %s, expected %s: %s", i, t.resp[i].name(), exp.name(), t.convert2string()))
      return 0;
    end
    return 1;
  endfunction

  // ------------------------------------------------------------------ inputs
  function void write_req(axi4_item t);
    if (enabled && t.dir == AXI4_WRITE) inflight_wr.push_back(t);
  endfunction

  function void write_done(axi4_item t);
    if (!enabled) return;
    if (t.dir == AXI4_WRITE) begin
      foreach (inflight_wr[i]) if (inflight_wr[i] == t) begin inflight_wr.delete(i); break; end
      n_wr++;
      void'(ok_resp(t));
      if (t.resp.size() && t.resp[0] != AXI4_OKAY && t.resp[0] != AXI4_EXOKAY) n_err++;
      else commit(t);
    end else begin
      n_rd++;
      void'(ok_resp(t));
      pend_rd.push_back(t);
    end
    check_reads();
    prune();
  endfunction

  function void commit(axi4_item w);
    byte_t bs[$];
    burst_bytes(w, bs);
    foreach (bs[i]) begin
      bit [255:0] s = '0;
      s[bs[i].d] = 1;
      // Writes that completed while w was in flight may be ordered either side of it.
      foreach (done_wr[k]) if (done_wr[k].t_done >= w.t_addr) begin
        byte_t ob[$];
        burst_bytes(done_wr[k], ob);
        foreach (ob[j]) if (ob[j].a == bs[i].a) s[ob[j].d] = 1;
      end
      if ($countones(s) > 1) n_ambiguous++;
      if (!hist.exists(bs[i].a)) hist[bs[i].a] = new();
      // Keep only the last entry before the horizon (the value then) and everything after.
      while (hist[bs[i].a].t.size() > 1 && hist[bs[i].a].t[1] <= horizon) begin
        void'(hist[bs[i].a].t.pop_front()); void'(hist[bs[i].a].v.pop_front());
      end
      hist[bs[i].a].t.push_back(w.t_done);
      hist[bs[i].a].v.push_back(s);
    end
    done_wr.push_back(w);
  endfunction

  function void check_reads();
    for (int i = 0; i < pend_rd.size(); i++) begin
      axi4_item r = pend_rd[i];
      bit blocked = 0;
      foreach (inflight_wr[k]) if (inflight_wr[k].t_addr <= r.t_done) blocked = 1;
      if (blocked) continue;
      pend_rd.delete(i); i--;
      if (r.resp.size() && r.resp[0] != AXI4_OKAY) begin n_err++; continue; end
      check_read(r);
    end
  endfunction

  function void check_read(axi4_item r);
    byte_t bs[$];
    burst_bytes(r, bs);
    foreach (bs[i]) begin
      bit [255:0] s = sets_during(bs[i].a, r.t_addr, r.t_done);
      foreach (done_wr[k]) if (done_wr[k].t_addr <= r.t_done && done_wr[k].t_done >= r.t_addr) begin
        byte_t ob[$];
        burst_bytes(done_wr[k], ob);
        foreach (ob[j]) if (ob[j].a == bs[i].a) s[ob[j].d] = 1;
      end
      n_bytes++;
      if (!s[bs[i].d])
        `uvm_error("MEM_SB", $sformatf("read byte %0h = %02h, not a possible value (%0d candidates): %s",
                   bs[i].a, bs[i].d, $countones(s), r.convert2string()))
    end
  endfunction

  // Forget completed writes and history that no pending or future check can need.
  function void prune();
    horizon = $time;
    foreach (inflight_wr[k]) if (inflight_wr[k].t_addr < horizon) horizon = inflight_wr[k].t_addr;
    foreach (pend_rd[k]) if (pend_rd[k].t_addr < horizon) horizon = pend_rd[k].t_addr;
    for (int k = 0; k < done_wr.size(); k++)
      if (done_wr[k].t_done < horizon) begin done_wr.delete(k); k--; end
  endfunction

  function void check_phase(uvm_phase phase);
    if (inflight_wr.size() || pend_rd.size())
      `uvm_error("MEM_SB", $sformatf("%0d writes in flight, %0d reads unchecked at end of test",
                 inflight_wr.size(), pend_rd.size()))
  endfunction

  function void report_phase(uvm_phase phase);
    `uvm_info("MEM_SB", $sformatf("%0d writes, %0d reads, %0d error bursts, %0d read bytes checked, %0d ambiguous byte writes",
              n_wr, n_rd, n_err, n_bytes, n_ambiguous), UVM_LOW)
  endfunction
endclass
