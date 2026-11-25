// axi4_selftest_top.sv: clock, reset, one AXI4 interface, the checker, and run_test().
module axi4_selftest_top;
  import uvm_pkg::*;
  import axi4_selftest_pkg::*;
  logic aclk = 0, aresetn = 0;
  always #5 aclk = ~aclk;
  initial begin repeat (5) @(posedge aclk); aresetn <= 1; end
`ifdef HEARTBEAT
  always begin #1000; $display("HB t=%0t", $time); $fflush; end
`endif

  axi4_if #(.AW(AW), .DW(DW), .IDW(IDW)) bus (.aclk(aclk), .aresetn(aresetn));

  axi4_checker #(.AW(AW), .DW(DW), .IDW(IDW)) chk (
    .aclk(aclk), .aresetn(aresetn),
    .awid(bus.awid), .awaddr(bus.awaddr), .awlen(bus.awlen), .awsize(bus.awsize), .awburst(bus.awburst),
    .awvalid(bus.awvalid), .awready(bus.awready),
    .wdata(bus.wdata), .wstrb(bus.wstrb), .wlast(bus.wlast), .wvalid(bus.wvalid), .wready(bus.wready),
    .bid(bus.bid), .bresp(bus.bresp), .bvalid(bus.bvalid), .bready(bus.bready),
    .arid(bus.arid), .araddr(bus.araddr), .arlen(bus.arlen), .arsize(bus.arsize), .arburst(bus.arburst),
    .arvalid(bus.arvalid), .arready(bus.arready),
    .rid(bus.rid), .rdata(bus.rdata), .rresp(bus.rresp), .rlast(bus.rlast), .rvalid(bus.rvalid), .rready(bus.rready));

  initial begin
    uvm_config_db#(virtual axi4_if #(.AW(AW), .DW(DW), .IDW(IDW)))::set(null, "*", "vif", bus);
    run_test();
  end
endmodule
