// axil2apb.sv: AXI4-Lite slave -> APB4 master bridge. One access at a time; a write needs
// both AW and W (accepted together), reads and writes alternate priority.
`default_nettype none
module axil2apb #(
  parameter int AW = 32,
  parameter int DW = 32
) (
  input  logic          clk,
  input  logic          rst_n,
  input  logic [AW-1:0] s_awaddr,
  input  logic [2:0]    s_awprot,
  input  logic          s_awvalid,
  output logic          s_awready,
  input  logic [DW-1:0] s_wdata,
  input  logic [DW/8-1:0] s_wstrb,
  input  logic          s_wvalid,
  output logic          s_wready,
  output logic [1:0]    s_bresp,
  output logic          s_bvalid,
  input  logic          s_bready,
  input  logic [AW-1:0] s_araddr,
  input  logic [2:0]    s_arprot,
  input  logic          s_arvalid,
  output logic          s_arready,
  output logic [DW-1:0] s_rdata,
  output logic [1:0]    s_rresp,
  output logic          s_rvalid,
  input  logic          s_rready,
  output logic [AW-1:0] paddr,
  output logic          psel,
  output logic          penable,
  output logic          pwrite,
  output logic [DW-1:0] pwdata,
  output logic [DW/8-1:0] pstrb,
  output logic [2:0]    pprot,
  input  logic          pready,
  input  logic [DW-1:0] prdata,
  input  logic          pslverr
);
  localparam logic [1:0] RESP_OKAY = 2'b00, RESP_SLVERR = 2'b10;
  typedef enum logic [2:0] { IDLE, SETUP, ACCESS, B_RESP, R_RESP } st_e;
  st_e st;
  logic prefer_rd, err;
  logic [DW-1:0] rdata;
  logic wr_go, rd_go;

  assign wr_go = (st == IDLE) && s_awvalid && s_wvalid && !(s_arvalid && prefer_rd);
  assign rd_go = (st == IDLE) && s_arvalid && !wr_go;
  assign s_awready = wr_go;
  assign s_wready  = wr_go;
  assign s_arready = rd_go;
  assign s_bvalid  = (st == B_RESP);
  assign s_bresp   = err ? RESP_SLVERR : RESP_OKAY;
  assign s_rvalid  = (st == R_RESP);
  assign s_rresp   = err ? RESP_SLVERR : RESP_OKAY;
  assign s_rdata   = rdata;
  assign psel      = (st == SETUP) || (st == ACCESS);
  assign penable   = (st == ACCESS);

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      st <= IDLE; prefer_rd <= 1'b0; err <= 1'b0; rdata <= '0;
      paddr <= '0; pwrite <= 1'b0; pwdata <= '0; pstrb <= '0; pprot <= '0;
    end else begin
      case (st)
        IDLE: begin
          if (wr_go) begin
            paddr <= s_awaddr; pwrite <= 1'b1; pwdata <= s_wdata; pstrb <= s_wstrb; pprot <= s_awprot;
            prefer_rd <= 1'b1; st <= SETUP;
          end else if (rd_go) begin
            paddr <= s_araddr; pwrite <= 1'b0; pwdata <= '0; pstrb <= '0; pprot <= s_arprot;
            prefer_rd <= 1'b0; st <= SETUP;
          end
        end
        SETUP: st <= ACCESS;
        ACCESS: if (pready) begin
`ifdef MUTANT_AXIL2APB_NOERR
          err <= 1'b0;                             // mutant: PSLVERR dropped
`else
          err <= pslverr;
`endif
          if (!pwrite) rdata <= prdata;
          st <= pwrite ? B_RESP : R_RESP;
        end
        B_RESP: if (s_bready) st <= IDLE;
        R_RESP: if (s_rready) st <= IDLE;
        default: st <= IDLE;
      endcase
    end
  end
endmodule
`default_nettype wire
