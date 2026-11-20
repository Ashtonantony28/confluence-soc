// confluence_xbar.sv: NM x NS AXI4 crossbar (ADR 0001).
//
// - Address decode: slave s owns addresses with (addr & S_MASK[s]) == S_BASE[s]; anything
//   else goes to an internal DECERR slave.
// - Per-slave round-robin arbitration on AW and AR; the grant is held while the winner waits,
//   so the payload a slave sees never changes under VALID.
// - IDs are widened on the slave side to {master index, master ID}; B and R are routed back
//   by the upper bits.
// - Same-ID ordering: a master may have outstanding transactions with one ID at only one
//   slave at a time (a second slave is stalled until they complete), which is what keeps
//   per-ID response order without reorder buffers. At most MAX_OUT outstanding per master
//   per direction.
// - W follows AW order: each slave keeps a FIFO of the masters it accepted AWs from, each
//   master a FIFO of the slaves its AWs went to; a W beat moves only when both heads agree.
//   AWs are accepted at the same instant on both sides, so the two orders are consistent and
//   cannot deadlock.
// - Read data is arbitrated per beat, so a master may see bursts of different IDs (from
//   different slaves) interleaved, as AXI4 allows. Holding the R channel until RLAST
//   deadlocks against interleaving slaves (found by xbar_random_test, CF-XBAR-001).
// Combinational (no register slices): a functional fabric for simulation and FPGA-scale
// clocks; slices can be added at the ports later behind a parameter.
`default_nettype none
module confluence_xbar #(
  parameter int NM      = 2,
  parameter int NS      = 2,
  parameter int AW      = 32,
  parameter int DW      = 128,
  parameter int MIDW    = 4,
  parameter int MAX_OUT = 8,
  parameter logic [NS-1:0][AW-1:0] S_BASE = '0,
  parameter logic [NS-1:0][AW-1:0] S_MASK = '0,
  localparam int MW   = (NM > 1) ? $clog2(NM) : 1,
  localparam int SIDW = MIDW + MW,
  localparam int SW   = DW / 8
) (
  input  logic clk,
  input  logic rst_n,
  // ---- master ports (the crossbar is their slave)
  input  logic [NM-1:0][MIDW-1:0] m_awid,
  input  logic [NM-1:0][AW-1:0]   m_awaddr,
  input  logic [NM-1:0][7:0]      m_awlen,
  input  logic [NM-1:0][2:0]      m_awsize,
  input  logic [NM-1:0][1:0]      m_awburst,
  input  logic [NM-1:0]           m_awlock,
  input  logic [NM-1:0][3:0]      m_awcache,
  input  logic [NM-1:0][2:0]      m_awprot,
  input  logic [NM-1:0][3:0]      m_awqos,
  input  logic [NM-1:0]           m_awvalid,
  output logic [NM-1:0]           m_awready,
  input  logic [NM-1:0][DW-1:0]   m_wdata,
  input  logic [NM-1:0][SW-1:0]   m_wstrb,
  input  logic [NM-1:0]           m_wlast,
  input  logic [NM-1:0]           m_wvalid,
  output logic [NM-1:0]           m_wready,
  output logic [NM-1:0][MIDW-1:0] m_bid,
  output logic [NM-1:0][1:0]      m_bresp,
  output logic [NM-1:0]           m_bvalid,
  input  logic [NM-1:0]           m_bready,
  input  logic [NM-1:0][MIDW-1:0] m_arid,
  input  logic [NM-1:0][AW-1:0]   m_araddr,
  input  logic [NM-1:0][7:0]      m_arlen,
  input  logic [NM-1:0][2:0]      m_arsize,
  input  logic [NM-1:0][1:0]      m_arburst,
  input  logic [NM-1:0]           m_arlock,
  input  logic [NM-1:0][3:0]      m_arcache,
  input  logic [NM-1:0][2:0]      m_arprot,
  input  logic [NM-1:0][3:0]      m_arqos,
  input  logic [NM-1:0]           m_arvalid,
  output logic [NM-1:0]           m_arready,
  output logic [NM-1:0][MIDW-1:0] m_rid,
  output logic [NM-1:0][DW-1:0]   m_rdata,
  output logic [NM-1:0][1:0]      m_rresp,
  output logic [NM-1:0]           m_rlast,
  output logic [NM-1:0]           m_rvalid,
  input  logic [NM-1:0]           m_rready,
  // ---- slave ports (the crossbar is their master)
  output logic [NS-1:0][SIDW-1:0] s_awid,
  output logic [NS-1:0][AW-1:0]   s_awaddr,
  output logic [NS-1:0][7:0]      s_awlen,
  output logic [NS-1:0][2:0]      s_awsize,
  output logic [NS-1:0][1:0]      s_awburst,
  output logic [NS-1:0]           s_awlock,
  output logic [NS-1:0][3:0]      s_awcache,
  output logic [NS-1:0][2:0]      s_awprot,
  output logic [NS-1:0][3:0]      s_awqos,
  output logic [NS-1:0]           s_awvalid,
  input  logic [NS-1:0]           s_awready,
  output logic [NS-1:0][DW-1:0]   s_wdata,
  output logic [NS-1:0][SW-1:0]   s_wstrb,
  output logic [NS-1:0]           s_wlast,
  output logic [NS-1:0]           s_wvalid,
  input  logic [NS-1:0]           s_wready,
  input  logic [NS-1:0][SIDW-1:0] s_bid,
  input  logic [NS-1:0][1:0]      s_bresp,
  input  logic [NS-1:0]           s_bvalid,
  output logic [NS-1:0]           s_bready,
  output logic [NS-1:0][SIDW-1:0] s_arid,
  output logic [NS-1:0][AW-1:0]   s_araddr,
  output logic [NS-1:0][7:0]      s_arlen,
  output logic [NS-1:0][2:0]      s_arsize,
  output logic [NS-1:0][1:0]      s_arburst,
  output logic [NS-1:0]           s_arlock,
  output logic [NS-1:0][3:0]      s_arcache,
  output logic [NS-1:0][2:0]      s_arprot,
  output logic [NS-1:0][3:0]      s_arqos,
  output logic [NS-1:0]           s_arvalid,
  input  logic [NS-1:0]           s_arready,
  input  logic [NS-1:0][SIDW-1:0] s_rid,
  input  logic [NS-1:0][DW-1:0]   s_rdata,
  input  logic [NS-1:0][1:0]      s_rresp,
  input  logic [NS-1:0]           s_rlast,
  input  logic [NS-1:0]           s_rvalid,
  output logic [NS-1:0]           s_rready
);
  localparam int NT  = NS + 1;                 // targets: NS slaves + DECERR slave
  localparam int TW  = $clog2(NT);
  localparam int NID = 1 << MIDW;
  localparam int CW  = $clog2(MAX_OUT + 1);
  localparam logic [TW-1:0] T_DEF = TW'(NS);

  // ------------------------------------------------------------------ target-side signals
  // Index NS is the DECERR slave, which ignores most payload fields.
  /* verilator lint_off UNUSEDSIGNAL */
  logic [NT-1:0][SIDW-1:0] t_awid, t_arid, t_bid, t_rid;
  logic [NT-1:0][AW-1:0]   t_awaddr, t_araddr;
  logic [NT-1:0][7:0]      t_awlen, t_arlen;
  logic [NT-1:0][2:0]      t_awsize, t_arsize, t_awprot, t_arprot;
  logic [NT-1:0][1:0]      t_awburst, t_arburst, t_bresp, t_rresp;
  logic [NT-1:0]           t_awlock, t_arlock;
  logic [NT-1:0][3:0]      t_awcache, t_arcache, t_awqos, t_arqos;
  logic [NT-1:0]           t_awvalid, t_awready, t_wvalid, t_wready, t_wlast;
  logic [NT-1:0][DW-1:0]   t_wdata, t_rdata;
  logic [NT-1:0][SW-1:0]   t_wstrb;
  logic [NT-1:0]           t_bvalid, t_bready, t_arvalid, t_arready, t_rvalid, t_rready, t_rlast;
  /* verilator lint_on UNUSEDSIGNAL */

  for (genvar s = 0; s < NS; s++) begin : g_sport
    assign s_awid[s] = t_awid[s];   assign s_awaddr[s] = t_awaddr[s]; assign s_awlen[s] = t_awlen[s];
    assign s_awsize[s] = t_awsize[s]; assign s_awburst[s] = t_awburst[s]; assign s_awlock[s] = t_awlock[s];
    assign s_awcache[s] = t_awcache[s]; assign s_awprot[s] = t_awprot[s]; assign s_awqos[s] = t_awqos[s];
    assign s_awvalid[s] = t_awvalid[s]; assign t_awready[s] = s_awready[s];
    assign s_wdata[s] = t_wdata[s]; assign s_wstrb[s] = t_wstrb[s]; assign s_wlast[s] = t_wlast[s];
    assign s_wvalid[s] = t_wvalid[s]; assign t_wready[s] = s_wready[s];
    assign t_bid[s] = s_bid[s]; assign t_bresp[s] = s_bresp[s]; assign t_bvalid[s] = s_bvalid[s];
    assign s_bready[s] = t_bready[s];
    assign s_arid[s] = t_arid[s];   assign s_araddr[s] = t_araddr[s]; assign s_arlen[s] = t_arlen[s];
    assign s_arsize[s] = t_arsize[s]; assign s_arburst[s] = t_arburst[s]; assign s_arlock[s] = t_arlock[s];
    assign s_arcache[s] = t_arcache[s]; assign s_arprot[s] = t_arprot[s]; assign s_arqos[s] = t_arqos[s];
    assign s_arvalid[s] = t_arvalid[s]; assign t_arready[s] = s_arready[s];
    assign t_rid[s] = s_rid[s]; assign t_rdata[s] = s_rdata[s]; assign t_rresp[s] = s_rresp[s];
    assign t_rlast[s] = s_rlast[s]; assign t_rvalid[s] = s_rvalid[s]; assign s_rready[s] = t_rready[s];
  end

  axi4_default_slave #(.IDW(SIDW), .DW(DW)) u_decerr (
    .clk(clk), .rst_n(rst_n),
    .awid(t_awid[NS]), .awvalid(t_awvalid[NS]), .awready(t_awready[NS]),
    .wlast(t_wlast[NS]), .wvalid(t_wvalid[NS]), .wready(t_wready[NS]),
    .bid(t_bid[NS]), .bresp(t_bresp[NS]), .bvalid(t_bvalid[NS]), .bready(t_bready[NS]),
    .arid(t_arid[NS]), .arlen(t_arlen[NS]), .arvalid(t_arvalid[NS]), .arready(t_arready[NS]),
    .rid(t_rid[NS]), .rdata(t_rdata[NS]), .rresp(t_rresp[NS]), .rlast(t_rlast[NS]),
    .rvalid(t_rvalid[NS]), .rready(t_rready[NS]));

  // ------------------------------------------------------------------ decode
  function automatic logic [TW-1:0] decode(logic [AW-1:0] a);
    for (int s = 0; s < NS; s++)
      if ((a & S_MASK[s]) == S_BASE[s]) return TW'(s);
    return T_DEF;
  endfunction

  logic [NM-1:0][TW-1:0] aw_tgt, ar_tgt;
  for (genvar m = 0; m < NM; m++) begin : g_dec
    assign aw_tgt[m] = decode(m_awaddr[m]);
    assign ar_tgt[m] = decode(m_araddr[m]);
  end

  // ------------------------------------------------------------------ outstanding tracking
  logic [NM-1:0][NID-1:0][CW-1:0] wr_cnt, rd_cnt;
  logic [NM-1:0][NID-1:0][TW-1:0] wr_slv, rd_slv;
  logic [NM-1:0][CW-1:0]          wr_tot, rd_tot;
  logic [NM-1:0]                  aw_ok, ar_ok;

  for (genvar m = 0; m < NM; m++) begin : g_ok
    assign aw_ok[m] = (wr_tot[m] < CW'(MAX_OUT)) &&
                      ((wr_cnt[m][m_awid[m]] == '0) || (wr_slv[m][m_awid[m]] == aw_tgt[m]));
    assign ar_ok[m] = (rd_tot[m] < CW'(MAX_OUT)) &&
                      ((rd_cnt[m][m_arid[m]] == '0) || (rd_slv[m][m_arid[m]] == ar_tgt[m]));
  end

  // ------------------------------------------------------------------ W ordering FIFOs
  logic [NT-1:0][MW-1:0] wq_s_head;   // per target: master of the oldest accepted AW
  logic [NT-1:0]         wq_s_empty, wq_s_full, wq_s_push, wq_s_pop;
  logic [NT-1:0][MW-1:0] wq_s_din;
  logic [NM-1:0][TW-1:0] wq_m_head;   // per master: target of its oldest accepted AW
  logic [NM-1:0]         wq_m_empty, wq_m_full, wq_m_push, wq_m_pop;
  logic [NM-1:0][TW-1:0] wq_m_din;

  for (genvar t = 0; t < NT; t++) begin : g_wqs
    cf_fifo #(.W(MW), .DEPTH(MAX_OUT)) u_q (
      .clk(clk), .rst_n(rst_n), .push(wq_s_push[t]), .din(wq_s_din[t]), .pop(wq_s_pop[t]),
      .head(wq_s_head[t]), .empty(wq_s_empty[t]), .full(wq_s_full[t]));
  end
  for (genvar m = 0; m < NM; m++) begin : g_wqm
    cf_fifo #(.W(TW), .DEPTH(MAX_OUT)) u_q (
      .clk(clk), .rst_n(rst_n), .push(wq_m_push[m]), .din(wq_m_din[m]), .pop(wq_m_pop[m]),
      .head(wq_m_head[m]), .empty(wq_m_empty[m]), .full(wq_m_full[m]));
  end

  // ------------------------------------------------------------------ AW arbitration
  logic [NT-1:0][NM-1:0] aw_req, aw_gnt, ar_req, ar_gnt;
  logic [NT-1:0]         aw_hold, aw_adv, ar_hold, ar_adv;

  always_comb begin
    for (int t = 0; t < NT; t++)
      for (int m = 0; m < NM; m++) begin
        aw_req[t][m] = m_awvalid[m] && (aw_tgt[m] == TW'(t)) && aw_ok[m] && !wq_s_full[t] && !wq_m_full[m];
        ar_req[t][m] = m_arvalid[m] && (ar_tgt[m] == TW'(t)) && ar_ok[m];
      end
  end

  for (genvar t = 0; t < NT; t++) begin : g_tarb
    cf_rr_arb #(.N(NM)) u_aw (.clk(clk), .rst_n(rst_n), .req(aw_req[t]), .hold(aw_hold[t]),
                              .advance(aw_adv[t]), .gnt(aw_gnt[t]));
    cf_rr_arb #(.N(NM)) u_ar (.clk(clk), .rst_n(rst_n), .req(ar_req[t]), .hold(ar_hold[t]),
                              .advance(ar_adv[t]), .gnt(ar_gnt[t]));
    assign aw_hold[t] = t_awvalid[t] && !t_awready[t];
    assign aw_adv[t]  = t_awvalid[t] && t_awready[t];
    assign ar_hold[t] = t_arvalid[t] && !t_arready[t];
    assign ar_adv[t]  = t_arvalid[t] && t_arready[t];
  end

  always_comb begin
    m_awready = '0;
    m_arready = '0;
    wq_s_push = '0; wq_s_din = '0; wq_m_push = '0; wq_m_din = '0;
    for (int t = 0; t < NT; t++) begin
      t_awvalid[t] = 1'b0; t_awid[t] = '0; t_awaddr[t] = '0; t_awlen[t] = '0; t_awsize[t] = '0;
      t_awburst[t] = '0; t_awlock[t] = 1'b0; t_awcache[t] = '0; t_awprot[t] = '0; t_awqos[t] = '0;
      t_arvalid[t] = 1'b0; t_arid[t] = '0; t_araddr[t] = '0; t_arlen[t] = '0; t_arsize[t] = '0;
      t_arburst[t] = '0; t_arlock[t] = 1'b0; t_arcache[t] = '0; t_arprot[t] = '0; t_arqos[t] = '0;
      for (int m = 0; m < NM; m++) begin
        if (aw_gnt[t][m] && aw_req[t][m]) begin
          t_awvalid[t] = 1'b1;
          t_awid[t] = {MW'(m), m_awid[m]}; t_awaddr[t] = m_awaddr[m]; t_awlen[t] = m_awlen[m];
          t_awsize[t] = m_awsize[m]; t_awburst[t] = m_awburst[m]; t_awlock[t] = m_awlock[m];
          t_awcache[t] = m_awcache[m]; t_awprot[t] = m_awprot[m]; t_awqos[t] = m_awqos[m];
          if (t_awready[t]) begin
            m_awready[m] = 1'b1;
            wq_s_push[t] = 1'b1; wq_s_din[t] = MW'(m);
            wq_m_push[m] = 1'b1; wq_m_din[m] = TW'(t);
          end
        end
        if (ar_gnt[t][m] && ar_req[t][m]) begin
          t_arvalid[t] = 1'b1;
          t_arid[t] = {MW'(m), m_arid[m]}; t_araddr[t] = m_araddr[m]; t_arlen[t] = m_arlen[m];
          t_arsize[t] = m_arsize[m]; t_arburst[t] = m_arburst[m]; t_arlock[t] = m_arlock[m];
          t_arcache[t] = m_arcache[m]; t_arprot[t] = m_arprot[m]; t_arqos[t] = m_arqos[m];
          if (t_arready[t]) m_arready[m] = 1'b1;
        end
      end
    end
  end

  // ------------------------------------------------------------------ W routing
  always_comb begin
    m_wready = '0;
    wq_s_pop = '0;
    wq_m_pop = '0;
    for (int t = 0; t < NT; t++) begin
      t_wvalid[t] = 1'b0; t_wdata[t] = '0; t_wstrb[t] = '0; t_wlast[t] = 1'b0;
      for (int m = 0; m < NM; m++) begin
        if (!wq_s_empty[t] && (wq_s_head[t] == MW'(m)) && !wq_m_empty[m] && (wq_m_head[m] == TW'(t))) begin
          t_wvalid[t] = m_wvalid[m];
          t_wdata[t]  = m_wdata[m];
          t_wstrb[t]  = m_wstrb[m];
          t_wlast[t]  = m_wlast[m];
          m_wready[m] = t_wready[t];
          if (m_wvalid[m] && t_wready[t] && m_wlast[m]) begin
            wq_s_pop[t] = 1'b1;
            wq_m_pop[m] = 1'b1;
          end
        end
      end
    end
  end

  // ------------------------------------------------------------------ B and R return paths
  logic [NM-1:0][NT-1:0] b_req, b_gnt, r_req, r_gnt;
  logic [NM-1:0]         b_hold, b_adv, r_hold, r_adv;

  always_comb begin
    for (int m = 0; m < NM; m++)
      for (int t = 0; t < NT; t++) begin
        b_req[m][t] = t_bvalid[t] && (t_bid[t][SIDW-1:MIDW] == MW'(m));
        r_req[m][t] = t_rvalid[t] && (t_rid[t][SIDW-1:MIDW] == MW'(m));
      end
  end

  for (genvar m = 0; m < NM; m++) begin : g_marb
    cf_rr_arb #(.N(NT)) u_b (.clk(clk), .rst_n(rst_n), .req(b_req[m]), .hold(b_hold[m]),
                             .advance(b_adv[m]), .gnt(b_gnt[m]));
    cf_rr_arb #(.N(NT)) u_r (.clk(clk), .rst_n(rst_n), .req(r_req[m]), .hold(r_hold[m]),
                             .advance(r_adv[m]), .gnt(r_gnt[m]));
    assign b_hold[m] = m_bvalid[m] && !m_bready[m];
    assign b_adv[m]  = m_bvalid[m] && m_bready[m];
    // Per-beat arbitration (CF-XBAR-001): locking a master's R channel to one slave until
    // RLAST deadlocks when slaves interleave read data of different masters.
    assign r_hold[m] = m_rvalid[m] && !m_rready[m];
    assign r_adv[m]  = m_rvalid[m] && m_rready[m];
  end

  always_comb begin
    t_bready = '0;
    t_rready = '0;
    for (int m = 0; m < NM; m++) begin
      m_bvalid[m] = 1'b0; m_bid[m] = '0; m_bresp[m] = '0;
      m_rvalid[m] = 1'b0; m_rid[m] = '0; m_rdata[m] = '0; m_rresp[m] = '0; m_rlast[m] = 1'b0;
      for (int t = 0; t < NT; t++) begin
        if (b_gnt[m][t] && b_req[m][t]) begin
          m_bvalid[m] = 1'b1; m_bid[m] = t_bid[t][MIDW-1:0]; m_bresp[m] = t_bresp[t];
          t_bready[t] = m_bready[m];
        end
        if (r_gnt[m][t] && r_req[m][t]) begin
          m_rvalid[m] = 1'b1; m_rid[m] = t_rid[t][MIDW-1:0]; m_rdata[m] = t_rdata[t];
          m_rresp[m] = t_rresp[t]; m_rlast[m] = t_rlast[t];
          t_rready[t] = m_rready[m];
        end
      end
    end
  end

  // ------------------------------------------------------------------ counters
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      wr_cnt <= '0; rd_cnt <= '0; wr_slv <= '0; rd_slv <= '0; wr_tot <= '0; rd_tot <= '0;
    end else begin
      for (int m = 0; m < NM; m++) begin
        logic aw_hs, b_hs, ar_hs, r_hs;
        aw_hs = m_awvalid[m] && m_awready[m];
        b_hs  = m_bvalid[m] && m_bready[m];
        ar_hs = m_arvalid[m] && m_arready[m];
        r_hs  = m_rvalid[m] && m_rready[m] && m_rlast[m];
        wr_tot[m] <= wr_tot[m] + CW'(aw_hs) - CW'(b_hs);
        rd_tot[m] <= rd_tot[m] + CW'(ar_hs) - CW'(r_hs);
        for (int i = 0; i < NID; i++) begin
          wr_cnt[m][i] <= wr_cnt[m][i] + CW'(aw_hs && (m_awid[m] == MIDW'(i)))
                                       - CW'(b_hs && (m_bid[m] == MIDW'(i)));
          rd_cnt[m][i] <= rd_cnt[m][i] + CW'(ar_hs && (m_arid[m] == MIDW'(i)))
                                       - CW'(r_hs && (m_rid[m] == MIDW'(i)));
        end
        if (aw_hs) wr_slv[m][m_awid[m]] <= aw_tgt[m];
        if (ar_hs) rd_slv[m][m_arid[m]] <= ar_tgt[m];
      end
    end
  end
endmodule
`default_nettype wire
