// cf_rr_arb.sv: round-robin arbiter whose grant is held while the winner waits.
// `hold` = the granted request is presented downstream but not yet accepted: the grant must
// not move (AXI payload stability). `advance` = the granted request was accepted.
`default_nettype none
module cf_rr_arb #(
  parameter int N = 4
) (
  input  logic         clk,
  input  logic         rst_n,
  input  logic [N-1:0] req,
  input  logic         hold,
  input  logic         advance,
  output logic [N-1:0] gnt
);
  localparam int IW = (N > 1) ? $clog2(N) : 1;
  logic [IW-1:0] last, held_idx, win_idx;
  logic          held;
  logic          found;

  always_comb begin
    found = 1'b0;
    win_idx = '0;
    for (int k = 1; k <= N; k++) begin
      if (!found && req[(int'(last) + k) % N]) begin
        found = 1'b1;
        win_idx = IW'((int'(last) + k) % N);
      end
    end
  end

  always_comb begin
    gnt = '0;
    if (held) gnt[held_idx] = 1'b1;
    else if (found) gnt[win_idx] = 1'b1;
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      last <= IW'(N - 1); held <= 1'b0; held_idx <= '0;
    end else begin
      if (advance) begin
        last <= held ? held_idx : win_idx;
        held <= 1'b0;
      end else if (hold && !held) begin
        held <= 1'b1;
        held_idx <= win_idx;
      end
    end
  end
endmodule
`default_nettype wire
