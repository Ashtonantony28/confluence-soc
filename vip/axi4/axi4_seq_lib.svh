// axi4_seq_lib.svh: reusable AXI4 master sequences.

class axi4_base_seq extends uvm_sequence #(axi4_item);
  `uvm_object_utils(axi4_base_seq)
  axi4_cfg cfg;
  function new(string name = "axi4_base_seq"); super.new(name); endfunction

  task pre_start();
    if (cfg == null && !uvm_config_db#(axi4_cfg)::get(m_sequencer, "", "cfg", cfg))
      `uvm_fatal("NOCFG", "sequence needs the agent cfg")
    set_response_queue_depth(-1);
    use_response_handler(1);
  endtask

  // Responses are drained by the handler; derived sequences may override to inspect them.
  function void response_handler(uvm_sequence_item response);
  endfunction

  function axi4_item make();
    axi4_item t = axi4_item::type_id::create("t");
    t.dbytes = cfg.data_bytes; t.id_width = cfg.id_width; t.addr_width = cfg.addr_width;
    return t;
  endfunction

  // Single full-width beat helpers (blocking: wait for the response).
  task write1(bit [63:0] addr, bit [AXI4_MAX_DW-1:0] data, output axi4_resp_e resp);
    axi4_item t = make();
    axi4_item r;
    bit [63:0] a_req = addr & ~64'(cfg.data_bytes - 1);   // no local:: inside with{} (simulator quirk)
    int unsigned sz = $clog2(cfg.data_bytes);
    use_response_handler(0);
    start_item(t);
    if (!t.randomize() with { dir == AXI4_WRITE; len == 0; burst == AXI4_INCR;
                              size == sz; addr == a_req; })
      `uvm_fatal("RAND", "write1")
    t.data[0] = data; t.strb[0] = '1;
    finish_item(t);
    get_response(r, t.get_transaction_id());
    resp = r.resp[0];
    use_response_handler(1);
  endtask

  task read1(bit [63:0] addr, output bit [AXI4_MAX_DW-1:0] data, output axi4_resp_e resp);
    axi4_item t = make();
    axi4_item r;
    bit [63:0] a_req = addr & ~64'(cfg.data_bytes - 1);
    int unsigned sz = $clog2(cfg.data_bytes);
    use_response_handler(0);
    start_item(t);
    if (!t.randomize() with { dir == AXI4_READ; len == 0; burst == AXI4_INCR;
                              size == sz; addr == a_req; })
      `uvm_fatal("RAND", "read1")
    finish_item(t);
    get_response(r, t.get_transaction_id());
    data = r.data[0]; resp = r.resp[0];
    use_response_handler(1);
  endtask
endclass

// N random legal bursts inside [lo, hi], mixed directions, pipelined (does not wait).
class axi4_random_seq extends axi4_base_seq;
  `uvm_object_utils(axi4_random_seq)
  int unsigned n = 200;
  bit [63:0]   lo = 64'h0, hi = 64'hFFFF;
  int unsigned write_pct = 50;
  int unsigned max_len = 255;
  function new(string name = "axi4_random_seq"); super.new(name); endfunction
  task body();
    repeat (n) begin
      axi4_item t = make();
      start_item(t);
      if (!t.randomize() with { addr >= lo; addr <= hi;
                                (addr + ((64'(len) + 1) << size)) <= hi + 1;
                                len <= max_len;
                                dir dist { AXI4_WRITE := write_pct, AXI4_READ := 100 - write_pct }; })
        `uvm_fatal("RAND", "axi4_random_seq")
      finish_item(t);
    end
  endtask
endclass
