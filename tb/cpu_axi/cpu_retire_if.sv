// cpu_retire_if.sv: Vortex-V retire/debug ports and bridge status, watched by the CPU env (M6).
// The debug ports are registered in the core, so they hold one core cycle's retires until the
// next core edge; the monitor samples them once per core edge (step = the bridge's clock enable).
interface cpu_retire_if #(parameter int XLEN = 64) (input logic clk, input logic rst_n);
  logic            step;          // core edge at the end of this bus cycle
  logic            r0_valid, r0_wbv, r1_valid, r1_wbv;
  logic [XLEN-1:0] r0_pc, r0_data, r1_pc, r1_data;
  logic [4:0]      r0_rd, r1_rd;
  logic            mlstat_sat;
  logic            bridge_err;
  logic [31:0]     core_cycles;
endinterface
