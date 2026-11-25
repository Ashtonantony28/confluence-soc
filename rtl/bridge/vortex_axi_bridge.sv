// vortex_axi_bridge.sv: Vortex-V core memory ports (M1-INTERFACE v1/v1.1, SYNC_MEM=0) -> one
// AXI4 master (ADR 0006). The core runs on core_clk_en through cf_clk_gate; between two core
// edges the bridge fetches the instruction word(s), waits for the core's combinational data
// request, performs it, then enables one core edge with every read value held stable. Single
// beat, one transaction outstanding, uncached. Error responses read as 0 and set err.
`default_nettype none
module vortex_axi_bridge #(
  parameter int XLEN        = 64,
  parameter int AW          = 32,
  parameter int DW          = 64,     // AXI data width, >= XLEN, power of 2
  parameter int IDW         = 4,
  parameter int FETCH_PORTS = 1,      // 2: also serve imem_addr1 (core WIDTH=2)
  parameter logic [IDW-1:0] ID_FETCH = '0,
  parameter logic [IDW-1:0] ID_DATA  = IDW'(1)
) (
  input  logic             clk,
  input  logic             rst_n,
  // core side
  output logic             core_clk_en,   // one core edge at the end of this cycle
  input  logic [XLEN-1:0]  imem_addr,
  output logic [31:0]      imem_rdata,
  input  logic [XLEN-1:0]  imem_addr1,
  output logic [31:0]      imem_rdata1,
  input  logic             dmem_req,
  input  logic             dmem_we,
  input  logic [XLEN-1:0]  dmem_addr,
  input  logic [1:0]       dmem_size,
  input  logic [XLEN-1:0]  dmem_wdata,
  output logic [XLEN-1:0]  dmem_rdata,
  // status
  output logic             err,           // sticky: an access got SLVERR/DECERR or was misaligned
  output logic [31:0]      core_cycles,   // core edges since reset
  // AXI4 master
  output logic [IDW-1:0]   m_awid,
  output logic [AW-1:0]    m_awaddr,
  output logic [7:0]       m_awlen,
  output logic [2:0]       m_awsize,
  output logic [1:0]       m_awburst,
  output logic             m_awlock,
  output logic [3:0]       m_awcache,
  output logic [2:0]       m_awprot,
  output logic [3:0]       m_awqos,
  output logic             m_awvalid,
  input  logic             m_awready,
  output logic [DW-1:0]    m_wdata,
  output logic [DW/8-1:0]  m_wstrb,
  output logic             m_wlast,
  output logic             m_wvalid,
  input  logic             m_wready,
  input  logic [IDW-1:0]   m_bid,
  input  logic [1:0]       m_bresp,
  input  logic             m_bvalid,
  output logic             m_bready,
  output logic [IDW-1:0]   m_arid,
  output logic [AW-1:0]    m_araddr,
  output logic [7:0]       m_arlen,
  output logic [2:0]       m_arsize,
  output logic [1:0]       m_arburst,
  output logic             m_arlock,
  output logic [3:0]       m_arcache,
  output logic [2:0]       m_arprot,
  output logic [3:0]       m_arqos,
  output logic             m_arvalid,
  input  logic             m_arready,
  input  logic [IDW-1:0]   m_rid,
  input  logic [DW-1:0]    m_rdata,
  input  logic [1:0]       m_rresp,
  input  logic             m_rlast,
  input  logic             m_rvalid,
  output logic             m_rready
);
  localparam int NB     = DW / 8;
  localparam int OFFW   = $clog2(NB);
  localparam int IBYTES = 4;
  localparam logic [2:0] SIZE_INST  = 3'd2;      // 4-byte instruction fetch
  localparam logic [1:0] BURST_INCR = 2'b01;
  localparam logic [1:0] RESP_OKAY  = 2'b00;
  localparam logic [2:0] PROT_DATA  = 3'b000;    // unprivileged, secure, data
  localparam logic [2:0] PROT_INST  = 3'b100;    // unprivileged, secure, instruction
  localparam logic [3:0] CACHE_DEV  = 4'b0000;   // device non-bufferable: uncached

  initial begin
    if (DW < XLEN || (DW & (DW - 1)) != 0) $fatal(1, "vortex_axi_bridge: DW must be a power of 2 >= XLEN");
    if (FETCH_PORTS != 1 && FETCH_PORTS != 2) $fatal(1, "vortex_axi_bridge: FETCH_PORTS must be 1 or 2");
  end

  typedef enum logic [3:0] {
    S_RESET, S_FETCH0, S_FETCH0_R, S_FETCH1, S_FETCH1_R, S_SETTLE, S_DATA, S_LOAD_R, S_STORE, S_STORE_B, S_STEP
  } state_e;
  state_e st;

  // ---- request held for the data phase (captured at S_SETTLE -> S_DATA) ----
  logic [XLEN-1:0] d_addr, d_wdata;
  logic [1:0]      d_size;
  logic            aw_done, w_done;

  // natural alignment: the access fits in one beat lane window (core accesses are aligned)
  function automatic logic misaligned(input logic [XLEN-1:0] a, input logic [1:0] sz);
    logic [XLEN-1:0] mask;
    mask = (XLEN'(1) << sz) - XLEN'(1);
    return (a & mask) != '0;
  endfunction

  /* verilator lint_off UNUSEDSIGNAL */   // only the lane bits of the address matter
  function automatic logic [OFFW-1:0] lane(input logic [XLEN-1:0] a);
    return a[OFFW-1:0];
  endfunction
  /* verilator lint_on UNUSEDSIGNAL */

  // ---- AXI constant fields ----
  assign m_awid = ID_DATA;  assign m_awlen = '0; assign m_awburst = BURST_INCR; assign m_awlock = 1'b0;
  assign m_awcache = CACHE_DEV; assign m_awprot = PROT_DATA; assign m_awqos = '0;
  assign m_arlen = '0; assign m_arburst = BURST_INCR; assign m_arlock = 1'b0;
  assign m_arcache = CACHE_DEV; assign m_arqos = '0;
  assign m_wlast = 1'b1;
  assign m_bready = (st == S_STORE_B);
  assign m_rready = (st == S_FETCH0_R) || (st == S_FETCH1_R) || (st == S_LOAD_R);
  assign core_clk_en = (st == S_STEP);

  // ---- read address channel: one of three requests, held until accepted ----
  always_comb begin
    m_arvalid = 1'b0; m_araddr = '0; m_arsize = SIZE_INST; m_arid = ID_FETCH; m_arprot = PROT_INST;
    unique case (st)
      S_FETCH0: begin m_arvalid = 1'b1; m_araddr = AW'(imem_addr);  end
      S_FETCH1: begin m_arvalid = 1'b1; m_araddr = AW'(imem_addr1); end
      S_DATA:   if (dmem_req && !dmem_we && !misaligned(d_addr, d_size)) begin
                  m_arvalid = 1'b1; m_araddr = AW'(d_addr); m_arsize = {1'b0, d_size};
                  m_arid = ID_DATA; m_arprot = PROT_DATA;
                end
      default: ;
    endcase
  end

  // ---- write channels (S_STORE: AW and W offered together, each held until taken) ----
  assign m_awvalid = (st == S_STORE) && !aw_done;
  assign m_awaddr  = AW'(d_addr);
  assign m_awsize  = {1'b0, d_size};
  assign m_wvalid  = (st == S_STORE) && !w_done;
  assign m_wdata   = DW'(d_wdata) << {lane(d_addr), 3'b000};
`ifdef MUTANT_VXB_WSTRB_FULL
  assign m_wstrb   = '1;                                    // mutant: every lane written
