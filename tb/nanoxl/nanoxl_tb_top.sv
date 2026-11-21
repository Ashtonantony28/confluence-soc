// nanoxl_tb_top.sv: nanoxl_top (default parameters: N=8, L=4) with an AXI4-Lite VIP master on
// its CSRs and three reactive AXI4 VIP slaves on its fetch and DMA masters (nanoxl_env_pkg).
`define NXL_AXI_RD(P, IFC) \
    .P``_axi_arid(IFC.arid), .P``_axi_araddr(IFC.araddr), .P``_axi_arlen(IFC.arlen), \
    .P``_axi_arsize(IFC.arsize), .P``_axi_arburst(IFC.arburst), .P``_axi_arlock(IFC.arlock), \
    .P``_axi_arcache(IFC.arcache), .P``_axi_arprot(IFC.arprot), .P``_axi_arvalid(IFC.arvalid), \
    .P``_axi_arready(IFC.arready), .P``_axi_rid(IFC.rid), .P``_axi_rdata(IFC.rdata), \
    .P``_axi_rresp(IFC.rresp), .P``_axi_rlast(IFC.rlast), .P``_axi_rvalid(IFC.rvalid), \
    .P``_axi_rready(IFC.rready)
`define NXL_AXI_WR(P, IFC) \
    .P``_axi_awid(IFC.awid), .P``_axi_awaddr(IFC.awaddr), .P``_axi_awlen(IFC.awlen), \
    .P``_axi_awsize(IFC.awsize), .P``_axi_awburst(IFC.awburst), .P``_axi_awlock(IFC.awlock), \
    .P``_axi_awcache(IFC.awcache), .P``_axi_awprot(IFC.awprot), .P``_axi_awvalid(IFC.awvalid), \
    .P``_axi_awready(IFC.awready), .P``_axi_wdata(IFC.wdata), .P``_axi_wstrb(IFC.wstrb), \
    .P``_axi_wlast(IFC.wlast), .P``_axi_wvalid(IFC.wvalid), .P``_axi_wready(IFC.wready), \
    .P``_axi_bid(IFC.bid), .P``_axi_bresp(IFC.bresp), .P``_axi_bvalid(IFC.bvalid), \
    .P``_axi_bready(IFC.bready)
