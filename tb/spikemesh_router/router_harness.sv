// router_harness.sv: one SpikeMesh router (rtl/noc/router.sv) at (X, Y) of a MESH_X x MESH_Y mesh,
// with VIP interfaces on every port and protocol checkers on every link:
//   N/E/S/W inputs  <- credit VIP senders     (tx0..tx3, depth = the router's input FIFO)
//   N/E/S/W outputs -> credit VIP receivers   (rx0..rx3, depth = the neighbour FIFO the router assumes)
//   L input         <- AXI4-Stream VIP master (lin, 48-bit flits, valid/ready)
//   L output        -> AXI4-Stream VIP slave  (lout)
// ENV is the UVM path of the router_env that drives it; the harness publishes its virtual
// interfaces under that path.
module router_harness #(
  parameter int    X          = 1,
  parameter int    Y          = 1,
  parameter int    MESH_X     = 3,
  parameter int    MESH_Y     = 3,
  parameter int    FIFO_DEPTH = 4,
  parameter string ENV        = "uvm_test_top.env"
) (
  input logic clk,
  input logic rst_n
);
  import uvm_pkg::*;
  localparam int FW = 48;
  localparam int NP = 4;            // credit ports N, E, S, W (router port index 0..3)
  localparam int PL = 4;            // local port index

  credit_if #(.DW(FW)) in_l  [NP] (.clk(clk), .rst_n(rst_n));
  credit_if #(.DW(FW)) out_l [NP] (.clk(clk), .rst_n(rst_n));
  axis_if   #(.DW(FW)) lin  (.aclk(clk), .aresetn(rst_n));
  axis_if   #(.DW(FW)) lout (.aclk(clk), .aresetn(rst_n));
  router_status_if     st   (.clk(clk), .rst_n(rst_n));

  logic [4:0]      in_valid, out_valid;
  logic [5*FW-1:0] in_flit, out_flit;
  logic [3:0]      credit_out, credit_in;
  logic            l_in_ready;

  genvar p;
  generate
    for (p = 0; p < NP; p++) begin : g_link
      assign in_valid[p]          = in_l[p].valid;
      assign in_flit[p*FW +: FW]  = in_l[p].data;
      assign in_l[p].credit       = credit_out[p];
      assign out_l[p].valid       = out_valid[p];
      assign out_l[p].data        = out_flit[p*FW +: FW];
      assign credit_in[p]         = out_l[p].credit;
      credit_checker #(.DW(FW), .DEPTH(FIFO_DEPTH)) chk_in (.clk(clk), .rst_n(rst_n),
        .valid(in_l[p].valid), .data(in_l[p].data), .credit(in_l[p].credit));
      credit_checker #(.DW(FW), .DEPTH(FIFO_DEPTH)) chk_out (.clk(clk), .rst_n(rst_n),
        .valid(out_l[p].valid), .data(out_l[p].data), .credit(out_l[p].credit));
      initial begin
        uvm_config_db#(virtual credit_if #(.DW(FW)))::set(null, $sformatf("%s.tx%0d*", ENV, p), "vif", in_l[p]);
        uvm_config_db#(virtual credit_if #(.DW(FW)))::set(null, $sformatf("%s.rx%0d*", ENV, p), "vif", out_l[p]);
      end
    end
  endgenerate

  assign in_valid[PL]          = lin.tvalid;
  assign in_flit[PL*FW +: FW]  = lin.tdata;
  assign lin.tready            = l_in_ready;
  assign lout.tvalid           = out_valid[PL];
  assign lout.tdata            = out_flit[PL*FW +: FW];
  assign lout.tkeep = '1; assign lout.tlast = 1'b1;      // each flit is its own packet
  assign lout.tuser = '0; assign lout.tid = '0; assign lout.tdest = '0;

  router #(.X(X), .Y(Y), .MESH_X(MESH_X), .MESH_Y(MESH_Y), .FIFO_DEPTH(FIFO_DEPTH)) u_router (
    .clk(clk), .rst_n(rst_n),
    .in_valid(in_valid), .in_flit(in_flit), .l_in_ready(l_in_ready), .credit_out(credit_out),
    .out_valid(out_valid), .out_flit(out_flit), .l_out_ready(lout.tready), .credit_in(credit_in),
    .busy(st.busy), .err(st.err), .drop_cnt(st.drop_cnt));

  axis_checker #(.DW(FW)) chk_lin (.aclk(clk), .aresetn(rst_n), .check_packed(1'b0),
    .tdata(lin.tdata), .tkeep(lin.tkeep), .tlast(lin.tlast), .tuser(lin.tuser), .tid(lin.tid),
    .tdest(lin.tdest), .tvalid(lin.tvalid), .tready(lin.tready));
  axis_checker #(.DW(FW)) chk_lout (.aclk(clk), .aresetn(rst_n), .check_packed(1'b0),
    .tdata(lout.tdata), .tkeep(lout.tkeep), .tlast(lout.tlast), .tuser(lout.tuser), .tid(lout.tid),
    .tdest(lout.tdest), .tvalid(lout.tvalid), .tready(lout.tready));

  initial begin
    uvm_config_db#(virtual axis_if #(.DW(FW)))::set(null, {ENV, ".lin*"}, "vif", lin);
    uvm_config_db#(virtual axis_if #(.DW(FW)))::set(null, {ENV, ".lout*"}, "vif", lout);
    uvm_config_db#(virtual router_status_if)::set(null, ENV, "svif", st);
  end
endmodule
