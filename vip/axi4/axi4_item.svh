// axi4_item.svh: one AXI4 burst (address phase + all data beats + response).
// Widths are the package maxima (AXI4_MAX_*); an agent's cfg narrows them through the
// non-random knobs dbytes / id_width / addr_width, which the constraints read.

typedef enum bit { AXI4_READ = 1'b0, AXI4_WRITE = 1'b1 } axi4_dir_e;
typedef enum bit [1:0] { AXI4_FIXED = 2'd0, AXI4_INCR = 2'd1, AXI4_WRAP = 2'd2, AXI4_RSVD = 2'd3 } axi4_burst_e;
typedef enum bit [1:0] { AXI4_OKAY = 2'd0, AXI4_EXOKAY = 2'd1, AXI4_SLVERR = 2'd2, AXI4_DECERR = 2'd3 } axi4_resp_e;

class axi4_item extends uvm_sequence_item;
  rand axi4_dir_e                dir;
  rand bit [AXI4_MAX_IDW-1:0]    id;
  rand bit [AXI4_MAX_AW-1:0]     addr;
  rand bit [7:0]                 len;      // beats - 1
  rand bit [2:0]                 size;     // log2(bytes per beat)
  rand axi4_burst_e              burst;
  rand bit [3:0]                 cache;
  rand bit [2:0]                 prot;
  rand bit [3:0]                 qos;
  bit                            lock;     // exclusive access not supported by the fabric (v1)

  // Payload: one entry per beat, full bus width, lanes placed as on the wires.
  bit [AXI4_MAX_DW-1:0]          data[];
  bit [AXI4_MAX_DW/8-1:0]        strb[];
  axi4_resp_e                    resp[];   // read: per beat; write: resp[0] only

  // Timing knobs for the master driver.
  rand int unsigned              addr_delay;
  rand int unsigned              data_delay;

  // Shape knobs (set from the agent cfg before randomize; not random).
  int unsigned dbytes      = AXI4_MAX_DW / 8;
  int unsigned id_width    = AXI4_MAX_IDW;
  int unsigned addr_width  = 32;
  bit          legal_only  = 1;   // 0 lets a violation sequence build illegal bursts

  // Filled in by the monitor (not compared).
  time         t_addr, t_done;
  int unsigned outstanding_at_issue;
  bit          completed_out_of_order;
  bit          interleaved;

  constraint c_id    { id < (64'd1 << id_width); }
  constraint c_addr  { addr_width < 64 -> addr < (64'd1 << addr_width); }
  constraint c_size  { (64'd1 << size) <= dbytes; }
  constraint c_burst { legal_only -> burst != AXI4_RSVD; }
  constraint c_wrap  { legal_only && burst == AXI4_WRAP -> (len inside {1, 3, 7, 15}) &&
                                                         ((addr & ((64'd1 << size) - 1)) == 0); }
  constraint c_fixed { legal_only && burst == AXI4_FIXED -> len <= 15; }
  constraint c_4k    { legal_only && burst == AXI4_INCR ->
                         (((addr & 64'hFFF) & ~((64'd1 << size) - 1)) + ((64'(len) + 1) << size)) <= 64'd4096; }
  constraint c_dist  { burst dist { AXI4_INCR := 70, AXI4_WRAP := 15, AXI4_FIXED := 15 };
                       len dist { 0 := 30, [1:15] := 50, [16:255] := 20 };
                       size dist { [0:7] :/ 1 }; }
  constraint c_dly   { addr_delay dist { 0 := 70, [1:4] := 25, [5:20] := 5 };
                       data_delay dist { 0 := 70, [1:4] := 25, [5:20] := 5 }; }
  constraint c_attr  { cache == 4'b0011; prot == 3'b000; qos == 4'd0; }

  `uvm_object_utils(axi4_item)

  function new(string name = "axi4_item"); super.new(name); endfunction

  function int unsigned beats();
    return int'(len) + 1;
  endfunction

  // --- AXI4 spec A3.4.2 address arithmetic -------------------------------------------
  function bit [63:0] aligned_addr();
    return addr & ~((64'd1 << size) - 1);
  endfunction

  function bit [63:0] wrap_boundary();
    bit [63:0] tot = (64'(len) + 1) << size;
    return (addr / tot) * tot;
  endfunction

  // Address of beat n (the first beat keeps the unaligned start address).
  function bit [63:0] beat_addr(int unsigned n);
    bit [63:0] nbytes = 64'd1 << size;
    bit [63:0] a;
    if (burst == AXI4_FIXED || n == 0) return addr;
    a = aligned_addr() + 64'(n) * nbytes;
    if (burst == AXI4_WRAP) begin
      bit [63:0] tot = (64'(len) + 1) << size;
      bit [63:0] lo  = wrap_boundary();
      a = addr + 64'(n) * nbytes;
      a = a & ~(nbytes - 1);
      if (a >= lo + tot) a = a - tot;
    end
    return a;
  endfunction

  // Byte lanes that carry data on beat n, for a bus of dbytes bytes.
  function void beat_lanes(int unsigned n, output int unsigned lo, output int unsigned hi);
    bit [63:0] a = beat_addr(n);
    bit [63:0] nbytes = 64'd1 << size;
    lo = int'(a % dbytes);
    hi = int'((a & ~(nbytes - 1)) % dbytes + nbytes - 1);
  endfunction

  // Fill data/strb for a write with random data on exactly the legal lanes of every beat.
  function void fill_write_data();
    data = new[beats()];
    strb = new[beats()];
    for (int unsigned n = 0; n < beats(); n++) begin
      int unsigned lo, hi;
      beat_lanes(n, lo, hi);
      for (int unsigned b = 0; b < dbytes; b++) begin
        data[n][8*b +: 8] = 8'($urandom);
        if (b >= lo && b <= hi) strb[n][b] = ($urandom_range(9) != 0);  // mostly full strobes
      end
    end
  endfunction

  function void post_randomize();
    if (dir == AXI4_WRITE) fill_write_data();
  endfunction

  function string convert2string();
    return $sformatf("%s id=%0h addr=%0h len=%0d size=%0d burst=%s resp=%s",
                     dir.name(), id, addr, len, size, burst.name(),
                     resp.size() ? resp[0].name() : "-");
  endfunction

  function void do_copy(uvm_object rhs);
    axi4_item r;
    super.do_copy(rhs);
    $cast(r, rhs);
    dir = r.dir; id = r.id; addr = r.addr; len = r.len; size = r.size; burst = r.burst;
    cache = r.cache; prot = r.prot; qos = r.qos; lock = r.lock;
    data = r.data; strb = r.strb; resp = r.resp;
    addr_delay = r.addr_delay; data_delay = r.data_delay;
    dbytes = r.dbytes; id_width = r.id_width; addr_width = r.addr_width; legal_only = r.legal_only;
    t_addr = r.t_addr; t_done = r.t_done; outstanding_at_issue = r.outstanding_at_issue;
    completed_out_of_order = r.completed_out_of_order; interleaved = r.interleaved;
  endfunction
endclass
