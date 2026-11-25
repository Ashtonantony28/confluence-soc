// xbar_tb_top.sv: confluence_xbar between NM VIP masters and NS VIP slaves, with an
// axi4_checker on every port.
module xbar_tb_top;
  import uvm_pkg::*;
  import axi4_pkg::*;
  import xbar_env_pkg::*;

  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  initial begin repeat (5) @(posedge clk); rst_n <= 1; end

  axi4_if #(.AW(AW), .DW(DW), .IDW(MIDW)) m_if [NM] (.aclk(clk), .aresetn(rst_n));
  axi4_if #(.AW(AW), .DW(DW), .IDW(SIDW)) s_if [NS] (.aclk(clk), .aresetn(rst_n));

  // packed-array views of the interfaces for the crossbar ports
  logic [NM-1:0][MIDW-1:0] m_awid, m_bid, m_arid, m_rid;
  logic [NM-1:0][AW-1:0]   m_awaddr, m_araddr;
  logic [NM-1:0][7:0]      m_awlen, m_arlen;
  logic [NM-1:0][2:0]      m_awsize, m_arsize, m_awprot, m_arprot;
  logic [NM-1:0][1:0]      m_awburst, m_arburst, m_bresp, m_rresp;
  logic [NM-1:0][3:0]      m_awcache, m_arcache, m_awqos, m_arqos;
  logic [NM-1:0]           m_awlock, m_arlock, m_awvalid, m_awready, m_wlast, m_wvalid, m_wready,
                           m_bvalid, m_bready, m_arvalid, m_arready, m_rlast, m_rvalid, m_rready;
  logic [NM-1:0][DW-1:0]   m_wdata, m_rdata;
  logic [NM-1:0][DW/8-1:0] m_wstrb;
  logic [NS-1:0][SIDW-1:0] s_awid, s_bid, s_arid, s_rid;
  logic [NS-1:0][AW-1:0]   s_awaddr, s_araddr;
  logic [NS-1:0][7:0]      s_awlen, s_arlen;
  logic [NS-1:0][2:0]      s_awsize, s_arsize, s_awprot, s_arprot;
  logic [NS-1:0][1:0]      s_awburst, s_arburst, s_bresp, s_rresp;
  logic [NS-1:0][3:0]      s_awcache, s_arcache, s_awqos, s_arqos;
  logic [NS-1:0]           s_awlock, s_arlock, s_awvalid, s_awready, s_wlast, s_wvalid, s_wready,
                           s_bvalid, s_bready, s_arvalid, s_arready, s_rlast, s_rvalid, s_rready;
  logic [NS-1:0][DW-1:0]   s_wdata, s_rdata;
  logic [NS-1:0][DW/8-1:0] s_wstrb;

  for (genvar m = 0; m < NM; m++) begin : g_m
    assign m_awid[m] = m_if[m].awid; assign m_awaddr[m] = m_if[m].awaddr; assign m_awlen[m] = m_if[m].awlen;
    assign m_awsize[m] = m_if[m].awsize; assign m_awburst[m] = m_if[m].awburst; assign m_awlock[m] = m_if[m].awlock;
    assign m_awcache[m] = m_if[m].awcache; assign m_awprot[m] = m_if[m].awprot; assign m_awqos[m] = m_if[m].awqos;
    assign m_awvalid[m] = m_if[m].awvalid; assign m_if[m].awready = m_awready[m];
    assign m_wdata[m] = m_if[m].wdata; assign m_wstrb[m] = m_if[m].wstrb; assign m_wlast[m] = m_if[m].wlast;
    assign m_wvalid[m] = m_if[m].wvalid; assign m_if[m].wready = m_wready[m];
    assign m_if[m].bid = m_bid[m]; assign m_if[m].bresp = m_bresp[m]; assign m_if[m].bvalid = m_bvalid[m];
    assign m_bready[m] = m_if[m].bready;
    assign m_arid[m] = m_if[m].arid; assign m_araddr[m] = m_if[m].araddr; assign m_arlen[m] = m_if[m].arlen;
    assign m_arsize[m] = m_if[m].arsize; assign m_arburst[m] = m_if[m].arburst; assign m_arlock[m] = m_if[m].arlock;
    assign m_arcache[m] = m_if[m].arcache; assign m_arprot[m] = m_if[m].arprot; assign m_arqos[m] = m_if[m].arqos;
    assign m_arvalid[m] = m_if[m].arvalid; assign m_if[m].arready = m_arready[m];
    assign m_if[m].rid = m_rid[m]; assign m_if[m].rdata = m_rdata[m]; assign m_if[m].rresp = m_rresp[m];
    assign m_if[m].rlast = m_rlast[m]; assign m_if[m].rvalid = m_rvalid[m]; assign m_rready[m] = m_if[m].rready;
    axi4_checker #(.AW(AW), .DW(DW), .IDW(MIDW)) chk (
      .aclk(clk), .aresetn(rst_n),
      .awid(m_if[m].awid), .awaddr(m_if[m].awaddr), .awlen(m_if[m].awlen), .awsize(m_if[m].awsize), .awburst(m_if[m].awburst),
      .awvalid(m_if[m].awvalid), .awready(m_if[m].awready),
      .wdata(m_if[m].wdata), .wstrb(m_if[m].wstrb), .wlast(m_if[m].wlast), .wvalid(m_if[m].wvalid), .wready(m_if[m].wready),
      .bid(m_if[m].bid), .bresp(m_if[m].bresp), .bvalid(m_if[m].bvalid), .bready(m_if[m].bready),
      .arid(m_if[m].arid), .araddr(m_if[m].araddr), .arlen(m_if[m].arlen), .arsize(m_if[m].arsize), .arburst(m_if[m].arburst),
      .arvalid(m_if[m].arvalid), .arready(m_if[m].arready),
      .rid(m_if[m].rid), .rdata(m_if[m].rdata), .rresp(m_if[m].rresp), .rlast(m_if[m].rlast), .rvalid(m_if[m].rvalid), .rready(m_if[m].rready));
    initial uvm_config_db#(virtual axi4_if #(.AW(AW), .DW(DW), .IDW(MIDW)))::set(null, $sformatf("uvm_test_top.env.mst%0d*", m), "vif", m_if[m]);
  end

  for (genvar s = 0; s < NS; s++) begin : g_s
    assign s_if[s].awid = s_awid[s]; assign s_if[s].awaddr = s_awaddr[s]; assign s_if[s].awlen = s_awlen[s];
    assign s_if[s].awsize = s_awsize[s]; assign s_if[s].awburst = s_awburst[s]; assign s_if[s].awlock = s_awlock[s];
    assign s_if[s].awcache = s_awcache[s]; assign s_if[s].awprot = s_awprot[s]; assign s_if[s].awqos = s_awqos[s];
    assign s_if[s].awvalid = s_awvalid[s]; assign s_awready[s] = s_if[s].awready;
    assign s_if[s].wdata = s_wdata[s]; assign s_if[s].wstrb = s_wstrb[s]; assign s_if[s].wlast = s_wlast[s];
    assign s_if[s].wvalid = s_wvalid[s]; assign s_wready[s] = s_if[s].wready;
    assign s_bid[s] = s_if[s].bid; assign s_bresp[s] = s_if[s].bresp; assign s_bvalid[s] = s_if[s].bvalid;
    assign s_if[s].bready = s_bready[s];
    assign s_if[s].arid = s_arid[s]; assign s_if[s].araddr = s_araddr[s]; assign s_if[s].arlen = s_arlen[s];
    assign s_if[s].arsize = s_arsize[s]; assign s_if[s].arburst = s_arburst[s]; assign s_if[s].arlock = s_arlock[s];
    assign s_if[s].arcache = s_arcache[s]; assign s_if[s].arprot = s_arprot[s]; assign s_if[s].arqos = s_arqos[s];
    assign s_if[s].arvalid = s_arvalid[s]; assign s_arready[s] = s_if[s].arready;
    assign s_rid[s] = s_if[s].rid; assign s_rdata[s] = s_if[s].rdata; assign s_rresp[s] = s_if[s].rresp;
    assign s_rlast[s] = s_if[s].rlast; assign s_rvalid[s] = s_if[s].rvalid; assign s_if[s].rready = s_rready[s];
    axi4_checker #(.AW(AW), .DW(DW), .IDW(SIDW)) chk (
      .aclk(clk), .aresetn(rst_n),
      .awid(s_if[s].awid), .awaddr(s_if[s].awaddr), .awlen(s_if[s].awlen), .awsize(s_if[s].awsize), .awburst(s_if[s].awburst),
      .awvalid(s_if[s].awvalid), .awready(s_if[s].awready),
      .wdata(s_if[s].wdata), .wstrb(s_if[s].wstrb), .wlast(s_if[s].wlast), .wvalid(s_if[s].wvalid), .wready(s_if[s].wready),
      .bid(s_if[s].bid), .bresp(s_if[s].bresp), .bvalid(s_if[s].bvalid), .bready(s_if[s].bready),
      .arid(s_if[s].arid), .araddr(s_if[s].araddr), .arlen(s_if[s].arlen), .arsize(s_if[s].arsize), .arburst(s_if[s].arburst),
      .arvalid(s_if[s].arvalid), .arready(s_if[s].arready),
      .rid(s_if[s].rid), .rdata(s_if[s].rdata), .rresp(s_if[s].rresp), .rlast(s_if[s].rlast), .rvalid(s_if[s].rvalid), .rready(s_if[s].rready));
    initial uvm_config_db#(virtual axi4_if #(.AW(AW), .DW(DW), .IDW(SIDW)))::set(null, $sformatf("uvm_test_top.env.slv%0d*", s), "vif", s_if[s]);
  end

  confluence_xbar #(.NM(NM), .NS(NS), .AW(AW), .DW(DW), .MIDW(MIDW), .MAX_OUT(MAX_OUT),
                    .S_BASE(S_BASE), .S_MASK(S_MASK)) dut (
    .clk(clk), .rst_n(rst_n),
    .m_awid(m_awid), .m_awaddr(m_awaddr), .m_awlen(m_awlen), .m_awsize(m_awsize), .m_awburst(m_awburst),
    .m_awlock(m_awlock), .m_awcache(m_awcache), .m_awprot(m_awprot), .m_awqos(m_awqos),
    .m_awvalid(m_awvalid), .m_awready(m_awready),
    .m_wdata(m_wdata), .m_wstrb(m_wstrb), .m_wlast(m_wlast), .m_wvalid(m_wvalid), .m_wready(m_wready),
    .m_bid(m_bid), .m_bresp(m_bresp), .m_bvalid(m_bvalid), .m_bready(m_bready),
    .m_arid(m_arid), .m_araddr(m_araddr), .m_arlen(m_arlen), .m_arsize(m_arsize), .m_arburst(m_arburst),
    .m_arlock(m_arlock), .m_arcache(m_arcache), .m_arprot(m_arprot), .m_arqos(m_arqos),
    .m_arvalid(m_arvalid), .m_arready(m_arready),
    .m_rid(m_rid), .m_rdata(m_rdata), .m_rresp(m_rresp), .m_rlast(m_rlast), .m_rvalid(m_rvalid), .m_rready(m_rready),
    .s_awid(s_awid), .s_awaddr(s_awaddr), .s_awlen(s_awlen), .s_awsize(s_awsize), .s_awburst(s_awburst),
    .s_awlock(s_awlock), .s_awcache(s_awcache), .s_awprot(s_awprot), .s_awqos(s_awqos),
    .s_awvalid(s_awvalid), .s_awready(s_awready),
    .s_wdata(s_wdata), .s_wstrb(s_wstrb), .s_wlast(s_wlast), .s_wvalid(s_wvalid), .s_wready(s_wready),
    .s_bid(s_bid), .s_bresp(s_bresp), .s_bvalid(s_bvalid), .s_bready(s_bready),
    .s_arid(s_arid), .s_araddr(s_araddr), .s_arlen(s_arlen), .s_arsize(s_arsize), .s_arburst(s_arburst),
    .s_arlock(s_arlock), .s_arcache(s_arcache), .s_arprot(s_arprot), .s_arqos(s_arqos),
    .s_arvalid(s_arvalid), .s_arready(s_arready),
    .s_rid(s_rid), .s_rdata(s_rdata), .s_rresp(s_rresp), .s_rlast(s_rlast), .s_rvalid(s_rvalid), .s_rready(s_rready));

`ifdef WAVES
  // Port-level waveform for docs/media (scripts/media.py): build with
  // DEFINES="+define+WAVES --trace-fst" BUILD_TAG=waves. Depth 1 = the packed port views above.
  initial begin
    $dumpfile("build/xbar_waves.fst");
    $dumpvars(1, xbar_tb_top);
  end
`endif

  initial run_test();
endmodule
