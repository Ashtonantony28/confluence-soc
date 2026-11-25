// credit_pkg.sv: Confluence credit-link VIP (ADR 0002). Sender (TX) driver with credit
// accounting, receiver (RX) driver that models a DEPTH-entry buffer draining at a random rate
// and returns credits, a monitor, coverage, an agent and a small sequence library. Protocol
// generic: it knows nothing about what the flits mean.
package credit_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import vip_common_pkg::*;

  localparam int CREDIT_MAX_DW = 128;

  `include "credit_item.svh"
  `include "credit_cfg.svh"
  `include "credit_tx_driver.svh"
  `include "credit_rx_driver.svh"
  `include "credit_monitor.svh"
  `include "credit_coverage.svh"
  `include "credit_agent.svh"
  `include "credit_seq_lib.svh"
endpackage
