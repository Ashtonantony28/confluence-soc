// axil_seq_lib.svh: reusable AXI4-Lite master sequences.

class axil_base_seq extends uvm_sequence #(axil_item);
  `uvm_object_utils(axil_base_seq)
  axil_cfg cfg;
  function new(string name = "axil_base_seq"); super.new(name); endfunction

  task pre_start();
    if (cfg == null && !uvm_config_db#(axil_cfg)::get(m_sequencer, "", "cfg", cfg))
      `uvm_fatal("NOCFG", "sequence needs the agent cfg")
    set_response_queue_depth(-1);
    use_response_handler(1);
  endtask

  // Responses are drained by the handler; derived sequences may override to inspect them.
  function void response_handler(uvm_sequence_item response);
  endfunction

  function axil_item make();
    axil_item t = axil_item::type_id::create("t");
    t.dbytes = cfg.data_bytes; t.addr_width = cfg.addr_width;
    return t;
  endfunction

  // Single full-width access helpers (blocking: wait for the response).
  task write1(bit [63:0] addr, bit [AXIL_MAX_DW-1:0] data, output axil_resp_e resp,
              input bit [AXIL_MAX_DW/8-1:0] strb_req = '1);
    axil_item t = make();
    axil_item r;
    bit [63:0] a_req = addr & ~64'(cfg.data_bytes - 1);   // no local:: inside with{} (simulator quirk)
    bit [AXIL_MAX_DW/8-1:0] s_req = strb_req & (AXIL_MAX_DW/8)'((16'd1 << cfg.data_bytes) - 1);
    use_response_handler(0);
    start_item(t);
    if (!t.randomize() with { dir == AXIL_WRITE; addr == a_req; strb == s_req; })
      `uvm_fatal("RAND", "write1")
    t.data = data;
    finish_item(t);
    get_response(r, t.get_transaction_id());
    resp = r.resp;
    use_response_handler(1);
  endtask

  task read1(bit [63:0] addr, output bit [AXIL_MAX_DW-1:0] data, output axil_resp_e resp);
    axil_item t = make();
    axil_item r;
    bit [63:0] a_req = addr & ~64'(cfg.data_bytes - 1);
    use_response_handler(0);
    start_item(t);
    if (!t.randomize() with { dir == AXIL_READ; addr == a_req; })
      `uvm_fatal("RAND", "read1")
    finish_item(t);
    get_response(r, t.get_transaction_id());
    data = r.data; resp = r.resp;
    use_response_handler(1);
  endtask
endclass

// N random legal accesses inside [lo, hi], mixed directions, pipelined (does not wait).
class axil_random_seq extends axil_base_seq;
  `uvm_object_utils(axil_random_seq)
  int unsigned n = 200;
  bit [63:0]   lo = 64'h0, hi = 64'hFFFF;
  int unsigned write_pct = 50;
  function new(string name = "axil_random_seq"); super.new(name); endfunction
  task body();
    bit [63:0] lo_r = lo, hi_r = hi;
    int unsigned wp = write_pct;
    repeat (n) begin
      axil_item t = make();
      start_item(t);
      if (!t.randomize() with { addr >= lo_r; addr <= hi_r;
                                dir dist { AXIL_WRITE := wp, AXIL_READ := 100 - wp }; })
        `uvm_fatal("RAND", "axil_random_seq")
      finish_item(t);
    end
  endtask
endclass
