// axil_if.sv: AXI4-Lite signal bundle used by the Confluence AXI4-Lite VIP (ADR 0002).
// Widths are parameters (DW is 32 or 64); the VIP classes are parameterised the same way.
// No clocking blocks: drivers update on posedge with nonblocking assignments and monitors
// sample at posedge, which is race free under Verilator --timing.
interface axil_if #(
  parameter int AW = 32,
  parameter int DW = 32
) (
  input logic aclk,
  input logic aresetn
);
  localparam int SW = DW / 8;

  // write address
  logic [AW-1:0] awaddr;
  logic [2:0]    awprot;
  logic          awvalid;
  logic          awready;
  // write data
  logic [DW-1:0] wdata;
  logic [SW-1:0] wstrb;
  logic          wvalid;
  logic          wready;
  // write response
  logic [1:0]    bresp;
  logic          bvalid;
  logic          bready;
  // read address
  logic [AW-1:0] araddr;
  logic [2:0]    arprot;
  logic          arvalid;
  logic          arready;
  // read data
  logic [DW-1:0] rdata;
  logic [1:0]    rresp;
  logic          rvalid;
  logic          rready;
endinterface