`else
  assign m_wstrb   = NB'(((1 << (1 << d_size)) - 1) << lane(d_addr));
`endif

  // ---- read data: the addressed bytes in the low bits ----
  logic [DW-1:0] r_shift;
  assign r_shift = m_rdata >> {lane(st == S_LOAD_R ? d_addr : (st == S_FETCH1_R ? imem_addr1 : imem_addr)), 3'b000};

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st          <= S_RESET;         // no valid until the first edge after reset (AXI A3.1.2)
      imem_rdata  <= '0;
      imem_rdata1 <= '0;
      dmem_rdata  <= '0;
      d_addr      <= '0;
      d_wdata     <= '0;
      d_size      <= '0;
      aw_done     <= 1'b0;
      w_done      <= 1'b0;
      err         <= 1'b0;
      core_cycles <= '0;
    end else begin
      unique case (st)
        S_RESET:    st <= S_FETCH0;
        S_FETCH0:   if (m_arready) st <= S_FETCH0_R;
        S_FETCH0_R: if (m_rvalid) begin
                      imem_rdata <= (m_rresp == RESP_OKAY) ? r_shift[IBYTES*8-1:0] : '0;
                      if (m_rresp != RESP_OKAY) err <= 1'b1;
                      st <= (FETCH_PORTS == 2) ? S_FETCH1 : S_SETTLE;
                    end
        S_FETCH1:   if (m_arready) st <= S_FETCH1_R;
        S_FETCH1_R: if (m_rvalid) begin
`ifdef MUTANT_VXB_FETCH1_STALE
                      imem_rdata1 <= imem_rdata;                                     // mutant
`else
                      imem_rdata1 <= (m_rresp == RESP_OKAY) ? r_shift[IBYTES*8-1:0] : '0;
`endif
                      if (m_rresp != RESP_OKAY) err <= 1'b1;
                      st <= S_SETTLE;
                    end
        // the core's data request depends combinationally on the fetched word: let it settle
`ifdef MUTANT_VXB_STALE_REQ
        S_SETTLE:   st <= S_DATA;                                // mutant: request from the previous cycle
`else
        S_SETTLE:   begin
                      d_addr <= dmem_addr; d_wdata <= dmem_wdata; d_size <= dmem_size;
                      st <= S_DATA;
                    end
`endif
        S_DATA:     if (!dmem_req) st <= S_STEP;
                    else if (misaligned(d_addr, d_size)) begin
                      err <= 1'b1; dmem_rdata <= '0; st <= S_STEP;
                    end else if (dmem_we) begin
                      aw_done <= 1'b0; w_done <= 1'b0; st <= S_STORE;
                    end else if (m_arready) st <= S_LOAD_R;
        S_LOAD_R:   if (m_rvalid) begin
`ifdef MUTANT_VXB_NO_LANE_SHIFT
                      dmem_rdata <= (m_rresp == RESP_OKAY) ? m_rdata[XLEN-1:0] : '0;   // mutant
`else
                      dmem_rdata <= (m_rresp == RESP_OKAY) ? r_shift[XLEN-1:0] : '0;
`endif
                      if (m_rresp != RESP_OKAY) err <= 1'b1;
                      st <= S_STEP;
                    end
        S_STORE:    begin
                      if (m_awready) aw_done <= 1'b1;
                      if (m_wready)  w_done  <= 1'b1;
`ifdef MUTANT_VXB_POSTED_WRITE
                      if ((aw_done || m_awready) && (w_done || m_wready)) st <= S_STEP;   // mutant: no wait for B
`else
                      if ((aw_done || m_awready) && (w_done || m_wready)) st <= S_STORE_B;
`endif
                    end
        S_STORE_B:  if (m_bvalid) begin
                      if (m_bresp != RESP_OKAY) err <= 1'b1;
                      st <= S_STEP;
                    end
        S_STEP:     begin
                      core_cycles <= core_cycles + 32'd1;
`ifdef MUTANT_VXB_DOUBLE_STEP
                      st <= (core_cycles[3:0] == 4'hF) ? S_STEP : S_FETCH0;   // mutant: sometimes two edges
`else
                      st <= S_FETCH0;
`endif
                    end
        default:    st <= S_FETCH0;
      endcase
    end
  end

  /* verilator lint_off UNUSEDSIGNAL */
  logic unused;
  assign unused = ^{m_bid, m_rid, m_rlast, r_shift};
  /* verilator lint_on UNUSEDSIGNAL */
endmodule
`default_nettype wire
