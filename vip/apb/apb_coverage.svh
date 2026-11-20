// apb_coverage.svh: protocol-level functional coverage of every completed APB4 transfer.

class apb_coverage extends uvm_subscriber #(apb_item);
  `uvm_component_utils(apb_coverage)

  apb_cfg      cfg;
  apb_item     t;
  int unsigned strb_kind;   // 0 none, 1 partial, 2 full

  covergroup cg_xfer;
    option.per_instance = 1;
    cp_dir:    coverpoint t.dir;
    cp_err:    coverpoint t.slverr;
    cp_waits:  coverpoint t.wait_states { bins zero = {0}; bins one = {1}; bins few = {[2:4]}; bins many = {[5:$]}; }
    cp_b2b:    coverpoint t.back_to_back;
    cp_prot:   coverpoint t.prot;
    x_dir_err:   cross cp_dir, cp_err;
    x_dir_waits: cross cp_dir, cp_waits;
    x_dir_b2b:   cross cp_dir, cp_b2b;
  endgroup

  covergroup cg_write;
    option.per_instance = 1;
    cp_strb: coverpoint strb_kind { bins none = {0}; bins partial = {1}; bins full = {2}; }
  endgroup

  function new(string name, uvm_component parent);
    super.new(name, parent);
    cg_xfer  = new();
    cg_write = new();
  endfunction

  function void write(apb_item x);
    bit [APB_MAX_DW/8-1:0] full;
    t = x;
    full = (APB_MAX_DW/8)'((8'd1 << t.dbytes) - 1);
    strb_kind = (t.strb == 0) ? 0 : ((t.strb & full) == full) ? 2 : 1;
    cg_xfer.sample();
    if (t.dir == APB_WRITE) cg_write.sample();
  endfunction

  function void report_phase(uvm_phase phase);
    `uvm_info("APB_COV", $sformatf("transfer coverage %0.1f%%, write coverage %0.1f%%",
              cg_xfer.get_inst_coverage(), cg_write.get_inst_coverage()), UVM_LOW)
  endfunction
endclass
