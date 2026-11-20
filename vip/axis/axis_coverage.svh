// axis_coverage.svh: protocol-level functional coverage of every completed AXI4-Stream packet.

class axis_coverage extends uvm_subscriber #(axis_item);
  `uvm_component_utils(axis_coverage)

  axis_cfg     cfg;
  axis_item    t;
  int unsigned nbeats;
  bit          last_partial, has_null_byte, has_null_xfer, user_nonzero;

  covergroup cg_pkt;
    option.per_instance = 1;
    cp_beats:   coverpoint nbeats { bins one = {1}; bins two_four = {[2:4]}; bins five_16 = {[5:16]}; bins long_ = {[17:$]}; }
    cp_len_mod: coverpoint (t.len % t.dbytes == 0) { bins whole = {1}; bins partial = {0}; }
    cp_last:    coverpoint last_partial;
    cp_null:    coverpoint has_null_byte;
    cp_stall:   coverpoint t.stall_cycles { bins none = {0}; bins some = {[1:7]}; bins many = {[8:$]}; }
    cp_gap:     coverpoint t.gap_cycles { bins none = {0}; bins some = {[1:$]}; }
    cp_user:    coverpoint user_nonzero;
    x_beats_stall: cross cp_beats, cp_stall;
  endgroup

  covergroup cg_side;
    option.per_instance = 1;
    cp_tid:   coverpoint t.tid   { bins lo = {[0:1]}; bins hi = {[2:$]}; }
    cp_tdest: coverpoint t.tdest { bins lo = {0}; bins hi = {[1:$]}; }
  endgroup

  function new(string name, uvm_component parent);
    super.new(name, parent);
    cg_pkt  = new();
    cg_side = new();
  endfunction

  function void write(axis_item x);
    t = x;
    nbeats = t.beats();
    last_partial = (nbeats > 0) && (t.keep[nbeats - 1] != (AXIS_MAX_DW/8)'((65'd1 << t.dbytes) - 1));
    has_null_byte = 0; has_null_xfer = 0; user_nonzero = 0;
    foreach (t.keep[n]) begin
      if (n + 1 < nbeats && t.keep[n] != (AXIS_MAX_DW/8)'((65'd1 << t.dbytes) - 1)) has_null_byte = 1;
      if (t.keep[n] == 0) has_null_xfer = 1;
      if (t.user[n] != 0) user_nonzero = 1;
    end
    cg_pkt.sample();
    if (t.id_width > 0 || t.dest_width > 0) cg_side.sample();
  endfunction

  function void report_phase(uvm_phase phase);
    if (cfg != null && cfg.id_width == 0 && cfg.dest_width == 0)
      `uvm_info("AXIS_COV", $sformatf("packet coverage %0.1f%% (no TID/TDEST)", cg_pkt.get_inst_coverage()), UVM_LOW)
    else
      `uvm_info("AXIS_COV", $sformatf("packet coverage %0.1f%%, tid/tdest coverage %0.1f%%",
                cg_pkt.get_inst_coverage(), cg_side.get_inst_coverage()), UVM_LOW)
  endfunction
endclass
