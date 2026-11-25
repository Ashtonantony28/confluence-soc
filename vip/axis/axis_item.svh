// axis_item.svh: one AXI4-Stream packet (all transfers of one TID/TDEST up to TLAST).
// Beats are stored as on the wires (full bus width, TKEEP per lane, TUSER per transfer).
// The random knobs pick the packet length and timing; post_randomize builds the beats for
// the bus width and TKEEP mode set through the non-random shape knobs.

typedef enum int { AXIS_KEEP_PACKED, AXIS_KEEP_SPARSE } axis_keep_mode_e;

class axis_item extends uvm_sequence_item;
  rand int unsigned               len;        // data (TKEEP-high) bytes in the packet
  rand bit [1:0]                  len_class;
  rand bit [AXIS_MAX_IDW-1:0]     tid;
  rand bit [AXIS_MAX_DESTW-1:0]   tdest;
  rand int unsigned               gap_before; // idle cycles before the first transfer

  bit [AXIS_MAX_DW-1:0]           data[];
  bit [AXIS_MAX_DW/8-1:0]         keep[];
  bit [AXIS_MAX_UW-1:0]           user[];

  // Shape knobs (set from the agent cfg before randomize; not random).
  int unsigned     dbytes     = 4;
  int unsigned     id_width   = 0;
  int unsigned     dest_width = 0;
  int unsigned     user_width = 0;
  int unsigned     max_len    = 256;
  axis_keep_mode_e keep_mode  = AXIS_KEEP_PACKED;

  // Filled in by the monitor (not compared).
  time         t_start, t_end;
  int unsigned stall_cycles;    // tvalid && !tready inside the packet
  int unsigned gap_cycles;      // !tvalid between the first and the last transfer
  bit          interleaved;     // transfers of another stream arrived inside this packet

  constraint c_len  { len >= 1; len <= max_len;
                      len_class dist { 0 := 25, 1 := 35, 2 := 30, 3 := 10 };
                      len_class == 0 -> len <= dbytes;
                      len_class == 1 -> len > dbytes && len <= 4 * dbytes;
                      len_class == 2 -> len > 4 * dbytes && len <= 16 * dbytes;
                      len_class == 3 -> len > 16 * dbytes;
                      // keep the classes satisfiable for a small max_len
                      max_len <= dbytes      -> len_class == 0;
                      max_len <= 4 * dbytes  -> len_class <= 1;
                      max_len <= 16 * dbytes -> len_class <= 2; }
  constraint c_side { tid < (16'd1 << id_width); tdest < (16'd1 << dest_width); }
  constraint c_gap  { gap_before dist { 0 := 60, [1:3] := 30, [4:12] := 10 }; }

  `uvm_object_utils(axis_item)

  function new(string name = "axis_item"); super.new(name); endfunction

  function int unsigned beats();
    return data.size();
  endfunction

  function bit [AXIS_MAX_UW-1:0] user_mask();
    return (user_width >= AXIS_MAX_UW) ? '1 : AXIS_MAX_UW'((64'd1 << user_width) - 1);
  endfunction

  function void push_beat(bit [AXIS_MAX_DW/8-1:0] k);
    int unsigned n = data.size();
    data = new[n + 1](data);
    keep = new[n + 1](keep);
    user = new[n + 1](user);
    for (int unsigned b = 0; b < dbytes; b++) data[n][8*b +: 8] = 8'($urandom);
    keep[n] = k;
    user[n] = AXIS_MAX_UW'($urandom) & user_mask();
  endfunction

  // Build the transfers for len data bytes. PACKED: every lane kept except the trailing
  // lanes of the last transfer. SPARSE: null bytes anywhere, including whole null
  // transfers in the middle; the last transfer always carries at least one data byte.
  function void build_beats();
    int unsigned left = len;
    data.delete(); keep.delete(); user.delete();
    while (left > 0) begin
      bit [AXIS_MAX_DW/8-1:0] k = '0;
      if (keep_mode == AXIS_KEEP_SPARSE && data.size() > 0 && $urandom_range(19) == 0) begin
        push_beat('0);                       // a null transfer
        continue;
      end
      for (int unsigned b = 0; b < dbytes && left > 0; b++) begin
        if (keep_mode == AXIS_KEEP_PACKED || $urandom_range(3) != 0) begin k[b] = 1; left--; end
      end
      if (k != 0 || keep_mode == AXIS_KEEP_SPARSE) push_beat(k);
    end
  endfunction

  function void post_randomize();
    build_beats();
  endfunction

  // The data bytes of the packet in stream order (null bytes removed).
  function void payload(ref bit [7:0] q[$]);
    q.delete();
    foreach (data[n]) for (int unsigned b = 0; b < dbytes; b++) if (keep[n][b]) q.push_back(data[n][8*b +: 8]);
  endfunction

  // "" when o carries the same packet (data on kept lanes, TKEEP, TUSER, TID, TDEST).
  function string diff(axis_item o);
    if (o.tid != tid || o.tdest != tdest)
      return $sformatf("tid/tdest %0h/%0h, expected %0h/%0h", o.tid, o.tdest, tid, tdest);
    if (o.beats() != beats()) return $sformatf("%0d transfers, expected %0d", o.beats(), beats());
    foreach (data[n]) begin
      if (o.keep[n] != keep[n]) return $sformatf("transfer %0d tkeep %0h, expected %0h", n, o.keep[n], keep[n]);
      if ((o.user[n] & user_mask()) != (user[n] & user_mask()))
        return $sformatf("transfer %0d tuser %0h, expected %0h", n, o.user[n], user[n]);
      for (int unsigned b = 0; b < dbytes; b++)
        if (keep[n][b] && o.data[n][8*b +: 8] != data[n][8*b +: 8])
          return $sformatf("transfer %0d byte %0d = %0h, expected %0h", n, b, o.data[n][8*b +: 8], data[n][8*b +: 8]);
    end
    return "";
  endfunction

  function string convert2string();
    return $sformatf("packet tid=%0h tdest=%0h len=%0d bytes in %0d transfers", tid, tdest, len, beats());
  endfunction

  function void do_copy(uvm_object rhs);
    axis_item r;
    super.do_copy(rhs);
    $cast(r, rhs);
    len = r.len; len_class = r.len_class; tid = r.tid; tdest = r.tdest; gap_before = r.gap_before;
    data = r.data; keep = r.keep; user = r.user;
    dbytes = r.dbytes; id_width = r.id_width; dest_width = r.dest_width; user_width = r.user_width;
    max_len = r.max_len; keep_mode = r.keep_mode;
    t_start = r.t_start; t_end = r.t_end; stall_cycles = r.stall_cycles; gap_cycles = r.gap_cycles;
    interleaved = r.interleaved;
  endfunction
endclass
