// credit_coverage.svh: receiver buffer occupancy at each flit (empty .. full) and spacing.

class credit_coverage extends uvm_subscriber #(credit_item);
  `uvm_component_utils(credit_coverage)
  credit_cfg   cfg;
  int unsigned occ, gap;
  int unsigned occ_class;   // 0: only flit buffered, 1: partly full, 2: buffer now full
  covergroup cg;
    cp_occ: coverpoint occ_class { bins one = {0}; bins partial = {1}; bins full = {2}; }
    cp_gap: coverpoint gap { bins back_to_back = {0}; bins short_ = {[1:3]}; bins long_ = {[4:$]}; }
    x_occ_gap: cross cp_occ, cp_gap;
  endgroup
  function new(string name, uvm_component parent); super.new(name, parent); cg = new(); endfunction
  function void build_phase(uvm_phase phase);
    if (cfg == null && !uvm_config_db#(credit_cfg)::get(this, "", "cfg", cfg)) `uvm_fatal("NOCFG", "credit cfg not set")
  endfunction
  function void write(credit_item t);
    occ = t.occupancy; gap = t.gap;
    occ_class = (occ >= cfg.depth) ? 2 : (occ <= 1) ? 0 : 1;
    cg.sample();
  endfunction
endclass
