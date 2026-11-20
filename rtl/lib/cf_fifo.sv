// cf_fifo.sv: small synchronous FIFO (registered storage, combinational head).
`default_nettype none
module cf_fifo #(
  parameter int W     = 8,
  parameter int DEPTH = 4
) (
  input  logic         clk,
  input  logic         rst_n,
  input  logic         push,
  input  logic [W-1:0] din,
  input  logic         pop,
  output logic [W-1:0] head,
  output logic         empty,
  output logic         full
);
  localparam int PW = (DEPTH > 1) ? $clog2(DEPTH) : 1;
  logic [W-1:0]  mem [DEPTH];
  logic [PW-1:0] rd, wr;
  logic [PW:0]   cnt;

  assign head  = mem[rd];
  assign empty = (cnt == '0);
  assign full  = (cnt == (PW+1)'(DEPTH));

  function automatic logic [PW-1:0] inc(logic [PW-1:0] p);
    return (p == PW'(DEPTH - 1)) ? '0 : p + 1'b1;
  endfunction

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      rd <= '0; wr <= '0; cnt <= '0;
    end else begin
      if (push && !full) begin mem[wr] <= din; wr <= inc(wr); end
      if (pop && !empty) rd <= inc(rd);
      cnt <= cnt + (PW+1)'(push && !full) - (PW+1)'(pop && !empty);
    end
  end
endmodule
`default_nettype wire
