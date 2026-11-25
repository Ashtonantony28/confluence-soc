// axis_seq_lib.svh: reusable AXI4-Stream master sequences.

class axis_base_seq extends uvm_sequence #(axis_item);
  `uvm_object_utils(axis_base_seq)
  axis_cfg cfg;
  function new(string name = "axis_base_seq"); super.new(name); endfunction

  task pre_start();
    if (cfg == null && !uvm_config_db#(axis_cfg)::get(m_sequencer, "", "cfg", cfg))
      `uvm_fatal("NOCFG", "sequence needs the agent cfg")
  endtask

  function axis_item make();
    axis_item t = axis_item::type_id::create("t");
    t.dbytes = cfg.data_bytes; t.id_width = cfg.id_width; t.dest_width = cfg.dest_width;
    t.user_width = cfg.user_width; t.max_len = cfg.max_pkt_bytes; t.keep_mode = cfg.keep_mode;
    return t;
  endfunction

  // One packet of exactly n data bytes (blocking until its TLAST is accepted).
  task send_len(int unsigned n, int unsigned gap = 0);
    axis_item t = make();
    int unsigned n_req = n, g_req = gap;   // no local:: inside with{} (simulator quirk)
    t.max_len = (n > t.max_len) ? n : t.max_len;
    start_item(t);
    if (!t.randomize() with { len == n_req; gap_before == g_req; }) `uvm_fatal("RAND", "send_len")
    finish_item(t);
  endtask
endclass

// N random packets.
class axis_random_seq extends axis_base_seq;
  `uvm_object_utils(axis_random_seq)
  int unsigned n = 200;
  function new(string name = "axis_random_seq"); super.new(name); endfunction
  task body();
    repeat (n) begin
      axis_item t = make();
      start_item(t);
      if (!t.randomize()) `uvm_fatal("RAND", "axis_random_seq")
      finish_item(t);
    end
  endtask
endclass
