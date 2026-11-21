// nanoxl_env_pkg.sv: NanoXL block environment (M4). nanoxl_top runs real compiled transformer
// programs; the expected values come from NanoXL's golden model through a trace that
// scripts/gen_nanoxl_trace.py records from the NanoXL host driver (ADR 0003, D4 golden images).
//
//   AXI4-Lite master (VIP) --RAL nanoxl_csr--> s_axil        CSRs, ring doorbell, polling
//   3 reactive AXI4 slaves (VIP), one shared memory  <-- mf (fetch), md, md1 (DMA)
//                                                       random latency / backpressure per seed
// The trace replay loads the DDR image into the shared memory, performs the driver's CSR
// accesses (reads poll until the golden value appears) and compares every byte the device must
// have written (logits per step, KV cache) with the golden values.
package nanoxl_env_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import vip_common_pkg::*;
  import axi4_pkg::*;
  import axil_pkg::*;
  import confluence_soc_ral_pkg::*;

  localparam int AW = 32, DW = 128, IDW = 4, LAW = 32, LDW = 32;
  localparam int NPORT = 3;                        // 0 = mf (fetch, read only), 1 = md, 2 = md1
  localparam string PORT_NAME[NPORT] = '{"mf", "md", "md1"};
  localparam int unsigned POLL_GAP = 16;           // cycles between polls of a CSR
  localparam longint unsigned POLL_MAX = 4_000_000; // cycles before a poll gives up

  `uvm_analysis_imp_decl(_dma)

  typedef axi4_agent #(AW, DW, IDW) s_agent_t;
  typedef axil_agent #(LAW, LDW)     l_agent_t;

  // ------------------------------------------------------------------ coverage
  // Command words seen on the fetch port, DMA burst shapes on the DMA ports, ring wrap.
  class nanoxl_cov extends uvm_component;
    `uvm_component_utils(nanoxl_cov)
    uvm_analysis_imp #(axi4_item, nanoxl_cov) fetch_export;
    uvm_analysis_imp_dma #(axi4_item, nanoxl_cov) dma_export;
    bit [5:0]   op;
    axi4_item   d;
    bit         wrapped;
    int unsigned n_words, n_dma;

    covergroup cg_cmd;
      cp_op: coverpoint op {
        bins end_ = {8'h01}; bins irq = {8'h02}; bins wait_ = {8'h03}; bins signal = {8'h04};
        bins dma_load = {8'h08}; bins dma_store = {8'h09}; bins gemm = {8'h10}; bins attn = {8'h11};
        bins gemm_gs = {8'h12}; bins vec = {8'h18}; bins requant = {8'h19}; bins ln = {8'h1A};
        bins softmax = {8'h1B}; bins gelu = {8'h1C}; bins kv_append = {8'h1D}; bins lut_load = {8'h1E};
      }
    endgroup
    covergroup cg_dma;
      cp_dir: coverpoint d.dir;
      cp_len: coverpoint d.len { bins one = {0}; bins short_ = {[1:15]}; bins mid = {[16:127]}; bins long_ = {[128:255]}; }
      cp_partial: coverpoint (d.dir == AXI4_WRITE && d.strb.size() > 0 && d.strb[0] != '1) { bins full = {0}; bins partial = {1}; }
      x_dir_len: cross cp_dir, cp_len;
    endgroup
    covergroup cg_ring;
      cp_wrap: coverpoint wrapped { bins no = {0}; bins yes = {1}; }
    endgroup

    function new(string name, uvm_component parent);
      super.new(name, parent);
      fetch_export = new("fetch_export", this);
      dma_export   = new("dma_export", this);
      cg_cmd = new(); cg_dma = new(); cg_ring = new();
    endfunction

    function void write(axi4_item t);          // fetch reads: every 128-bit beat is one command
      foreach (t.data[i]) begin op = t.data[i][5:0]; n_words++; cg_cmd.sample(); end
    endfunction
    function void write_dma(axi4_item t);
      d = t; n_dma++; cg_dma.sample();
    endfunction
    function void note_wrap(bit w);
      wrapped = w; cg_ring.sample();
    endfunction
    function void report_phase(uvm_phase phase);
      `uvm_info("NXL_COV", $sformatf("%0d command words, %0d DMA bursts; coverage cmd %.1f%% dma %.1f%% ring %.1f%%",
                n_words, n_dma, cg_cmd.get_inst_coverage(), cg_dma.get_inst_coverage(),
                cg_ring.get_inst_coverage()), UVM_LOW)
    endfunction
  endclass

  // ------------------------------------------------------------------ environment
  class nanoxl_env extends uvm_env;
    `uvm_component_utils(nanoxl_env)
    axi4_cfg         scfg[NPORT];
    axil_cfg         lcfg;
    s_agent_t        sa[NPORT];
    l_agent_t        la;
    vip_mem          mem;
    nanoxl_csr       ral;
    axil_reg_adapter adp;
    nanoxl_cov       cov;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction

    function void build_phase(uvm_phase phase);
      mem = vip_mem::type_id::create("mem");
      mem.uninit = UNINIT_ZERO;                  // the driver zeroes the buffer before loading
      for (int i = 0; i < NPORT; i++) begin
        scfg[i] = axi4_cfg::type_id::create($sformatf("scfg%0d", i));
        scfg[i].role = AXI4_SLAVE; scfg[i].addr_width = AW; scfg[i].data_bytes = DW / 8;
        scfg[i].id_width = IDW; scfg[i].mem = mem; scfg[i].has_cov = 0;
        uvm_config_db#(axi4_cfg)::set(this, $sformatf("sa%0d", i), "cfg", scfg[i]);
        sa[i] = s_agent_t::type_id::create($sformatf("sa%0d", i), this);
      end
      lcfg = axil_cfg::type_id::create("lcfg");
      lcfg.role = AXIL_MASTER; lcfg.addr_width = LAW; lcfg.data_bytes = LDW / 8; lcfg.has_cov = 0;
      uvm_config_db#(axil_cfg)::set(this, "la", "cfg", lcfg);
      la = l_agent_t::type_id::create("la", this);
      cov = nanoxl_cov::type_id::create("cov", this);
      ral = new("nanoxl");
      ral.build(); ral.lock_model(); ral.reset();
      adp = axil_reg_adapter::type_id::create("adp");
    endfunction

    function void connect_phase(uvm_phase phase);
      ral.default_map.set_sequencer(la.sqr, adp);
      ral.default_map.set_auto_predict(1);
      sa[0].mon.ap.connect(cov.fetch_export);
      sa[1].mon.ap.connect(cov.dma_export);
      sa[2].mon.ap.connect(cov.dma_export);
    endfunction

    // Latency / backpressure profile of the memory side, chosen per test.
    function void memory_profile(int unsigned busy_pct, int unsigned min_lat, int unsigned max_lat);
      foreach (scfg[i]) begin
        scfg[i].slave_ready_busy_pct = busy_pct;
        scfg[i].slave_min_latency = min_lat; scfg[i].slave_max_latency = max_lat;
        scfg[i].slave_beat_gap_pct = busy_pct / 2;
      end
    endfunction
  endclass

  // ------------------------------------------------------------------ trace replay
  class nanoxl_trace_seq extends uvm_reg_sequence;
    `uvm_object_utils(nanoxl_trace_seq)
    string     path;
    nanoxl_env env;
    int unsigned n_w, n_r, n_load, n_cmp, n_bad;
    bit [31:0] last_head;
    function new(string name = "nanoxl_trace_seq"); super.new(name); endfunction

    function uvm_reg reg_at(bit [31:0] off);
      uvm_reg r = env.ral.default_map.get_reg_by_offset(off);
      if (r == null) `uvm_fatal("TRACE", $sformatf("no register at CSR offset %0h", off))
      return r;
    endfunction

    task poll(bit [31:0] off, bit [31:0] want);
      uvm_status_e st;
      uvm_reg_data_t v;
      uvm_reg r = reg_at(off);
      longint unsigned waited = 0;
      forever begin
        r.read(st, v, .parent(this));
        if (st != UVM_IS_OK) `uvm_error("TRACE", $sformatf("CSR read %0h failed", off))
        if (32'(v) == want) break;
        if (waited > POLL_MAX) begin
          `uvm_error("TRACE", $sformatf("CSR %s reads %0h, golden %0h (gave up after %0d cycles)",
                     r.get_name(), 32'(v), want, waited))
          break;
        end
        repeat (POLL_GAP) @(posedge env.la.mdrv.vif.aclk);
        waited += POLL_GAP;
      end
      if (r.get_name() == "RING_HEAD") begin
        if (want < last_head) env.cov.note_wrap(1); else env.cov.note_wrap(0);
        last_head = want;
      end
    endtask

    function void load(bit [63:0] a, string hex);
      for (int i = 0; i < hex.len() / 2; i++) env.mem.write_byte(a + 64'(i), 8'(hex.substr(2*i, 2*i+1).atohex()));
      n_load += hex.len() / 2;
    endfunction

    function void check(bit [63:0] a, string hex);
      for (int i = 0; i < hex.len() / 2; i++) begin
        bit [7:0] exp = 8'(hex.substr(2*i, 2*i+1).atohex());
        bit [7:0] got = env.mem.read_byte(a + 64'(i));
        n_cmp++;
        if (got != exp) begin
          n_bad++;
          if (n_bad <= 10) `uvm_error("GOLDEN", $sformatf("DDR %0h = %02h, golden %02h", a + 64'(i), got, exp))
        end
      end
    endfunction

    task body();
      int fd = $fopen(path, "r");
      string line, tag, s1, s2;
      bit [63:0] a, b;
      uvm_status_e st;
      uvm_reg_data_t v;
      if (fd == 0) `uvm_fatal("TRACE", {"cannot open trace ", path})
      while ($fgets(line, fd)) begin
        if (line.len() < 1 || line[0] == "#") continue;
        tag = line.substr(0, 0);
        case (tag)
          "B": ;
          "M": begin void'($sscanf(line, "M %h %s", a, s1)); load(a, s1); end
          "C": begin void'($sscanf(line, "C %h %s", a, s1)); check(a, s1); end
          "W": begin
            void'($sscanf(line, "W %h %h", a, b));
            reg_at(32'(a)).write(st, b, .parent(this)); n_w++;
            if (st != UVM_IS_OK) `uvm_error("TRACE", $sformatf("CSR write %0h failed", a))
          end
          "R": begin void'($sscanf(line, "R %h %h", a, b)); poll(32'(a), 32'(b)); n_r++; end
          "X": begin void'($sscanf(line, "X %h", a)); reg_at(32'(a)).read(st, v, .parent(this)); end
          "S": begin void'($sscanf(line, "S %s", s1)); `uvm_info("TRACE", {"start ", s1}, UVM_LOW) end
          "E": break;
          default: `uvm_fatal("TRACE", {"bad trace record: ", line})
        endcase
      end
      $fclose(fd);
      `uvm_info("TRACE", $sformatf("%0d bytes loaded, %0d CSR writes, %0d golden CSR reads, %0d output bytes checked, %0d wrong",
                n_load, n_w, n_r, n_cmp, n_bad), UVM_LOW)
      if (n_cmp == 0) `uvm_error("TRACE", "trace checked no output bytes")
    endtask
  endclass

  // ------------------------------------------------------------------ tests
  // +TRACE=<file> selects the golden trace; the test picks the memory profile.
  class nanoxl_base_test extends uvm_test;
    `uvm_component_utils(nanoxl_base_test)
    nanoxl_env env;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void build_phase(uvm_phase phase);
      env = nanoxl_env::type_id::create("env", this);
    endfunction
    virtual function void set_profile();
      env.memory_profile(0, 1, 1);
    endfunction
    function void end_of_elaboration_phase(uvm_phase phase);
      set_profile();
    endfunction
    task run_phase(uvm_phase phase);
      nanoxl_trace_seq s = nanoxl_trace_seq::type_id::create("trace");
      phase.raise_objection(this);
      if (!$value$plusargs("TRACE=%s", s.path)) `uvm_fatal("TRACE", "+TRACE=<golden trace> required")
      s.env = env; s.model = env.ral;
      repeat (20) @(posedge env.la.mdrv.vif.aclk);
      s.start(null);
      repeat (50) @(posedge env.la.mdrv.vif.aclk);
      phase.drop_objection(this);
    endtask
    function void report_phase(uvm_phase phase);
      uvm_report_server rs = uvm_report_server::get_server();
      if (rs.get_severity_count(UVM_ERROR) + rs.get_severity_count(UVM_FATAL) == 0) $display("*** TEST PASSED ***");
      else $display("*** TEST FAILED ***");
    endfunction
  endclass

  // Ideal memory: one-cycle latency, no backpressure.
  class nanoxl_fast_test extends nanoxl_base_test;
    `uvm_component_utils(nanoxl_fast_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
  endclass

  // Random latency and backpressure on every memory port (seed-dependent).
  class nanoxl_random_test extends nanoxl_base_test;
    `uvm_component_utils(nanoxl_random_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void set_profile();
      env.memory_profile($urandom_range(10, 40), 1, $urandom_range(8, 40));
    endfunction
  endclass

  // DDR-like: long read latency, little backpressure.
  class nanoxl_slow_mem_test extends nanoxl_base_test;
    `uvm_component_utils(nanoxl_slow_mem_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void set_profile();
      env.memory_profile(5, 40, 80);
    endfunction
  endclass

  // Negative check of the checker: the DMA memories flip a bit in some read beats, so the device
  // computes on corrupted weights / activations and the golden compare must notice. GOLDEN errors
  // are demoted to warnings and the test fails if none appeared. (Fetch data stays clean so the
  // command stream itself is never corrupted.)
  class nanoxl_demote_catcher extends uvm_report_catcher;
    int unsigned n;
    function new(string name = "nanoxl_demote_catcher"); super.new(name); endfunction
    function action_e catch();
      if (get_severity() == UVM_ERROR && get_id() inside {"GOLDEN", "TRACE"}) begin
        n++; set_severity(UVM_WARNING);
      end
      return THROW;
    endfunction
  endclass

  class nanoxl_corrupt_test extends nanoxl_base_test;
    `uvm_component_utils(nanoxl_corrupt_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void set_profile();
      env.memory_profile(0, 1, 1);
      env.scfg[1].slave_corrupt_pct = 2; env.scfg[2].slave_corrupt_pct = 2;
    endfunction
    nanoxl_demote_catcher dc;
    function void start_of_simulation_phase(uvm_phase phase);
      dc = new("dc");
      uvm_report_cb::add(null, dc);
    endfunction
    function void check_phase(uvm_phase phase);
      if (dc.n == 0) `uvm_error("CORRUPT", "corrupted DMA data went unnoticed by the golden compare")
      else `uvm_info("CORRUPT", $sformatf("golden compare flagged corrupted data (%0d reports demoted)", dc.n), UVM_LOW)
    endfunction
  endclass
endpackage
