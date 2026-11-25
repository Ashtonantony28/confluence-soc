// axil_slave_driver.svh: reactive, memory-backed AXI4-Lite slave. Accepts up to
// cfg.slave_max_accept requests per direction, answers after a random latency with random
// ready stalls, and responds in order (AXI4-Lite has no IDs). Accesses that hit a cfg error
// region get SLVERR (writes are dropped, reads return zero).

class axil_slave_driver #(int AW = 32, int DW = 32) extends uvm_component;
  `uvm_component_param_utils(axil_slave_driver #(AW, DW))

  typedef virtual axil_if #(.AW(AW), .DW(DW)) vif_t;
  localparam int SW = DW / 8;

  vif_t            vif;
  axil_cfg         cfg;
  longint unsigned cycle;
  bit              injected;

  bit [63:0]       aw_pend[$];       // accepted write addresses waiting for data
  bit [DW-1:0]     w_data_pend[$];   // accepted write data waiting for an address
  bit [SW-1:0]     w_strb_pend[$];
  axil_resp_e      b_sched[$];       // writes applied, response pending (in order)
  longint unsigned b_ready_at[$];
  bit [63:0]       r_sched[$];       // accepted read addresses (in order)
  longint unsigned r_ready_at[$];
  bit              b_inj, r_inj;     // the response on the bus is an injected extra one

  function new(string name, uvm_component parent); super.new(name, parent); endfunction

  function void build_phase(uvm_phase phase);
    if (!uvm_config_db#(vif_t)::get(this, "", "vif", vif)) `uvm_fatal("NOVIF", "axil vif not set")
    if (!uvm_config_db#(axil_cfg)::get(this, "", "cfg", cfg)) `uvm_fatal("NOCFG", "axil cfg not set")
    if (cfg.mem == null) cfg.mem = vip_common_pkg::vip_mem::type_id::create("mem");
  endfunction

  function bit inject_now(axil_inject_e k);
    if (cfg.inject != k || injected) return 0;
    injected = 1;
    `uvm_info("AXIL_INJ", $sformatf("injecting %s", k.name()), UVM_LOW)
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
    vif.bresp <= '0; vif.rdata <= '0; vif.rresp <= '0;
    @(posedge vif.aclk);
    while (!vif.aresetn) @(posedge vif.aclk);
    forever begin
      @(posedge vif.aclk);
      cycle++;
      // Sample every handshake first (all use pre-edge values), then decide next outputs.
      sample();
      apply_writes();
      drive_ready();
      drive_b();
      drive_r();
    end
  endtask

  function void sample();
    if (vif.awvalid && vif.awready) aw_pend.push_back(64'(vif.awaddr));
    if (vif.wvalid && vif.wready) begin
      w_data_pend.push_back(vif.wdata); w_strb_pend.push_back(vif.wstrb);
    end
    if (vif.bvalid && vif.bready) begin
      if (b_inj) b_inj = 0;
      else begin void'(b_sched.pop_front()); void'(b_ready_at.pop_front()); end
    end
    if (vif.arvalid && vif.arready) begin
      r_sched.push_back(64'(vif.araddr)); r_ready_at.push_back(cycle + latency());
    end
    if (vif.rvalid && vif.rready) begin
      if (r_inj) r_inj = 0;
      else begin void'(r_sched.pop_front()); void'(r_ready_at.pop_front()); end
    end
  endfunction

  function bit [63:0] word_base(bit [63:0] a);
    return a & ~64'(SW - 1);
  endfunction

  function void apply_writes();
    while (aw_pend.size() > 0 && w_data_pend.size() > 0) begin
      bit [63:0]   a = aw_pend.pop_front();
      bit [DW-1:0] d = w_data_pend.pop_front();
      bit [SW-1:0] s = w_strb_pend.pop_front();
      bit          err = cfg.in_err_region(a);
      if (!err)
        for (int unsigned b = 0; b < SW; b++)
          if (s[b]) cfg.mem.write_byte(word_base(a) + 64'(b), d[8*b +: 8]);
      b_sched.push_back(err ? AXIL_SLVERR : AXIL_OKAY);
      b_ready_at.push_back(cycle + latency());
    end
  endfunction

  function void drive_ready();
    vif.awready <= (aw_pend.size() + b_sched.size() < cfg.slave_max_accept) && !busy();
    vif.wready  <= (w_data_pend.size() < cfg.slave_max_accept) && !busy();
    vif.arready <= (r_sched.size() < cfg.slave_max_accept) && !busy();
  endfunction

  function void drive_b();
    // A response on the bus stays until it is taken (AXI handshake rule).
    if (vif.bvalid && !vif.bready) begin
      if (inject_now(AXIL_INJ_B_VALID_DROP)) vif.bvalid <= 0;
      else if (inject_now(AXIL_INJ_B_PAYLOAD_CHANGE)) vif.bresp <= vif.bresp ^ 2'b10;
      return;
    end
    vif.bvalid <= 0;
    if (b_sched.size() == 0 && aw_pend.size() == 0 && w_data_pend.size() == 0 &&
        inject_now(AXIL_INJ_B_UNSOLICITED)) begin
      vif.bresp <= AXIL_OKAY; vif.bvalid <= 1; b_inj = 1;
      return;
    end
    if (b_sched.size() == 0 || b_ready_at[0] > cycle) return;
    vif.bresp <= b_sched[0];
    if (inject_now(AXIL_INJ_EXOKAY)) vif.bresp <= AXIL_EXOKAY;
    vif.bvalid <= 1;
  endfunction

  function bit [DW-1:0] read_word(bit [63:0] a, output axil_resp_e resp);
    bit [DW-1:0] d;
    if (cfg.in_err_region(a)) begin resp = AXIL_SLVERR; return '0; end
    resp = AXIL_OKAY;
    for (int unsigned b = 0; b < SW; b++) d[8*b +: 8] = cfg.mem.read_byte(word_base(a) + 64'(b));
    if (cfg.slave_corrupt_pct && $urandom_range(99) < cfg.slave_corrupt_pct)
      d[$urandom_range(DW - 1)] ^= 1'b1;
    return d;
  endfunction

  function void drive_r();
    axil_resp_e resp;
    if (vif.rvalid && !vif.rready) begin
      if (inject_now(AXIL_INJ_R_VALID_DROP)) vif.rvalid <= 0;
      else if (inject_now(AXIL_INJ_R_PAYLOAD_CHANGE)) vif.rdata <= ~vif.rdata;
      return;
    end
    vif.rvalid <= 0;
    if (r_sched.size() == 0 && inject_now(AXIL_INJ_R_UNSOLICITED)) begin
      vif.rdata <= '0; vif.rresp <= AXIL_OKAY; vif.rvalid <= 1; r_inj = 1;
      return;
    end
    if (r_sched.size() == 0 || r_ready_at[0] > cycle) return;
    vif.rdata <= read_word(r_sched[0], resp);
    vif.rresp <= resp;
    if (inject_now(AXIL_INJ_EXOKAY)) vif.rresp <= AXIL_EXOKAY;
    vif.rvalid <= 1;
  endfunction
endclass
