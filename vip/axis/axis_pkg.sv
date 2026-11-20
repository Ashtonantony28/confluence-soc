// axis_pkg.sv: Confluence AXI4-Stream VIP (ADR 0002). Master driver, backpressuring slave,
// packet-rebuilding monitor, coverage, agent and sequence library. Classes are
// parameterised by the bus widths; the packet item uses the package maxima below.
package axis_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import vip_common_pkg::*;

  localparam int AXIS_MAX_DW    = 512;
  localparam int AXIS_MAX_IDW   = 8;
  localparam int AXIS_MAX_DESTW = 8;
  localparam int AXIS_MAX_UW    = 32;   // TUSER bits per transfer

  `include "axis_item.svh"
  `include "axis_cfg.svh"
  `include "axis_packer.svh"
  `include "axis_master_driver.svh"
  `include "axis_slave_driver.svh"
  `include "axis_monitor.svh"
  `include "axis_coverage.svh"
  `include "axis_agent.svh"
  `include "axis_seq_lib.svh"
endpackage
