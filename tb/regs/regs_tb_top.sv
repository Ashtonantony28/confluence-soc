// regs_tb_top.sv: M3 register bench. One AXI4-Lite or APB VIP master per CSR block, each with
// its protocol checker; hardware-side inputs of the register blocks are idle (tied to 0), so
// every field holds its reset value until software writes it.
`define CF_AXIL_PORTS(IFC) \
    .s_axil_awready(IFC.awready), .s_axil_awvalid(IFC.awvalid), .s_axil_awaddr(IFC.awaddr), \
    .s_axil_awprot(IFC.awprot), .s_axil_wready(IFC.wready), .s_axil_wvalid(IFC.wvalid), \
    .s_axil_wdata(IFC.wdata), .s_axil_wstrb(IFC.wstrb), .s_axil_bready(IFC.bready), \
    .s_axil_bvalid(IFC.bvalid), .s_axil_bresp(IFC.bresp), .s_axil_arready(IFC.arready), \
    .s_axil_arvalid(IFC.arvalid), .s_axil_araddr(IFC.araddr), .s_axil_arprot(IFC.arprot), \
    .s_axil_rready(IFC.rready), .s_axil_rvalid(IFC.rvalid), .s_axil_rdata(IFC.rdata), \
    .s_axil_rresp(IFC.rresp)
`define CF_AXIL_CHK(IFC, NAME) \
  axil_checker #(.AW(AW), .DW(DW)) NAME (.aclk(clk), .aresetn(rst_n), \
    .awaddr(IFC.awaddr), .awprot(IFC.awprot), .awvalid(IFC.awvalid), .awready(IFC.awready), \
    .wdata(IFC.wdata), .wstrb(IFC.wstrb), .wvalid(IFC.wvalid), .wready(IFC.wready), \
    .bresp(IFC.bresp), .bvalid(IFC.bvalid), .bready(IFC.bready), .araddr(IFC.araddr), \
    .arprot(IFC.arprot), .arvalid(IFC.arvalid), .arready(IFC.arready), .rdata(IFC.rdata), \
    .rresp(IFC.rresp), .rvalid(IFC.rvalid), .rready(IFC.rready))
