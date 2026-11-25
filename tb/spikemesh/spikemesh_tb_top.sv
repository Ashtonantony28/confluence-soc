// spikemesh_tb_top.sv: spikemesh_top configured for the trained 256-256-10 network (the
// parameters tests/system uses: RtlBackend.for_program(prog, lanes=8)).
module spikemesh_tb_top;
  import uvm_pkg::*;
  import spikemesh_env_pkg::*;

  localparam int MESH_X = 2, MESH_Y = 2, N_NEURONS = 256, N_AXONS = 256, W_BITS = 8;
  localparam int FANOUT_DEPTH = 1024, LANES = 8, FIFO_DEPTH = 4, LEARN_MODE = 1;

  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  initial begin repeat (5) @(posedge clk); rst_n <= 1; end

  axis_if #(.DW(FW))   hin  (.aclk(clk), .aresetn(rst_n));
  axis_if #(.DW(FW))   hout (.aclk(clk), .aresetn(rst_n));
  spikemesh_ctrl_if    ctl  (.clk(clk), .rst_n(rst_n));

  assign hout.tkeep = '1;
  assign hout.tlast = 1'b1;          // each flit is its own packet
  assign hout.tuser = '0; assign hout.tid = '0; assign hout.tdest = '0;

  spikemesh_top #(.MESH_X(MESH_X), .MESH_Y(MESH_Y), .N_NEURONS(N_NEURONS), .N_AXONS(N_AXONS),
                  .W_BITS(W_BITS), .FANOUT_DEPTH(FANOUT_DEPTH), .LANES(LANES), .FIFO_DEPTH(FIFO_DEPTH),
                  .LEARN_MASK('0), .LEARN_MODE(LEARN_MODE)) u_dut (
    .clk(clk), .rst_n(rst_n),
    .host_in_valid(hin.tvalid), .host_in_ready(hin.tready), .host_in_flit(hin.tdata),
    .host_out_valid(hout.tvalid), .host_out_ready(hout.tready), .host_out_flit(hout.tdata),
    .step(ctl.step), .step_done(ctl.step_done), .t_parity(ctl.t_parity),
    .err(ctl.err), .drop_cnt(ctl.drop_cnt), .busy(ctl.busy), .drained(ctl.drained));

  axis_checker #(.DW(FW)) chk_in (.aclk(clk), .aresetn(rst_n), .check_packed(1'b0),
    .tdata(hin.tdata), .tkeep(hin.tkeep), .tlast(hin.tlast), .tuser(hin.tuser), .tid(hin.tid),
    .tdest(hin.tdest), .tvalid(hin.tvalid), .tready(hin.tready));
  axis_checker #(.DW(FW)) chk_out (.aclk(clk), .aresetn(rst_n), .check_packed(1'b0),
    .tdata(hout.tdata), .tkeep(hout.tkeep), .tlast(hout.tlast), .tuser(hout.tuser), .tid(hout.tid),
    .tdest(hout.tdest), .tvalid(hout.tvalid), .tready(hout.tready));

  initial begin
    uvm_config_db#(virtual axis_if #(.DW(FW)))::set(null, "uvm_test_top.env.ia*", "vif", hin);
    uvm_config_db#(virtual axis_if #(.DW(FW)))::set(null, "uvm_test_top.env.oa*", "vif", hout);
    uvm_config_db#(ctrl_vif_t)::set(null, "uvm_test_top.env", "cvif", ctl);
    run_test();
  end
endmodule
