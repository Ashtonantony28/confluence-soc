// axil_coverage.svh: protocol-level functional coverage of every completed AXI4-Lite access.

class axil_coverage extends uvm_subscriber #(axil_item);
  `uvm_component_utils(axil_coverage)

  axil_cfg  cfg;
  axil_item t;
  int unsigned strb_kind;   // 0 none, 1 partial, 2 full
  bit       err;

  covergroup cg_access;
    option.per_instance = 1;
    cp_dir:   coverpoint t.dir;
    cp_resp:  coverpoint t.resp { bins okay = {AXIL_OKAY}; bins slverr = {AXIL_SLVERR}; }
    cp_prot:  coverpoint t.prot;
    cp_outst: coverpoint t.outstanding_at_issue { bins none = {0}; bins one = {1}; bins few = {[2:3]}; bins many = {[4:$]}; }
    cp_lat:   coverpoint t.latency { bins fast = {[0:2]}; bins mid = {[3:8]}; bins slow = {[9:$]}; }
    x_dir_resp:  cross cp_dir, cp_resp;
    x_dir_outst: cross cp_dir, cp_outst;
  endgroup

  covergroup cg_write;
    option.per_instance = 1;
    cp_strb:  coverpoint strb_kind { bins none = {0}; bins partial = {1}; bins full = {2}; }
    cp_w_first: coverpoint t.w_before_aw;
  endgroup

  function new(string name, uvm_component parent);
    super.new(name, parent);
    cg_access = new();
    cg_write  = new();
  endfunction

  function void write(axil_item x);
    bit [AXIL_MAX_DW/8-1:0] full;
    t = x;
    full = (AXIL_MAX_DW/8)'((16'd1 << t.dbytes) - 1);
    strb_kind = (t.strb == 0) ? 0 : ((t.strb & full) == full) ? 2 : 1;
    cg_access.sample();
    if (t.dir == AXIL_WRITE) cg_write.sample();
  endfunction

  function void report_phase(uvm_phase phase);
    `uvm_info("AXIL_COV", $sformatf("access coverage %0.1f%%, write coverage %0.1f%%",
              cg_access.get_inst_coverage(), cg_write.get_inst_coverage()), UVM_LOW)
  endfunction
endclass
