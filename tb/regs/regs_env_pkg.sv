// regs_env_pkg.sv: M3 register environment. Every CSR block of the SoC map is driven through
// its own VIP master and checked by the RAL generated from regs/*.rdl (ADR 0004):
//   AXI4-Lite: cf_sys_ctrl, cf_irq_ctrl, cf_timer, cf_dma_csr, cf_spikemesh_ctl (generated RTL)
//              and NanoXL's real csr_axil (audit of nanoxl_csr.rdl against the IP)
//   APB:       cf_mailbox (generated RTL) and MLACC's real mlacc_top (audit of mlacc_csr.rdl)
package regs_env_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import vip_common_pkg::*;
  import axil_pkg::*;
  import apb_pkg::*;
  import confluence_soc_ral_pkg::*;

  localparam int AW = 32, DW = 32;
  localparam int NL = 6, NP = 2;
  localparam string L_NAMES[NL] = '{"sys_ctrl", "irq_ctrl", "timer", "dma", "spikemesh", "nanoxl"};
  localparam string P_NAMES[NP] = '{"mailbox", "mlacc"};
  localparam bit [11:0] WIN_LAST = 12'hFFC;        // every block decodes a 4 KiB window
  // Unmapped addresses answer SLVERR everywhere except NanoXL (docs/control.md: OKAY, reads 0).
  localparam bit L_HOLE_ERR[NL] = '{1, 1, 1, 1, 1, 0};
  localparam bit P_HOLE_ERR[NP] = '{1, 1};

  typedef axil_agent #(AW, DW) l_agent_t;
  typedef apb_agent  #(AW, DW) p_agent_t;

  class regs_env extends uvm_env;
    `uvm_component_utils(regs_env)
    l_agent_t        la[NL];
    p_agent_t        pa[NP];
    uvm_reg_block    blk[NL + NP];
    string           blk_name[NL + NP];
    axil_reg_adapter ladp;
    apb_reg_adapter  padp;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction

    function uvm_reg_block make_block(string n);
      case (n)
        "sys_ctrl":  begin cf_sys_ctrl      b = new(n); b.build(); return b; end
        "irq_ctrl":  begin cf_irq_ctrl      b = new(n); b.build(); return b; end
        "timer":     begin cf_timer         b = new(n); b.build(); return b; end
        "dma":       begin cf_dma_csr       b = new(n); b.build(); return b; end
        "spikemesh": begin cf_spikemesh_ctl b = new(n); b.build(); return b; end
        "nanoxl":    begin nanoxl_csr       b = new(n); b.build(); return b; end
        "mailbox":   begin cf_mailbox       b = new(n); b.build(); return b; end
        "mlacc":     begin mlacc_csr        b = new(n); b.build(); return b; end
        default: `uvm_fatal("REGS", {"unknown block ", n})
      endcase
      return null;
    endfunction

    function void build_phase(uvm_phase phase);
      ladp = axil_reg_adapter::type_id::create("ladp");
      padp = apb_reg_adapter::type_id::create("padp");
      padp.dbytes = DW / 8; padp.addr_width = AW;
      for (int i = 0; i < NL; i++) begin
        axil_cfg c = axil_cfg::type_id::create($sformatf("lcfg%0d", i));
        c.role = AXIL_MASTER; c.addr_width = AW; c.data_bytes = DW / 8; c.has_cov = 0;
        uvm_config_db#(axil_cfg)::set(this, $sformatf("la%0d", i), "cfg", c);
        la[i] = l_agent_t::type_id::create($sformatf("la%0d", i), this);
        blk_name[i] = L_NAMES[i];
      end
      for (int i = 0; i < NP; i++) begin
        apb_cfg c = apb_cfg::type_id::create($sformatf("pcfg%0d", i));
        c.role = APB_MASTER; c.addr_width = AW; c.data_bytes = DW / 8; c.has_cov = 0;
        uvm_config_db#(apb_cfg)::set(this, $sformatf("pa%0d", i), "cfg", c);
        pa[i] = p_agent_t::type_id::create($sformatf("pa%0d", i), this);
        blk_name[NL + i] = P_NAMES[i];
      end
      foreach (blk[i]) begin
        uvm_reg_field f[$];
        blk[i] = make_block(blk_name[i]);
        blk[i].lock_model();
        blk[i].reset();
        // Hardware inputs are idle in this bench, so a W1C status bit can only change through
        // software: compare it (the generator marks hwset fields volatile, which would hide a
        // W1C implemented as plain RW).
        blk[i].get_fields(f);
        foreach (f[j]) if (f[j].get_access() == "W1C") begin f[j].set_volatility(0); f[j].set_compare(UVM_CHECK); end
      end
    endfunction

    function void connect_phase(uvm_phase phase);
      for (int i = 0; i < NL; i++) begin
        blk[i].default_map.set_sequencer(la[i].sqr, ladp);
        blk[i].default_map.set_auto_predict(1);
      end
      for (int i = 0; i < NP; i++) begin
        blk[NL + i].default_map.set_sequencer(pa[i].sqr, padp);
        blk[NL + i].default_map.set_auto_predict(1);
      end
    endfunction
  endclass

  // Random write / mirror-check traffic on every writable register (W1C, WO and RW fields are
  // predicted by the RAL access policies; volatile fields are not compared).
  class regs_rw_seq extends uvm_reg_sequence;
    `uvm_object_utils(regs_rw_seq)
    int unsigned n = 200;
    function new(string name = "regs_rw_seq"); super.new(name); endfunction
    task body();
      uvm_reg regs[$];
      uvm_status_e st;
      model.get_registers(regs);
      repeat (n) begin
        uvm_reg r = regs[$urandom_range(regs.size() - 1)];
        if ($urandom_range(1)) begin
          r.write(st, {$urandom, $urandom}, .parent(this));
          if (st != UVM_IS_OK) `uvm_error("REGS", {"write failed: ", r.get_full_name()})
        end
        r.mirror(st, UVM_CHECK, .parent(this));
        if (st != UVM_IS_OK) `uvm_error("REGS", {"read failed: ", r.get_full_name()})
      end
    endtask
  endclass

  // Every unmapped word of a block's 4 KiB window: reads return 0, reads and writes answer with
  // the block's documented response, and (checked by the test afterwards) no write to a hole
  // changes a mapped register (catches partial address decode / aliasing).
  class regs_hole_axil_seq extends axil_base_seq;
    `uvm_object_utils(regs_hole_axil_seq)
    uvm_reg_block blk;
    bit expect_err;
    int unsigned n_holes;
    function new(string name = "regs_hole_axil_seq"); super.new(name); endfunction
    task body();
      axil_resp_e exp = expect_err ? AXIL_SLVERR : AXIL_OKAY;
      for (int unsigned a = 0; a <= WIN_LAST; a += 4) begin
        bit [AXIL_MAX_DW-1:0] d;
        axil_resp_e r;
        if (blk.default_map.get_reg_by_offset(a) != null) continue;
        n_holes++;
        read1(a, d, r);
        if (r != exp || d != 0) `uvm_error("HOLE", $sformatf("%s read %03h: data %0h resp %s, expected 0 / %s", blk.get_name(), a, d, r.name(), exp.name()))
        write1(a, {$urandom, $urandom}, r);
        if (r != exp) `uvm_error("HOLE", $sformatf("%s write %03h: resp %s, expected %s", blk.get_name(), a, r.name(), exp.name()))
      end
    endtask
  endclass

  class regs_hole_apb_seq extends apb_base_seq;
    `uvm_object_utils(regs_hole_apb_seq)
    uvm_reg_block blk;
    bit expect_err;
    int unsigned n_holes;
    function new(string name = "regs_hole_apb_seq"); super.new(name); endfunction
    task body();
      for (int unsigned a = 0; a <= WIN_LAST; a += 4) begin
        bit [APB_MAX_DW-1:0] d;
        bit e;
        if (blk.default_map.get_reg_by_offset(a) != null) continue;
        n_holes++;
        read1(a, d, e);
        if (e != expect_err || d != 0) `uvm_error("HOLE", $sformatf("%s read %03h: data %0h slverr %0b, expected 0 / %0b", blk.get_name(), a, d, e, expect_err))
        write1(a, $urandom, e);
        if (e != expect_err) `uvm_error("HOLE", $sformatf("%s write %03h: slverr %0b, expected %0b", blk.get_name(), a, e, expect_err))
      end
    endtask
  endclass

  class regs_base_test extends uvm_test;
    `uvm_component_utils(regs_base_test)
    regs_env env;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void build_phase(uvm_phase phase);
      env = regs_env::type_id::create("env", this);
    endfunction
    virtual function uvm_reg_sequence make_seq(int i);
      return null;
    endfunction
    task run_phase(uvm_phase phase);
      phase.raise_objection(this);
      #200;
      foreach (env.blk[i]) begin
        automatic int k = i;
        fork begin
          uvm_reg_sequence s = make_seq(k);
          s.model = env.blk[k];
          `uvm_info("REGS", $sformatf("%s on %s", s.get_type_name(), env.blk_name[k]), UVM_LOW)
          s.start(null);
        end join_none
      end
      wait fork;
      #100;
      phase.drop_objection(this);
    endtask
    function void report_phase(uvm_phase phase);
      uvm_report_server rs = uvm_report_server::get_server();
      if (rs.get_severity_count(UVM_ERROR) + rs.get_severity_count(UVM_FATAL) == 0) $display("*** TEST PASSED ***");
      else $display("*** TEST FAILED ***");
    endfunction
  endclass

  class regs_hw_reset_test extends regs_base_test;
    `uvm_component_utils(regs_hw_reset_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function uvm_reg_sequence make_seq(int i);
      uvm_reg_hw_reset_seq s = uvm_reg_hw_reset_seq::type_id::create($sformatf("rst%0d", i)); return s;
    endfunction
  endclass

  class regs_bit_bash_test extends regs_base_test;
    `uvm_component_utils(regs_bit_bash_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function uvm_reg_sequence make_seq(int i);
      uvm_reg_bit_bash_seq s = uvm_reg_bit_bash_seq::type_id::create($sformatf("bb%0d", i)); return s;
    endfunction
  endclass

  class regs_rw_test extends regs_base_test;
    `uvm_component_utils(regs_rw_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function uvm_reg_sequence make_seq(int i);
      regs_rw_seq s = regs_rw_seq::type_id::create($sformatf("rw%0d", i)); return s;
    endfunction
  endclass
  class regs_unmapped_test extends regs_base_test;
    `uvm_component_utils(regs_unmapped_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task run_phase(uvm_phase phase);
      phase.raise_objection(this);
      #200;
      for (int i = 0; i < NL; i++) begin
        automatic int k = i;
        fork begin
          regs_hole_axil_seq s = regs_hole_axil_seq::type_id::create($sformatf("hole%0d", k));
          s.blk = env.blk[k]; s.expect_err = L_HOLE_ERR[k];
          s.start(env.la[k].sqr);
          check_unchanged(k, s.n_holes);
        end join_none
      end
      for (int i = 0; i < NP; i++) begin
        automatic int k = i;
        fork begin
          regs_hole_apb_seq s = regs_hole_apb_seq::type_id::create($sformatf("phole%0d", k));
          s.blk = env.blk[NL + k]; s.expect_err = P_HOLE_ERR[k];
          s.start(env.pa[k].sqr);
          check_unchanged(NL + k, s.n_holes);
        end join_none
      end
      wait fork;
      #100;
      phase.drop_objection(this);
    endtask
    // Mapped registers still hold their reset values (the RAL mirror) after the hole writes.
    task check_unchanged(int k, int unsigned n_holes);
      uvm_status_e st;
      `uvm_info("REGS", $sformatf("%s: %0d unmapped words probed", env.blk_name[k], n_holes), UVM_LOW)
      env.blk[k].mirror(st, UVM_CHECK);
    endtask
  endclass
endpackage
