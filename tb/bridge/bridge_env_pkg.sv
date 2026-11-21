// bridge_env_pkg.sv: block environment for the AXI4 -> AXI4-Lite and AXI4-Lite -> APB
// bridges (M2). Two chains run side by side, each driven by an AXI4 VIP master:
//   chain 0: AXI4 master -> axi2axil -> AXI4-Lite VIP slave
//   chain 1: AXI4 master -> axi2axil -> axil2apb -> APB VIP slave
// The downstream VIP slave's memory is the reference; the generic axi4_mem_scoreboard on the
// AXI4 side checks every byte, including narrow, unaligned, FIXED and WRAP bursts split
// into 32-bit words.
package bridge_env_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import vip_common_pkg::*;
  import axi4_pkg::*;
  import axil_pkg::*;
  import apb_pkg::*;

  localparam int AW = 32, DW = 128, IDW = 6, LDW = 32;
  localparam bit [63:0] WIN = 64'h3FFF;          // traffic window per chain
  localparam bit [63:0] ERR_LO = 64'h2000, ERR_HI = 64'h2FFF;   // 4 KiB aligned: bursts are all-in or all-out

  typedef axi4_agent #(AW, DW, IDW) a_agent_t;
  typedef axil_agent #(AW, LDW)     l_agent_t;
  typedef apb_agent  #(AW, LDW)     p_agent_t;

  class bridge_mem_sb extends axi4_mem_scoreboard;
    `uvm_component_utils(bridge_mem_sb)
    bit errs_on;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function axi4_resp_e expect_resp(axi4_item t);
      if (errs_on && t.addr >= ERR_LO && t.addr <= ERR_HI) return AXI4_SLVERR;
      return AXI4_OKAY;
    endfunction
  endclass

  class bridge_env extends uvm_env;
    `uvm_component_utils(bridge_env)
    axi4_cfg  acfg[2];
    axil_cfg  lcfg;
    apb_cfg   pcfg;
    a_agent_t ma[2];
    l_agent_t ls;
    p_agent_t ps;
    bridge_mem_sb sb[2];
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void build_phase(uvm_phase phase);
      for (int c = 0; c < 2; c++) begin
        acfg[c] = axi4_cfg::type_id::create($sformatf("acfg%0d", c));
        acfg[c].role = AXI4_MASTER; acfg[c].addr_width = AW; acfg[c].data_bytes = DW / 8; acfg[c].id_width = IDW;
        uvm_config_db#(axi4_cfg)::set(this, $sformatf("ma%0d", c), "cfg", acfg[c]);
        ma[c] = a_agent_t::type_id::create($sformatf("ma%0d", c), this);
        sb[c] = bridge_mem_sb::type_id::create($sformatf("sb%0d", c), this);
      end
      lcfg = axil_cfg::type_id::create("lcfg");
      lcfg.role = AXIL_SLAVE; lcfg.addr_width = AW; lcfg.data_bytes = LDW / 8; lcfg.has_cov = 0;
      uvm_config_db#(axil_cfg)::set(this, "ls", "cfg", lcfg);
      ls = l_agent_t::type_id::create("ls", this);
      pcfg = apb_cfg::type_id::create("pcfg");
      pcfg.role = APB_SLAVE; pcfg.addr_width = AW; pcfg.data_bytes = LDW / 8; pcfg.has_cov = 0;
      uvm_config_db#(apb_cfg)::set(this, "ps", "cfg", pcfg);
      ps = p_agent_t::type_id::create("ps", this);
    endfunction
    function void connect_phase(uvm_phase phase);
      for (int c = 0; c < 2; c++) begin
        ma[c].mon.ap_req.connect(sb[c].req_export);
        ma[c].mon.ap.connect(sb[c].done_export);
      end
    endfunction
    task wait_idle();
      do @(posedge ma[0].mdrv.vif.aclk); while (ma[0].mdrv.outstanding || ma[1].mdrv.outstanding);
      repeat (10) @(posedge ma[0].mdrv.vif.aclk);
    endtask
  endclass

  class bridge_base_test extends uvm_test;
    `uvm_component_utils(bridge_base_test)
    bridge_env env;
    int unsigned n = 150, max_len = 15;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void build_phase(uvm_phase phase);
      env = bridge_env::type_id::create("env", this);
      void'($value$plusargs("N=%d", n));
    endfunction
    task run_phase(uvm_phase phase);
      phase.raise_objection(this);
      fork
        begin
          for (int c = 0; c < 2; c++) begin
            automatic int cc = c;
            fork begin
              axi4_random_seq s = axi4_random_seq::type_id::create($sformatf("s%0d", cc));
              s.n = n; s.lo = 0; s.hi = WIN; s.max_len = max_len;
              s.start(env.ma[cc].sqr);
            end join_none
          end
          wait fork;
          env.wait_idle();
        end
        begin repeat (3000000) @(posedge env.ma[0].mdrv.vif.aclk); `uvm_error("TIMEOUT", "test timed out") end
      join_any
      disable fork;
      phase.drop_objection(this);
    endtask
    function void report_phase(uvm_phase phase);
      uvm_report_server rs = uvm_report_server::get_server();
      if (rs.get_severity_count(UVM_ERROR) + rs.get_severity_count(UVM_FATAL) == 0) $display("*** TEST PASSED ***");
      else $display("*** TEST FAILED ***");
    endfunction
  endclass

  class bridge_smoke_test extends bridge_base_test;
    `uvm_component_utils(bridge_smoke_test)
    function new(string name, uvm_component parent); super.new(name, parent); n = 20; max_len = 3; endfunction
  endclass

  class bridge_random_test extends bridge_base_test;
    `uvm_component_utils(bridge_random_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
  endclass

  class bridge_error_test extends bridge_base_test;
    `uvm_component_utils(bridge_error_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void end_of_elaboration_phase(uvm_phase phase);
      env.lcfg.err_lo.push_back(ERR_LO); env.lcfg.err_hi.push_back(ERR_HI);
      env.pcfg.err_lo.push_back(ERR_LO); env.pcfg.err_hi.push_back(ERR_HI);
      env.sb[0].errs_on = 1; env.sb[1].errs_on = 1;
    endfunction
    function void check_phase(uvm_phase phase);
      if (env.sb[0].n_err == 0 || env.sb[1].n_err == 0) `uvm_error("ERRTEST", "a chain saw no error response")
    endfunction
  endclass
  // Error region of a single 32-bit word inside a 16-byte beat: the bridge must merge the
  // per-word responses into the worst one (kills a "last word wins" BRESP/RRESP bug that a
  // 4 KiB-aligned region cannot see). Directed, so the memory scoreboard is off.

  // Directed traffic for bridge_word_err_test: one full beat per 16-byte line of 0x2000-0x203F.
  class bridge_word_err_seq extends axi4_base_seq;
    `uvm_object_utils(bridge_word_err_seq)
    int chain;
    function new(string name = "bridge_word_err_seq"); super.new(name); endfunction
    task body();
      for (bit [63:0] a = 64'h2000; a < 64'h2040; a += 16) begin
        axi4_resp_e wr, rr, exp;
        bit [AXI4_MAX_DW-1:0] d;
        exp = (a == 64'h2030) ? AXI4_OKAY : AXI4_SLVERR;
        write1(a, {4{32'hC0FFEE00 | 32'(a)}}, wr);
        read1(a, d, rr);
        if (wr != exp) `uvm_error("WORDERR", $sformatf("chain %0d write %0h bresp %s, expected %s", chain, a, wr.name(), exp.name()))
        if (rr != exp) `uvm_error("WORDERR", $sformatf("chain %0d read %0h rresp %s, expected %s", chain, a, rr.name(), exp.name()))
      end
    endtask
  endclass

  class bridge_word_err_test extends bridge_base_test;
    `uvm_component_utils(bridge_word_err_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void end_of_elaboration_phase(uvm_phase phase);
      foreach (BAD[i]) begin
        env.lcfg.err_lo.push_back(BAD[i]); env.lcfg.err_hi.push_back(BAD[i] + 3);
        env.pcfg.err_lo.push_back(BAD[i]); env.pcfg.err_hi.push_back(BAD[i] + 3);
      end
      env.sb[0].enabled = 0; env.sb[1].enabled = 0;
    endfunction
    localparam bit [63:0] BAD[3] = '{64'h2000, 64'h2018, 64'h202C};  // first, middle, last word
    task run_phase(uvm_phase phase);
      phase.raise_objection(this);
      for (int c = 0; c < 2; c++) begin
        automatic int cc = c;
        fork begin
          bridge_word_err_seq s = bridge_word_err_seq::type_id::create($sformatf("d%0d", cc));
          s.chain = cc;
          s.start(env.ma[cc].sqr);
        end join_none
      end
      wait fork;
      env.wait_idle();
      phase.drop_objection(this);
    endtask
  endclass
endpackage