`define CF_APB_CHK(IFC, NAME) \
  apb_checker #(.AW(AW), .DW(DW)) NAME (.pclk(clk), .presetn(rst_n), .paddr(IFC.paddr), \
    .psel(IFC.psel), .penable(IFC.penable), .pwrite(IFC.pwrite), .pwdata(IFC.pwdata), \
    .pstrb(IFC.pstrb), .pprot(IFC.pprot), .pready(IFC.pready), .prdata(IFC.prdata), \
    .pslverr(IFC.pslverr))

module regs_tb_top;
  import uvm_pkg::*;
  import regs_env_pkg::*;

  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  initial begin repeat (5) @(posedge clk); rst_n <= 1; end

  axil_if #(.AW(AW), .DW(DW)) l0 (.aclk(clk), .aresetn(rst_n));
  axil_if #(.AW(AW), .DW(DW)) l1 (.aclk(clk), .aresetn(rst_n));
  axil_if #(.AW(AW), .DW(DW)) l2 (.aclk(clk), .aresetn(rst_n));
  axil_if #(.AW(AW), .DW(DW)) l3 (.aclk(clk), .aresetn(rst_n));
  axil_if #(.AW(AW), .DW(DW)) l4 (.aclk(clk), .aresetn(rst_n));
  axil_if #(.AW(AW), .DW(DW)) l5 (.aclk(clk), .aresetn(rst_n));
  apb_if  #(.AW(AW), .DW(DW)) p0 (.pclk(clk), .presetn(rst_n));
  apb_if  #(.AW(AW), .DW(DW)) p1 (.pclk(clk), .presetn(rst_n));

  // ---------------------------------------------------------------- generated register blocks
  cf_sys_ctrl_pkg::cf_sys_ctrl__in_t           sys_in  = '{default: '0};
  cf_irq_ctrl_pkg::cf_irq_ctrl__in_t           irq_in  = '{default: '0};
  cf_timer_pkg::cf_timer__in_t                 tmr_in  = '{default: '0};
  cf_dma_csr_pkg::cf_dma_csr__in_t             dma_in  = '{default: '0};
  cf_spikemesh_ctl_pkg::cf_spikemesh_ctl__in_t sm_in   = '{default: '0};
  cf_mailbox_pkg::cf_mailbox__in_t             mbx_in  = '{default: '0};

  cf_sys_ctrl      u_sys (.clk(clk), .rst_n(rst_n), `CF_AXIL_PORTS(l0), .hwif_in(sys_in), .hwif_out());
  cf_irq_ctrl      u_irq (.clk(clk), .rst_n(rst_n), `CF_AXIL_PORTS(l1), .hwif_in(irq_in), .hwif_out());
  cf_timer         u_tmr (.clk(clk), .rst_n(rst_n), `CF_AXIL_PORTS(l2), .hwif_in(tmr_in), .hwif_out());
  cf_dma_csr       u_dma (.clk(clk), .rst_n(rst_n), `CF_AXIL_PORTS(l3), .hwif_in(dma_in), .hwif_out());
  cf_spikemesh_ctl u_sm  (.clk(clk), .rst_n(rst_n), `CF_AXIL_PORTS(l4), .hwif_in(sm_in),  .hwif_out());
  cf_mailbox       u_mbx (.clk(clk), .rst_n(rst_n),
    .s_apb_psel(p0.psel), .s_apb_penable(p0.penable), .s_apb_pwrite(p0.pwrite), .s_apb_pprot(p0.pprot),
    .s_apb_paddr(p0.paddr), .s_apb_pwdata(p0.pwdata), .s_apb_pstrb(p0.pstrb),
    .s_apb_pready(p0.pready), .s_apb_prdata(p0.prdata), .s_apb_pslverr(p0.pslverr),
    .hwif_in(mbx_in), .hwif_out());

  // ---------------------------------------------------------------- real IP CSR blocks (audit)
  csr_axil u_nxl (.clk(clk), .rst_n(rst_n),
    .s_axil_awaddr(l5.awaddr[11:0]), .s_axil_awprot(l5.awprot), .s_axil_arprot(l5.arprot),
    .s_axil_awvalid(l5.awvalid), .s_axil_awready(l5.awready), .s_axil_wdata(l5.wdata),
    .s_axil_wstrb(l5.wstrb), .s_axil_wvalid(l5.wvalid), .s_axil_wready(l5.wready),
    .s_axil_bresp(l5.bresp), .s_axil_bvalid(l5.bvalid), .s_axil_bready(l5.bready),
    .s_axil_araddr(l5.araddr[11:0]), .s_axil_arvalid(l5.arvalid), .s_axil_arready(l5.arready),
    .s_axil_rdata(l5.rdata), .s_axil_rresp(l5.rresp), .s_axil_rvalid(l5.rvalid), .s_axil_rready(l5.rready),
    .ring_base(), .ring_size(), .ring_tail(), .doorbell(), .step_mode(), .step_pulse(), .soft_req(),
    .sem_sel(), .sat_clr(), .irq(),
    .clr(1'b0), .soft_busy(1'b0), .ring_head('0), .cfg_ok(1'b0), .halted(1'b0), .err_code('0),
    .err_index('0), .err_word('0), .irq_pulse(1'b0), .irq_code('0), .end_pulse(1'b0),
    .all_idle(1'b1), .q_idle('0), .eng_busy('0), .retire_inc('0), .last_index('0),
    .q_overflow(1'b0), .sem_val('0), .dma_bytes_valid(1'b0), .dma_bytes('0), .sat_cnt('0));

  mlacc_top u_mlacc (.clk(clk), .rst_n(rst_n),
    .psel(p1.psel), .penable(p1.penable), .pwrite(p1.pwrite), .paddr(p1.paddr[11:0]),
    .pwdata(p1.pwdata), .prdata(p1.prdata), .pready(p1.pready), .pslverr(p1.pslverr),
    .cmd_valid(1'b0), .cmd_ready(), .cmd_tag('0), .cmd_op('0), .cmd_rs1('0), .cmd_rs2('0),
    .cmd_rs3('0), .rsp_valid(), .rsp_ready(1'b1), .rsp_tag(), .rsp_result(), .rsp_sat(), .irq());

  // ---------------------------------------------------------------- protocol checkers
  `CF_AXIL_CHK(l0, chk_l0);
  `CF_AXIL_CHK(l1, chk_l1);
  `CF_AXIL_CHK(l2, chk_l2);
  `CF_AXIL_CHK(l3, chk_l3);
  `CF_AXIL_CHK(l4, chk_l4);
  `CF_AXIL_CHK(l5, chk_l5);
  `CF_APB_CHK(p0, chk_p0);
  `CF_APB_CHK(p1, chk_p1);

  initial begin
    uvm_config_db#(virtual axil_if #(.AW(AW), .DW(DW)))::set(null, "uvm_test_top.env.la0*", "vif", l0);
    uvm_config_db#(virtual axil_if #(.AW(AW), .DW(DW)))::set(null, "uvm_test_top.env.la1*", "vif", l1);
    uvm_config_db#(virtual axil_if #(.AW(AW), .DW(DW)))::set(null, "uvm_test_top.env.la2*", "vif", l2);
    uvm_config_db#(virtual axil_if #(.AW(AW), .DW(DW)))::set(null, "uvm_test_top.env.la3*", "vif", l3);
    uvm_config_db#(virtual axil_if #(.AW(AW), .DW(DW)))::set(null, "uvm_test_top.env.la4*", "vif", l4);
    uvm_config_db#(virtual axil_if #(.AW(AW), .DW(DW)))::set(null, "uvm_test_top.env.la5*", "vif", l5);
    uvm_config_db#(virtual apb_if #(.AW(AW), .DW(DW)))::set(null, "uvm_test_top.env.pa0*", "vif", p0);
    uvm_config_db#(virtual apb_if #(.AW(AW), .DW(DW)))::set(null, "uvm_test_top.env.pa1*", "vif", p1);
    run_test();
  end
endmodule
