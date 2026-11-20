// apb_seq_lib.svh: reusable APB4 master sequences. The driver completes an item before
// item_done, so results are read from the item right after finish_item.

class apb_base_seq extends uvm_sequence #(apb_item);
  `uvm_object_utils(apb_base_seq)
  apb_cfg cfg;
  function new(string name = "apb_base_seq"); super.new(name); endfunction

  task pre_start();
    if (cfg == null && !uvm_config_db#(apb_cfg)::get(m_sequencer, "", "cfg", cfg))
      `uvm_fatal("NOCFG", "sequence needs the agent cfg")
  endtask

  function apb_item make();
    apb_item t = apb_item::type_id::create("t");
    t.dbytes = cfg.data_bytes; t.addr_width = cfg.addr_width;
    return t;
  endfunction

  task write1(bit [31:0] addr, bit [APB_MAX_DW-1:0] data, output bit slverr,
              input bit [APB_MAX_DW/8-1:0] strb_req = '1);
    apb_item t = make();
    bit [31:0] a_req = addr & ~32'(cfg.data_bytes - 1);   // no local:: inside with{} (simulator quirk)
    bit [APB_MAX_DW/8-1:0] s_req = strb_req & (APB_MAX_DW/8)'((8'd1 << cfg.data_bytes) - 1);
    start_item(t);
    if (!t.randomize() with { dir == APB_WRITE; addr == a_req; strb == s_req; })
      `uvm_fatal("RAND", "write1")
    t.data = data;
    finish_item(t);
    slverr = t.slverr;
  endtask

  task read1(bit [31:0] addr, output bit [APB_MAX_DW-1:0] data, output bit slverr);
    apb_item t = make();
    bit [31:0] a_req = addr & ~32'(cfg.data_bytes - 1);
    start_item(t);
    if (!t.randomize() with { dir == APB_READ; addr == a_req; })
      `uvm_fatal("RAND", "read1")
    finish_item(t);
    data = t.data; slverr = t.slverr;
  endtask
endclass

// N random legal transfers inside [lo, hi], mixed directions.
class apb_random_seq extends apb_base_seq;
  `uvm_object_utils(apb_random_seq)
  int unsigned n = 200;
  bit [31:0]   lo = 32'h0, hi = 32'hFFF;
  int unsigned write_pct = 50;
  function new(string name = "apb_random_seq"); super.new(name); endfunction
  task body();
    bit [31:0] lo_r = lo, hi_r = hi;
    int unsigned wp = write_pct;
    repeat (n) begin
      apb_item t = make();
      start_item(t);
      if (!t.randomize() with { addr >= lo_r; addr <= hi_r;
                                dir dist { APB_WRITE := wp, APB_READ := 100 - wp }; })
        `uvm_fatal("RAND", "apb_random_seq")
      finish_item(t);
    end
  endtask
endclass
