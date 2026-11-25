// router_status_if.sv: SpikeMesh router status outputs watched by the router env (M5).
interface router_status_if (input logic clk, input logic rst_n);
  logic       busy;
  logic       err;
  logic [7:0] drop_cnt;
endinterface
