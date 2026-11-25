// axi4_pkg.sv: Confluence AXI4 VIP (ADR 0002). Master driver, reactive slave, monitor,
// coverage, agent and sequence library. Classes are parameterised by the bus widths; the
// transaction item uses the package maxima below.
package axi4_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import vip_common_pkg::*;

  localparam int AXI4_MAX_AW  = 64;
  localparam int AXI4_MAX_DW  = 128;   // the Confluence fabric is 128 bits wide (ADR 0001)
  localparam int AXI4_MAX_IDW = 8;

  `include "axi4_item.svh"
  `include "axi4_cfg.svh"
  `include "axi4_master_driver.svh"
  `include "axi4_slave_driver.svh"
  `include "axi4_monitor.svh"
  `include "axi4_coverage.svh"
  `include "axi4_agent.svh"
  `include "axi4_seq_lib.svh"
  `include "axi4_mem_scoreboard.svh"
endpackage
