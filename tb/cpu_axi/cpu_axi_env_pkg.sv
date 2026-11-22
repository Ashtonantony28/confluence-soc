// cpu_axi_env_pkg.sv: Vortex-V CPU-on-AXI environment (M6, ADR 0006). The out-of-order core runs
// programs from a reactive AXI4 VIP slave memory through vortex_axi_bridge; every retired
// instruction is compared in order with Vortex-V's golden ISS (a trace recorded by
// scripts/gen_cpu_trace.py, ADR 0003 D4), and the run must end with tohost PASS, the ISS's final
// mlstat.SAT and, for random programs, the ISS's final data region.
package cpu_axi_env_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import vip_common_pkg::*;
  import axi4_pkg::*;

  localparam int XLEN = 64, AW = 32, DW = 64, IDW = 4;
  localparam bit [63:0] TOHOST_ADDR = 64'h8000_1000;
  typedef virtual cpu_retire_if #(.XLEN(XLEN)) rvif_t;
  typedef axi4_agent #(AW, DW, IDW) s_agent_t;

  // one core cycle: the instructions it retired (0, 1 or 2, oldest first)
  class cpu_cycle_item extends uvm_sequence_item;
    `uvm_object_utils(cpu_cycle_item)
    int unsigned     n;
    bit [XLEN-1:0]   pc[2], data[2];
    bit              wbv[2];
    bit [4:0]        rd[2];
    int unsigned     cycle;
    function new(string name = "cpu_cycle_item"); super.new(name); endfunction
  endclass

  // ------------------------------------------------------------------ retire monitor
  class cpu_retire_mon extends uvm_monitor;
    `uvm_component_utils(cpu_retire_mon)
    rvif_t vif;
    uvm_analysis_port #(cpu_cycle_item) ap;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void build_phase(uvm_phase phase);
      ap = new("ap", this);
      if (!uvm_config_db#(rvif_t)::get(this, "", "rvif", vif)) `uvm_fatal("NOVIF", "cpu_retire_if not set")
    endfunction
    task run_phase(uvm_phase phase);
      bit pend = 0;
      forever begin
        @(posedge vif.clk);
        if (!vif.rst_n) begin pend = 0; continue; end
        if (pend) begin                       // the core edge happened at the previous posedge
          cpu_cycle_item t = cpu_cycle_item::type_id::create("t");
          t.cycle = vif.core_cycles;
          if (vif.r0_valid) begin t.pc[0] = vif.r0_pc; t.wbv[0] = vif.r0_wbv; t.rd[0] = vif.r0_rd; t.data[0] = vif.r0_data; t.n = 1; end
          if (vif.r1_valid) begin t.pc[t.n] = vif.r1_pc; t.wbv[t.n] = vif.r1_wbv; t.rd[t.n] = vif.r1_rd; t.data[t.n] = vif.r1_data; t.n++; end
          ap.write(t);
        end
        pend = vif.step;
      end
    endtask
  endclass

  // ------------------------------------------------------------------ lockstep checker
  class cpu_lockstep_checker extends uvm_subscriber #(cpu_cycle_item);
    `uvm_component_utils(cpu_lockstep_checker)
    typedef struct { bit [XLEN-1:0] pc, data; bit wbv; bit [4:0] rd; bit [6:0] op; } exp_t;
    exp_t        exp[$];
    int unsigned n_exp, n_ok, n_bad, n_cycles, n_dual;
    bit          finished;                    // every expected retire seen, then an idle core cycle
    bit          drained;                     // every expected retire seen
    bit [6:0]    op;
    covergroup cg_op;
      cp_op: coverpoint op {
        bins load = {7'h03}; bins op_imm = {7'h13}; bins auipc = {7'h17}; bins op_imm32 = {7'h1b};
        bins store = {7'h23}; bins op = {7'h33}; bins lui = {7'h37}; bins op32 = {7'h3b};
        bins branch = {7'h63}; bins jalr = {7'h67}; bins jal = {7'h6f}; bins xmlacc = {7'h0b};
      }
    endgroup
    function new(string name, uvm_component parent); super.new(name, parent); cg_op = new(); endfunction

    function void expect_retire(bit [XLEN-1:0] pc, bit wbv, bit [4:0] rd, bit [XLEN-1:0] data, bit [6:0] o);
      exp_t e; e.pc = pc; e.wbv = wbv; e.rd = rd; e.data = data; e.op = o;
      exp.push_back(e); n_exp++;
    endfunction

    function void write(cpu_cycle_item t);
      if (finished) return;
      n_cycles++;
      if (t.n == 2) n_dual++;
      if (drained) begin                      // retires before the first idle cycle after tohost
        if (t.n != 0) begin
          n_bad++;
          `uvm_error("GOLDEN", $sformatf("core retired pc %0h after the ISS halted at the tohost store", t.pc[0]))
        end
        finished = 1;
        return;
      end
      for (int i = 0; i < t.n; i++) begin
        exp_t e;
        string why = "";
        if (exp.size() == 0) begin
          n_bad++;
          `uvm_error("GOLDEN", $sformatf("core retired pc %0h after the ISS halted at the tohost store", t.pc[i]))
          continue;
        end
        e = exp.pop_front();
        op = e.op; cg_op.sample();
        if (t.pc[i] !== e.pc) why = $sformatf("pc %0h, ISS %0h", t.pc[i], e.pc);
        else if (t.wbv[i] !== e.wbv) why = $sformatf("writeback valid %0b, ISS %0b", t.wbv[i], e.wbv);
        else if (e.wbv && t.rd[i] !== e.rd) why = $sformatf("rd x%0d, ISS x%0d", t.rd[i], e.rd);
        else if (e.wbv && t.data[i] !== e.data) why = $sformatf("x%0d = %0h, ISS %0h", e.rd, t.data[i], e.data);
        if (why == "") n_ok++;
        else begin
          n_bad++;
          if (n_bad <= 10) `uvm_error("GOLDEN", $sformatf("retire %0d (pc %0h, core cycle %0d): %s", n_ok + n_bad - 1, e.pc, t.cycle, why))
        end
      end
      if (exp.size() == 0) drained = 1;
    endfunction

    function void report_phase(uvm_phase phase);
      `uvm_info("LOCKSTEP", $sformatf("%0d of %0d ISS retires matched, %0d mismatches, %0d core cycles (%0d dual-retire)",
                n_ok, n_exp, n_bad, n_cycles, n_dual), UVM_LOW)
    endfunction
  endclass

  // ------------------------------------------------------------------ environment
  class cpu_axi_env extends uvm_env;
    `uvm_component_utils(cpu_axi_env)
    axi4_cfg             mcfg;
    s_agent_t            mem_agent;
    vip_mem              mem;
    cpu_retire_mon       rmon;
    cpu_lockstep_checker chk;
    rvif_t               rvif;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void build_phase(uvm_phase phase);
      mem = vip_mem::type_id::create("mem");
      mem.uninit = UNINIT_ZERO;               // the ISS memory reads 0 where nothing was loaded
      mcfg = axi4_cfg::type_id::create("mcfg");
      mcfg.role = AXI4_SLAVE; mcfg.addr_width = AW; mcfg.data_bytes = DW / 8; mcfg.id_width = IDW;
      mcfg.mem = mem;
      uvm_config_db#(axi4_cfg)::set(this, "mem", "cfg", mcfg);
      mem_agent = s_agent_t::type_id::create("mem", this);
      rmon = cpu_retire_mon::type_id::create("rmon", this);
      chk  = cpu_lockstep_checker::type_id::create("chk", this);
      if (!uvm_config_db#(rvif_t)::get(this, "", "rvif", rvif)) `uvm_fatal("NOVIF", "cpu_retire_if not set")
    endfunction
    function void connect_phase(uvm_phase phase);
      rmon.ap.connect(chk.analysis_export);
    endfunction
  endclass

  // ------------------------------------------------------------------ tests (+TRACE=<file>)
  class cpu_base_test extends uvm_test;
    `uvm_component_utils(cpu_base_test)
    cpu_axi_env env;
    string      path;
    bit [63:0]  exp_tohost;
    bit         exp_sat;
    bit [63:0]  c_addr[$];
    string      c_hex[$];
    longint unsigned max_cycles = 20_000_000;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void build_phase(uvm_phase phase); env = cpu_axi_env::type_id::create("env", this); endfunction
    virtual function void set_profile(axi4_cfg c);
      c.slave_ready_busy_pct = 0; c.slave_min_latency = 1; c.slave_max_latency = 1; c.slave_beat_gap_pct = 0;
    endfunction
    function void end_of_elaboration_phase(uvm_phase phase);
      set_profile(env.mcfg);
      `uvm_info("PROFILE", $sformatf("memory: %0d%% busy, latency %0d..%0d", env.mcfg.slave_ready_busy_pct,
                env.mcfg.slave_min_latency, env.mcfg.slave_max_latency), UVM_LOW)
    endfunction

    function void load_trace();
      int fd;
      string line, tag, hex;
      bit [63:0] a, pc, data;
      int unsigned wbv, rd, op, sat;
      if (!$value$plusargs("TRACE=%s", path)) `uvm_fatal("TRACE", "+TRACE=<golden trace> required")
      fd = $fopen(path, "r");
      if (fd == 0) `uvm_fatal("TRACE", {"cannot open trace ", path})
      while ($fgets(line, fd)) begin
        if (line.len() < 1 || line[0] == "#") continue;
        case (line[0])
          "M": begin
            void'($sscanf(line, "M %h %s", a, hex));
            for (int i = 0; i < hex.len() / 2; i++) env.mem.write_byte(a + 64'(i), 8'(hex.substr(2*i, 2*i+1).atohex()));
          end
          "R": begin
            void'($sscanf(line, "R %h %h %h %h %h", pc, wbv, rd, data, op));
            env.chk.expect_retire(pc, wbv[0], rd[4:0], data, op[6:0]);
          end
          "X": begin void'($sscanf(line, "X %h %h", data, sat)); exp_tohost = data; exp_sat = sat[0]; end
          "C": begin void'($sscanf(line, "C %h %s", a, hex)); c_addr.push_back(a); c_hex.push_back(hex); end
          "E": break;
          default: `uvm_fatal("TRACE", {"bad trace record: ", line})
        endcase
      end
      $fclose(fd);
      `uvm_info("TRACE", $sformatf("%s: %0d retires expected", path, env.chk.n_exp), UVM_LOW)
    endfunction

    function void start_of_simulation_phase(uvm_phase phase); load_trace(); endfunction

    task run_phase(uvm_phase phase);
      longint unsigned c = 0;
      phase.raise_objection(this);
      while (!env.chk.finished) begin
        @(posedge env.rvif.clk);
        if (++c > max_cycles) begin
          `uvm_error("CPU", $sformatf("timeout after %0d bus cycles: %0d of %0d retires seen", max_cycles,
                     env.chk.n_ok + env.chk.n_bad, env.chk.n_exp))
          break;
        end
      end
      repeat (20) @(posedge env.rvif.clk);
      phase.drop_objection(this);
    endtask

    function void check_phase(uvm_phase phase);
      bit [63:0] th = 0;
      int unsigned n_cbad = 0;
      for (int i = 0; i < 4; i++) th |= 64'(env.mem.read_byte(TOHOST_ADDR + 64'(i))) << (8 * i);
      if (th != exp_tohost) `uvm_error("GOLDEN", $sformatf("tohost = %0h, ISS %0h", th, exp_tohost))
      if (env.rvif.mlstat_sat !== exp_sat) `uvm_error("GOLDEN", $sformatf("mlstat.SAT = %0b, ISS %0b", env.rvif.mlstat_sat, exp_sat))
      if (env.rvif.bridge_err !== 1'b0) `uvm_error("CPU", "bridge err set (error response or misaligned access)")
      foreach (c_addr[k])
        for (int i = 0; i < c_hex[k].len() / 2; i++) begin
          bit [7:0] want = 8'(c_hex[k].substr(2*i, 2*i+1).atohex());
          bit [7:0] got = env.mem.read_byte(c_addr[k] + 64'(i));
          if (got !== want && ++n_cbad <= 5)
            `uvm_error("GOLDEN", $sformatf("memory @%0h = %02h, ISS %02h", c_addr[k] + 64'(i), got, want))
        end
    endfunction

    function void report_phase(uvm_phase phase);
      uvm_report_server rs = uvm_report_server::get_server();
      `uvm_info("CPU_COV", $sformatf("retired opcode classes %.1f%%, %0d core cycles", env.chk.cg_op.get_inst_coverage(),
                env.rvif.core_cycles), UVM_LOW)
      if (rs.get_severity_count(UVM_ERROR) + rs.get_severity_count(UVM_FATAL) == 0) $display("*** TEST PASSED ***");
      else $display("*** TEST FAILED ***");
    endfunction
  endclass

  // single-cycle memory, always ready
  class cpu_fast_test extends cpu_base_test;
    `uvm_component_utils(cpu_fast_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
  endclass

  // random latency and backpressure per seed
  class cpu_random_test extends cpu_base_test;
    `uvm_component_utils(cpu_random_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void set_profile(axi4_cfg c);
      c.slave_ready_busy_pct = $urandom_range(0, 40);
      c.slave_min_latency = $urandom_range(1, 4);
      c.slave_max_latency = c.slave_min_latency + $urandom_range(0, 16);
      c.slave_beat_gap_pct = 0;
    endfunction
  endclass

  // DDR-like latency
  class cpu_slow_test extends cpu_base_test;
    `uvm_component_utils(cpu_slow_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void set_profile(axi4_cfg c);
      c.slave_ready_busy_pct = 20; c.slave_min_latency = 20; c.slave_max_latency = 60; c.slave_beat_gap_pct = 0;
    endfunction
  endclass

  // Negative check of the checker: the memory flips a bit in some read beats (wrong instructions
  // or load data reach the core) and the lockstep compare must notice. GOLDEN and CPU errors are
  // demoted to warnings; the test fails if none appeared.
  class cpu_demote_catcher extends uvm_report_catcher;
    int unsigned n;
    function new(string name = "cpu_demote_catcher"); super.new(name); endfunction
    function action_e catch();
      if (get_severity() == UVM_ERROR && get_id() inside {"GOLDEN", "CPU"}) begin n++; set_severity(UVM_WARNING); end
      return THROW;
    endfunction
  endclass

  class cpu_corrupt_test extends cpu_base_test;
    `uvm_component_utils(cpu_corrupt_test)
    cpu_demote_catcher dc;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void set_profile(axi4_cfg c);
      super.set_profile(c);
      c.slave_corrupt_pct = 2;
      max_cycles = 2_000_000;
    endfunction
    function void start_of_simulation_phase(uvm_phase phase);
      super.start_of_simulation_phase(phase);
      dc = new("dc");
      uvm_report_cb::add(null, dc);
    endfunction
    function void check_phase(uvm_phase phase);
      super.check_phase(phase);
      if (dc.n == 0) `uvm_error("CORRUPT", "corrupted memory reads went unnoticed by the lockstep compare")
      else `uvm_info("CORRUPT", $sformatf("lockstep compare flagged corrupted reads (%0d reports demoted)", dc.n), UVM_LOW)
    endfunction
  endclass
endpackage
