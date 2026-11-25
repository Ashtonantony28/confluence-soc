// apb_slave_driver.svh: reactive, memory-backed APB4 completer. Picks a random number of wait
// states at every SETUP, presents prdata / pslverr together with pready, and commits writes
// (honouring pstrb) when the transfer completes. Addresses in a cfg error region answer
// PSLVERR: writes are dropped and reads return zero.

class apb_slave_driver #(int AW = 32, int DW = 32) extends uvm_component;
  `uvm_component_param_utils(apb_slave_driver #(AW, DW))

  typedef virtual apb_if #(.AW(AW), .DW(DW)) vif_t;
  localparam int SW = DW / 8;

  vif_t        vif;
  apb_cfg      cfg;
  int unsigned waits_left;

  function new(string name, uvm_component parent); super.new(name, parent); endfunction

  function void build_phase(uvm_phase phase);
    if (!uvm_config_db#(vif_t)::get(this, "", "vif", vif)) `uvm_fatal("NOVIF", "apb vif not set")
    if (!uvm_config_db#(apb_cfg)::get(this, "", "cfg", cfg)) `uvm_fatal("NOCFG", "apb cfg not set")
    if (cfg.mem == null) cfg.mem = vip_common_pkg::vip_mem::type_id::create("mem");
  endfunction

  function bit [63:0] word_base(bit [AW-1:0] a);
    return 64'(a) & ~64'(SW - 1);
  endfunction

  // Drive pready with the response for the transfer currently on the bus.
  function void present();
    bit err = cfg.in_err_region(64'(vif.paddr));
    bit [DW-1:0] d = '0;
    if (!vif.pwrite && !err) begin
      for (int unsigned b = 0; b < SW; b++) d[8*b +: 8] = cfg.mem.read_byte(word_base(vif.paddr) + 64'(b));
      if (cfg.slave_corrupt_pct && $urandom_range(99) < cfg.slave_corrupt_pct)
        d[$urandom_range(DW - 1)] ^= 1'b1;
    end
    vif.prdata  <= d;
    vif.pslverr <= err;
    vif.pready  <= 1;
  endfunction

  task run_phase(uvm_phase phase);
    vif.pready <= 0; vif.prdata <= '0; vif.pslverr <= 0;
    forever begin
      @(posedge vif.pclk);
      if (!vif.presetn) begin
        vif.pready <= 0; vif.pslverr <= 0; waits_left = 0;
        continue;
      end
      if (vif.psel && vif.penable && vif.pready) begin
        // Transfer completes on this edge.
        if (vif.pwrite && !cfg.in_err_region(64'(vif.paddr)))
          for (int unsigned b = 0; b < SW; b++)
            if (vif.pstrb[b]) cfg.mem.write_byte(word_base(vif.paddr) + 64'(b), vif.pwdata[8*b +: 8]);
        vif.pready <= 0; vif.pslverr <= 0;
      end else if (vif.psel && !vif.penable) begin
        // SETUP: choose the wait states of the coming ACCESS.
        waits_left = vip_common_pkg::vip_delay::pick(cfg.slave_wait_pct, cfg.slave_max_wait);
        if (waits_left == 0) present();
        else vif.pready <= 0;
      end else if (vif.psel && vif.penable) begin
        // ACCESS wait state.
        if (waits_left > 0) waits_left--;
        if (waits_left == 0) present();
      end else begin
        vif.pready <= 0;
      end
    end
  endtask
endclass
