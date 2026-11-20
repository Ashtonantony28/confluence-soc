// apb_pkg.sv: Confluence APB4 VIP (ADR 0002). Master driver, reactive slave, monitor,
// coverage, agent, sequence library and a uvm_reg adapter (ported from the MLACC-UVM APB
// agent). Classes are parameterised by the bus widths; the item uses the package maxima.
package apb_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import vip_common_pkg::*;

  localparam int APB_MAX_AW = 32;
  localparam int APB_MAX_DW = 32;   // APB4 data is at most 32 bits

  `include "apb_item.svh"
  `include "apb_cfg.svh"
  `include "apb_master_driver.svh"
  `include "apb_slave_driver.svh"
  `include "apb_monitor.svh"
  `include "apb_coverage.svh"
  `include "apb_agent.svh"
  `include "apb_seq_lib.svh"
  `include "apb_reg_adapter.svh"
endpackage
