// apb_cfg.svh: configuration of one APB4 agent (master or slave role, active or passive).

typedef enum int { APB_MASTER, APB_SLAVE } apb_role_e;

// Deliberate protocol violations the master driver can inject so the checker can be proven
// to fire (vip self-test). NONE in every normal run.
typedef enum int {
  APB_INJ_NONE,
  APB_INJ_ENABLE_NO_SETUP,   // psel and penable rise together (no SETUP cycle)
  APB_INJ_SETUP_NO_ACCESS,   // SETUP lasts two cycles
  APB_INJ_ADDR_CHANGE_WAIT,  // paddr changes during a wait state
  APB_INJ_SEL_DROP_WAIT,     // psel falls during a wait state
  APB_INJ_SETUP_CHANGE,      // paddr changes between SETUP and ACCESS
  APB_INJ_ENABLE_STUCK,      // penable stays high the cycle after the transfer completes
  APB_INJ_ENABLE_NO_SEL,     // penable high while psel is low
  APB_INJ_READ_STRB,         // pstrb non-zero on a read
  APB_INJ_SEL_IN_RESET       // psel pulsed while presetn is low
} apb_inject_e;

class apb_cfg extends uvm_object;
  `uvm_object_utils(apb_cfg)

  apb_role_e              role      = APB_MASTER;
  uvm_active_passive_enum is_active = UVM_ACTIVE;
  bit                     has_cov   = 1;

  // shape (must match the interface parameters)
  int unsigned addr_width = 32;
  int unsigned data_bytes = 4;

  // slave driver: wait states are 0 with probability (100 - slave_wait_pct)%, else 1..max
  int unsigned slave_wait_pct = 40;
  int unsigned slave_max_wait = 6;
  // PSLVERR regions [lo, hi] (inclusive). A write there is dropped; a read returns zero.
  bit [63:0]   err_lo[$];
  bit [63:0]   err_hi[$];

  int unsigned slave_corrupt_pct = 0;  // scoreboard sanity tests only: % of reads with a flipped bit

  vip_common_pkg::vip_mem mem;         // slave backing store (created by the slave if null)

  apb_inject_e inject = APB_INJ_NONE;  // see enum; the driver injects once, on the first chance

  function new(string name = "apb_cfg"); super.new(name); endfunction

  function bit in_err_region(bit [63:0] a);
    foreach (err_lo[i]) if (a >= err_lo[i] && a <= err_hi[i]) return 1;
    return 0;
  endfunction
endclass
