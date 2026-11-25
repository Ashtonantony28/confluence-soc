// axi2axil.sv: AXI4 slave -> AXI4-Lite master bridge (ADR 0001).
// One burst at a time, write and read alternating priority. Every AXI beat is split into
// the AXI4-Lite words that cover its active byte lanes (narrow, unaligned, FIXED, INCR and
// WRAP bursts are all handled); read words are assembled into the wide beat. The burst's
// write response is the worst AXI4-Lite response seen; each read beat carries the worst
// response of its words.
`default_nettype none
module axi2axil #(
  parameter int AW  = 32,
  parameter int DW  = 128,   // AXI4 side
  parameter int LDW = 32,    // AXI4-Lite side
  parameter int IDW = 6
) (
  input  logic           clk,
  input  logic           rst_n,
  // AXI4 slave
  input  logic [IDW-1:0] s_awid,
  input  logic [AW-1:0]  s_awaddr,
  input  logic [7:0]     s_awlen,
  input  logic [2:0]     s_awsize,
  input  logic [1:0]     s_awburst,
  input  logic [2:0]     s_awprot,
  input  logic           s_awvalid,
  output logic           s_awready,
  input  logic [DW-1:0]  s_wdata,
  input  logic [DW/8-1:0] s_wstrb,
  input  logic           s_wvalid,
  output logic           s_wready,
  output logic [IDW-1:0] s_bid,
  output logic [1:0]     s_bresp,
  output logic           s_bvalid,
  input  logic           s_bready,
  input  logic [IDW-1:0] s_arid,
  input  logic [AW-1:0]  s_araddr,
  input  logic [7:0]     s_arlen,
  input  logic [2:0]     s_arsize,
  input  logic [1:0]     s_arburst,
  input  logic [2:0]     s_arprot,
  input  logic           s_arvalid,
  output logic           s_arready,
  output logic [IDW-1:0] s_rid,
  output logic [DW-1:0]  s_rdata,
  output logic [1:0]     s_rresp,
  output logic           s_rlast,
  output logic           s_rvalid,
  input  logic           s_rready,
  // AXI4-Lite master
  output logic [AW-1:0]  m_awaddr,
  output logic [2:0]     m_awprot,
  output logic           m_awvalid,
  input  logic           m_awready,
  output logic [LDW-1:0] m_wdata,
  output logic [LDW/8-1:0] m_wstrb,
  output logic           m_wvalid,
  input  logic           m_wready,
  input  logic [1:0]     m_bresp,
  input  logic           m_bvalid,
  output logic           m_bready,
  output logic [AW-1:0]  m_araddr,
  output logic [2:0]     m_arprot,
  output logic           m_arvalid,
  input  logic           m_arready,
  input  logic [LDW-1:0] m_rdata,
  input  logic [1:0]     m_rresp,
  input  logic           m_rvalid,
  output logic           m_rready
);
  localparam int SB  = DW / 8;
  localparam int LB  = LDW / 8;
  localparam int LSH = $clog2(LB);
  localparam int SBW = $clog2(SB);
  localparam int NWL = SB / LB;                  // lite words per wide beat
  localparam int WLW = (NWL > 1) ? $clog2(NWL) : 1;
  localparam logic [1:0] B_FIXED = 2'd0, B_WRAP = 2'd2;

  typedef enum logic [3:0] { IDLE, W_WAIT, W_LITE, W_B, W_NEXT, W_RESP, R_AR, R_R, R_BEAT } st_e;
  st_e st;

  logic [IDW-1:0] id;
  logic [AW-1:0]  baddr;        // address of the current beat
  logic [AW-1:0]  word;         // address of the current lite word
  logic [AW-1:0]  bhi;          // last byte address of the current beat
  logic [7:0]     len, beat;
  logic [2:0]     size;
  logic [1:0]     burst;
  logic [2:0]     prot;
  logic [1:0]     resp_acc;     // worst response of the burst (W) / beat (R)
  logic           aw_done, w_done;
  logic [DW-1:0]  rbuf;
  logic           prefer_rd;

  function automatic logic [1:0] worst(logic [1:0] a, logic [1:0] b);
    return (b > a) ? b : a;     // OKAY < EXOKAY < SLVERR < DECERR
  endfunction

  function automatic logic [AW-1:0] beat_hi(logic [AW-1:0] a, logic [2:0] sz);
    logic [AW-1:0] nb;
    nb = AW'(1) << sz;
    return (a & ~(nb - AW'(1))) + nb - AW'(1);
  endfunction

  function automatic logic [AW-1:0] next_beat(logic [AW-1:0] a, logic [2:0] sz, logic [1:0] bu, logic [7:0] ln);
    logic [AW-1:0] nb, inc, wb, base;
    nb  = AW'(1) << sz;
    inc = (a & ~(nb - AW'(1))) + nb;
    if (bu == B_FIXED) return a;
`ifndef MUTANT_AXI2AXIL_WRAP
    if (bu == B_WRAP) begin
      wb   = (AW'(ln) + AW'(1)) << sz;           // 2, 4, 8 or 16 beats: a power of two
      base = a & ~(wb - AW'(1));
      return ((inc - base) >= wb) ? base : inc;
    end
`endif
    return inc;
  endfunction

  logic [WLW-1:0] lane;
  if (NWL > 1) begin : g_lane
`ifdef MUTANT_AXI2AXIL_LANE
    assign lane = '0;                          // mutant: every word on lane 0
`else
    assign lane = word[SBW-1:LSH];
`endif
  end else begin : g_lane1
    assign lane = '0;
  end

  // ------------------------------------------------------------------ outputs
  assign s_awready = (st == IDLE) && s_awvalid && !(s_arvalid && prefer_rd);
  assign s_arready = (st == IDLE) && s_arvalid && !(s_awvalid && !prefer_rd);
  assign s_wready  = (st == W_NEXT);
  assign s_bvalid  = (st == W_RESP);
  assign s_bid     = id;
  assign s_bresp   = resp_acc;
  assign s_rvalid  = (st == R_BEAT);
  assign s_rid     = id;
  assign s_rdata   = rbuf;
  assign s_rresp   = resp_acc;
  assign s_rlast   = (beat == len);

  assign m_awaddr  = word;
  assign m_awprot  = prot;
  assign m_awvalid = (st == W_LITE) && !aw_done;
  assign m_wdata   = s_wdata[int'(lane) * LDW +: LDW];
  assign m_wstrb   = s_wstrb[int'(lane) * LB +: LB];
  assign m_wvalid  = (st == W_LITE) && !w_done;
  assign m_bready  = (st == W_B);
  assign m_araddr  = word;
  assign m_arprot  = prot;
  assign m_arvalid = (st == R_AR);
  assign m_rready  = (st == R_R);

  // more lite words in this beat?
  logic more_words;
  assign more_words = ((word & ~AW'(LB - 1)) + AW'(LB)) <= bhi &&
                      ((word & ~AW'(LB - 1)) + AW'(LB)) > (word & ~AW'(LB - 1));   // no wrap-around

  // ------------------------------------------------------------------ state machine
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      st <= IDLE; id <= '0; baddr <= '0; word <= '0; bhi <= '0; len <= '0; beat <= '0;
      size <= '0; burst <= '0; prot <= '0; resp_acc <= '0; aw_done <= 1'b0; w_done <= 1'b0;
      rbuf <= '0; prefer_rd <= 1'b0;
    end else begin
      case (st)
        IDLE: begin
          beat <= '0; resp_acc <= '0; aw_done <= 1'b0; w_done <= 1'b0; rbuf <= '0;
          if (s_awready) begin
            id <= s_awid; baddr <= s_awaddr; word <= s_awaddr & ~AW'(LB - 1);
            bhi <= beat_hi(s_awaddr, s_awsize); len <= s_awlen; size <= s_awsize;
            burst <= s_awburst; prot <= s_awprot; prefer_rd <= 1'b1;
            st <= W_WAIT;
          end else if (s_arready) begin
            id <= s_arid; baddr <= s_araddr; word <= s_araddr & ~AW'(LB - 1);
            bhi <= beat_hi(s_araddr, s_arsize); len <= s_arlen; size <= s_arsize;
            burst <= s_arburst; prot <= s_arprot; prefer_rd <= 1'b0;
            st <= R_AR;
          end
        end
        W_WAIT: if (s_wvalid) st <= W_LITE;
        W_LITE: begin
          if (m_awvalid && m_awready) aw_done <= 1'b1;
          if (m_wvalid && m_wready) w_done <= 1'b1;
          if ((aw_done || m_awready) && (w_done || m_wready)) st <= W_B;
        end
        W_B: if (m_bvalid) begin
`ifdef MUTANT_AXI2AXIL_BRESP
          resp_acc <= m_bresp;                     // mutant: last word's response wins
`else
          resp_acc <= worst(resp_acc, m_bresp);
`endif
          aw_done <= 1'b0; w_done <= 1'b0;
          if (more_words) begin word <= (word & ~AW'(LB - 1)) + AW'(LB); st <= W_LITE; end
          else st <= W_NEXT;
        end
        W_NEXT: begin                      // accept the wide beat (s_wready = 1 here)
          if (beat == len) st <= W_RESP;
          else begin
            logic [AW-1:0] nbaddr;
            nbaddr = next_beat(baddr, size, burst, len);
            baddr <= nbaddr; word <= nbaddr & ~AW'(LB - 1); bhi <= beat_hi(nbaddr, size);
            beat <= beat + 8'd1;
            st <= W_WAIT;
          end
        end
        W_RESP: if (s_bready) st <= IDLE;
        R_AR: if (m_arready) st <= R_R;
        R_R: if (m_rvalid) begin
          rbuf[int'(lane) * LDW +: LDW] <= m_rdata;
          resp_acc <= worst(resp_acc, m_rresp);
          if (more_words) begin word <= (word & ~AW'(LB - 1)) + AW'(LB); st <= R_AR; end
          else st <= R_BEAT;
        end
        R_BEAT: if (s_rready) begin
          if (beat == len) st <= IDLE;
          else begin
            logic [AW-1:0] nbaddr;
            nbaddr = next_beat(baddr, size, burst, len);
            baddr <= nbaddr; word <= nbaddr & ~AW'(LB - 1); bhi <= beat_hi(nbaddr, size);
            beat <= beat + 8'd1; resp_acc <= '0; rbuf <= '0;
            st <= R_AR;
          end
        end
        default: st <= IDLE;
      endcase
    end
  end
endmodule
`default_nettype wire
