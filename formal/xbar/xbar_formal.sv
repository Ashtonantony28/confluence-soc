// xbar_formal.sv: formal harness for confluence_xbar (M2). NM=2 masters, NS=2 slaves,
// narrow widths. Masters and slaves are unconstrained except for the AXI4 rules they must
// obey (assumptions); the crossbar's outputs are checked against the properties below.
// Run: sby -f formal/xbar/xbar.sby   (prove = k-induction, bmc = bounded check)
module xbar_formal (input clk);
  localparam NM = 2, NS = 2, AW = 8, DW = 8, MIDW = 1, MAX_OUT = 2;
  localparam MW = 1, SIDW = MIDW + MW, SW = DW / 8, NID = 2;
  // S0: 0x00-0x3F, S1: 0x40-0x7F, 0x80-0xFF unmapped (DECERR)
  localparam [NS*AW-1:0] S_BASE = {8'h40, 8'h00};
  localparam [NS*AW-1:0] S_MASK = {8'hC0, 8'hC0};

  reg rst_n = 1'b0;
  reg init = 1'b1;
  always @(posedge clk) begin init <= 1'b0; rst_n <= 1'b1; end

  // ---------------------------------------------------------------- free inputs
  (* anyseq *) wire [NM*MIDW-1:0] m_awid, m_arid;
  (* anyseq *) wire [NM*AW-1:0]   m_awaddr, m_araddr;
  (* anyseq *) wire [NM*8-1:0]    m_awlen, m_arlen;
  (* anyseq *) wire [NM-1:0]      m_awvalid, m_wvalid, m_wlast, m_bready, m_arvalid, m_rready;
  (* anyseq *) wire [NM*DW-1:0]   m_wdata;
  (* anyseq *) wire [NS-1:0]      s_awready, s_wready, s_bvalid, s_arready, s_rvalid, s_rlast;
  (* anyseq *) wire [NS*SIDW-1:0] s_bid, s_rid;
  (* anyseq *) wire [NS*2-1:0]    s_bresp, s_rresp;
  (* anyseq *) wire [NS*DW-1:0]   s_rdata;

  wire [NM-1:0] m_awready, m_wready, m_bvalid, m_arready, m_rvalid, m_rlast;
  wire [NM*MIDW-1:0] m_bid, m_rid;
  wire [NS-1:0] s_awvalid, s_wvalid, s_wlast, s_bready, s_arvalid, s_rready;
  wire [NS*SIDW-1:0] s_awid, s_arid;
  wire [NS*AW-1:0] s_awaddr, s_araddr;
  wire [NS*8-1:0] s_awlen, s_arlen;
  wire [NS*DW-1:0] s_wdata;

  confluence_xbar #(.NM(NM), .NS(NS), .AW(AW), .DW(DW), .MIDW(MIDW), .MAX_OUT(MAX_OUT),
                    .S_BASE(S_BASE), .S_MASK(S_MASK)) dut (
    .clk(clk), .rst_n(rst_n),
    .m_awid(m_awid), .m_awaddr(m_awaddr), .m_awlen(m_awlen), .m_awsize({NM{3'd0}}), .m_awburst({NM{2'd1}}),
    .m_awlock({NM{1'b0}}), .m_awcache({NM{4'd0}}), .m_awprot({NM{3'd0}}), .m_awqos({NM{4'd0}}),
    .m_awvalid(m_awvalid), .m_awready(m_awready),
    .m_wdata(m_wdata), .m_wstrb({NM{1'b1}}), .m_wlast(m_wlast), .m_wvalid(m_wvalid), .m_wready(m_wready),
    .m_bid(m_bid), .m_bresp(), .m_bvalid(m_bvalid), .m_bready(m_bready),
    .m_arid(m_arid), .m_araddr(m_araddr), .m_arlen(m_arlen), .m_arsize({NM{3'd0}}), .m_arburst({NM{2'd1}}),
    .m_arlock({NM{1'b0}}), .m_arcache({NM{4'd0}}), .m_arprot({NM{3'd0}}), .m_arqos({NM{4'd0}}),
    .m_arvalid(m_arvalid), .m_arready(m_arready),
    .m_rid(m_rid), .m_rdata(), .m_rresp(), .m_rlast(m_rlast), .m_rvalid(m_rvalid), .m_rready(m_rready),
    .s_awid(s_awid), .s_awaddr(s_awaddr), .s_awlen(s_awlen), .s_awsize(), .s_awburst(), .s_awlock(),
    .s_awcache(), .s_awprot(), .s_awqos(), .s_awvalid(s_awvalid), .s_awready(s_awready),
    .s_wdata(s_wdata), .s_wstrb(), .s_wlast(s_wlast), .s_wvalid(s_wvalid), .s_wready(s_wready),
    .s_bid(s_bid), .s_bresp(s_bresp), .s_bvalid(s_bvalid), .s_bready(s_bready),
    .s_arid(s_arid), .s_araddr(s_araddr), .s_arlen(s_arlen), .s_arsize(), .s_arburst(), .s_arlock(),
    .s_arcache(), .s_arprot(), .s_arqos(), .s_arvalid(s_arvalid), .s_arready(s_arready),
    .s_rid(s_rid), .s_rdata(s_rdata), .s_rresp(s_rresp), .s_rlast(s_rlast), .s_rvalid(s_rvalid), .s_rready(s_rready));

  function [1:0] dec(input [AW-1:0] a);
    dec = (a[7:6] == 2'b00) ? 2'd0 : (a[7:6] == 2'b01) ? 2'd1 : 2'd2;
  endfunction

  // ---------------------------------------------------------------- reference counters
  // Flattened 4-bit counters (Yosys-friendly):
  //   WO/RO(m,id,t): outstanding per (master, id, target) seen at the master ports
  //   SP(s,x): AWs a slave accepted whose WLAST it has not seen; SR(s,x): writes it owes a B
  //   SD(s,x): reads it owes; SL(s,x): beats left minus one in the oldest read of that ID
  // with x = {master, id} = the slave-side ID. Target 2 is the DECERR slave.
  localparam NX = NM * NID;
  reg [4*NM*NID*3-1:0] wo, ro, wo_n, ro_n;
  reg [4*NS*NX-1:0]    sp, sr, sd, sp_n, sr_n, sd_n;
  reg [8*NS*NX-1:0]    sl, sl_n;
  function integer kmt(input integer mm, input integer ii, input integer tt); kmt = (mm * NID + ii) * 3 + tt; endfunction
  function integer ksx(input integer ss, input integer xx); ksx = ss * NX + xx; endfunction
  `define WO(mm,ii,tt) wo[4*kmt(mm,ii,tt) +: 4]
  `define RO(mm,ii,tt) ro[4*kmt(mm,ii,tt) +: 4]
  `define SP(ss,xx) sp[4*ksx(ss,xx) +: 4]
  `define SR(ss,xx) sr[4*ksx(ss,xx) +: 4]
  `define SD(ss,xx) sd[4*ksx(ss,xx) +: 4]
  `define SL(ss,xx) sl[8*ksx(ss,xx) +: 8]

  integer m, i, t, s;   // used only by the bookkeeping block below

  // ---------------------------------------------------------------- environment assumptions
  // Masters: AXI handshake rules on their outputs; one AW in flight per (master, id) keeps
  // the reference model small (multiple IDs and masters still overlap).
  generate genvar gm;
  for (gm = 0; gm < NM; gm = gm + 1) begin : g_m_assume
    always @(posedge clk) if (!init) begin
      if ($past(m_awvalid[gm] && !m_awready[gm] && rst_n))
        assume (m_awvalid[gm] && m_awid[gm*MIDW +: MIDW] == $past(m_awid[gm*MIDW +: MIDW]) &&
                m_awaddr[gm*AW +: AW] == $past(m_awaddr[gm*AW +: AW]) && m_awlen[gm*8 +: 8] == $past(m_awlen[gm*8 +: 8]));
      if ($past(m_wvalid[gm] && !m_wready[gm] && rst_n))
        assume (m_wvalid[gm] && m_wlast[gm] == $past(m_wlast[gm]) && m_wdata[gm*DW +: DW] == $past(m_wdata[gm*DW +: DW]));
      if ($past(m_arvalid[gm] && !m_arready[gm] && rst_n))
        assume (m_arvalid[gm] && m_arid[gm*MIDW +: MIDW] == $past(m_arid[gm*MIDW +: MIDW]) &&
                m_araddr[gm*AW +: AW] == $past(m_araddr[gm*AW +: AW]) && m_arlen[gm*8 +: 8] == $past(m_arlen[gm*8 +: 8]));
    end
    // Short bursts keep the state space small.
    always @* begin
      assume (m_awlen[gm*8 +: 8] <= 8'd1);
      assume (m_arlen[gm*8 +: 8] == 8'd0);   // single-beat reads; several per ID may be outstanding
    end
  end
  endgenerate

  genvar gs;
  generate for (gs = 0; gs < NS; gs = gs + 1) begin : g_s_assume
    always @(posedge clk) if (!init) begin
      if ($past(s_bvalid[gs] && !s_bready[gs] && rst_n))
        assume (s_bvalid[gs] && s_bid[gs*SIDW +: SIDW] == $past(s_bid[gs*SIDW +: SIDW]) && s_bresp[gs*2 +: 2] == $past(s_bresp[gs*2 +: 2]));
      if ($past(s_rvalid[gs] && !s_rready[gs] && rst_n))
        assume (s_rvalid[gs] && s_rid[gs*SIDW +: SIDW] == $past(s_rid[gs*SIDW +: SIDW]) &&
                s_rlast[gs] == $past(s_rlast[gs]) && s_rdata[gs*DW +: DW] == $past(s_rdata[gs*DW +: DW]));
    end
    // Slaves respond only to what they owe: B after AW and WLAST, R for an outstanding read
    // with RLAST on the right beat.
    always @* begin
      if (s_bvalid[gs]) assume (`SR(gs, s_bid[gs*SIDW +: SIDW]) != 0);
      if (s_rvalid[gs]) begin
        assume (`SD(gs, s_rid[gs*SIDW +: SIDW]) != 0);
        assume (s_rlast[gs] == (`SL(gs, s_rid[gs*SIDW +: SIDW]) == 0));
      end
    end
  end endgenerate

  always @* if (!rst_n) begin
    assume (m_awvalid == 0); assume (m_wvalid == 0); assume (m_arvalid == 0);
    assume (s_bvalid == 0); assume (s_rvalid == 0);
  end

  // ---------------------------------------------------------------- properties
  generate for (gs = 0; gs < NS; gs = gs + 1) begin : g_s_prop
    // P1: crossbar holds AW/AR/W valid and payload toward each slave until accepted.
    always @(posedge clk) if (!init && rst_n && $past(rst_n)) begin
      if ($past(s_awvalid[gs] && !s_awready[gs]))
        assert (s_awvalid[gs] && s_awid[gs*SIDW +: SIDW] == $past(s_awid[gs*SIDW +: SIDW]) &&
                s_awaddr[gs*AW +: AW] == $past(s_awaddr[gs*AW +: AW]) && s_awlen[gs*8 +: 8] == $past(s_awlen[gs*8 +: 8]));
      if ($past(s_arvalid[gs] && !s_arready[gs]))
        assert (s_arvalid[gs] && s_arid[gs*SIDW +: SIDW] == $past(s_arid[gs*SIDW +: SIDW]) &&
                s_araddr[gs*AW +: AW] == $past(s_araddr[gs*AW +: AW]));
      if ($past(s_wvalid[gs] && !s_wready[gs]))
        assert (s_wvalid[gs] && s_wdata[gs*DW +: DW] == $past(s_wdata[gs*DW +: DW]) && s_wlast[gs] == $past(s_wlast[gs]));
    end
    // P2: a request reaches only the slave its address decodes to.
    always @* begin
      if (s_awvalid[gs]) assert (dec(s_awaddr[gs*AW +: AW]) == gs);
      if (s_arvalid[gs]) assert (dec(s_araddr[gs*AW +: AW]) == gs);
    end
    // P3: an AW/AR accepted by a slave was accepted from the master named in the ID upper
    // bits, in the same cycle, with the same ID and address (no loss, no invention).
    always @* if (rst_n) begin
      if (s_awvalid[gs] && s_awready[gs])
        assert (m_awvalid[s_awid[gs*SIDW+MIDW]] && m_awready[s_awid[gs*SIDW+MIDW]] &&
                m_awid[s_awid[gs*SIDW+MIDW]*MIDW +: MIDW] == s_awid[gs*SIDW +: MIDW] &&
                m_awaddr[s_awid[gs*SIDW+MIDW]*AW +: AW] == s_awaddr[gs*AW +: AW]);
      if (s_arvalid[gs] && s_arready[gs])
        assert (m_arvalid[s_arid[gs*SIDW+MIDW]] && m_arready[s_arid[gs*SIDW+MIDW]] &&
                m_arid[s_arid[gs*SIDW+MIDW]*MIDW +: MIDW] == s_arid[gs*SIDW +: MIDW]);
    end
  end endgenerate

  generate for (gm = 0; gm < NM; gm = gm + 1) begin : g_m_prop
    // P4: B/R toward a master held stable until accepted.
    always @(posedge clk) if (!init && rst_n && $past(rst_n)) begin
      if ($past(m_bvalid[gm] && !m_bready[gm]))
        assert (m_bvalid[gm] && m_bid[gm*MIDW +: MIDW] == $past(m_bid[gm*MIDW +: MIDW]));
      if ($past(m_rvalid[gm] && !m_rready[gm]))
        assert (m_rvalid[gm] && m_rid[gm*MIDW +: MIDW] == $past(m_rid[gm*MIDW +: MIDW]) && m_rlast[gm] == $past(m_rlast[gm]));
    end
    // P5: a master only gets responses for IDs it has outstanding.
    always @* if (rst_n) begin
      if (m_bvalid[gm]) assert (`WO(gm, m_bid[gm*MIDW +: MIDW], 0) + `WO(gm, m_bid[gm*MIDW +: MIDW], 1) +
                                `WO(gm, m_bid[gm*MIDW +: MIDW], 2) != 0);
      if (m_rvalid[gm]) assert (`RO(gm, m_rid[gm*MIDW +: MIDW], 0) + `RO(gm, m_rid[gm*MIDW +: MIDW], 1) +
                                `RO(gm, m_rid[gm*MIDW +: MIDW], 2) != 0);
    end
    // P6: same-ID ordering rule: outstanding transactions of one (master, id) sit at one target.
    for (genvar gi = 0; gi < NID; gi = gi + 1) begin : g_id
      always @* if (rst_n) begin
        assert (((`WO(gm, gi, 0) != 0) + (`WO(gm, gi, 1) != 0) + (`WO(gm, gi, 2) != 0)) <= 1);
        assert (((`RO(gm, gi, 0) != 0) + (`RO(gm, gi, 1) != 0) + (`RO(gm, gi, 2) != 0)) <= 1);
      end
    end
  end endgenerate

  // ---------------------------------------------------------------- reference bookkeeping
  // AW order per slave, tracked independently of the crossbar: a 4-entry shift FIFO of
  // slave-side IDs. W completion credits the head; P7 checks W routing against it.
  localparam QD = 4;
  reg [SIDW*QD-1:0] aq [0:NS-1];
  reg [2:0]         aq_n [0:NS-1];
  reg [SIDW-1:0]    wl_id [0:NS-1];
  integer ws;
  always @* for (ws = 0; ws < NS; ws = ws + 1) wl_id[ws] = aq[ws][SIDW-1:0];

  genvar gq;
  generate for (gq = 0; gq < NS; gq = gq + 1) begin : g_aq
    wire push = s_awvalid[gq] && s_awready[gq];
    wire pop  = s_wvalid[gq] && s_wready[gq] && s_wlast[gq];
    always @(posedge clk) begin
      if (!rst_n) begin aq[gq] <= 0; aq_n[gq] <= 0; end
      else begin
        case ({push, pop})
          2'b10: begin aq[gq][aq_n[gq]*SIDW +: SIDW] <= s_awid[gq*SIDW +: SIDW]; aq_n[gq] <= aq_n[gq] + 1; end
          2'b01: begin aq[gq] <= aq[gq] >> SIDW; aq_n[gq] <= aq_n[gq] - 1; end
          2'b11: begin aq[gq] <= (aq[gq] >> SIDW) | ({{(SIDW*(QD-1)){1'b0}}, s_awid[gq*SIDW +: SIDW]} << ((aq_n[gq] - 1) * SIDW)); end
          default: ;
        endcase
      end
    end
    always @* if (rst_n) begin
      assume (aq_n[gq] < QD);
      // P7: W at a slave belongs to the oldest AW it accepted: same cycle, same master, same beat.
      if (s_wvalid[gq] && s_wready[gq]) begin
        assert (aq_n[gq] != 0);
        assert (m_wvalid[wl_id[gq][SIDW-1]] && m_wready[wl_id[gq][SIDW-1]] &&
                m_wdata[wl_id[gq][SIDW-1]*DW +: DW] == s_wdata[gq*DW +: DW] &&
                m_wlast[wl_id[gq][SIDW-1]] == s_wlast[gq]);
      end
    end
  end endgenerate

  always @* begin
    wo_n = wo; ro_n = ro; sp_n = sp; sr_n = sr; sd_n = sd; sl_n = sl;
    for (m = 0; m < NM; m = m + 1) for (i = 0; i < NID; i = i + 1) for (t = 0; t < 3; t = t + 1) begin
      wo_n[4*kmt(m,i,t) +: 4] = `WO(m,i,t)
        + ((m_awvalid[m] && m_awready[m] && m_awid[m*MIDW +: MIDW] == i && dec(m_awaddr[m*AW +: AW]) == t) ? 4'd1 : 4'd0)
        - ((m_bvalid[m] && m_bready[m] && m_bid[m*MIDW +: MIDW] == i && `WO(m,i,t) != 0) ? 4'd1 : 4'd0);
      ro_n[4*kmt(m,i,t) +: 4] = `RO(m,i,t)
        + ((m_arvalid[m] && m_arready[m] && m_arid[m*MIDW +: MIDW] == i && dec(m_araddr[m*AW +: AW]) == t) ? 4'd1 : 4'd0)
        - ((m_rvalid[m] && m_rready[m] && m_rlast[m] && m_rid[m*MIDW +: MIDW] == i && `RO(m,i,t) != 0) ? 4'd1 : 4'd0);
    end
    for (s = 0; s < NS; s = s + 1) for (i = 0; i < NX; i = i + 1) begin
      sp_n[4*ksx(s,i) +: 4] = `SP(s,i)
        + ((s_awvalid[s] && s_awready[s] && s_awid[s*SIDW +: SIDW] == i) ? 4'd1 : 4'd0)
        - ((s_wvalid[s] && s_wready[s] && s_wlast[s] && wl_id[s] == i) ? 4'd1 : 4'd0);
      sr_n[4*ksx(s,i) +: 4] = `SR(s,i)
        + ((s_wvalid[s] && s_wready[s] && s_wlast[s] && wl_id[s] == i) ? 4'd1 : 4'd0)
        - ((s_bvalid[s] && s_bready[s] && s_bid[s*SIDW +: SIDW] == i) ? 4'd1 : 4'd0);
      sd_n[4*ksx(s,i) +: 4] = `SD(s,i)
        + ((s_arvalid[s] && s_arready[s] && s_arid[s*SIDW +: SIDW] == i) ? 4'd1 : 4'd0)
        - ((s_rvalid[s] && s_rready[s] && s_rlast[s] && s_rid[s*SIDW +: SIDW] == i) ? 4'd1 : 4'd0);
      // Beats left of the oldest read of this ID (bursts of one ID are served in order).
      if (s_rvalid[s] && s_rready[s] && s_rid[s*SIDW +: SIDW] == i && !s_rlast[s])
        sl_n[8*ksx(s,i) +: 8] = `SL(s,i) - 8'd1;
      else if (s_rvalid[s] && s_rready[s] && s_rid[s*SIDW +: SIDW] == i && s_rlast[s])
        sl_n[8*ksx(s,i) +: 8] = 8'd0;   // next read of this ID, if any, re-armed below
      if (s_arvalid[s] && s_arready[s] && s_arid[s*SIDW +: SIDW] == i && sd_n[4*ksx(s,i) +: 4] == 4'd1)
        sl_n[8*ksx(s,i) +: 8] = s_arlen[s*8 +: 8];
    end
  end

  always @(posedge clk) begin
    if (!rst_n) begin wo <= 0; ro <= 0; sp <= 0; sr <= 0; sd <= 0; sl <= 0; end
    else begin wo <= wo_n; ro <= ro_n; sp <= sp_n; sr <= sr_n; sd <= sd_n; sl <= sl_n; end
  end

  // Keep at most one write per (master, id) outstanding (bounds the reference model).
  generate for (gm = 0; gm < NM; gm = gm + 1) begin : g_one
    always @* if (m_awvalid[gm])
      assume (`WO(gm, m_awid[gm*MIDW +: MIDW], 0) + `WO(gm, m_awid[gm*MIDW +: MIDW], 1) +
              `WO(gm, m_awid[gm*MIDW +: MIDW], 2) == 0);
  end endgenerate

  // ---------------------------------------------------------------- covers
  always @* begin
    cover (s_awvalid[0] && s_awready[0] && s_awvalid[1] && s_awready[1]);
    cover (m_bvalid[0] && m_bready[0] && m_bvalid[1] && m_bready[1]);
    cover (m_rvalid[1] && m_rready[1] && m_rlast[1] && `RO(1, 0, 2) != 0);
  end
endmodule
