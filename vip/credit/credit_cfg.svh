// credit_cfg.svh: configuration of one credit-link agent (sender or receiver, active or passive).

typedef enum int { CREDIT_TX, CREDIT_RX } credit_role_e;

// Deliberate protocol violations for the VIP self-test; NONE in every normal run.
typedef enum int {
  CREDIT_INJ_NONE,
  CREDIT_INJ_NO_CREDIT,       // TX sends one flit while holding no credit (R01)
  CREDIT_INJ_EXTRA_CREDIT,    // RX returns a credit for a flit it never got (R02)
  CREDIT_INJ_VALID_IN_RESET   // TX pulses valid during reset (R03)
} credit_inject_e;

class credit_cfg extends uvm_object;
  `uvm_object_utils(credit_cfg)
  credit_role_e           role      = CREDIT_TX;
  uvm_active_passive_enum is_active = UVM_ACTIVE;
  bit                     has_cov   = 1;
  int unsigned            data_bits = 48;     // must match the interface
  int unsigned            depth     = 4;      // receiver buffer depth = sender's initial credits

  // RX driver: after each pop, the next pop waits vip_delay::pick(rx_busy_pct, rx_delay_max)
  int unsigned rx_busy_pct  = 30;
  int unsigned rx_delay_max = 4;

  credit_inject_e inject = CREDIT_INJ_NONE;

  function new(string name = "credit_cfg"); super.new(name); endfunction
endclass
