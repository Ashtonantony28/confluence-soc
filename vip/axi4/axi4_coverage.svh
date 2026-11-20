// axi4_coverage.svh: protocol-level functional coverage of every completed burst.

class axi4_coverage extends uvm_subscriber #(axi4_item);
  `uvm_component_utils(axi4_coverage)

  axi4_cfg  cfg;
  axi4_item t;
  bit       narrow, unaligned, ends_at_4k, any_err;
  int unsigned outst;

  covergroup cg_burst;
    option.per_instance = 1;
    cp_dir:   coverpoint t.dir;
    cp_burst: coverpoint t.burst { bins fixed = {AXI4_FIXED}; bins incr = {AXI4_INCR}; bins wrap = {AXI4_WRAP}; }
    cp_len:   coverpoint t.len { bins single = {0}; bins short_ = {[1:3]}; bins mid = {[4:15]};
                                 bins long_ = {[16:254]}; bins max = {255}; }
    cp_wrap_len: coverpoint t.len iff (t.burst == AXI4_WRAP) { bins w2 = {1}; bins w4 = {3}; bins w8 = {7}; bins w16 = {15}; }
    cp_narrow:    coverpoint narrow;
    cp_unaligned: coverpoint unaligned;
    cp_4k:        coverpoint ends_at_4k { bins hit = {1}; }
    cp_resp:      coverpoint any_err;
    cp_outst:     coverpoint outst { bins none = {0}; bins few = {[1:3]}; bins many = {[4:15]}; bins deep = {[16:$]}; }
    cp_ooo:       coverpoint t.completed_out_of_order;
    x_dir_burst:  cross cp_dir, cp_burst;
    x_dir_len:    cross cp_dir, cp_len;
    x_burst_narrow: cross cp_burst, cp_narrow;
    x_dir_resp:   cross cp_dir, cp_resp;
    x_dir_ooo:    cross cp_dir, cp_ooo;
  endgroup

  covergroup cg_read;
    option.per_instance = 1;
    cp_interleaved: coverpoint t.interleaved;
  endgroup

  function new(string name, uvm_component parent);
    super.new(name, parent);
    cg_burst = new();
    cg_read  = new();
  endfunction

  function void write(axi4_item x);
    t = x;
    narrow    = (64'd1 << t.size) < t.dbytes;
    unaligned = (t.addr & ((64'd1 << t.size) - 1)) != 0;
    ends_at_4k = (t.burst == AXI4_INCR) &&
                 (((t.aligned_addr() & 64'hFFF) + ((64'(t.len) + 1) << t.size)) == 64'd4096);
    any_err = 0;
    foreach (t.resp[i]) if (t.resp[i] != AXI4_OKAY) any_err = 1;
    outst = t.outstanding_at_issue;
    cg_burst.sample();
    if (t.dir == AXI4_READ) cg_read.sample();
  endfunction

  function void report_phase(uvm_phase phase);
    `uvm_info("AXI4_COV", $sformatf("burst coverage %0.1f%%, read coverage %0.1f%%",
              cg_burst.get_inst_coverage(), cg_read.get_inst_coverage()), UVM_LOW)
  endfunction
endclass
