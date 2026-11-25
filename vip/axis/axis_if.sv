// axis_if.sv: AXI4-Stream (ARM IHI 0051A) signal bundle used by the Confluence AXI-Stream VIP
// (ADR 0002). TID / TDEST / TUSER are optional: a width parameter of 0 means "not present";
// the wire is then one bit wide, driven 0 and ignored by monitor, checker and scoreboards.
// TSTRB and TWAKEUP are not modelled (every byte is a data or a null byte, per TKEEP).
// No clocking blocks: drivers update on posedge with nonblocking assignments and monitors
// sample at posedge, which is race free under Verilator --timing.
interface axis_if #(
  parameter int DW    = 32,
  parameter int IDW   = 0,
  parameter int DESTW = 0,
  parameter int UW    = 0
) (
  input logic aclk,
  input logic aresetn
);
  localparam int KW    = DW / 8;
  localparam int IDW_I = (IDW > 0) ? IDW : 1;
  localparam int DSW_I = (DESTW > 0) ? DESTW : 1;
  localparam int UW_I  = (UW > 0) ? UW : 1;

  logic [DW-1:0]    tdata;
  logic [KW-1:0]    tkeep;
  logic             tlast;
  logic [UW_I-1:0]  tuser;
  logic [IDW_I-1:0] tid;
  logic [DSW_I-1:0] tdest;
  logic             tvalid;
  logic             tready;
endinterface
