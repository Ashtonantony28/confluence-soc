// axi4_cfg.svh: configuration of one AXI4 agent (master or slave role, active or passive).

typedef enum int { AXI4_MASTER, AXI4_SLAVE } axi4_role_e;

// Deliberate protocol violations a driver can inject so the checker can be proven to fire
// (vip self-test). NONE in every normal run.
typedef enum int {
  AXI4_INJ_NONE,
  // master side
  AXI4_INJ_AW_VALID_DROP,     // awvalid falls before awready
  AXI4_INJ_AW_PAYLOAD_CHANGE, // awaddr changes while awvalid && !awready
  AXI4_INJ_W_VALID_DROP,      // wvalid falls before wready
  AXI4_INJ_WLAST_EARLY,       // wlast on the second-to-last beat
  AXI4_INJ_WLAST_MISSING,     // wlast low on the last beat (raised one beat late)
  AXI4_INJ_AR_VALID_DROP,     // arvalid falls before arready
  AXI4_INJ_BURST_RSVD,        // arburst = 2'b11
  AXI4_INJ_WRAP_BAD_LEN,      // WRAP with len = 2
  AXI4_INJ_CROSS_4K,          // INCR burst crossing a 4 KiB boundary
  AXI4_INJ_SIZE_TOO_BIG,      // awsize wider than the data bus
  AXI4_INJ_WSTRB_OUTSIDE,     // narrow write beat with every strobe set (lanes outside the transfer)
  // slave side
  AXI4_INJ_RLAST_EARLY,       // rlast one beat early
  AXI4_INJ_R_UNKNOWN_ID,      // read data for an ID with nothing outstanding
  AXI4_INJ_B_UNKNOWN_ID,      // write response for an ID with no completed write
  AXI4_INJ_R_VALID_DROP,      // rvalid falls before rready
  AXI4_INJ_B_VALID_DROP       // bvalid falls before bready
} axi4_inject_e;

class axi4_cfg extends uvm_object;
  `uvm_object_utils(axi4_cfg)

  axi4_role_e             role       = AXI4_MASTER;
  uvm_active_passive_enum is_active  = UVM_ACTIVE;
  bit                     has_cov    = 1;

  // shape (must match the interface parameters)
  int unsigned addr_width = 32;
  int unsigned data_bytes = 16;
  int unsigned id_width   = 4;

  // master driver
  int unsigned max_outstanding = 16;   // bursts issued but not completed
  int unsigned bready_busy_pct = 20;   // % of cycles bready/rready held low
  int unsigned ready_max_stall = 4;

  // slave driver
  int unsigned slave_ready_busy_pct = 25;  // % of cycles a*ready / wready held low
  int unsigned slave_min_latency    = 1;   // cycles from request to first response
  int unsigned slave_max_latency    = 12;
  int unsigned slave_max_accept     = 8;   // outstanding requests accepted per direction
  bit          slave_reorder        = 1;   // responses to different IDs may complete out of order
  bit          slave_interleave     = 1;   // read data of different IDs may interleave
  int unsigned slave_beat_gap_pct   = 15;  // % chance of an idle cycle between data beats
  // SLVERR regions [lo, hi] (inclusive). A burst touching one gets SLVERR on all beats.
  bit [63:0]   err_lo[$];
  bit [63:0]   err_hi[$];

  int unsigned slave_corrupt_pct    = 0; // scoreboard sanity tests only: % of read beats with a flipped bit

  vip_common_pkg::vip_mem mem;            // slave backing store (created by the agent if null)

  axi4_inject_e inject = AXI4_INJ_NONE;    // see enum; drivers inject once, on the first chance

  function new(string name = "axi4_cfg"); super.new(name); endfunction

  function bit in_err_region(bit [63:0] a);
    foreach (err_lo[i]) if (a >= err_lo[i] && a <= err_hi[i]) return 1;
    return 0;
  endfunction
endclass
