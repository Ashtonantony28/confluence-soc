// spikemesh_env_pkg.sv: SpikeMesh chip environment (M5). spikemesh_top (2x2 mesh, 256 neurons
// and axons per core) runs the trained 256-256-10 N-MNIST network; the expected host-bound spikes
// come from SpikeMesh's golden chip model through a trace that scripts/gen_spikemesh_trace.py
// records from SpikeMesh's own host API (ADR 0003, D4 golden images).
//
//   AXI4-Stream VIP master (48-bit flits) --> host_in       config, input spikes, state resets
//   AXI4-Stream VIP slave, random tready  <-- host_out      host-bound spikes (hidden + output layer)
//   spikemesh_ctrl_if                     <-> step / step_done / drained / err
// Every timestep's host-bound spikes are compared with the golden set; err and drop_cnt must
// stay 0.
package spikemesh_env_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import vip_common_pkg::*;
  import axis_pkg::*;

  localparam int FW = 48;                          // flit width (SPEC sec. 4)
  localparam int FB = FW / 8;
  localparam longint unsigned STEP_MAX = 2_000_000; // cycles before a STEP is declared hung
  typedef virtual spikemesh_ctrl_if ctrl_vif_t;
  typedef axis_agent #(FW) s_agent_t;

  // ------------------------------------------------------------------ collector + coverage
  class spikemesh_out_mon extends uvm_subscriber #(axis_item);
    `uvm_component_utils(spikemesh_out_mon)
    bit [FW-1:0] got[$];
    bit [3:0]    src_x, src_y;
    bit          par;
    int unsigned n_total;
    covergroup cg_out;
      cp_src: coverpoint {src_x, src_y} { bins c00 = {8'h00}; bins c10 = {8'h10}; bins c01 = {8'h01}; bins c11 = {8'h11}; }
      cp_par: coverpoint par;
      x_src_par: cross cp_src, cp_par;
    endgroup
    function new(string name, uvm_component parent); super.new(name, parent); cg_out = new(); endfunction
    function void write(axis_item t);
      foreach (t.data[i]) begin
        bit [FW-1:0] f = FW'(t.data[i]);
        got.push_back(f); n_total++;
        if (f[47:46] == 2'd0 && f[45:42] == 4'hF) begin
          src_x = f[29:26]; src_y = f[25:22]; par = f[37]; cg_out.sample();
        end
      end
    endfunction
  endclass

  class spikemesh_cov extends uvm_component;
    `uvm_component_utils(spikemesh_cov)
    int unsigned step_cycles, step_spikes;
    bit [1:0]    in_type;
    covergroup cg_step;
      cp_cycles: coverpoint step_cycles { bins short_ = {[0:499]}; bins mid = {[500:1999]}; bins long_ = {[2000:$]}; }
      cp_spikes: coverpoint step_spikes { bins none = {0}; bins few = {[1:20]}; bins many = {[21:80]}; bins storm = {[81:$]}; }
    endgroup
    covergroup cg_in;
      cp_type: coverpoint in_type { bins spike = {0}; bins cfg = {1}; bins read = {2}; bins ctrl = {3}; }
    endgroup
    function new(string name, uvm_component parent); super.new(name, parent); cg_step = new(); cg_in = new(); endfunction
    function void sample_step(int unsigned c, int unsigned s); step_cycles = c; step_spikes = s; cg_step.sample(); endfunction
    function void sample_in(bit [FW-1:0] f); in_type = f[47:46]; cg_in.sample(); endfunction
  endclass

  // ------------------------------------------------------------------ environment
  class spikemesh_env extends uvm_env;
    `uvm_component_utils(spikemesh_env)
    axis_cfg          icfg, ocfg;
    s_agent_t         ia, oa;
    spikemesh_out_mon omon;
    spikemesh_cov     cov;
    ctrl_vif_t        cvif;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void build_phase(uvm_phase phase);
      icfg = axis_cfg::type_id::create("icfg");
      icfg.role = AXIS_MASTER; icfg.data_bytes = FB; icfg.has_cov = 0; icfg.beat_gap_pct = 0;
      uvm_config_db#(axis_cfg)::set(this, "ia", "cfg", icfg);
      ia = s_agent_t::type_id::create("ia", this);
      ocfg = axis_cfg::type_id::create("ocfg");
      ocfg.role = AXIS_SLAVE; ocfg.data_bytes = FB; ocfg.has_cov = 0; ocfg.slave_ready_busy_pct = 0;
      uvm_config_db#(axis_cfg)::set(this, "oa", "cfg", ocfg);
      oa = s_agent_t::type_id::create("oa", this);
      omon = spikemesh_out_mon::type_id::create("omon", this);
      cov = spikemesh_cov::type_id::create("cov", this);
      if (!uvm_config_db#(ctrl_vif_t)::get(this, "", "cvif", cvif)) `uvm_fatal("NOVIF", "spikemesh_ctrl_if not set")
    endfunction
    function void connect_phase(uvm_phase phase);
      oa.mon.ap.connect(omon.analysis_export);
    endfunction
  endclass

  // ------------------------------------------------------------------ trace replay
  class spikemesh_trace_seq extends axis_base_seq;
    `uvm_object_utils(spikemesh_trace_seq)
    string        path;
    spikemesh_env env;
    int unsigned  in_gap_pct;                    // % of flits sent after an idle gap
    int unsigned  corrupt_every;                 // >0: flip a weight bit in every Nth weight CFG_WRITE
    int unsigned  n_wcfg, n_corrupt;
    int unsigned  n_flits, n_steps, n_out, n_bad;
    function new(string name = "spikemesh_trace_seq"); super.new(name); endfunction

    task send_flit(bit [FW-1:0] f);
      axis_item t = make();
      t.len = FB;
      t.gap_before = ($urandom_range(99) < in_gap_pct) ? $urandom_range(3, 1) : 0;
      t.data = new[1]; t.keep = new[1]; t.user = new[1];
      t.data[0] = f; t.keep[0] = '1; t.user[0] = '0;
      start_item(t);
      finish_item(t);                            // returns once the chip took the flit
      env.cov.sample_in(f);
      n_flits++;
    endtask

    // drained && host-out FIFO empty for 2 cycles (tests/system/tb_sys.sv wait_drained)
    task wait_drained();
      int cnt = 0;
      longint unsigned c = 0;
      while (cnt < 2) begin
        @(posedge env.cvif.clk);
        cnt = (env.cvif.drained && !env.oa.sdrv.vif.tvalid) ? cnt + 1 : 0;
        if (++c > STEP_MAX) begin `uvm_error("TRACE", "chip did not drain"); break; end
      end
    endtask

    task do_step(output int unsigned cycles);
      longint unsigned c = 0;
      @(posedge env.cvif.clk);
      env.cvif.step <= 1'b1;
      @(posedge env.cvif.clk);
      env.cvif.step <= 1'b0;
      while (!env.cvif.step_done) begin
        @(posedge env.cvif.clk);
        if (++c > STEP_MAX) begin `uvm_error("TRACE", "step_done never came"); break; end
      end
      wait_drained();
      cycles = int'(c);
      n_steps++;
    endtask

    function void compare(string line);
      string tok[$];
      bit [FW-1:0] want[$], have[$];
      int n;
      // tokens after "O <n>"
      begin
        int s = 0;
        for (int i = 0; i <= line.len(); i++)
          if (i == line.len() || line[i] == " " || line[i] == "\n") begin
            if (i > s) tok.push_back(line.substr(s, i - 1));
            s = i + 1;
          end
      end
      n = tok[1].atoi();
      // atohex() returns a 32-bit integer; flits are FW bits wide
      for (int i = 2; i < tok.size(); i++) begin
        bit [FW-1:0] v;
        void'($sscanf(tok[i], "%h", v));
        want.push_back(v);
      end
      if (want.size() != n) `uvm_fatal("TRACE", {"malformed O record: ", line})
      have = env.omon.got;
      env.omon.got.delete();
      have.sort(); want.sort();
      n_out += want.size();
      if (have != want) begin
        n_bad++;
        if (n_bad <= 5) `uvm_error("GOLDEN", $sformatf("step %0d: chip sent %0d host flits, golden %0d%s", n_steps,
                                   have.size(), want.size(), first_diff(have, want)))
      end
    endfunction

    function string first_diff(bit [FW-1:0] h[$], bit [FW-1:0] w[$]);
      foreach (w[i]) if (i >= h.size() || h[i] != w[i])
        return $sformatf("; first difference at %0d: chip %012h golden %012h", i, i < h.size() ? h[i] : 0, w[i]);
      return "";
    endfunction

    task body();
      int fd = $fopen(path, "r");
      string line;
      bit [63:0] f;
      int unsigned cyc;
      if (fd == 0) `uvm_fatal("TRACE", {"cannot open trace ", path})
      while ($fgets(line, fd)) begin
        if (line.len() < 1 || line[0] == "#") continue;
        case (line[0])
          "P": `uvm_info("TRACE", {"program parameters: ", line.substr(2, line.len() - 2)}, UVM_LOW)
          "F": begin
            void'($sscanf(line, "F %h", f));
            // weight CFG_WRITE: type [47:46] == 1, address [37:16] below the neuron region (SPEC §5)
            if (corrupt_every != 0 && f[47:46] == 2'd1 && f[37:36] == 2'd0 && (++n_wcfg % corrupt_every) == 0) begin
              f[6] = ~f[6];
              n_corrupt++;
            end
            send_flit(FW'(f));
          end
          "T": begin
            int unsigned n_before = env.omon.got.size();
            do_step(cyc);
            env.cov.sample_step(cyc, env.omon.got.size() - n_before);
          end
          "Y": wait_drained();
          "O": compare(line);
          "S": `uvm_info("TRACE", {"start ", line.substr(2, line.len() - 2)}, UVM_LOW)
          "E": break;
          default: `uvm_fatal("TRACE", {"bad trace record: ", line})
        endcase
      end
      $fclose(fd);
      if (env.omon.got.size() != 0) `uvm_error("GOLDEN", $sformatf("%0d host flits left over after the last comparison", env.omon.got.size()))
      `uvm_info("TRACE", $sformatf("%0d flits sent, %0d steps, %0d golden host flits compared, %0d steps wrong",
                n_flits, n_steps, n_out, n_bad), UVM_LOW)
      if (n_out == 0) `uvm_error("TRACE", "trace compared no output flits")
    endtask
  endclass

  // ------------------------------------------------------------------ tests (+TRACE=<file>)
  class spikemesh_base_test extends uvm_test;
    `uvm_component_utils(spikemesh_base_test)
    spikemesh_env env;
    int unsigned in_gap_pct, corrupt_every;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void build_phase(uvm_phase phase);
      env = spikemesh_env::type_id::create("env", this);
    endfunction
    virtual function void set_profile(); endfunction
    function void end_of_elaboration_phase(uvm_phase phase); set_profile(); endfunction
    task run_phase(uvm_phase phase);
      spikemesh_trace_seq s = spikemesh_trace_seq::type_id::create("trace");
      phase.raise_objection(this);
      if (!$value$plusargs("TRACE=%s", s.path)) `uvm_fatal("TRACE", "+TRACE=<golden trace> required")
      s.env = env; s.in_gap_pct = in_gap_pct; s.corrupt_every = corrupt_every;
      env.cvif.step <= 1'b0;
      while (!env.cvif.rst_n) @(posedge env.cvif.clk);
      repeat (10) @(posedge env.cvif.clk);
      s.start(env.ia.sqr);
      repeat (20) @(posedge env.cvif.clk);
      phase.drop_objection(this);
    endtask
    function void check_phase(uvm_phase phase);
      if (env.cvif.err !== 1'b0 || env.cvif.drop_cnt !== 8'd0)
        `uvm_error("SPIKEMESH", $sformatf("err=%0b drop_cnt=%0d at end of test", env.cvif.err, env.cvif.drop_cnt))
    endfunction
    function void report_phase(uvm_phase phase);
      uvm_report_server rs = uvm_report_server::get_server();
      `uvm_info("SM_COV", $sformatf("host flits by source/parity %.1f%%, step shapes %.1f%%, input flit types %.1f%%",
                env.omon.cg_out.get_inst_coverage(), env.cov.cg_step.get_inst_coverage(),
                env.cov.cg_in.get_inst_coverage()), UVM_LOW)
      if (rs.get_severity_count(UVM_ERROR) + rs.get_severity_count(UVM_FATAL) == 0) $display("*** TEST PASSED ***");
      else $display("*** TEST FAILED ***");
    endfunction
  endclass

  // Host always ready, flits back to back.
  class spikemesh_fast_test extends spikemesh_base_test;
    `uvm_component_utils(spikemesh_fast_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
  endclass

  // Random host backpressure on host_out and idle gaps on host_in (per seed).
  class spikemesh_backpressure_test extends spikemesh_base_test;
    `uvm_component_utils(spikemesh_backpressure_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void set_profile();
      env.ocfg.slave_ready_busy_pct = $urandom_range(20, 70);
      in_gap_pct = $urandom_range(0, 30);
    endfunction
  endclass

  // Negative check of the checker: the host image is corrupted (one weight bit flipped in every
  // 97th weight CFG_WRITE), so the chip computes on wrong weights and the golden compare must
  // notice. GOLDEN errors are demoted to warnings; the test fails if none appeared.
  class spikemesh_demote_catcher extends uvm_report_catcher;
    int unsigned n;
    function new(string name = "spikemesh_demote_catcher"); super.new(name); endfunction
    function action_e catch();
      if (get_severity() == UVM_ERROR && get_id() == "GOLDEN") begin
        n++; set_severity(UVM_WARNING);
      end
      return THROW;
    endfunction
  endclass

  class spikemesh_corrupt_test extends spikemesh_base_test;
    `uvm_component_utils(spikemesh_corrupt_test)
    spikemesh_demote_catcher dc;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void set_profile(); corrupt_every = 97; endfunction
    function void start_of_simulation_phase(uvm_phase phase);
      dc = new("dc");
      uvm_report_cb::add(null, dc);
    endfunction
    function void check_phase(uvm_phase phase);
      super.check_phase(phase);
      if (dc.n == 0) `uvm_error("CORRUPT", "corrupted weights went unnoticed by the golden compare")
      else `uvm_info("CORRUPT", $sformatf("golden compare flagged corrupted weights (%0d reports demoted)", dc.n), UVM_LOW)
    endfunction
  endclass
endpackage
