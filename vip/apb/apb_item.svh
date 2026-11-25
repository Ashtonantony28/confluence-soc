// apb_item.svh: one APB4 transfer (SETUP + ACCESS with any number of wait states).

typedef enum bit { APB_READ = 1'b0, APB_WRITE = 1'b1 } apb_dir_e;

class apb_item extends uvm_sequence_item;
  rand apb_dir_e              dir;
  rand bit [APB_MAX_AW-1:0]   addr;
  rand bit [APB_MAX_DW-1:0]   data;     // write: driven data; read: returned data
  rand bit [APB_MAX_DW/8-1:0] strb;     // write only (reads drive all zero, APB4 3.1)
  rand bit [2:0]              prot;
  rand bit                    full_strb;
  bit                         slverr;

  // Master driver timing: IDLE cycles before SETUP. 0 after a transfer = back-to-back
  // (psel stays high, ACCESS goes straight to the next SETUP).
  rand int unsigned           idle;

  // Shape knobs (set from the agent cfg before randomize; not random).
  int unsigned dbytes     = APB_MAX_DW / 8;
  int unsigned addr_width = 32;

  // Filled in by the driver / monitor (not compared).
  int unsigned wait_states;
  bit          back_to_back;
  time         t_setup, t_done;

  constraint c_addr  { addr_width < 32 -> addr < (32'd1 << addr_width);
                       (addr & 32'(dbytes - 1)) == 0; }
  constraint c_strb  { strb <= ((8'd1 << dbytes) - 1);
                       dir == APB_READ -> strb == 0;
                       dir == APB_WRITE && full_strb -> strb == ((8'd1 << dbytes) - 1);
                       full_strb dist { 1 := 80, 0 := 20 }; }
  constraint c_idle  { idle dist { 0 := 50, [1:3] := 40, [4:10] := 10 }; }

  `uvm_object_utils(apb_item)

  function new(string name = "apb_item"); super.new(name); endfunction

  function string convert2string();
    return $sformatf("%s addr=%0h data=%0h strb=%0h prot=%0d slverr=%0b waits=%0d",
                     dir.name(), addr, data, strb, prot, slverr, wait_states);
  endfunction

  function void do_copy(uvm_object rhs);
    apb_item r;
    super.do_copy(rhs);
    $cast(r, rhs);
    dir = r.dir; addr = r.addr; data = r.data; strb = r.strb; prot = r.prot; slverr = r.slverr;
    full_strb = r.full_strb; idle = r.idle; dbytes = r.dbytes; addr_width = r.addr_width;
    wait_states = r.wait_states; back_to_back = r.back_to_back; t_setup = r.t_setup; t_done = r.t_done;
  endfunction
endclass
