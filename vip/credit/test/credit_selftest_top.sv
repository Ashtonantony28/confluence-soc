// credit_selftest_top.sv: clock, reset, one credit link, the checker, and run_test().
module credit_selftest_top;
  import uvm_pkg::*;
  import credit_selftest_pkg::*;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  initial begin repeat (5) @(posedge clk); rst_n <= 1; end

  credit_if #(.DW(DW)) link (.clk(clk), .rst_n(rst_n));
  credit_checker #(.DW(DW), .DEPTH(DEPTH)) chk (.clk(clk), .rst_n(rst_n), .valid(link.valid),
    .data(link.data), .credit(link.credit));

  initial begin
    uvm_config_db#(virtual credit_if #(.DW(DW)))::set(null, "*", "vif", link);
    run_test();
  end
endmodule
