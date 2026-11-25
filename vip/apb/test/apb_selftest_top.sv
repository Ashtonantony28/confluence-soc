// apb_selftest_top.sv: clock, reset, one APB4 interface, the checker, and run_test().
module apb_selftest_top;
  import uvm_pkg::*;
  import apb_selftest_pkg::*;
  logic pclk = 0, presetn = 0;
  always #5 pclk = ~pclk;
  initial begin repeat (5) @(posedge pclk); presetn <= 1; end

  apb_if #(.AW(AW), .DW(DW)) bus (.pclk(pclk), .presetn(presetn));

  apb_checker #(.AW(AW), .DW(DW)) chk (
    .pclk(pclk), .presetn(presetn),
    .paddr(bus.paddr), .psel(bus.psel), .penable(bus.penable), .pwrite(bus.pwrite),
    .pwdata(bus.pwdata), .pstrb(bus.pstrb), .pprot(bus.pprot),
    .pready(bus.pready), .prdata(bus.prdata), .pslverr(bus.pslverr));

  initial begin
    uvm_config_db#(virtual apb_if #(.AW(AW), .DW(DW)))::set(null, "*", "vif", bus);
    run_test();
  end
endmodule
