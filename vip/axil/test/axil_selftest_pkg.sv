// axil_selftest_pkg.sv: proves the AXI4-Lite VIP against itself before it is trusted on a DUT.
// VIP master <-> VIP reactive slave on one interface; an independent scoreboard predicts
// every read from its own memory model; the protocol checker watches the wires.
// The data width comes from AXIL_SELFTEST_DW (32 by default; the axil64_selftest bench sets 64).
`ifndef AXIL_SELFTEST_DW
`define AXIL_SELFTEST_DW 32
`endif
package axil_selftest_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import vip_common_pkg::*;
  import axil_pkg::*;

  localparam int AW = 32, DW = `AXIL_SELFTEST_DW;
  typedef axil_agent #(AW, DW) agent_t;

  `uvm_analysis_imp_decl(_axil_req)
  `uvm_analysis_imp_decl(_axil_done)

  // ------------------------------------------------------------------ scoreboard
  // Memory model updated at each completed OKAY write (AXI4-Lite completes writes in order).
  // A read is data-checked only when no write to its word was in flight at any point of the
  // read's lifetime (the slave may apply such a write before or after serving the read); the
  // tests keep reads and writes in disjoint halves so almost every read is checked.
  class axil_selftest_sb extends uvm_component;
    `uvm_component_utils(axil_selftest_sb)
    uvm_analysis_imp_axil_req  #(axil_item, axil_selftest_sb) req_export;
    uvm_analysis_imp_axil_done #(axil_item, axil_selftest_sb) done_export;
    axil_cfg     scfg;               // slave cfg: which addresses answer SLVERR
    bit          enabled = 1;
    vip_mem      model;
    int unsigned inflight[bit [63:0]];
    int unsigned gen[bit [63:0]];
    bit [63:0]   rd_word[$];
    int unsigned rd_gen[$];
    bit          rd_dirty[$];
    int unsigned n_wr, n_rd, n_checked, n_skipped, n_err;

    function new(string name, uvm_component parent);
      super.new(name, parent);
      req_export  = new("req_export", this);
      done_export = new("done_export", this);
      model = vip_mem::type_id::create("model");
    endfunction

    function int unsigned gen_of(bit [63:0] w);
      return gen.exists(w) ? gen[w] : 0;
    endfunction
    function int unsigned inflight_of(bit [63:0] w);
      return inflight.exists(w) ? inflight[w] : 0;
    endfunction

    function void write_axil_req(axil_item t);
      bit [63:0] w = t.word_addr();
      if (t.dir == AXIL_WRITE) begin
        inflight[w] = inflight_of(w) + 1;
        gen[w] = gen_of(w) + 1;
      end else begin
        rd_word.push_back(w); rd_gen.push_back(gen_of(w)); rd_dirty.push_back(inflight_of(w) != 0);
      end
    endfunction

    function void write_axil_done(axil_item t);
      bit [63:0] w = t.word_addr();
      axil_resp_e exp = scfg.in_err_region(t.addr) ? AXIL_SLVERR : AXIL_OKAY;
      if (!enabled) return;
      if (t.resp != exp)
        `uvm_error("AXIL_SB", $sformatf("%s: expected %s", t.convert2string(), exp.name()))
      if (t.resp != AXIL_OKAY) n_err++;
      if (t.dir == AXIL_WRITE) begin
        n_wr++;
        inflight[w] = inflight_of(w) - 1;
        if (t.resp == AXIL_OKAY)
          for (int unsigned b = 0; b < t.dbytes; b++)
            if (t.strb[b]) model.write_byte(w + 64'(b), t.data[8*b +: 8]);
      end else begin
        bit [63:0]   rw = rd_word.pop_front();
        int unsigned g  = rd_gen.pop_front();
        bit          d  = rd_dirty.pop_front();
        n_rd++;
        if (rw != w) `uvm_error("AXIL_SB", $sformatf("read order: expected word %0h, got %0h", rw, w))
        else if (t.resp != AXIL_OKAY) ;
        else if (d || g != gen_of(w) || inflight_of(w) != 0) n_skipped++;
        else begin
          bit [AXIL_MAX_DW-1:0] e = '0;
          for (int unsigned b = 0; b < t.dbytes; b++) e[8*b +: 8] = model.read_byte(w + 64'(b));
          n_checked++;
          if (e != t.data) `uvm_error("AXIL_SB", $sformatf("%s: expected data %0h", t.convert2string(), e))
        end
      end
    endfunction

    function void check_phase(uvm_phase phase);
      if (enabled && rd_word.size() != 0)
        `uvm_error("AXIL_SB", $sformatf("%0d reads issued but never completed", rd_word.size()))
    endfunction

    function void report_phase(uvm_phase phase);
      `uvm_info("AXIL_SB", $sformatf("%0d writes, %0d reads (%0d data-checked, %0d skipped), %0d error responses",
                n_wr, n_rd, n_checked, n_skipped, n_err), UVM_LOW)
    endfunction
  endclass

  // ------------------------------------------------------------------ env
  class axil_selftest_env extends uvm_env;
    `uvm_component_utils(axil_selftest_env)
    axil_cfg mcfg, scfg;
    agent_t  mst, slv;
    axil_selftest_sb sb;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void build_phase(uvm_phase phase);
      mcfg = axil_cfg::type_id::create("mcfg");
      scfg = axil_cfg::type_id::create("scfg");
      mcfg.role = AXIL_MASTER; mcfg.addr_width = AW; mcfg.data_bytes = DW / 8;
      scfg.role = AXIL_SLAVE;  scfg.addr_width = AW; scfg.data_bytes = DW / 8;
      scfg.has_cov = 0;
      uvm_config_db#(axil_cfg)::set(this, "mst", "cfg", mcfg);
      uvm_config_db#(axil_cfg)::set(this, "slv", "cfg", scfg);
      mst = agent_t::type_id::create("mst", this);
      slv = agent_t::type_id::create("slv", this);
      sb  = axil_selftest_sb::type_id::create("sb", this);
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
  class axil_base_test extends uvm_test;
    `uvm_component_utils(axil_base_test)
    axil_selftest_env env;
    int unsigned timeout_cycles = 500000;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void build_phase(uvm_phase phase);
      env = axil_selftest_env::type_id::create("env", this);
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

  class axil_smoke_test extends axil_base_test;
    `uvm_component_utils(axil_smoke_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task stimulus();
      axil_base_seq s = axil_base_seq::type_id::create("s");
      axil_resp_e r;
      bit [AXIL_MAX_DW-1:0] d, e;
      int unsigned nb = DW / 8;
      s.cfg = env.mcfg;
      s.set_sequencer(env.mst.sqr);
      s.pre_start();
      for (int i = 0; i < 16; i++) s.write1(64'h100 + 64'(nb * i), {2{32'hC0DE_0000 + 32'(i)}}, r);
      for (int i = 0; i < 16; i++) begin
        s.read1(64'h100 + 64'(nb * i), d, r);
        e = {2{32'hC0DE_0000 + 32'(i)}};
        if (DW < AXIL_MAX_DW) e[AXIL_MAX_DW-1:32] = '0;
        if (d != e || r != AXIL_OKAY) `uvm_error("SMOKE", $sformatf("word %0d read %0h (%s)", i, d, r.name()))
      end
      // Byte strobes: only lane 0 of word 0 changes.
      s.write1(64'h100, '1, r, 1);
      s.read1(64'h100, d, r);
      if (d[7:0] != 8'hFF || d[15:8] != 8'h00) `uvm_error("SMOKE", $sformatf("strobed write read back %0h", d))
    endtask
  endclass

  // Rounds of concurrent traffic: writes to one half of the window while reads check the
  // other half (written in an earlier round), so read data is never racing a write.
  class axil_random_test extends axil_base_test;
    `uvm_component_utils(axil_random_test)
    int unsigned rounds = 6, per_round = 150;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      void'($value$plusargs("ROUNDS=%d", rounds));
    endfunction
    task stimulus();
      for (int unsigned r = 0; r < rounds; r++) begin
        axil_random_seq w  = axil_random_seq::type_id::create("w");
        axil_random_seq rd = axil_random_seq::type_id::create("rd");
        bit [63:0] half = 64'h400;
        w.n = per_round;  w.write_pct = 100; w.lo = (r % 2) ? half : 0; w.hi = w.lo + half - 1;
        rd.n = per_round; rd.write_pct = 0;  rd.lo = (r % 2) ? 0 : half; rd.hi = rd.lo + half - 1;
        fork
          w.start(env.mst.sqr);
          rd.start(env.mst.sqr);
        join
        env.wait_idle();
      end
    endtask
    function void check_phase(uvm_phase phase);
      if (env.sb.enabled && env.sb.n_checked == 0) `uvm_error("RANDOM", "no read was data-checked")
    endfunction
  endclass

  // One access at a time, no response backpressure.
  class axil_serial_test extends axil_random_test;
    `uvm_component_utils(axil_serial_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void end_of_elaboration_phase(uvm_phase phase);
      env.mcfg.max_outstanding = 1; env.mcfg.bready_busy_pct = 0;
      rounds = 2;
    endfunction
  endclass

  class axil_error_test extends axil_random_test;
    `uvm_component_utils(axil_error_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void end_of_elaboration_phase(uvm_phase phase);
      env.scfg.err_lo.push_back(64'h100); env.scfg.err_hi.push_back(64'h17F);
      env.scfg.err_lo.push_back(64'h600); env.scfg.err_hi.push_back(64'h63F);
      rounds = 4;
    endfunction
    function void check_phase(uvm_phase phase);
      super.check_phase(phase);
      if (env.sb.n_err == 0) `uvm_error("ERRTEST", "no SLVERR access was exercised")
    endfunction
  endclass

  // The scoreboard must notice a slave that corrupts read data.
  class axil_sb_sanity_test extends axil_random_test;
    `uvm_component_utils(axil_sb_sanity_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void end_of_elaboration_phase(uvm_phase phase);
      env.scfg.slave_corrupt_pct = 3;
      env.sb.set_report_severity_id_override(UVM_ERROR, "AXIL_SB", UVM_WARNING);
      rounds = 2;
    endfunction
    function void check_phase(uvm_phase phase);
      int unsigned n = uvm_report_server::get_server().get_id_count("AXIL_SB");
      if (n < 2) `uvm_error("SANITY", "scoreboard missed injected read-data corruption")
      else `uvm_info("SANITY", $sformatf("scoreboard flagged %0d corrupted reads", n - 1), UVM_LOW)
    endfunction
  endclass

  // +INJECT=<axil_inject_e name> +EXPECT_RULE=AXIL-Rnn: the injected violation must be
  // caught by that checker rule. Everything else that goes wrong afterwards is expected.
  class axil_violation_test extends axil_base_test;
    `uvm_component_utils(axil_violation_test)
    string inj_s, rule;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!$value$plusargs("INJECT=%s", inj_s) || !$value$plusargs("EXPECT_RULE=%s", rule))
        `uvm_fatal("ARGS", "need +INJECT= and +EXPECT_RULE=")
      vip_checker_db::expect_violations = 1;
    endfunction
    function void end_of_elaboration_phase(uvm_phase phase);
      axil_inject_e k;
      bit found = 0;
      k = k.first();
      forever begin
        if (k.name() == inj_s) begin found = 1; break; end
        if (k == k.last()) break;
        k = k.next();
      end
      if (!found) `uvm_fatal("ARGS", {"unknown injection ", inj_s})
      if (k >= AXIL_INJ_B_VALID_DROP) env.scfg.inject = k; else env.mcfg.inject = k;
      env.sb.enabled = 0;
      env.scfg.slave_ready_busy_pct = 60;   // stalls give the hold injections a chance
      env.mcfg.bready_busy_pct = 50;
      env.mst.mdrv.set_report_severity_id_override(UVM_ERROR, "AXIL_MST", UVM_WARNING);
    endfunction
    task stimulus();
      axil_random_seq s = axil_random_seq::type_id::create("s");
      s.n = 80; s.lo = 0; s.hi = 64'h3FF;
      fork
        s.start(env.mst.sqr);
        begin repeat (5000) @(posedge env.mst.mdrv.vif.aclk); end
      join_any
      disable fork;
      repeat (500) @(posedge env.mst.mdrv.vif.aclk);   // let the slave drain its responses
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
