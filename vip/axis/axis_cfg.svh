// axis_cfg.svh: configuration of one AXI4-Stream agent (master or slave role, active or passive).

typedef enum int { AXIS_MASTER, AXIS_SLAVE } axis_role_e;

// Deliberate protocol violations the master driver can inject so the checker can be proven
// to fire (vip self-test). NONE in every normal run.
typedef enum int {
  AXIS_INJ_NONE,
  AXIS_INJ_VALID_DROP,      // tvalid falls before tready
  AXIS_INJ_DATA_CHANGE,     // tdata changes while tvalid && !tready
  AXIS_INJ_LAST_CHANGE,     // tlast changes while tvalid && !tready
  AXIS_INJ_ID_CHANGE,       // tid changes while tvalid && !tready
  AXIS_INJ_VALID_IN_RESET,  // tvalid pulsed while aresetn is low
  AXIS_INJ_KEEP_HOLE,       // packed stream: a null byte below a data byte
  AXIS_INJ_KEEP_SHORT_MID   // packed stream: a partial transfer that is not the last
} axis_inject_e;

class axis_cfg extends uvm_object;
  `uvm_object_utils(axis_cfg)

  axis_role_e             role      = AXIS_MASTER;
  uvm_active_passive_enum is_active = UVM_ACTIVE;
  bit                     has_cov   = 1;

  // shape (must match the interface parameters; 0 = signal not present)
  int unsigned data_bytes = 4;
  int unsigned id_width   = 0;
  int unsigned dest_width = 0;
  int unsigned user_width = 0;

  // master driver
  axis_keep_mode_e keep_mode     = AXIS_KEEP_PACKED;
  int unsigned     max_pkt_bytes = 256;
  int unsigned     beat_gap_pct  = 15;   // % chance of an idle cycle before a transfer inside a packet
  int unsigned     beat_gap_max  = 3;

  // slave driver
  int unsigned slave_ready_busy_pct = 30;  // % of cycles tready held low
  int unsigned slave_corrupt_pct    = 0;   // scoreboard sanity tests only: % of received packets with a flipped bit

  axis_inject_e inject = AXIS_INJ_NONE;    // see enum; the driver injects once, on the first chance

  function new(string name = "axis_cfg"); super.new(name); endfunction
endclass
