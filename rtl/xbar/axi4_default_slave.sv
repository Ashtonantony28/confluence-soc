// axi4_default_slave.sv: answers every request with DECERR (unmapped addresses, ADR 0001).
// One write and one read at a time: accepts AW, sinks W through WLAST, returns B=DECERR;
// accepts AR, returns len+1 beats of RRESP=DECERR with zero data.
`default_nettype none
module axi4_default_slave #(
  parameter int IDW = 6,
  parameter int DW  = 128
) (
  input  logic           clk,
  input  logic           rst_n,
  input  logic [IDW-1:0] awid,
  input  logic           awvalid,
  output logic           awready,
  input  logic           wlast,
  input  logic           wvalid,
  output logic           wready,
  output logic [IDW-1:0] bid,
  output logic [1:0]     bresp,
  output logic           bvalid,
  input  logic           bready,
  input  logic [IDW-1:0] arid,
  input  logic [7:0]     arlen,
  input  logic           arvalid,
  output logic           arready,
  output logic [IDW-1:0] rid,
  output logic [DW-1:0]  rdata,
  output logic [1:0]     rresp,
  output logic           rlast,
  output logic           rvalid,
  input  logic           rready
);
  localparam logic [1:0] RESP_DECERR = 2'b11;
  typedef enum logic [1:0] { W_IDLE, W_DATA, W_RESP } wst_e;
  wst_e          wst;
  logic          rbusy;
  logic [7:0]    rleft;

  assign awready = (wst == W_IDLE);
  assign wready  = (wst == W_DATA);
  assign bvalid  = (wst == W_RESP);
  assign bresp   = RESP_DECERR;
  assign arready = !rbusy;
  assign rvalid  = rbusy;
  assign rresp   = RESP_DECERR;
  assign rdata   = '0;
  assign rlast   = rbusy && (rleft == 8'd0);

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      wst <= W_IDLE; bid <= '0; rbusy <= 1'b0; rleft <= '0; rid <= '0;
    end else begin
      case (wst)
        W_IDLE: if (awvalid) begin bid <= awid; wst <= W_DATA; end
        W_DATA: if (wvalid && wlast) wst <= W_RESP;
        W_RESP: if (bready) wst <= W_IDLE;
        default: wst <= W_IDLE;
      endcase
      if (!rbusy && arvalid) begin rbusy <= 1'b1; rid <= arid; rleft <= arlen; end
      else if (rbusy && rready) begin
        if (rleft == 8'd0) rbusy <= 1'b0;
        else rleft <= rleft - 8'd1;
      end
    end
  end
endmodule
`default_nettype wire
