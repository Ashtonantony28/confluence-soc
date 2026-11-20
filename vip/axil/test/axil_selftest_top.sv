// axil_selftest_top.sv: clock, reset, one AXI4-Lite interface, the checker, and run_test().
module axil_selftest_top;
  import uvm_pkg::*;
  import axil_selftest_pkg::*;
  logic aclk = 0, aresetn = 0;
  always #5 aclk = ~aclk;
  initial begin repeat (5) @(posedge aclk); aresetn <= 1; end

  axil_if #(.AW(AW), .DW(DW)) bus (.aclk(aclk), .aresetn(aresetn));

  axil_checker #(.AW(AW), .DW(DW)) chk (
    .aclk(aclk), .aresetn(aresetn),
    .awaddr(bus.awaddr), .awprot(bus.awprot), .awvalid(bus.awvalid), .awready(bus.awready),
    .wdata(bus.wdata), .wstrb(bus.wstrb), .wvalid(bus.wvalid), .wready(bus.wready),
    .bresp(bus.bresp), .bvalid(bus.bvalid), .bready(bus.bready),
    .araddr(bus.araddr), .arprot(bus.arprot), .arvalid(bus.arvalid), .arready(bus.arready),
    .rdata(bus.rdata), .rresp(bus.rresp), .rvalid(bus.rvalid), .rready(bus.rready));

  initial begin
    uvm_config_db#(virtual axil_if #(.AW(AW), .DW(DW)))::set(null, "*", "vif", bus);
    run_test();
  end
endmodule
