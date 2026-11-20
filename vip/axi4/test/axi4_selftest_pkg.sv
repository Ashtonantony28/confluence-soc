// axi4_selftest_pkg.sv: proves the AXI4 VIP against itself before it is trusted on a DUT.
// VIP master <-> VIP reactive slave on one interface; an independent scoreboard predicts
// every read from its own memory model; the protocol checker watches the wires.
package axi4_selftest_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import vip_common_pkg::*;
  import axi4_pkg::*;

  localparam int AW = 32, DW = 128, IDW = 4;
  typedef axi4_agent #(AW, DW, IDW) agent_t;

  // ------------------------------------------------------------------ scoreboard
  // The generic memory scoreboard, told which addresses the slave maps to SLVERR.
  class axi4_selftest_sb extends axi4_mem_scoreboard;
    `uvm_component_utils(axi4_selftest_sb)
    axi4_cfg scfg;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function axi4_resp_e expect_resp(axi4_item t);
      for (int unsigned n = 0; n < t.beats(); n++) if (scfg.in_err_region(t.beat_addr(n))) return AXI4_SLVERR;
      return AXI4_OKAY;
    endfunction
  endclass

  // ------------------------------------------------------------------ env
  class axi4_selftest_env extends uvm_env;
    `uvm_component_utils(axi4_selftest_env)
    axi4_cfg mcfg, scfg;
    agent_t  mst, slv;
    axi4_selftest_sb sb;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void build_phase(uvm_phase phase);
      mcfg = axi4_cfg::type_id::create("mcfg");
      scfg = axi4_cfg::type_id::create("scfg");
      mcfg.role = AXI4_MASTER; mcfg.addr_width = AW; mcfg.data_bytes = DW / 8; mcfg.id_width = IDW;
      scfg.role = AXI4_SLAVE;  scfg.addr_width = AW; scfg.data_bytes = DW / 8; scfg.id_width = IDW;
      scfg.has_cov = 0;
      uvm_config_db#(axi4_cfg)::set(this, "mst", "cfg", mcfg);
      uvm_config_db#(axi4_cfg)::set(this, "slv", "cfg", scfg);
      mst = agent_t::type_id::create("mst", this);
      slv = agent_t::type_id::create("slv", this);
      sb  = axi4_selftest_sb::type_id::create("sb", this);
    endfunction
    function void connect_phase(uvm_phase phase);
      sb.scfg = scfg;
      mst.mon.ap_req.connect(sb.req_export);
      mst.mon.ap.connect(sb.done_export);
    endfunction
    task wait_idle();
      do @(posedge mst.mdrv.vif.aclk); while (mst.mdrv.outstanding != 0);
      repeat (5) @(posedge mst.mdrv.vif.aclk);
    endtask
  endclass

  // ------------------------------------------------------------------ tests
  class axi4_base_test extends uvm_test;
    `uvm_component_utils(axi4_base_test)
    axi4_selftest_env env;
    int unsigned timeout_cycles = 1000000;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void build_phase(uvm_phase phase);
      env = axi4_selftest_env::type_id::create("env", this);
    endfunction
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
    function void report_phase(uvm_phase phase);
      uvm_report_server rs = uvm_report_server::get_server();
      if (rs.get_severity_count(UVM_ERROR) + rs.get_severity_count(UVM_FATAL) == 0)
        $display("*** TEST PASSED ***");
      else $display("*** TEST FAILED ***");
    endfunction
  endclass

  class axi4_smoke_test extends axi4_base_test;
    `uvm_component_utils(axi4_smoke_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task stimulus();
      axi4_base_seq s = axi4_base_seq::type_id::create("s");
      axi4_resp_e r;
      bit [AXI4_MAX_DW-1:0] d;
      s.cfg = env.mcfg;
      fork begin
        s.set_sequencer(env.mst.sqr);
        s.pre_start();
        for (int i = 0; i < 16; i++) s.write1(64'h100 + 64'(16 * i), {4{32'hC0DE_0000 + 32'(i)}}, r);
        for (int i = 0; i < 16; i++) begin
          s.read1(64'h100 + 64'(16 * i), d, r);
          if (d != {4{32'hC0DE_0000 + 32'(i)}}) `uvm_error("SMOKE", $sformatf("word %0d read %0h", i, d))
        end
      end join
    endtask
  endclass

  // Rounds of concurrent traffic: writes to one half of the window while reads check the
  // other half (written in an earlier round), so read data is never racing a write.
  class axi4_random_test extends axi4_base_test;
    `uvm_component_utils(axi4_random_test)
    int unsigned rounds = 6, per_round = 120;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      void'($value$plusargs("ROUNDS=%d", rounds));
    endfunction
    task stimulus();
      for (int unsigned r = 0; r < rounds; r++) begin
        axi4_random_seq w = axi4_random_seq::type_id::create("w");
        axi4_random_seq rd = axi4_random_seq::type_id::create("rd");
        bit [63:0] half = 64'h8000;
        w.max_len = 63; rd.max_len = 63;
        w.n = per_round;  w.write_pct = 100; w.lo = (r % 2) ? half : 0; w.hi = w.lo + half - 1;
        rd.n = per_round; rd.write_pct = 0;  rd.lo = (r % 2) ? 0 : half; rd.hi = rd.lo + half - 1;
        fork
          w.start(env.mst.sqr);
          rd.start(env.mst.sqr);
        join
        env.wait_idle();
      end
    endtask
  endclass

  class axi4_inorder_test extends axi4_random_test;
    `uvm_component_utils(axi4_inorder_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void end_of_elaboration_phase(uvm_phase phase);
      env.scfg.slave_reorder = 0; env.scfg.slave_interleave = 0;
      env.mcfg.max_outstanding = 1; env.mcfg.bready_busy_pct = 0;
      rounds = 2;
    endfunction
  endclass

  class axi4_error_test extends axi4_random_test;
    `uvm_component_utils(axi4_error_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void end_of_elaboration_phase(uvm_phase phase);
      env.scfg.err_lo.push_back(64'h2000); env.scfg.err_hi.push_back(64'h2FFF);
      env.scfg.err_lo.push_back(64'hA100); env.scfg.err_hi.push_back(64'hA1FF);
      rounds = 4;
    endfunction
    function void check_phase(uvm_phase phase);
      if (env.sb.n_err == 0) `uvm_error("ERRTEST", "no SLVERR burst was exercised")
    endfunction
  endclass

  // The scoreboard must notice a slave that corrupts read data (guards against a scoreboard
  // that is too permissive, e.g. after the ambiguity handling for reordered writes).
  class axi4_sb_sanity_test extends axi4_random_test;
    `uvm_component_utils(axi4_sb_sanity_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void end_of_elaboration_phase(uvm_phase phase);
      env.scfg.slave_corrupt_pct = 2;
      env.sb.set_report_severity_id_override(UVM_ERROR, "MEM_SB", UVM_WARNING);
      rounds = 2;
    endfunction
    function void check_phase(uvm_phase phase);
      int unsigned n = uvm_report_server::get_server().get_id_count("MEM_SB");
      if (n < 2) `uvm_error("SANITY", "scoreboard missed injected read-data corruption")
      else `uvm_info("SANITY", $sformatf("scoreboard flagged %0d corrupted reads", n - 1), UVM_LOW)
    endfunction
  endclass

  // +INJECT=<axi4_inject_e name> +EXPECT_RULE=AXI4-Rnn: the injected violation must be
  // caught by that checker rule. Everything else that goes wrong afterwards is expected.
  class axi4_violation_test extends axi4_base_test;
    `uvm_component_utils(axi4_violation_test)
    string inj_s, rule;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!$value$plusargs("INJECT=%s", inj_s) || !$value$plusargs("EXPECT_RULE=%s", rule))
        `uvm_fatal("ARGS", "need +INJECT= and +EXPECT_RULE=")
      vip_checker_db::expect_violations = 1;
      timeout_cycles = 20000;
    endfunction
    function void end_of_elaboration_phase(uvm_phase phase);
      axi4_inject_e k;
      bit found = 0;
      k = k.first();
      forever begin
        if (k.name() == inj_s) begin found = 1; break; end
        if (k == k.last()) break;
        k = k.next();
      end
      if (!found) `uvm_fatal("ARGS", {"unknown injection ", inj_s})
      if (k >= AXI4_INJ_RLAST_EARLY) env.scfg.inject = k; else env.mcfg.inject = k;
      env.sb.enabled = 0;
      env.scfg.slave_ready_busy_pct = 60;   // stalls give the valid-drop injections a chance
      env.mst.mdrv.set_report_severity_id_override(UVM_ERROR, "AXI4_MST", UVM_WARNING);
    endfunction
    task stimulus();
      axi4_random_seq s = axi4_random_seq::type_id::create("s");
      s.n = 100; s.lo = 0; s.hi = 64'h3FFF; s.max_len = 7;
      fork
        s.start(env.mst.sqr);
        begin repeat (5000) @(posedge env.mst.mdrv.vif.aclk); end
      join_any
      disable fork;
    endtask
    task run_phase(uvm_phase phase);
      phase.raise_objection(this);
      stimulus();
      phase.drop_objection(this);
    endtask
    function void check_phase(uvm_phase phase);
      if (vip_checker_db::count(rule) == 0)
        `uvm_error("VIOL", $sformatf("%s was injected but %s never fired", inj_s, rule))
      else `uvm_info("VIOL", $sformatf("%s caught by %s (%0d hits)", inj_s, rule, vip_checker_db::count(rule)), UVM_LOW)
    endfunction
  endclass
endpackage
