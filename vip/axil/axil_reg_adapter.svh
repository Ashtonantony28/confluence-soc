// axil_reg_adapter.svh: uvm_reg <-> axil_item. The AXI4-Lite master driver returns each access
// with put_response (it pipelines), so provides_responses = 1 and the register map waits for
// the response that carries the read data and BRESP/RRESP.

class axil_reg_adapter extends uvm_reg_adapter;
  `uvm_object_utils(axil_reg_adapter)
  int unsigned dbytes     = 4;
  int unsigned addr_width = 32;

  function new(string name = "axil_reg_adapter");
    super.new(name);
    supports_byte_enable = 1;
    provides_responses   = 1;
  endfunction

  virtual function uvm_sequence_item reg2bus(const ref uvm_reg_bus_op rw);
    axil_item t = axil_item::type_id::create("t");
    t.dbytes = dbytes; t.addr_width = addr_width;
    t.dir  = (rw.kind == UVM_WRITE) ? AXIL_WRITE : AXIL_READ;
    t.addr = AXIL_MAX_AW'(rw.addr);
    t.data = AXIL_MAX_DW'(rw.data);
    t.strb = (rw.kind == UVM_WRITE) ? (AXIL_MAX_DW/8)'(rw.byte_en) & (AXIL_MAX_DW/8)'((16'd1 << dbytes) - 1) : '0;
    t.prot = 3'b000;
    t.addr_delay = 0; t.data_delay = 0;
    return t;
  endfunction

  virtual function void bus2reg(uvm_sequence_item bus_item, ref uvm_reg_bus_op rw);
    axil_item t;
    if (!$cast(t, bus_item)) `uvm_fatal("CAST", "not an axil_item")
    rw.kind    = (t.dir == AXIL_WRITE) ? UVM_WRITE : UVM_READ;
    rw.addr    = t.addr;
    rw.data    = t.data;
    rw.byte_en = t.strb;
    rw.status  = (t.resp == AXIL_OKAY || t.resp == AXIL_EXOKAY) ? UVM_IS_OK : UVM_NOT_OK;
  endfunction
endclass
