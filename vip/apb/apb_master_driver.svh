// apb_master_driver.svh: APB4 requester. One transfer at a time (APB has no pipelining):
// optional IDLE cycles, SETUP, ACCESS until pready. With idle == 0 and the next item ready,
// the next SETUP follows the completing ACCESS directly (psel stays high). The item is
// updated in place (read data, pslverr, wait states) before item_done, so a sequence reads
// the result straight after finish_item.

class apb_master_driver #(int AW = 32, int DW = 32) extends uvm_driver #(apb_item);
  `uvm_component_param_utils(apb_master_driver #(AW, DW))

  typedef virtual apb_if #(.AW(AW), .DW(DW)) vif_t;
  localparam int SW = DW / 8;

  vif_t    vif;
  apb_cfg  cfg;
  bit      injected;
  bit      busy;            // a transfer is in progress (for wait_idle in tests)

  function new(string name, uvm_component parent); super.new(name, parent); endfunction

  function void build_phase(uvm_phase phase);
    if (!uvm_config_db#(vif_t)::get(this, "", "vif", vif)) `uvm_fatal("NOVIF", "apb vif not set")
    if (!uvm_config_db#(apb_cfg)::get(this, "", "cfg", cfg)) `uvm_fatal("NOCFG", "apb cfg not set")
  endfunction

  function bit inject_now(apb_inject_e k);
    if (cfg.inject != k || injected) return 0;
    injected = 1;
    `uvm_info("APB_INJ", $sformatf("injecting %s", k.name()), UVM_LOW)
    return 1;
  endfunction

  task run_phase(uvm_phase phase);
    vif.psel <= 0; vif.penable <= 0; vif.pwrite <= 0; vif.paddr <= '0; vif.pwdata <= '0;
    vif.pstrb <= '0; vif.pprot <= '0;
    @(posedge vif.pclk);
    if (!vif.presetn && inject_now(APB_INJ_SEL_IN_RESET)) begin
      vif.psel <= 1; @(posedge vif.pclk); vif.psel <= 0;
    end
    while (!vif.presetn) @(posedge vif.pclk);
    forever begin
      seq_item_port.try_next_item(req);
      if (req == null) begin
        vif.psel <= 0;
        vif.penable <= inject_now(APB_INJ_ENABLE_NO_SEL);
        @(posedge vif.pclk);
        continue;
      end
      busy = 1;
      if (req.idle > 0) begin
        vif.psel <= 0; vif.penable <= 0;
        repeat (req.idle) @(posedge vif.pclk);
      end
      transfer(req);
      seq_item_port.item_done();
      busy = 0;
      if (inject_now(APB_INJ_ENABLE_STUCK)) begin
        vif.psel <= 0; @(posedge vif.pclk);   // penable is still high from the ACCESS
      end
    end
  endtask

  task transfer(apb_item t);
    // SETUP
    vif.psel <= 1; vif.penable <= 0; vif.pwrite <= t.dir; vif.paddr <= AW'(t.addr);
    vif.pwdata <= (t.dir == APB_WRITE) ? DW'(t.data) : '0;
    vif.pstrb <= (t.dir == APB_WRITE) ? SW'(t.strb) : '0;
    vif.pprot <= t.prot;
    if (t.dir == APB_READ && inject_now(APB_INJ_READ_STRB)) vif.pstrb <= SW'(1);
    if (inject_now(APB_INJ_ENABLE_NO_SETUP)) vif.penable <= 1;
    t.t_setup = $time;
    @(posedge vif.pclk);
    if (inject_now(APB_INJ_SETUP_NO_ACCESS)) @(posedge vif.pclk);
    // ACCESS
    vif.penable <= 1;
    if (inject_now(APB_INJ_SETUP_CHANGE)) vif.paddr <= AW'(t.addr) ^ AW'(32'h40);
    t.wait_states = 0;
    @(posedge vif.pclk);
    while (!vif.pready) begin
      t.wait_states++;
      if (inject_now(APB_INJ_ADDR_CHANGE_WAIT)) vif.paddr <= vif.paddr ^ AW'(32'h40);
      else if (inject_now(APB_INJ_SEL_DROP_WAIT)) begin
        vif.psel <= 0; @(posedge vif.pclk); vif.psel <= 1;
      end
      @(posedge vif.pclk);
    end
    t.slverr = vif.pslverr;
    if (t.dir == APB_READ) t.data = APB_MAX_DW'(vif.prdata);
    t.t_done = $time;
  endtask
endclass
