// apb_monitor.svh: publishes one item per completed APB4 transfer on ap, annotated with the
// number of wait states and whether the SETUP followed the previous ACCESS directly
// (back-to-back, psel never fell).

class apb_monitor #(int AW = 32, int DW = 32) extends uvm_monitor;
  `uvm_component_param_utils(apb_monitor #(AW, DW))

  typedef virtual apb_if #(.AW(AW), .DW(DW)) vif_t;

  vif_t    vif;
  apb_cfg  cfg;
  uvm_analysis_port #(apb_item) ap;

  int unsigned waits;
  bit          prev_done;      // the previous cycle completed a transfer
  bit          b2b;
  time         t_setup;
  int unsigned n_writes, n_reads;

  function new(string name, uvm_component parent); super.new(name, parent); endfunction

  function void build_phase(uvm_phase phase);
    ap = new("ap", this);
    if (!uvm_config_db#(vif_t)::get(this, "", "vif", vif)) `uvm_fatal("NOVIF", "apb vif not set")
    if (!uvm_config_db#(apb_cfg)::get(this, "", "cfg", cfg)) `uvm_fatal("NOCFG", "apb cfg not set")
  endfunction

  task run_phase(uvm_phase phase);
    forever begin
      @(posedge vif.pclk);
      if (!vif.presetn) begin prev_done = 0; waits = 0; continue; end
      if (vif.psel && !vif.penable) begin
        b2b = prev_done; waits = 0; t_setup = $time;
      end
      prev_done = 0;
      if (vif.psel && vif.penable) begin
        if (!vif.pready) waits++;
        else begin
          apb_item t = apb_item::type_id::create("t");
          t.dbytes = cfg.data_bytes; t.addr_width = cfg.addr_width;
          t.dir = apb_dir_e'(vif.pwrite); t.addr = APB_MAX_AW'(vif.paddr); t.prot = vif.pprot;
          t.strb = (APB_MAX_DW/8)'(vif.pstrb); t.slverr = vif.pslverr;
          t.data = APB_MAX_DW'(vif.pwrite ? vif.pwdata : vif.prdata);
          t.wait_states = waits; t.back_to_back = b2b; t.t_setup = t_setup; t.t_done = $time;
          if (vif.pwrite) n_writes++; else n_reads++;
          ap.write(t);
          prev_done = 1; waits = 0;
        end
      end
    end
  endtask

  function void report_phase(uvm_phase phase);
    `uvm_info("APB_MON", $sformatf("%0d writes, %0d reads observed", n_writes, n_reads), UVM_LOW)
  endfunction
endclass
