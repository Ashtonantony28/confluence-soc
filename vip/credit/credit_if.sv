// credit_if.sv: credit-based flit link used by the Confluence credit VIP (ADR 0002).
// One flit per cycle while `valid` is high (no ready); the sender may only send while it holds
// a credit. The receiver returns one credit per cycle that `credit` is high, one for each flit
// it consumed. The sender's credit count starts at the receiver's buffer depth after reset.
// No clocking blocks: drivers update on posedge with nonblocking assignments, monitors sample
// at posedge.
interface credit_if #(parameter int DW = 48) (input logic clk, input logic rst_n);
  logic          valid;
  logic [DW-1:0] data;
  logic          credit;
endinterface
