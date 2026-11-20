// axil_item.svh: one AXI4-Lite access (single beat: address, data, response).
// Widths are the package maxima (AXIL_MAX_*); an agent's cfg narrows them through the
// non-random knobs dbytes / addr_width, which the constraints read.

typedef enum bit { AXIL_READ = 1'b0, AXIL_WRITE = 1'b1 } axil_dir_e;
typedef enum bit [1:0] { AXIL_OKAY = 2'd0, AXIL_EXOKAY = 2'd1, AXIL_SLVERR = 2'd2, AXIL_DECERR = 2'd3 } axil_resp_e;

class axil_item extends uvm_sequence_item;
  rand axil_dir_e              dir;
  rand bit [AXIL_MAX_AW-1:0]   addr;
  rand bit [2:0]               prot;
  rand bit [AXIL_MAX_DW-1:0]   data;     // write: driven data; read: returned data
  rand bit [AXIL_MAX_DW/8-1:0] strb;     // write only
  rand bit                     full_strb;
  axil_resp_e                  resp;

  // Timing knobs for the master driver (AW/AR and W wait independently, so W may lead AW).
  rand int unsigned            addr_delay;
  rand int unsigned            data_delay;

  // Shape knobs (set from the agent cfg before randomize; not random).
  int unsigned dbytes     = AXIL_MAX_DW / 8;
  int unsigned addr_width = 32;
  bit          aligned    = 1;   // address aligned to the bus width (the usual case)

  // Filled in by the monitor (not compared).
  time         t_addr, t_done;
  int unsigned outstanding_at_issue;
  int unsigned latency;          // cycles from address handshake to response handshake
  bit          w_before_aw;      // write data handshake happened before the address
  longint unsigned cyc_addr;       // monitor cycle count at the address handshake

  constraint c_addr  { addr_width < 64 -> addr < (64'd1 << addr_width);
                       aligned -> (addr & 64'(dbytes - 1)) == 0; }
  constraint c_strb  { strb <= ((16'd1 << dbytes) - 1);
                       full_strb -> strb == ((16'd1 << dbytes) - 1);
                       full_strb dist { 1 := 80, 0 := 20 }; }
  constraint c_dly   { addr_delay dist { 0 := 70, [1:4] := 25, [5:20] := 5 };
                       data_delay dist { 0 := 70, [1:4] := 25, [5:20] := 5 }; }

  `uvm_object_utils(axil_item)

  function new(string name = "axil_item"); super.new(name); endfunction

  function bit [63:0] word_addr();
    return addr & ~64'(dbytes - 1);
  endfunction

  function string convert2string();
    return $sformatf("%s addr=%0h prot=%0d data=%0h strb=%0h resp=%s", dir.name(), addr, prot,
                     data, strb, resp.name());
  endfunction

  function void do_copy(uvm_object rhs);
    axil_item r;
    super.do_copy(rhs);
    $cast(r, rhs);
    dir = r.dir; addr = r.addr; prot = r.prot; data = r.data; strb = r.strb; resp = r.resp;
    full_strb = r.full_strb; addr_delay = r.addr_delay; data_delay = r.data_delay;
    dbytes = r.dbytes; addr_width = r.addr_width; aligned = r.aligned;
    t_addr = r.t_addr; t_done = r.t_done; outstanding_at_issue = r.outstanding_at_issue;
    latency = r.latency; w_before_aw = r.w_before_aw; cyc_addr = r.cyc_addr;
  endfunction
endclass
