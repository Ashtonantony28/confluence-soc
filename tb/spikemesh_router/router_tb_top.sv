// router_tb_top.sv: two SpikeMesh routers of a 3x3 mesh under test at once, each with its own
// router_env: the centre router (1,1), where all five ports carry traffic, and the corner
// router (0,0), whose W port is the host link (host-bound flits leave there).
module router_tb_top;
  import uvm_pkg::*;
  import router_env_pkg::*;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  initial begin repeat (5) @(posedge clk); rst_n <= 1; end

  router_harness #(.X(1), .Y(1), .MESH_X(3), .MESH_Y(3), .FIFO_DEPTH(4), .ENV("uvm_test_top.rc")) h_centre (
    .clk(clk), .rst_n(rst_n));
  router_harness #(.X(0), .Y(0), .MESH_X(3), .MESH_Y(3), .FIFO_DEPTH(4), .ENV("uvm_test_top.rh")) h_corner (
    .clk(clk), .rst_n(rst_n));

  initial begin
    #0;              // let the harness initial blocks publish their interfaces first (same time step)
    run_test();
  end
endmodule
