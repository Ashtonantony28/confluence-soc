// apb_selftest_pkg.sv: proves the APB4 VIP against itself before it is trusted on a DUT.
// VIP master <-> VIP reactive slave on one interface; an independent scoreboard predicts
// every read from its own memory model; the protocol checker watches the wires.
package apb_selftest_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import vip_common_pkg::*;
  import apb_pkg::*;

  localparam int AW = 32, DW = 32;
  typedef apb_agent #(AW, DW) agent_t;

  // ------------------------------------------------------------------ scoreboard
  // APB is strictly sequential, so a plain memory model predicts every read exactly.
  class apb_selftest_sb extends uvm_subscriber #(apb_item);
    `uvm_component_utils(apb_selftest_sb)
    apb_cfg      scfg;               // slave cfg: which addresses answer PSLVERR
    bit          enabled = 1;
    vip_mem      model;
    int unsigned n_wr, n_rd, n_checked, n_err;

    function new(string name, uvm_component parent);
      super.new(name, parent);
      model = vip_mem::type_id::create("model");
    endfunction

    function void write(apb_item t);
      bit exp_err = scfg.in_err_region(64'(t.addr));
      bit [63:0] w = 64'(t.addr) & ~64'(t.dbytes - 1);
      if (!enabled) return;
      if (t.slverr != exp_err)
        `uvm_error("APB_SB", $sformatf("%s: expected pslverr=%0b", t.convert2string(), exp_err))
      if (t.slverr) n_err++;
      if (t.dir == APB_WRITE) begin
        n_wr++;
        if (!t.slverr)
          for (int unsigned b = 0; b < t.dbytes; b++)
            if (t.strb[b]) model.write_byte(w + 64'(b), t.data[8*b +: 8]);
      end else begin
        n_rd++;
        if (!t.slverr) begin
          bit [APB_MAX_DW-1:0] e = '0;
          for (int unsigned b = 0; b < t.dbytes; b++) e[8*b +: 8] = model.read_byte(w + 64'(b));
          n_checked++;
          if (e != t.data) `uvm_error("APB_SB", $sformatf("%s: expected data %0h", t.convert2string(), e))
        end
      end
    endfunction

    function void report_phase(uvm_phase phase);
      `uvm_info("APB_SB", $sformatf("%0d writes, %0d reads (%0d data-checked), %0d error responses",
                n_wr, n_rd, n_checked, n_err), UVM_LOW)
    endfunction
  endclass

  // ------------------------------------------------------------------ register model (reg test)
  class apb_st_reg extends uvm_reg;
    `uvm_object_utils(apb_st_reg)
    rand uvm_reg_field f;
    function new(string name = "apb_st_reg"); super.new(name, 32, UVM_NO_COVERAGE); endfunction
    virtual function void build();
      f = uvm_reg_field::type_id::create("f");
      f.configure(this, 32, 0, "RW", 0, 32'h0, 0, 1, 1);
    endfunction
  endclass

  class apb_st_reg_block extends uvm_reg_block;
    `uvm_object_utils(apb_st_reg_block)
    localparam int NREGS = 8;
    apb_st_reg  r[NREGS];
    uvm_reg_map apb_map;
    function new(string name = "apb_st_reg_block"); super.new(name, UVM_NO_COVERAGE); endfunction
    virtual function void build();
      apb_map = create_map("apb_map", 'h800, 4, UVM_LITTLE_ENDIAN);
      foreach (r[i]) begin
        r[i] = apb_st_reg::type_id::create($sformatf("r%0d", i));
        r[i].configure(this);
        r[i].build();
        apb_map.add_reg(r[i], 4 * i, "RW");
      end
      lock_model();
    endfunction
  endclass

  // ------------------------------------------------------------------ env
  class apb_selftest_env extends uvm_env;
    `uvm_component_utils(apb_selftest_env)
    apb_cfg mcfg, scfg;
    agent_t mst, slv;
    apb_selftest_sb sb;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void build_phase(uvm_phase phase);
      mcfg = apb_cfg::type_id::create("mcfg");
      scfg = apb_cfg::type_id::create("scfg");
      mcfg.role = APB_MASTER; mcfg.addr_width = AW; mcfg.data_bytes = DW / 8;
      scfg.role = APB_SLAVE;  scfg.addr_width = AW; scfg.data_bytes = DW / 8;
      scfg.has_cov = 0;
      uvm_config_db#(apb_cfg)::set(this, "mst", "cfg", mcfg);
      uvm_config_db#(apb_cfg)::set(this, "slv", "cfg", scfg);
      mst = agent_t::type_id::create("mst", this);
      slv = agent_t::type_id::create("slv", this);
      sb  = apb_selftest_sb::type_id::create("sb", this);
    endfunction
    function void connect_phase(uvm_phase phase);
      sb.scfg = scfg;
      mst.mon.ap.connect(sb.analysis_export);
    endfunction
    task wait_idle();
      do @(posedge mst.mdrv.vif.pclk); while (mst.mdrv.busy);
      repeat (5) @(posedge mst.mdrv.vif.pclk);
    endtask
  endclass

  // ------------------------------------------------------------------ tests
  class apb_base_test extends uvm_test;
    `uvm_component_utils(apb_base_test)
    apb_selftest_env env;
    int unsigned timeout_cycles = 500000;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void build_phase(uvm_phase phase);
      env = apb_selftest_env::type_id::create("env", this);
    endfunction
    virtual task stimulus(); endtask
    task run_phase(uvm_phase phase);
      phase.raise_objection(this);
      fork
        begin stimulus(); env.wait_idle(); end
        begin repeat (timeout_cycles) @(posedge env.mst.mdrv.vif.pclk);
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

  class apb_smoke_test extends apb_base_test;
    `uvm_component_utils(apb_smoke_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task stimulus();
      apb_base_seq s = apb_base_seq::type_id::create("s");
      bit e;
      bit [APB_MAX_DW-1:0] d;
      s.cfg = env.mcfg;
      s.set_sequencer(env.mst.sqr);
      s.pre_start();
      for (int i = 0; i < 16; i++) s.write1(32'h100 + 32'(4 * i), 32'hC0DE_0000 + 32'(i), e);
      for (int i = 0; i < 16; i++) begin
        s.read1(32'h100 + 32'(4 * i), d, e);
        if (d != 32'hC0DE_0000 + 32'(i) || e) `uvm_error("SMOKE", $sformatf("word %0d read %0h (err %0b)", i, d, e))
      end
      s.write1(32'h100, '1, e, 4'b0010);          // only byte lane 1 changes
      s.read1(32'h100, d, e);
      if (d != 32'hC0DE_FF00) `uvm_error("SMOKE", $sformatf("strobed write read back %0h", d))
    endtask
  endclass

  class apb_random_test extends apb_base_test;
    `uvm_component_utils(apb_random_test)
    int unsigned n = 1500;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      void'($value$plusargs("N=%d", n));
    endfunction
    task stimulus();
      apb_random_seq s = apb_random_seq::type_id::create("s");
      s.n = n; s.lo = 0; s.hi = 32'h3FF;
      s.start(env.mst.sqr);
    endtask
    function void check_phase(uvm_phase phase);
      if (env.sb.enabled && env.sb.n_checked == 0) `uvm_error("RANDOM", "no read was data-checked")
    endfunction
  endclass

  class apb_error_test extends apb_random_test;
    `uvm_component_utils(apb_error_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void end_of_elaboration_phase(uvm_phase phase);
      env.scfg.err_lo.push_back(64'h100); env.scfg.err_hi.push_back(64'h17F);
      env.scfg.err_lo.push_back(64'h300); env.scfg.err_hi.push_back(64'h303);
      n = 800;
    endfunction
    function void check_phase(uvm_phase phase);
      super.check_phase(phase);
      if (env.sb.n_err == 0) `uvm_error("ERRTEST", "no PSLVERR transfer was exercised")
    endfunction
  endclass

  // The scoreboard must notice a slave that corrupts read data.
  class apb_sb_sanity_test extends apb_random_test;
    `uvm_component_utils(apb_sb_sanity_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void end_of_elaboration_phase(uvm_phase phase);
      env.scfg.slave_corrupt_pct = 3;
      env.sb.set_report_severity_id_override(UVM_ERROR, "APB_SB", UVM_WARNING);
      n = 600;
    endfunction
    function void check_phase(uvm_phase phase);
      int unsigned c = uvm_report_server::get_server().get_id_count("APB_SB");
      if (c < 2) `uvm_error("SANITY", "scoreboard missed injected read-data corruption")
      else `uvm_info("SANITY", $sformatf("scoreboard flagged %0d corrupted reads", c - 1), UVM_LOW)
    endfunction
  endclass

  // uvm_reg frontdoor through apb_reg_adapter, mirror kept by a predictor on the monitor.
  class apb_reg_test extends apb_base_test;
    `uvm_component_utils(apb_reg_test)
    apb_st_reg_block              regs;
    apb_reg_adapter               adapter;
    uvm_reg_predictor #(apb_item) predictor;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      regs = apb_st_reg_block::type_id::create("regs");
      regs.build();
      adapter   = apb_reg_adapter::type_id::create("adapter");
      predictor = uvm_reg_predictor #(apb_item)::type_id::create("predictor", this);
    endfunction
    function void connect_phase(uvm_phase phase);
      regs.apb_map.set_sequencer(env.mst.sqr, adapter);
      regs.apb_map.set_auto_predict(0);
      predictor.map = regs.apb_map;
      predictor.adapter = adapter;
      env.mst.mon.ap.connect(predictor.bus_in);
    endfunction
    function void end_of_elaboration_phase(uvm_phase phase);
      env.scfg.err_lo.push_back(64'h81C); env.scfg.err_hi.push_back(64'h81F);   // r7 answers PSLVERR
    endfunction
    task stimulus();
      uvm_status_e st;
      uvm_reg_data_t v[apb_st_reg_block::NREGS], rd;
      foreach (regs.r[i]) begin
        v[i] = uvm_reg_data_t'($urandom);
        regs.r[i].write(st, v[i]);
        if ((st == UVM_IS_OK) == (i == 7)) `uvm_error("REG", $sformatf("r%0d write status %s", i, st.name()))
      end
      foreach (regs.r[i]) begin
        if (i == 7) continue;
        regs.r[i].read(st, rd);
        if (st != UVM_IS_OK || rd != v[i]) `uvm_error("REG", $sformatf("r%0d read %0h (%s), wrote %0h", i, rd, st.name(), v[i]))
        regs.r[i].mirror(st, UVM_CHECK);
      end
      regs.r[7].read(st, rd);
      if (st != UVM_NOT_OK) `uvm_error("REG", "r7 read in a PSLVERR region returned UVM_IS_OK")
    endtask
  endclass

  // +INJECT=<apb_inject_e name> +EXPECT_RULE=APB-Rnn: the injected violation must be caught
  // by that checker rule. Everything else that goes wrong afterwards is expected.
  class apb_violation_test extends apb_base_test;
    `uvm_component_utils(apb_violation_test)
    string inj_s, rule;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!$value$plusargs("INJECT=%s", inj_s) || !$value$plusargs("EXPECT_RULE=%s", rule))
        `uvm_fatal("ARGS", "need +INJECT= and +EXPECT_RULE=")
      vip_checker_db::expect_violations = 1;
    endfunction
    function void end_of_elaboration_phase(uvm_phase phase);
      apb_inject_e k;
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
      env.scfg.slave_wait_pct = 70;   // wait states give the wait-state injections a chance
    endfunction
    task stimulus();
      apb_random_seq s = apb_random_seq::type_id::create("s");
      s.n = 60; s.lo = 0; s.hi = 32'h3FF;
      fork
        s.start(env.mst.sqr);
        begin repeat (5000) @(posedge env.mst.mdrv.vif.pclk); end
      join_any
      disable fork;
      repeat (50) @(posedge env.mst.mdrv.vif.pclk);
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
