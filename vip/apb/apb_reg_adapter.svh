// apb_reg_adapter.svh: uvm_reg <-> apb_item, ported from the MLACC-UVM APB agent. The driver
// fills in read data and pslverr before item_done, so provides_responses stays 0 and a
// uvm_reg_predictor on the monitor's ap keeps the mirror (explicit prediction).

class apb_reg_adapter extends uvm_reg_adapter;
  `uvm_object_utils(apb_reg_adapter)
  int unsigned dbytes     = APB_MAX_DW / 8;
  int unsigned addr_width = APB_MAX_AW;

  function new(string name = "apb_reg_adapter");
    super.new(name);
    supports_byte_enable = 1;
    provides_responses   = 0;
  endfunction

  virtual function uvm_sequence_item reg2bus(const ref uvm_reg_bus_op rw);
    apb_item t = apb_item::type_id::create("t");
    t.dbytes = dbytes; t.addr_width = addr_width;
    t.dir  = (rw.kind == UVM_WRITE) ? APB_WRITE : APB_READ;
    t.addr = APB_MAX_AW'(rw.addr);
    t.data = APB_MAX_DW'(rw.data);
    t.strb = (rw.kind == UVM_WRITE) ? (APB_MAX_DW/8)'(rw.byte_en) & (APB_MAX_DW/8)'((8'd1 << dbytes) - 1) : '0;
    t.prot = 3'b000;
    t.idle = 0;
    return t;
  endfunction

  virtual function void bus2reg(uvm_sequence_item bus_item, ref uvm_reg_bus_op rw);
    apb_item t;
    if (!$cast(t, bus_item)) `uvm_fatal("CAST", "not an apb_item")
    rw.kind    = (t.dir == APB_WRITE) ? UVM_WRITE : UVM_READ;
    rw.addr    = t.addr;
    rw.data    = t.data;
    rw.byte_en = t.strb;
    rw.status  = t.slverr ? UVM_NOT_OK : UVM_IS_OK;
  endfunction
endclass
