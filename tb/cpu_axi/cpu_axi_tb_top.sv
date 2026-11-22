// cpu_axi_tb_top.sv: Vortex-V out-of-order core (default parameters: WIDTH=1, SYNC_MEM=0) on a
// gated clock, vortex_axi_bridge, and a reactive AXI4 VIP slave as the memory (cpu_axi_env_pkg).
// +define+CPU_WIDTH2 builds the two-wide core with the bridge's second fetch port.
module cpu_axi_tb_top;
  import uvm_pkg::*;
  import cpu_axi_env_pkg::*;
`ifdef CPU_WIDTH2
  localparam int WIDTH = 2;
`else
  localparam int WIDTH = 1;
`endif

  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  // release on a falling edge, so the gated core never sees reset end and a clock edge together
  initial begin repeat (8) @(posedge clk); @(negedge clk); rst_n <= 1; end

  axi4_if #(.AW(AW), .DW(DW), .IDW(IDW)) m (.aclk(clk), .aresetn(rst_n));
  cpu_retire_if #(.XLEN(XLEN))           ret (.clk(clk), .rst_n(rst_n));

  logic            core_en, gclk;
  logic [XLEN-1:0] imem_addr, imem_addr1, dmem_addr, dmem_wdata, dmem_rdata;
  logic [31:0]     imem_rdata, imem_rdata1;
  logic            dmem_req, dmem_we;
  logic [1:0]      dmem_size;

  // the core runs freely in reset (its reset is asynchronous); afterwards one edge per step
  cf_clk_gate u_cg (.clk(clk), .en(core_en || !rst_n), .gclk(gclk));

  vortex_ooo_core #(.XLEN(XLEN), .WIDTH(WIDTH)) u_core (
    .clk(gclk), .rst_n(rst_n),
    .imem_addr(imem_addr), .imem_rdata(imem_rdata), .imem_addr1(imem_addr1), .imem_rdata1(imem_rdata1),
    .dmem_req(dmem_req), .dmem_we(dmem_we), .dmem_addr(dmem_addr), .dmem_size(dmem_size),
    .dmem_wdata(dmem_wdata), .dmem_rdata(dmem_rdata),
    .dbg_retire_valid(ret.r0_valid), .dbg_retire_pc(ret.r0_pc), .dbg_wb_valid(ret.r0_wbv),
    .dbg_wb_rd(ret.r0_rd), .dbg_wb_data(ret.r0_data), .dbg_mlstat_sat(ret.mlstat_sat),
    .dbg1_retire_valid(ret.r1_valid), .dbg1_retire_pc(ret.r1_pc), .dbg1_wb_valid(ret.r1_wbv),
    .dbg1_wb_rd(ret.r1_rd), .dbg1_wb_data(ret.r1_data));

  vortex_axi_bridge #(.XLEN(XLEN), .AW(AW), .DW(DW), .IDW(IDW), .FETCH_PORTS(WIDTH)) u_bridge (
    .clk(clk), .rst_n(rst_n), .core_clk_en(core_en),
    .imem_addr(imem_addr), .imem_rdata(imem_rdata), .imem_addr1(imem_addr1), .imem_rdata1(imem_rdata1),
    .dmem_req(dmem_req), .dmem_we(dmem_we), .dmem_addr(dmem_addr), .dmem_size(dmem_size),
    .dmem_wdata(dmem_wdata), .dmem_rdata(dmem_rdata),
    .err(ret.bridge_err), .core_cycles(ret.core_cycles),
    .m_awid(m.awid), .m_awaddr(m.awaddr), .m_awlen(m.awlen), .m_awsize(m.awsize), .m_awburst(m.awburst),
    .m_awlock(m.awlock), .m_awcache(m.awcache), .m_awprot(m.awprot), .m_awqos(m.awqos),
    .m_awvalid(m.awvalid), .m_awready(m.awready), .m_wdata(m.wdata), .m_wstrb(m.wstrb),
    .m_wlast(m.wlast), .m_wvalid(m.wvalid), .m_wready(m.wready), .m_bid(m.bid), .m_bresp(m.bresp),
    .m_bvalid(m.bvalid), .m_bready(m.bready), .m_arid(m.arid), .m_araddr(m.araddr), .m_arlen(m.arlen),
    .m_arsize(m.arsize), .m_arburst(m.arburst), .m_arlock(m.arlock), .m_arcache(m.arcache),
    .m_arprot(m.arprot), .m_arqos(m.arqos), .m_arvalid(m.arvalid), .m_arready(m.arready),
    .m_rid(m.rid), .m_rdata(m.rdata), .m_rresp(m.rresp), .m_rlast(m.rlast), .m_rvalid(m.rvalid),
    .m_rready(m.rready));
  assign ret.step = core_en;

  axi4_checker #(.AW(AW), .DW(DW), .IDW(IDW)) chk (.aclk(clk), .aresetn(rst_n),
    .awid(m.awid), .awaddr(m.awaddr), .awlen(m.awlen), .awsize(m.awsize), .awburst(m.awburst),
    .awvalid(m.awvalid), .awready(m.awready), .wdata(m.wdata), .wstrb(m.wstrb), .wlast(m.wlast),
    .wvalid(m.wvalid), .wready(m.wready), .bid(m.bid), .bresp(m.bresp), .bvalid(m.bvalid),
    .bready(m.bready), .arid(m.arid), .araddr(m.araddr), .arlen(m.arlen), .arsize(m.arsize),
    .arburst(m.arburst), .arvalid(m.arvalid), .arready(m.arready), .rid(m.rid), .rdata(m.rdata),
    .rresp(m.rresp), .rlast(m.rlast), .rvalid(m.rvalid), .rready(m.rready));

  initial begin
    uvm_config_db#(virtual axi4_if #(.AW(AW), .DW(DW), .IDW(IDW)))::set(null, "uvm_test_top.env.mem*", "vif", m);
    uvm_config_db#(virtual cpu_retire_if #(.XLEN(XLEN)))::set(null, "uvm_test_top.env*", "rvif", ret);
    run_test();
  end
endmodule
