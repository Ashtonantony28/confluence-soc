// spikemesh_ctrl_if.sv: the step protocol and status pins of spikemesh_top (SPEC sec. 3, 8),
// driven and sampled by the SpikeMesh env through a virtual interface.
interface spikemesh_ctrl_if (input logic clk, input logic rst_n);
  logic       step;
  logic       step_done;
  logic       t_parity;
  logic       err;
  logic [7:0] drop_cnt;
  logic       busy;
  logic       drained;
endinterface
