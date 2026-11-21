// credit_monitor.svh: publishes every flit on the wire, annotated with the receiver buffer
// occupancy right after it (from credit accounting) and the cycles since the previous flit.

class credit_monitor #(int DW = 48) extends uvm_monitor;
  `uvm_component_param_utils(credit_monitor #(DW))
  typedef virtual credit_if #(.DW(DW)) vif_t;
  vif_t        vif;
  credit_cfg   cfg;
  uvm_analysis_port #(credit_item) ap;
  int          held;
  int unsigned n_flits, idle;

  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void build_phase(uvm_phase phase);
    ap = new("ap", this);
    if (!uvm_config_db#(vif_t)::get(this, "", "vif", vif)) `uvm_fatal("NOVIF", "credit vif not set")
    if (!uvm_config_db#(credit_cfg)::get(this, "", "cfg", cfg)) `uvm_fatal("NOCFG", "credit cfg not set")
  endfunction

  task run_phase(uvm_phase phase);
    forever begin
      @(posedge vif.clk);
      if (!vif.rst_n) begin held = int'(cfg.depth); idle = 0; continue; end
      held = held - int'(vif.valid) + int'(vif.credit);
      if (vif.valid) begin
        credit_item t = credit_item::type_id::create("flit");
        t.data = CREDIT_MAX_DW'(vif.data);
        t.gap = idle;
        t.occupancy = (held < 0) ? cfg.depth : cfg.depth - held;
        n_flits++; idle = 0;
        ap.write(t);
      end else idle++;
    end
  endtask

  function void report_phase(uvm_phase phase);
    `uvm_info("CREDIT_MON", $sformatf("%0d flits observed", n_flits), UVM_HIGH)
  endfunction
endclass
