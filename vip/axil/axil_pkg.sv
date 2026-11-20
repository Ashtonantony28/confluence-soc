// axil_pkg.sv: Confluence AXI4-Lite VIP (ADR 0002). Master driver, reactive slave, monitor,
// coverage, agent and sequence library. Classes are parameterised by the bus widths; the
// transaction item uses the package maxima below.
package axil_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import vip_common_pkg::*;

  localparam int AXIL_MAX_AW = 64;
  localparam int AXIL_MAX_DW = 64;   // AXI4-Lite allows 32- or 64-bit data

  `include "axil_item.svh"
  `include "axil_cfg.svh"
  `include "axil_master_driver.svh"
  `include "axil_slave_driver.svh"
  `include "axil_monitor.svh"
  `include "axil_coverage.svh"
  `include "axil_agent.svh"
  `include "axil_seq_lib.svh"
endpackage
