// axis_packer.svh: rebuilds packets from accepted transfers, one packet in progress per
// TID/TDEST stream (AXI4-Stream allows transfers of different streams to interleave).
// Shared by the monitor and the slave driver.

class axis_packer extends uvm_object;
  `uvm_object_utils(axis_packer)
  axis_cfg  cfg;
  axis_item cur[int];        // packet in progress per stream key {tid, tdest}
  int       last_key = -1;   // stream of the previous transfer

  function new(string name = "axis_packer"); super.new(name); endfunction

  function void clear();
    cur.delete(); last_key = -1;
  endfunction

  // Adds one accepted transfer; returns the finished packet on TLAST, else null.
  function axis_item push(bit [AXIS_MAX_IDW-1:0] tid, bit [AXIS_MAX_DESTW-1:0] tdest,
                          bit [AXIS_MAX_DW-1:0] d, bit [AXIS_MAX_DW/8-1:0] k,
                          bit [AXIS_MAX_UW-1:0] u, bit last);
    int key = {tid, tdest};
    axis_item t;
    int unsigned n;
    if (!cur.exists(key)) begin
      t = axis_item::type_id::create("pkt");
      t.dbytes = cfg.data_bytes; t.id_width = cfg.id_width; t.dest_width = cfg.dest_width;
      t.user_width = cfg.user_width; t.keep_mode = cfg.keep_mode;
      t.tid = tid; t.tdest = tdest; t.len = 0; t.t_start = $time;
      cur[key] = t;
    end
    t = cur[key];
    if (last_key >= 0 && last_key != key && cur.exists(last_key)) begin
      t.interleaved = 1; cur[last_key].interleaved = 1;
    end
    last_key = key;
    n = t.data.size();
    t.data = new[n + 1](t.data);
    t.keep = new[n + 1](t.keep);
    t.user = new[n + 1](t.user);
    t.data[n] = d; t.keep[n] = k; t.user[n] = u & t.user_mask();
    for (int unsigned b = 0; b < cfg.data_bytes; b++) if (k[b]) t.len++;
    if (!last) return null;
    t.t_end = $time;
    cur.delete(key);
    last_key = -1;
    return t;
  endfunction

  function int unsigned open_packets();
    return cur.num();
  endfunction
endclass
