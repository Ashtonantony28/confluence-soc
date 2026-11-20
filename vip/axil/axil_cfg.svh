// axil_cfg.svh: configuration of one AXI4-Lite agent (master or slave role, active or passive).

typedef enum int { AXIL_MASTER, AXIL_SLAVE } axil_role_e;

// Deliberate protocol violations a driver can inject so the checker can be proven to fire
// (vip self-test). NONE in every normal run. Slave-side kinds start at AXIL_INJ_B_VALID_DROP.
typedef enum int {
  AXIL_INJ_NONE,
  // master side
  AXIL_INJ_AW_VALID_DROP,      // awvalid falls before awready
  AXIL_INJ_AW_PAYLOAD_CHANGE,  // awaddr changes while awvalid && !awready
  AXIL_INJ_W_VALID_DROP,       // wvalid falls before wready
  AXIL_INJ_W_PAYLOAD_CHANGE,   // wdata changes while wvalid && !wready
  AXIL_INJ_AR_VALID_DROP,      // arvalid falls before arready
  AXIL_INJ_AR_PAYLOAD_CHANGE,  // araddr changes while arvalid && !arready
  AXIL_INJ_VALID_IN_RESET,     // arvalid pulsed while aresetn is low
  // slave side
  AXIL_INJ_B_VALID_DROP,       // bvalid falls before bready
  AXIL_INJ_B_PAYLOAD_CHANGE,   // bresp changes while bvalid && !bready
  AXIL_INJ_R_VALID_DROP,       // rvalid falls before rready
  AXIL_INJ_R_PAYLOAD_CHANGE,   // rdata changes while rvalid && !rready
  AXIL_INJ_B_UNSOLICITED,      // a write response with no write outstanding
  AXIL_INJ_R_UNSOLICITED,      // read data with no read outstanding
  AXIL_INJ_EXOKAY              // EXOKAY response (AXI4-Lite has no exclusive access)
} axil_inject_e;

class axil_cfg extends uvm_object;
  `uvm_object_utils(axil_cfg)

  axil_role_e             role       = AXIL_MASTER;
  uvm_active_passive_enum is_active  = UVM_ACTIVE;
  bit                     has_cov    = 1;

  // shape (must match the interface parameters)
  int unsigned addr_width = 32;
  int unsigned data_bytes = 4;

  // master driver
  int unsigned max_outstanding = 8;    // accesses issued but not completed
  int unsigned bready_busy_pct = 20;   // % of cycles bready/rready held low

  // slave driver
  int unsigned slave_ready_busy_pct = 25;  // % of cycles a*ready / wready held low
  int unsigned slave_min_latency    = 0;   // cycles from accept to response valid
  int unsigned slave_max_latency    = 8;
  int unsigned slave_max_accept     = 4;   // accepted but unanswered requests per direction
  // SLVERR regions [lo, hi] (inclusive). A write there is dropped; a read returns zero.
  bit [63:0]   err_lo[$];
  bit [63:0]   err_hi[$];

  int unsigned slave_corrupt_pct = 0;  // scoreboard sanity tests only: % of reads with a flipped bit

  vip_common_pkg::vip_mem mem;         // slave backing store (created by the slave if null)

  axil_inject_e inject = AXIL_INJ_NONE; // see enum; drivers inject once, on the first chance

  function new(string name = "axil_cfg"); super.new(name); endfunction

  function bit in_err_region(bit [63:0] a);
    foreach (err_lo[i]) if (a >= err_lo[i] && a <= err_hi[i]) return 1;
    return 0;
  endfunction
endclass
