// apb_if.sv: APB4 (AMBA APB protocol v2.0, IHI 0024C) signal bundle used by the Confluence
// APB VIP (ADR 0002). One completer select line. DW is 8, 16 or 32.
// No clocking blocks: drivers update on posedge with nonblocking assignments and monitors
// sample at posedge, which is race free under Verilator --timing.
interface apb_if #(
  parameter int AW = 32,
  parameter int DW = 32
) (
  input logic pclk,
  input logic presetn
);
  localparam int SW = DW / 8;

  logic [AW-1:0] paddr;
  logic          psel;
  logic          penable;
  logic          pwrite;
  logic [DW-1:0] pwdata;
  logic [SW-1:0] pstrb;
  logic [2:0]    pprot;
  logic          pready;
  logic [DW-1:0] prdata;
  logic          pslverr;
endinterface
