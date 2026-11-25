// credit_selftest_pkg.sv: proves the credit-link VIP against itself before it is trusted on a
// DUT. VIP sender -> VIP receiver on one link (depth 4); a scoreboard checks that the wire
// (monitor) and the consumer (receiver pops) both see exactly the sent flits in order; the
// protocol checker watches the wires and must stay silent, or catch an injected violation.
package credit_selftest_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import vip_common_pkg::*;
  import credit_pkg::*;

  localparam int DW = 48, DEPTH = 4;
  typedef credit_agent #(DW) agent_t;

  `uvm_analysis_imp_decl(_exp)
  `uvm_analysis_imp_decl(_mon)
  `uvm_analysis_imp_decl(_rcv)

  class credit_selftest_sb extends uvm_component;
    `uvm_component_utils(credit_selftest_sb)
    uvm_analysis_imp_exp #(credit_item, credit_selftest_sb) exp_export;
    uvm_analysis_imp_mon #(credit_item, credit_selftest_sb) mon_export;
    uvm_analysis_imp_rcv #(credit_item, credit_selftest_sb) rcv_export;
    bit enabled = 1;
    bit [DW-1:0] e_mon[$], e_rcv[$], a_mon[$], a_rcv[$];
    int unsigned n_exp;
    function new(string name, uvm_component parent);
      super.new(name, parent);
      exp_export = new("exp_export", this); mon_export = new("mon_export", this); rcv_export = new("rcv_export", this);
    endfunction
    function void match(string who, ref bit [DW-1:0] e[$], ref bit [DW-1:0] a[$]);
      while (e.size() && a.size()) begin
        bit [DW-1:0] x = e.pop_front(), y = a.pop_front();
        if (x !== y) `uvm_error("CREDIT_SB", $sformatf("%s saw %0h, sent %0h", who, y, x))
      end
    endfunction
    function void write_exp(credit_item t);
      if (!enabled) return;
      n_exp++; e_mon.push_back(DW'(t.data)); e_rcv.push_back(DW'(t.data));
      match("monitor", e_mon, a_mon); match("receiver", e_rcv, a_rcv);
    endfunction
    function void write_mon(credit_item t);
      if (!enabled) return;
      a_mon.push_back(DW'(t.data)); match("monitor", e_mon, a_mon);
    endfunction
    function void write_rcv(credit_item t);
      if (!enabled) return;
      a_rcv.push_back(DW'(t.data)); match("receiver", e_rcv, a_rcv);
    endfunction
    function void check_phase(uvm_phase phase);
      if (enabled && (e_mon.size() || e_rcv.size() || a_mon.size() || a_rcv.size()))
        `uvm_error("CREDIT_SB", $sformatf("unmatched: sent-not-seen %0d/%0d, seen-not-sent %0d/%0d (monitor/receiver)",
                   e_mon.size(), e_rcv.size(), a_mon.size(), a_rcv.size()))
    endfunction
    function void report_phase(uvm_phase phase);
      `uvm_info("CREDIT_SB", $sformatf("%0d flits sent and matched", n_exp), UVM_LOW)
    endfunction
  endclass

  class credit_selftest_env extends uvm_env;
    `uvm_component_utils(credit_selftest_env)
    credit_cfg tcfg, rcfg;
    agent_t    tx, rx;
    credit_selftest_sb sb;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void build_phase(uvm_phase phase);
      tcfg = credit_cfg::type_id::create("tcfg"); tcfg.role = CREDIT_TX; tcfg.depth = DEPTH;
      rcfg = credit_cfg::type_id::create("rcfg"); rcfg.role = CREDIT_RX; rcfg.depth = DEPTH; rcfg.has_cov = 0;
      uvm_config_db#(credit_cfg)::set(this, "tx", "cfg", tcfg);
      uvm_config_db#(credit_cfg)::set(this, "rx", "cfg", rcfg);
      tx = agent_t::type_id::create("tx", this);
      rx = agent_t::type_id::create("rx", this);
      sb = credit_selftest_sb::type_id::create("sb", this);
    endfunction
    function void connect_phase(uvm_phase phase);
      tx.tdrv.ap_sent.connect(sb.exp_export);
      tx.mon.ap.connect(sb.mon_export);
      rx.rdrv.ap_rcvd.connect(sb.rcv_export);
    endfunction
  endclass

  class credit_base_test extends uvm_test;
    `uvm_component_utils(credit_base_test)
    credit_selftest_env env;
    int unsigned n = 300;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void build_phase(uvm_phase phase); env = credit_selftest_env::type_id::create("env", this); endfunction
    virtual task stimulus();
      credit_random_seq s = credit_random_seq::type_id::create("s");
      credit_burst_seq  b = credit_burst_seq::type_id::create("b");
      s.n = n; b.n = n / 3;
      s.start(env.tx.sqr);
      b.start(env.tx.sqr);
    endtask
    task run_phase(uvm_phase phase);
      phase.raise_objection(this);
      stimulus();
      repeat (100) @(posedge env.tx.tdrv.vif.clk);
      phase.drop_objection(this);
    endtask
    function void report_phase(uvm_phase phase);
      uvm_report_server rs = uvm_report_server::get_server();
      if (env.tx.cov != null)
        `uvm_info("CREDIT_COV", $sformatf("occupancy x spacing %.1f%%", env.tx.cov.cg.get_inst_coverage()), UVM_LOW)
      if (rs.get_severity_count(UVM_ERROR) + rs.get_severity_count(UVM_FATAL) == 0) $display("*** TEST PASSED ***");
      else $display("*** TEST FAILED ***");
    endfunction
  endclass

  // receiver always drains at once: the sender rarely runs out of credits
  class credit_smoke_test extends credit_base_test;
    `uvm_component_utils(credit_smoke_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void end_of_elaboration_phase(uvm_phase phase); env.rcfg.rx_busy_pct = 0; endfunction
  endclass

  class credit_random_test extends credit_base_test;
    `uvm_component_utils(credit_random_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void end_of_elaboration_phase(uvm_phase phase);
      env.rcfg.rx_busy_pct = $urandom_range(10, 60); env.rcfg.rx_delay_max = $urandom_range(1, 6);
    endfunction
  endclass

  // slow receiver: the buffer fills and the sender stalls on credits most of the time
  class credit_backpressure_test extends credit_base_test;
    `uvm_component_utils(credit_backpressure_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void end_of_elaboration_phase(uvm_phase phase);
      env.rcfg.rx_busy_pct = 90; env.rcfg.rx_delay_max = 10;
    endfunction
    function void check_phase(uvm_phase phase);
      if (env.tx.tdrv.n_waits == 0) `uvm_error("CREDIT_TEST", "sender never waited for a credit")
    endfunction
  endclass

  // +INJECT=<credit_inject_e name> +EXPECT_RULE=CREDIT-Rnn
  class credit_violation_test extends credit_base_test;
    `uvm_component_utils(credit_violation_test)
    string inj_s, rule;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!$value$plusargs("INJECT=%s", inj_s) || !$value$plusargs("EXPECT_RULE=%s", rule))
        `uvm_fatal("ARGS", "need +INJECT= and +EXPECT_RULE=")
      vip_checker_db::expect_violations = 1;
      n = 60;
    endfunction
    function void end_of_elaboration_phase(uvm_phase phase);
      credit_inject_e k = k.first();
      bit found = 0;
      forever begin
        if (k.name() == inj_s) begin found = 1; break; end
        if (k == k.last()) break;
        k = k.next();
      end
      if (!found) `uvm_fatal("ARGS", {"unknown injection ", inj_s})
      if (k == CREDIT_INJ_EXTRA_CREDIT) env.rcfg.inject = k; else env.tcfg.inject = k;
      env.rcfg.rx_busy_pct = 80; env.rcfg.rx_delay_max = 6;   // run out of credits often
      env.sb.enabled = 0;
    endfunction
    function void check_phase(uvm_phase phase);
      if (vip_checker_db::count(rule) == 0) `uvm_error("VIOLATION", {rule, " did not fire for ", inj_s})
      else `uvm_info("VIOLATION", $sformatf("%s caught by %s (%0d hits)", inj_s, rule, vip_checker_db::count(rule)), UVM_LOW)
    endfunction
  endclass
endpackage
