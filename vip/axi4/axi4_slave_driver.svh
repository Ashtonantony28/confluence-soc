// axi4_slave_driver.svh: reactive, memory-backed AXI4 slave. Accepts up to
// cfg.slave_max_accept requests per direction, answers after a random latency, and (when
// enabled) completes different IDs out of order and interleaves read data across IDs while
// keeping per-ID order, exactly the freedom AXI4 gives a slave.

class axi4_slave_driver #(int AW = 32, int DW = 128, int IDW = 4) extends uvm_component;
  `uvm_component_param_utils(axi4_slave_driver #(AW, DW, IDW))

  typedef virtual axi4_if #(.AW(AW), .DW(DW), .IDW(IDW)) vif_t;
  localparam int SW = DW / 8;

  vif_t        vif;
  axi4_cfg     cfg;
  longint unsigned cycle;
  bit          injected;

  axi4_item    aw_pend[$];          // accepted write addresses waiting for their data
  axi4_item    w_bursts[$];         // complete write data bursts waiting for their address
  axi4_item    w_cur;               // write data burst being received
  axi4_item    b_sched[$];          // writes applied, response pending
  longint unsigned b_ready_at[$];
  axi4_item    r_sched[$];          // accepted reads
  longint unsigned r_ready_at[$];
  int unsigned r_beat[$];           // next beat to send per entry
  int          b_cur = -1;          // index into b_sched being driven (-1 none)
  int          r_cur = -1;

  function new(string name, uvm_component parent); super.new(name, parent); endfunction

  function void build_phase(uvm_phase phase);
    if (!uvm_config_db#(vif_t)::get(this, "", "vif", vif)) `uvm_fatal("NOVIF", "axi4 vif not set")
    if (!uvm_config_db#(axi4_cfg)::get(this, "", "cfg", cfg)) `uvm_fatal("NOCFG", "axi4 cfg not set")
    if (cfg.mem == null) cfg.mem = vip_common_pkg::vip_mem::type_id::create("mem");
  endfunction

  function bit inject_now(axi4_inject_e k);
    if (cfg.inject != k || injected) return 0;
    injected = 1;
    `uvm_info("AXI4_INJ", $sformatf("injecting %s", k.name()), UVM_LOW)
    return 1;
  endfunction

  function longint unsigned latency();
    return longint'($urandom_range(cfg.slave_max_latency, cfg.slave_min_latency));
  endfunction

  function bit busy();
    return $urandom_range(99) < cfg.slave_ready_busy_pct;
  endfunction

  task run_phase(uvm_phase phase);
    vif.awready <= 0; vif.wready <= 0; vif.arready <= 0; vif.bvalid <= 0; vif.rvalid <= 0;
    vif.bid <= '0; vif.bresp <= '0; vif.rid <= '0; vif.rdata <= '0; vif.rresp <= '0; vif.rlast <= 0;
    @(posedge vif.aclk);
    while (!vif.aresetn) @(posedge vif.aclk);
    forever begin
      @(posedge vif.aclk);
      cycle++;
      // Sample every handshake first (all use pre-edge values), then decide next outputs.
      sample_aw(); sample_w(); sample_b(); sample_ar(); sample_r();
      apply_writes();
      drive_ready();
      drive_b();
      drive_r();
    end
  endtask

  // ------------------------------------------------------------------ sampling
  function axi4_item new_req(axi4_dir_e d, bit [IDW-1:0] id, bit [AW-1:0] a, bit [7:0] l,
                             bit [2:0] s, bit [1:0] b);
    axi4_item t = axi4_item::type_id::create("req");
    t.dir = d; t.id = AXI4_MAX_IDW'(id); t.addr = AXI4_MAX_AW'(a); t.len = l; t.size = s;
    t.burst = axi4_burst_e'(b); t.dbytes = cfg.data_bytes;
    return t;
  endfunction

  function void sample_aw();
    if (vif.awvalid && vif.awready)
      aw_pend.push_back(new_req(AXI4_WRITE, vif.awid, vif.awaddr, vif.awlen, vif.awsize, vif.awburst));
  endfunction

  function void sample_w();
    if (vif.wvalid && vif.wready) begin
      int unsigned n;
      if (w_cur == null) w_cur = axi4_item::type_id::create("wdata");
      n = w_cur.data.size();
      w_cur.data = new[n + 1](w_cur.data);
      w_cur.strb = new[n + 1](w_cur.strb);
      w_cur.data[n] = AXI4_MAX_DW'(vif.wdata);
      w_cur.strb[n] = (AXI4_MAX_DW/8)'(vif.wstrb);
      if (vif.wlast) begin w_bursts.push_back(w_cur); w_cur = null; end
    end
  endfunction

  function void sample_b();
    if (vif.bvalid && vif.bready && b_cur >= 0) begin
      b_sched.delete(b_cur); b_ready_at.delete(b_cur); b_cur = -1;
    end else if (vif.bvalid && vif.bready && b_cur < 0) begin
      b_cur = -1;   // an injected unknown-ID response was taken
    end
  endfunction

  function void sample_ar();
    if (vif.arvalid && vif.arready) begin
      r_sched.push_back(new_req(AXI4_READ, vif.arid, vif.araddr, vif.arlen, vif.arsize, vif.arburst));
      r_ready_at.push_back(cycle + latency());
      r_beat.push_back(0);
    end
  endfunction

  bit r_inj_pending;   // the beat on the bus is an injected unknown-ID beat
  bit r_early_last;    // the beat on the bus carries an injected early rlast

  function void sample_r();
    if (vif.rvalid && vif.rready) begin
      if (r_inj_pending) r_inj_pending = 0;
      else if (r_cur >= 0) begin
        r_beat[r_cur]++;
        if (r_early_last || r_beat[r_cur] >= r_sched[r_cur].beats()) begin
          r_sched.delete(r_cur); r_ready_at.delete(r_cur); r_beat.delete(r_cur);
          r_cur = -1;
        end
        r_early_last = 0;
      end
    end
  endfunction

  // ------------------------------------------------------------------ memory side
  function int unsigned eff_size(axi4_item t);
    int unsigned maxsz = $clog2(cfg.data_bytes);
    return (t.size > maxsz) ? maxsz : t.size;  // an oversize request (a violation) is clamped
  endfunction

  function bit burst_hits_err(axi4_item t);
    for (int unsigned n = 0; n < t.beats(); n++)
      if (cfg.in_err_region(t.beat_addr(n))) return 1;
    return 0;
  endfunction

  function void apply_writes();
    while (aw_pend.size() > 0 && w_bursts.size() > 0) begin
      axi4_item a = aw_pend.pop_front();
      axi4_item w = w_bursts.pop_front();
      bit err;
      a.size = 3'(eff_size(a));
      err = burst_hits_err(a);
      if (!err) begin
        int unsigned nb = (w.data.size() < a.beats()) ? w.data.size() : a.beats();
        for (int unsigned n = 0; n < nb; n++) begin
          int unsigned lo, hi;
          bit [63:0] base = a.beat_addr(n) & ~64'(cfg.data_bytes - 1);
          a.beat_lanes(n, lo, hi);
          for (int unsigned b = lo; b <= hi; b++)
            if (w.strb[n][b]) cfg.mem.write_byte(base + 64'(b), w.data[n][8*b +: 8]);
        end
      end
      a.resp = new[1];
      a.resp[0] = err ? AXI4_SLVERR : AXI4_OKAY;
      b_sched.push_back(a);
      b_ready_at.push_back(cycle + latency());
    end
  endfunction

  // ------------------------------------------------------------------ outputs
  function void drive_ready();
    int unsigned wr_inflight = aw_pend.size() + b_sched.size();
    vif.awready <= (wr_inflight < cfg.slave_max_accept) && !busy();
    vif.wready  <= !busy();
    vif.arready <= (r_sched.size() < cfg.slave_max_accept) && !busy();
  endfunction

  // Entries that are the oldest outstanding of their ID and whose latency has elapsed.
  function void eligible(ref axi4_item q[$], ref longint unsigned rdy[$], output int idx[$]);
    bit seen[bit [AXI4_MAX_IDW-1:0]];
    idx.delete();
    foreach (q[i]) begin
      if (!seen.exists(q[i].id)) begin
        seen[q[i].id] = 1;
        if (rdy[i] <= cycle) idx.push_back(i);
      end
    end
  endfunction

  function bit [IDW-1:0] unused_id(ref axi4_item q[$]);
    for (int unsigned c = 0; c < (1 << IDW); c++) begin
      bit used = 0;
      foreach (q[i]) if (q[i].id == c) used = 1;
      if (!used) return IDW'(c);
    end
    return '1;
  endfunction

  bit b_inj_active;
  bit b_dropped;

  function void drive_b();
    int idx[$];
    // Hold the current response until it is taken (AXI handshake rule).
    if ((b_cur >= 0 || b_inj_active) && !(vif.bvalid && vif.bready)) begin
      if (!b_dropped && vif.bvalid && inject_now(AXI4_INJ_B_VALID_DROP)) begin
        vif.bvalid <= 0; b_dropped = 1;
      end else vif.bvalid <= 1;
      return;
    end
    b_inj_active = 0;
    vif.bvalid <= 0;
    if (b_sched.size() > 0 && inject_now(AXI4_INJ_B_UNKNOWN_ID)) begin
      vif.bid <= unused_id(b_sched); vif.bresp <= AXI4_OKAY; vif.bvalid <= 1;
      b_inj_active = 1; b_cur = -1;
      return;
    end
    eligible(b_sched, b_ready_at, idx);
    if (idx.size() == 0) return;
    b_cur = cfg.slave_reorder ? idx[$urandom_range(idx.size() - 1)] : idx[0];
    vif.bid   <= IDW'(b_sched[b_cur].id);
    vif.bresp <= b_sched[b_cur].resp[0];
    vif.bvalid <= 1;
  endfunction

  function bit [DW-1:0] read_beat(axi4_item t, int unsigned n, output axi4_resp_e resp);
    bit [DW-1:0] d;
    int unsigned lo, hi;
    bit [63:0] base;
    axi4_item c;
    $cast(c, t.clone());
    c.size = 3'(eff_size(t));
    c.dbytes = cfg.data_bytes;
    base = c.beat_addr(n) & ~64'(cfg.data_bytes - 1);
    c.beat_lanes(n, lo, hi);
    for (int unsigned b = 0; b < SW; b++)
      d[8*b +: 8] = (b >= lo && b <= hi) ? cfg.mem.read_byte(base + 64'(b)) : 8'($urandom);
    resp = burst_hits_err(c) ? AXI4_SLVERR : AXI4_OKAY;
    if (cfg.slave_corrupt_pct && $urandom_range(99) < cfg.slave_corrupt_pct)
      d[8 * lo + $urandom_range(7)] ^= 1'b1;     // a lane that carries data
    return d;
  endfunction

  bit r_dropped;

  function void drive_r();
    int idx[$];
    axi4_resp_e resp;
    bit last;
    // A beat on the bus stays until it is taken.
    if (vif.rvalid && !vif.rready) begin
      if (!r_dropped && inject_now(AXI4_INJ_R_VALID_DROP)) begin
        vif.rvalid <= 0; r_dropped = 1;
        if (r_inj_pending) r_inj_pending = 0;
      end
      return;
    end
    vif.rvalid <= 0;
    if (r_sched.size() > 0 && $urandom_range(99) < cfg.slave_beat_gap_pct) return;
    if (r_sched.size() > 0 && inject_now(AXI4_INJ_R_UNKNOWN_ID)) begin
      vif.rid <= unused_id(r_sched); vif.rdata <= '0; vif.rresp <= AXI4_OKAY; vif.rlast <= 1;
      vif.rvalid <= 1; r_inj_pending = 1;
      return;
    end
    // Continue the current burst unless interleaving and the dice say switch.
    if (r_cur < 0 || (cfg.slave_interleave && $urandom_range(3) == 0)) begin
      eligible(r_sched, r_ready_at, idx);
      if (r_cur >= 0) begin
        bit found = 0;
        foreach (idx[i]) if (idx[i] == r_cur) found = 1;
        if (!found) idx.push_back(r_cur);
      end
      if (idx.size() == 0) return;
      r_cur = cfg.slave_reorder ? idx[$urandom_range(idx.size() - 1)] : idx[0];
    end
    vif.rid   <= IDW'(r_sched[r_cur].id);
    vif.rdata <= read_beat(r_sched[r_cur], r_beat[r_cur], resp);
    vif.rresp <= resp;
    last = (r_beat[r_cur] + 1 == r_sched[r_cur].beats());
    if (!last && r_beat[r_cur] + 2 == r_sched[r_cur].beats() && inject_now(AXI4_INJ_RLAST_EARLY)) begin
      last = 1; r_early_last = 1;
    end
    vif.rlast  <= last;
    vif.rvalid <= 1;
  endfunction
endclass
