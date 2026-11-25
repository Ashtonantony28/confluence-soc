// xbar_env_pkg.sv: block-level UVM environment for confluence_xbar (M2).
// NM VIP masters drive the crossbar; NS VIP reactive slaves share one global memory, so the
// generic axi4_mem_scoreboard on the master monitors checks end-to-end data. A routing
// scoreboard checks that every request reaches exactly the decoded slave with ID {m, id} and
// unchanged attributes. Built from monitors only, so it also runs passively (ADR 0002).
package xbar_env_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import vip_common_pkg::*;
  import axi4_pkg::*;

  localparam int NM = 3, NS = 3, AW = 32, DW = 128, MIDW = 4, MAX_OUT = 8;
  localparam int MW = $clog2(NM), SIDW = MIDW + MW;
  localparam logic [NS-1:0][AW-1:0] S_BASE = {32'h0002_0000, 32'h0001_0000, 32'h0000_0000};
  localparam logic [NS-1:0][AW-1:0] S_MASK = {32'hFFFE_0000, 32'hFFFF_0000, 32'hFFFF_0000};
  localparam bit [63:0] ADDR_TOP = 64'h4_FFFF;   // traffic window; 0x40000.. is unmapped

  typedef axi4_agent #(AW, DW, MIDW) m_agent_t;
  typedef axi4_agent #(AW, DW, SIDW) s_agent_t;

  function automatic int decode(bit [63:0] a);
    for (int s = 0; s < NS; s++) if ((AW'(a) & S_MASK[s]) == S_BASE[s]) return s;
    return NS;   // DECERR
  endfunction

  // ------------------------------------------------------------------ scoreboards
  class xbar_mem_sb extends axi4_mem_scoreboard;
    `uvm_component_utils(xbar_mem_sb)
    axi4_cfg scfg[NS];
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function axi4_resp_e expect_resp(axi4_item t);
      int s = decode(t.addr);
      if (s == NS) return AXI4_DECERR;
      for (int unsigned n = 0; n < t.beats(); n++) if (scfg[s].in_err_region(t.beat_addr(n))) return AXI4_SLVERR;
      return AXI4_OKAY;
    endfunction
  endclass

  `uvm_analysis_imp_decl(_mreq)
  `uvm_analysis_imp_decl(_sreq)

  // Wraps a monitor port so one scoreboard can tell which port an item came from.
  class xbar_port_tap #(type T = int) extends uvm_subscriber #(axi4_item);
    `uvm_component_param_utils(xbar_port_tap #(T))
    T   sink;
    int idx;
    bit is_master;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void write(axi4_item t);
      sink.observe(is_master, idx, t);
    endfunction
  endclass

  class xbar_route_sb extends uvm_component;
    `uvm_component_utils(xbar_route_sb)
    axi4_item exp_q[NS][$];      // requests expected at each slave, in master issue order
    int unsigned n_routed[NM][NS + 1];
    int unsigned n_checked;
    axi4_item  c_t;
    int        c_m, c_s;

    covergroup cg_route;
      cp_m: coverpoint c_m { bins m[] = {[0:NM-1]}; }
      cp_s: coverpoint c_s { bins s[] = {[0:NS]}; }
      cp_dir: coverpoint c_t.dir;
      x_route: cross cp_m, cp_s, cp_dir;
    endgroup

    function new(string name, uvm_component parent); super.new(name, parent); cg_route = new(); endfunction

    function void observe(bit is_master, int idx, axi4_item t);
      if (is_master) begin
        int s = decode(t.addr);
        c_t = t; c_m = idx; c_s = s; cg_route.sample();
        n_routed[idx][s]++;
        if (s < NS) begin
          axi4_item e;
          $cast(e, t.clone());
          e.id = AXI4_MAX_IDW'({MW'(idx), MIDW'(t.id)});
          exp_q[s].push_back(e);
        end
      end else begin
        int k = -1;
        foreach (exp_q[idx][i]) if (exp_q[idx][i].id == t.id && exp_q[idx][i].dir == t.dir) begin k = i; break; end
        if (k < 0) begin
          `uvm_error("ROUTE", $sformatf("slave %0d got unexpected %s", idx, t.convert2string()))
          return;
        end
        if (exp_q[idx][k].addr != t.addr || exp_q[idx][k].len != t.len || exp_q[idx][k].size != t.size ||
            exp_q[idx][k].burst != t.burst || exp_q[idx][k].prot != t.prot || exp_q[idx][k].cache != t.cache)
          `uvm_error("ROUTE", $sformatf("slave %0d attribute mismatch: got %s, sent %s", idx,
                     t.convert2string(), exp_q[idx][k].convert2string()))
        exp_q[idx].delete(k);
        n_checked++;
      end
    endfunction

    function void check_phase(uvm_phase phase);
      foreach (exp_q[s]) if (exp_q[s].size())
        `uvm_error("ROUTE", $sformatf("%0d requests never reached slave %0d", exp_q[s].size(), s))
    endfunction

    function void report_phase(uvm_phase phase);
      string str = "";
      foreach (n_routed[m]) begin
        str = {str, $sformatf("\n  master %0d ->", m)};
        foreach (n_routed[m][s]) str = {str, $sformatf(" %s:%0d", s == NS ? "DECERR" : $sformatf("S%0d", s), n_routed[m][s])};
      end
      `uvm_info("ROUTE", $sformatf("%0d requests routed and matched, route coverage %0.1f%%%s",
                n_checked, cg_route.get_inst_coverage(), str), UVM_LOW)
    endfunction
  endclass

  // ------------------------------------------------------------------ env
  class xbar_env extends uvm_env;
    `uvm_component_utils(xbar_env)
    axi4_cfg  mcfg[NM], scfg[NS];
    m_agent_t mst[NM];
    s_agent_t slv[NS];
    vip_mem   mem;
    xbar_mem_sb   msb;
    xbar_route_sb rsb;
    xbar_port_tap #(xbar_route_sb) mtap[NM], stap[NS];

    function new(string name, uvm_component parent); super.new(name, parent); endfunction

    function void build_phase(uvm_phase phase);
      mem = vip_mem::type_id::create("mem");
      for (int m = 0; m < NM; m++) begin
        mcfg[m] = axi4_cfg::type_id::create($sformatf("mcfg%0d", m));
        mcfg[m].role = AXI4_MASTER; mcfg[m].addr_width = AW; mcfg[m].data_bytes = DW / 8; mcfg[m].id_width = MIDW;
        uvm_config_db#(axi4_cfg)::set(this, $sformatf("mst%0d", m), "cfg", mcfg[m]);
        mst[m] = m_agent_t::type_id::create($sformatf("mst%0d", m), this);
        mtap[m] = xbar_port_tap #(xbar_route_sb)::type_id::create($sformatf("mtap%0d", m), this);
      end
      for (int s = 0; s < NS; s++) begin
        scfg[s] = axi4_cfg::type_id::create($sformatf("scfg%0d", s));
        scfg[s].role = AXI4_SLAVE; scfg[s].addr_width = AW; scfg[s].data_bytes = DW / 8; scfg[s].id_width = SIDW;
        scfg[s].mem = mem; scfg[s].has_cov = 0;
        uvm_config_db#(axi4_cfg)::set(this, $sformatf("slv%0d", s), "cfg", scfg[s]);
        slv[s] = s_agent_t::type_id::create($sformatf("slv%0d", s), this);
        stap[s] = xbar_port_tap #(xbar_route_sb)::type_id::create($sformatf("stap%0d", s), this);
      end
      msb = xbar_mem_sb::type_id::create("msb", this);
      rsb = xbar_route_sb::type_id::create("rsb", this);
    endfunction

    function void connect_phase(uvm_phase phase);
      for (int s = 0; s < NS; s++) begin
        msb.scfg[s] = scfg[s];
        stap[s].sink = rsb; stap[s].idx = s; stap[s].is_master = 0;
        slv[s].mon.ap_req.connect(stap[s].analysis_export);
      end
      for (int m = 0; m < NM; m++) begin
        mst[m].mon.ap_req.connect(msb.req_export);
        mst[m].mon.ap.connect(msb.done_export);
        mtap[m].sink = rsb; mtap[m].idx = m; mtap[m].is_master = 1;
        mst[m].mon.ap_req.connect(mtap[m].analysis_export);
      end
    endfunction

    task wait_idle();
      bit busy;
      do begin
        @(posedge mst[0].mdrv.vif.aclk);
        busy = 0;
        for (int m = 0; m < NM; m++) if (mst[m].mdrv.outstanding != 0) busy = 1;
      end while (busy);
      repeat (20) @(posedge mst[0].mdrv.vif.aclk);
    endtask
  endclass

  // ------------------------------------------------------------------ tests
  class xbar_base_test extends uvm_test;
    `uvm_component_utils(xbar_base_test)
    xbar_env env;
    int unsigned timeout_cycles = 2000000;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void build_phase(uvm_phase phase);
      env = xbar_env::type_id::create("env", this);
    endfunction
    virtual task stimulus(); endtask
    task run_phase(uvm_phase phase);
      phase.raise_objection(this);
      fork
        begin stimulus(); env.wait_idle(); end
        begin repeat (timeout_cycles) @(posedge env.mst[0].mdrv.vif.aclk);
              `uvm_error("TIMEOUT", $sformatf("test did not finish in %0d cycles", timeout_cycles)) end
      join_any
      disable fork;
      phase.drop_objection(this);
    endtask
    function void report_phase(uvm_phase phase);
      uvm_report_server rs = uvm_report_server::get_server();
      if (rs.get_severity_count(UVM_ERROR) + rs.get_severity_count(UVM_FATAL) == 0) $display("*** TEST PASSED ***");
      else $display("*** TEST FAILED ***");
    endfunction

    // Every master runs n random bursts in [lo, hi] at the same time.
    task all_masters(int unsigned n, bit [63:0] lo, bit [63:0] hi, int unsigned max_len = 31,
                     int unsigned write_pct = 50);
      for (int m = 0; m < NM; m++) begin
        automatic int mm = m;
        fork begin
          axi4_random_seq s = axi4_random_seq::type_id::create($sformatf("seq_m%0d", mm));
          s.n = n; s.lo = lo; s.hi = hi; s.max_len = max_len; s.write_pct = write_pct;
          s.start(env.mst[mm].sqr);
        end join_none
      end
      wait fork;
    endtask
  endclass

  class xbar_smoke_test extends xbar_base_test;
    `uvm_component_utils(xbar_smoke_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task stimulus(); all_masters(20, 0, ADDR_TOP, 3); endtask
  endclass

  // All masters, all slaves and the unmapped region, mixed traffic.
  class xbar_random_test extends xbar_base_test;
    `uvm_component_utils(xbar_random_test)
    int unsigned n = 400;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void build_phase(uvm_phase phase); super.build_phase(phase); void'($value$plusargs("N=%d", n)); endfunction
    task stimulus(); all_masters(n, 0, ADDR_TOP); endtask
  endclass

  // Every master hammers one slave: arbitration fairness and W-order FIFOs under contention.
  class xbar_hotspot_test extends xbar_base_test;
    `uvm_component_utils(xbar_hotspot_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task stimulus();
      all_masters(250, 64'h1_0000, 64'h1_0FFF, 15);
      all_masters(250, 64'h2_0000, 64'h2_00FF, 3);
    endtask
  endclass

  // Two IDs per master spread over every slave: exercises the same-ID-one-slave stall.
  class xbar_same_id_test extends xbar_base_test;
    `uvm_component_utils(xbar_same_id_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void end_of_elaboration_phase(uvm_phase phase);
      for (int m = 0; m < NM; m++) env.mcfg[m].id_width = 1;   // items constrained to IDs 0..1
    endfunction
    task stimulus(); all_masters(300, 0, ADDR_TOP, 7); endtask
  endclass

  class xbar_error_test extends xbar_base_test;
    `uvm_component_utils(xbar_error_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void end_of_elaboration_phase(uvm_phase phase);
      env.scfg[0].err_lo.push_back(64'h0_8000); env.scfg[0].err_hi.push_back(64'h0_8FFF);
      env.scfg[2].err_lo.push_back(64'h3_0000); env.scfg[2].err_hi.push_back(64'h3_00FF);
    endfunction
    task stimulus(); all_masters(300, 0, ADDR_TOP, 15); endtask
    function void check_phase(uvm_phase phase);
      if (env.msb.n_err == 0) `uvm_error("ERRTEST", "no error response exercised")
    endfunction
  endclass

  // Slow slaves and slow masters: long stalls on every channel.
  class xbar_backpressure_test extends xbar_base_test;
    `uvm_component_utils(xbar_backpressure_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void end_of_elaboration_phase(uvm_phase phase);
      foreach (env.scfg[s]) begin
        env.scfg[s].slave_ready_busy_pct = 70; env.scfg[s].slave_max_latency = 40; env.scfg[s].slave_beat_gap_pct = 50;
        env.scfg[s].slave_max_accept = 2;
      end
      foreach (env.mcfg[m]) env.mcfg[m].bready_busy_pct = 60;
    endfunction
    task stimulus(); all_masters(150, 0, ADDR_TOP, 15); endtask
  endclass
endpackage
