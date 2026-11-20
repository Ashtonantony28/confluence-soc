// axis_selftest_pkg.sv: proves the AXI4-Stream VIP against itself before it is trusted on a
// DUT. VIP master -> VIP slave on one interface; a scoreboard compares every packet the
// master sent with the packet rebuilt by the monitor (wire view) and by the slave (consumer
// view); the protocol checker watches the wires.
// Default shape: 64-bit data, 4-bit TID, 2-bit TDEST, 4-bit TUSER. With AXIS_SELFTEST_MIN
// (axis_min_selftest bench): 8-bit data and no TID / TDEST / TUSER.
package axis_selftest_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import vip_common_pkg::*;
  import axis_pkg::*;

`ifdef AXIS_SELFTEST_MIN
  localparam int DW = 8, IDW = 0, DESTW = 0, UW = 0;
`else
  localparam int DW = 64, IDW = 4, DESTW = 2, UW = 4;
`endif
  typedef axis_agent #(DW, IDW, DESTW, UW) agent_t;

  `uvm_analysis_imp_decl(_axis_exp)
  `uvm_analysis_imp_decl(_axis_mon)
  `uvm_analysis_imp_decl(_axis_slv)

  // ------------------------------------------------------------------ scoreboard
  // The master sends packets whole (no interleaving), so both actual streams must match the
  // sent stream in order. The sent copy and the observed copy of a packet are published on
  // the same clock edge in no defined order, so either side may arrive first.
  class axis_selftest_sb extends uvm_component;
    `uvm_component_utils(axis_selftest_sb)
    uvm_analysis_imp_axis_exp #(axis_item, axis_selftest_sb) exp_export;
    uvm_analysis_imp_axis_mon #(axis_item, axis_selftest_sb) mon_export;
    uvm_analysis_imp_axis_slv #(axis_item, axis_selftest_sb) slv_export;
    bit          enabled = 1;
    axis_item    exp_mon[$], exp_slv[$], act_mon[$], act_slv[$];
    int unsigned n_exp, n_mon, n_slv, n_bytes;

    function new(string name, uvm_component parent);
      super.new(name, parent);
      exp_export = new("exp_export", this);
      mon_export = new("mon_export", this);
      slv_export = new("slv_export", this);
    endfunction

    function void match(string who, ref axis_item e[$], ref axis_item a[$]);
      while (e.size() > 0 && a.size() > 0) begin
        axis_item x = e.pop_front();
        axis_item y = a.pop_front();
        string d = x.diff(y);
        if (d != "") `uvm_error("AXIS_SB", $sformatf("%s packet mismatch: %s (sent %s)", who, d, x.convert2string()))
      end
    endfunction

    function void write_axis_exp(axis_item t);
      if (!enabled) return;
      n_exp++; n_bytes += t.len;
      exp_mon.push_back(t); exp_slv.push_back(t);
      match("monitor", exp_mon, act_mon);
      match("slave", exp_slv, act_slv);
    endfunction
    function void write_axis_mon(axis_item t);
      if (!enabled) return;
      n_mon++; act_mon.push_back(t); match("monitor", exp_mon, act_mon);
    endfunction
    function void write_axis_slv(axis_item t);
      if (!enabled) return;
      n_slv++; act_slv.push_back(t); match("slave", exp_slv, act_slv);
    endfunction

    function void check_phase(uvm_phase phase);
      if (!enabled) return;
      if (exp_mon.size() || exp_slv.size() || act_mon.size() || act_slv.size())
        `uvm_error("AXIS_SB", $sformatf("unmatched packets: sent-not-seen %0d/%0d, seen-not-sent %0d/%0d (monitor/slave)",
                   exp_mon.size(), exp_slv.size(), act_mon.size(), act_slv.size()))
    endfunction

    function void report_phase(uvm_phase phase);
      `uvm_info("AXIS_SB", $sformatf("%0d packets sent (%0d bytes), %0d seen by the monitor, %0d received by the slave",
                n_exp, n_bytes, n_mon, n_slv), UVM_LOW)
    endfunction
  endclass

  // ------------------------------------------------------------------ env
  class axis_selftest_env extends uvm_env;
    `uvm_component_utils(axis_selftest_env)
    axis_cfg mcfg, scfg;
    agent_t  mst, slv;
    axis_selftest_sb sb;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void build_phase(uvm_phase phase);
      mcfg = axis_cfg::type_id::create("mcfg");
      scfg = axis_cfg::type_id::create("scfg");
      mcfg.role = AXIS_MASTER; scfg.role = AXIS_SLAVE;
      mcfg.data_bytes = DW / 8; mcfg.id_width = IDW; mcfg.dest_width = DESTW; mcfg.user_width = UW;
      scfg.data_bytes = DW / 8; scfg.id_width = IDW; scfg.dest_width = DESTW; scfg.user_width = UW;
      scfg.has_cov = 0;
      uvm_config_db#(axis_cfg)::set(this, "mst", "cfg", mcfg);
      uvm_config_db#(axis_cfg)::set(this, "slv", "cfg", scfg);
      mst = agent_t::type_id::create("mst", this);
      slv = agent_t::type_id::create("slv", this);
      sb  = axis_selftest_sb::type_id::create("sb", this);
    endfunction
    function void connect_phase(uvm_phase phase);
      mst.mdrv.ap_sent.connect(sb.exp_export);
      mst.mon.ap.connect(sb.mon_export);
      slv.sdrv.ap_rcvd.connect(sb.slv_export);
    endfunction
    task wait_idle();
      do @(posedge mst.mdrv.vif.aclk); while (mst.mdrv.busy);
      repeat (5) @(posedge mst.mdrv.vif.aclk);
    endtask
  endclass

  // ------------------------------------------------------------------ tests
  class axis_base_test extends uvm_test;
    `uvm_component_utils(axis_base_test)
    axis_selftest_env env;
    int unsigned timeout_cycles = 1000000;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void build_phase(uvm_phase phase);
      env = axis_selftest_env::type_id::create("env", this);
      if ($test$plusargs("AXIS_SPARSE") && !is_sparse())
        `uvm_fatal("ARGS", "+AXIS_SPARSE turns off the packed-TKEEP check; use it with axis_sparse_test only")
    endfunction
    virtual function bit is_sparse(); return 0; endfunction
    virtual task stimulus(); endtask
    task run_phase(uvm_phase phase);
      phase.raise_objection(this);
      fork
        begin stimulus(); env.wait_idle(); end
        begin repeat (timeout_cycles) @(posedge env.mst.mdrv.vif.aclk);
              `uvm_error("TIMEOUT", $sformatf("test did not finish in %0d cycles", timeout_cycles)) end
      join_any
      disable fork;
      phase.drop_objection(this);
    endtask
    function void check_phase(uvm_phase phase);
      if (env.sb.enabled && (env.sb.n_exp == 0 || env.sb.n_mon != env.sb.n_exp || env.sb.n_slv != env.sb.n_exp))
        `uvm_error("COUNT", $sformatf("sent %0d packets, monitor saw %0d, slave received %0d",
                   env.sb.n_exp, env.sb.n_mon, env.sb.n_slv))
    endfunction
    function void report_phase(uvm_phase phase);
      uvm_report_server rs = uvm_report_server::get_server();
      if (rs.get_severity_count(UVM_ERROR) + rs.get_severity_count(UVM_FATAL) == 0)
        $display("*** TEST PASSED ***");
      else $display("*** TEST FAILED ***");
    endfunction
  endclass

  // Every length from one byte to three full transfers plus one, without and with gaps.
  class axis_smoke_test extends axis_base_test;
    `uvm_component_utils(axis_smoke_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task stimulus();
      axis_base_seq s = axis_base_seq::type_id::create("s");
      s.cfg = env.mcfg;
      s.set_sequencer(env.mst.sqr);
      s.pre_start();
      for (int unsigned n = 1; n <= 3 * (DW / 8) + 1; n++) s.send_len(n, 0);
      for (int unsigned n = 1; n <= 3 * (DW / 8) + 1; n++) s.send_len(n, 2);
    endtask
  endclass

  class axis_random_test extends axis_base_test;
    `uvm_component_utils(axis_random_test)
    int unsigned n = 400;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      void'($value$plusargs("N=%d", n));
    endfunction
    task stimulus();
      axis_random_seq s = axis_random_seq::type_id::create("s");
      s.n = n;
      s.start(env.mst.sqr);
    endtask
  endclass

  // Null bytes anywhere (base protocol TKEEP freedom). Needs +AXIS_SPARSE, which makes the
  // top disable the packed-stream rule AXIS-R04.
  class axis_sparse_test extends axis_random_test;
    `uvm_component_utils(axis_sparse_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function bit is_sparse(); return 1; endfunction
    function void end_of_elaboration_phase(uvm_phase phase);
      if (!$test$plusargs("AXIS_SPARSE")) `uvm_fatal("ARGS", "axis_sparse_test needs +AXIS_SPARSE")
      env.mcfg.keep_mode = AXIS_KEEP_SPARSE; env.scfg.keep_mode = AXIS_KEEP_SPARSE;
    endfunction
  endclass

  // Heavy backpressure against a master that never idles, then a free-flowing phase.
  class axis_backpressure_test extends axis_random_test;
    `uvm_component_utils(axis_backpressure_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void end_of_elaboration_phase(uvm_phase phase);
      env.scfg.slave_ready_busy_pct = 85; env.mcfg.beat_gap_pct = 0;
      n = 150;
    endfunction
    task stimulus();
      super.stimulus();
      env.wait_idle();
      env.scfg.slave_ready_busy_pct = 0;
      super.stimulus();
    endtask
  endclass

  // The scoreboard must notice a consumer that receives corrupted data.
  class axis_sb_sanity_test extends axis_random_test;
    `uvm_component_utils(axis_sb_sanity_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void end_of_elaboration_phase(uvm_phase phase);
      env.scfg.slave_corrupt_pct = 5;
      env.sb.set_report_severity_id_override(UVM_ERROR, "AXIS_SB", UVM_WARNING);
      n = 200;
    endfunction
    function void check_phase(uvm_phase phase);
      int unsigned c = uvm_report_server::get_server().get_id_count("AXIS_SB");
      super.check_phase(phase);
      if (c < 2) `uvm_error("SANITY", "scoreboard missed injected data corruption")
      else `uvm_info("SANITY", $sformatf("scoreboard flagged %0d corrupted packets", c - 1), UVM_LOW)
    endfunction
  endclass

  // +INJECT=<axis_inject_e name> +EXPECT_RULE=AXIS-Rnn: the injected violation must be
  // caught by that checker rule. Everything else that goes wrong afterwards is expected.
  class axis_violation_test extends axis_base_test;
    `uvm_component_utils(axis_violation_test)
    string inj_s, rule;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!$value$plusargs("INJECT=%s", inj_s) || !$value$plusargs("EXPECT_RULE=%s", rule))
        `uvm_fatal("ARGS", "need +INJECT= and +EXPECT_RULE=")
      vip_checker_db::expect_violations = 1;
    endfunction
    function void end_of_elaboration_phase(uvm_phase phase);
      axis_inject_e k;
      bit found = 0;
      k = k.first();
      forever begin
        if (k.name() == inj_s) begin found = 1; break; end
        if (k == k.last()) break;
        k = k.next();
      end
      if (!found) `uvm_fatal("ARGS", {"unknown injection ", inj_s})
      env.mcfg.inject = k;
      env.sb.enabled = 0;
      env.scfg.slave_ready_busy_pct = 60;   // stalls give the hold injections a chance
    endfunction
    task stimulus();
      axis_random_seq s = axis_random_seq::type_id::create("s");
      s.n = 40;
      fork
        s.start(env.mst.sqr);
        begin repeat (20000) @(posedge env.mst.mdrv.vif.aclk); end
      join_any
      disable fork;
    endtask
    task run_phase(uvm_phase phase);
      phase.raise_objection(this);
      stimulus();
      repeat (20) @(posedge env.mst.mdrv.vif.aclk);
      phase.drop_objection(this);
    endtask
    function void check_phase(uvm_phase phase);
      if (vip_checker_db::count(rule) == 0)
        `uvm_error("VIOL", $sformatf("%s was injected but %s never fired", inj_s, rule))
      else `uvm_info("VIOL", $sformatf("%s caught by %s (%0d hits)", inj_s, rule, vip_checker_db::count(rule)), UVM_LOW)
    endfunction
  endclass
endpackage
