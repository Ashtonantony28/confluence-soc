// axi4_if.sv: AXI4 (full) signal bundle used by the Confluence AXI4 VIP.
// Widths are parameters; the VIP classes are parameterised the same way (axi4_pkg).
// No clocking blocks: drivers update on posedge with nonblocking assignments and monitors
// sample at posedge, which is race free under Verilator --timing.
interface axi4_if #(
  parameter int AW  = 32,
  parameter int DW  = 128,
  parameter int IDW = 4
) (
  input logic aclk,
  input logic aresetn
);
  localparam int SW = DW / 8;

  // write address
  logic [IDW-1:0] awid;
  logic [AW-1:0]  awaddr;
  logic [7:0]     awlen;
  logic [2:0]     awsize;
  logic [1:0]     awburst;
  logic           awlock;
  logic [3:0]     awcache;
  logic [2:0]     awprot;
  logic [3:0]     awqos;
  logic           awvalid;
  logic           awready;
  // write data
  logic [DW-1:0]  wdata;
  logic [SW-1:0]  wstrb;
  logic           wlast;
  logic           wvalid;
  logic           wready;
  // write response
  logic [IDW-1:0] bid;
  logic [1:0]     bresp;
  logic           bvalid;
  logic           bready;
  // read address
  logic [IDW-1:0] arid;
  logic [AW-1:0]  araddr;
  logic [7:0]     arlen;
  logic [2:0]     arsize;
  logic [1:0]     arburst;
  logic           arlock;
  logic [3:0]     arcache;
  logic [2:0]     arprot;
  logic [3:0]     arqos;
  logic           arvalid;
  logic           arready;
  // read data
  logic [IDW-1:0] rid;
  logic [DW-1:0]  rdata;
  logic [1:0]     rresp;
  logic           rlast;
  logic           rvalid;
  logic           rready;
endinterface
