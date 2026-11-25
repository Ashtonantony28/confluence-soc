// axis_selftest_top.sv: clock, reset, one AXI4-Stream interface, the checker, and run_test().
// The packed-TKEEP rule (AXIS-R04) is on unless +AXIS_SPARSE is given (axis_sparse_test).
module axis_selftest_top;
  import uvm_pkg::*;
  import axis_selftest_pkg::*;
  logic aclk = 0, aresetn = 0;
  logic check_packed;
  always #5 aclk = ~aclk;
  initial begin repeat (5) @(posedge aclk); aresetn <= 1; end
  initial check_packed = !$test$plusargs("AXIS_SPARSE");

  axis_if #(.DW(DW), .IDW(IDW), .DESTW(DESTW), .UW(UW)) bus (.aclk(aclk), .aresetn(aresetn));

  axis_checker #(.DW(DW), .IDW(IDW), .DESTW(DESTW), .UW(UW)) chk (
    .aclk(aclk), .aresetn(aresetn), .check_packed(check_packed),
    .tdata(bus.tdata), .tkeep(bus.tkeep), .tlast(bus.tlast), .tuser(bus.tuser),
    .tid(bus.tid), .tdest(bus.tdest), .tvalid(bus.tvalid), .tready(bus.tready));

  initial begin
    uvm_config_db#(virtual axis_if #(.DW(DW), .IDW(IDW), .DESTW(DESTW), .UW(UW)))::set(null, "*", "vif", bus);
    run_test();
  end
endmodule