`define NXL_AXI_CHK(IFC, NAME) \
  axi4_checker #(.AW(AW), .DW(DW), .IDW(IDW)) NAME (.aclk(clk), .aresetn(rst_n), \
    .awid(IFC.awid), .awaddr(IFC.awaddr), .awlen(IFC.awlen), .awsize(IFC.awsize), \
    .awburst(IFC.awburst), .awvalid(IFC.awvalid), .awready(IFC.awready), .wdata(IFC.wdata), \
    .wstrb(IFC.wstrb), .wlast(IFC.wlast), .wvalid(IFC.wvalid), .wready(IFC.wready), \
    .bid(IFC.bid), .bresp(IFC.bresp), .bvalid(IFC.bvalid), .bready(IFC.bready), \
    .arid(IFC.arid), .araddr(IFC.araddr), .arlen(IFC.arlen), .arsize(IFC.arsize), \
    .arburst(IFC.arburst), .arvalid(IFC.arvalid), .arready(IFC.arready), .rid(IFC.rid), \
    .rdata(IFC.rdata), .rresp(IFC.rresp), .rlast(IFC.rlast), .rvalid(IFC.rvalid), \
    .rready(IFC.rready))

module nanoxl_tb_top;
  import uvm_pkg::*;
  import nanoxl_env_pkg::*;

  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  initial begin repeat (8) @(posedge clk); rst_n <= 1; end

  axil_if #(.AW(LAW), .DW(LDW))           csr (.aclk(clk), .aresetn(rst_n));
  axi4_if #(.AW(AW), .DW(DW), .IDW(IDW))  mf  (.aclk(clk), .aresetn(rst_n));
  axi4_if #(.AW(AW), .DW(DW), .IDW(IDW))  md  (.aclk(clk), .aresetn(rst_n));
  axi4_if #(.AW(AW), .DW(DW), .IDW(IDW))  md1 (.aclk(clk), .aresetn(rst_n));

  // the fetch master has no write channels
  assign mf.awid = '0;  assign mf.awaddr = '0; assign mf.awlen = '0;  assign mf.awsize = '0;
  assign mf.awburst = '0; assign mf.awlock = '0; assign mf.awcache = '0; assign mf.awprot = '0;
  assign mf.awqos = '0; assign mf.awvalid = 1'b0; assign mf.wdata = '0; assign mf.wstrb = '0;
  assign mf.wlast = 1'b0; assign mf.wvalid = 1'b0; assign mf.bready = 1'b1;
  assign mf.arqos = '0; assign md.awqos = '0; assign md.arqos = '0; assign md1.awqos = '0; assign md1.arqos = '0;

  logic irq;
  nanoxl_top u_dut (.clk(clk), .rst_n(rst_n), .irq(irq),
    .s_axil_awaddr(csr.awaddr[11:0]), .s_axil_awprot(csr.awprot), .s_axil_awvalid(csr.awvalid),
    .s_axil_awready(csr.awready), .s_axil_wdata(csr.wdata), .s_axil_wstrb(csr.wstrb),
    .s_axil_wvalid(csr.wvalid), .s_axil_wready(csr.wready), .s_axil_bresp(csr.bresp),
    .s_axil_bvalid(csr.bvalid), .s_axil_bready(csr.bready), .s_axil_araddr(csr.araddr[11:0]),
    .s_axil_arprot(csr.arprot), .s_axil_arvalid(csr.arvalid), .s_axil_arready(csr.arready),
    .s_axil_rdata(csr.rdata), .s_axil_rresp(csr.rresp), .s_axil_rvalid(csr.rvalid),
    .s_axil_rready(csr.rready),
    `NXL_AXI_RD(mf, mf),
    `NXL_AXI_WR(md, md), `NXL_AXI_RD(md, md),
    `NXL_AXI_WR(md1, md1), `NXL_AXI_RD(md1, md1));

  `NXL_AXI_CHK(mf, chk_mf);
  `NXL_AXI_CHK(md, chk_md);
  `NXL_AXI_CHK(md1, chk_md1);
  axil_checker #(.AW(LAW), .DW(LDW)) chk_csr (.aclk(clk), .aresetn(rst_n),
    .awaddr(csr.awaddr), .awprot(csr.awprot), .awvalid(csr.awvalid), .awready(csr.awready),
    .wdata(csr.wdata), .wstrb(csr.wstrb), .wvalid(csr.wvalid), .wready(csr.wready),
    .bresp(csr.bresp), .bvalid(csr.bvalid), .bready(csr.bready), .araddr(csr.araddr),
    .arprot(csr.arprot), .arvalid(csr.arvalid), .arready(csr.arready), .rdata(csr.rdata),
    .rresp(csr.rresp), .rvalid(csr.rvalid), .rready(csr.rready));

  initial begin
    uvm_config_db#(virtual axil_if #(.AW(LAW), .DW(LDW)))::set(null, "uvm_test_top.env.la*", "vif", csr);
    uvm_config_db#(virtual axi4_if #(.AW(AW), .DW(DW), .IDW(IDW)))::set(null, "uvm_test_top.env.sa0*", "vif", mf);
    uvm_config_db#(virtual axi4_if #(.AW(AW), .DW(DW), .IDW(IDW)))::set(null, "uvm_test_top.env.sa1*", "vif", md);
    uvm_config_db#(virtual axi4_if #(.AW(AW), .DW(DW), .IDW(IDW)))::set(null, "uvm_test_top.env.sa2*", "vif", md1);
    run_test();
  end
endmodule
