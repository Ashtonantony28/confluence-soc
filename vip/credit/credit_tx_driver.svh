// credit_tx_driver.svh: sends one flit per item, after item.gap idle cycles and only while it
// holds a credit. Credits are counted as depth - sent + returned; `returned` is counted by a
// separate sampling process, so a read races at most one credit low (conservative, never
// optimistic). Every sent item is published on ap_sent (stimulus view for scoreboards).

class credit_tx_driver #(int DW = 48) extends uvm_driver #(credit_item);
  `uvm_component_param_utils(credit_tx_driver #(DW))
  typedef virtual credit_if #(.DW(DW)) vif_t;
  vif_t        vif;
  credit_cfg   cfg;
  uvm_analysis_port #(credit_item) ap_sent;
  int unsigned sent, returned, n_waits;
  bit          injected;

  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void build_phase(uvm_phase phase);
    ap_sent = new("ap_sent", this);
    if (!uvm_config_db#(vif_t)::get(this, "", "vif", vif)) `uvm_fatal("NOVIF", "credit vif not set")
    if (!uvm_config_db#(credit_cfg)::get(this, "", "cfg", cfg)) `uvm_fatal("NOCFG", "credit cfg not set")
  endfunction

  function int avail(); return int'(cfg.depth) - int'(sent) + int'(returned); endfunction

  task count_credits();
    forever begin
      @(posedge vif.clk);
      if (!vif.rst_n) begin sent = 0; returned = 0; end
      else if (vif.credit) returned++;
    end
  endtask

  task run_phase(uvm_phase phase);
    vif.valid <= 1'b0;
    vif.data  <= '0;
    fork count_credits(); join_none
    if (cfg.inject == CREDIT_INJ_VALID_IN_RESET) begin
      @(posedge vif.clk); @(posedge vif.clk);
      if (!vif.rst_n) begin vif.valid <= 1'b1; @(posedge vif.clk); vif.valid <= 1'b0; injected = 1; end
    end
    forever begin
      credit_item t;
      seq_item_port.get_next_item(t);
      while (!vif.rst_n) begin vif.valid <= 1'b0; @(posedge vif.clk); end
      repeat (t.gap) begin vif.valid <= 1'b0; @(posedge vif.clk); end
      t.credit_wait = 0;
      while (avail() <= 0 && !(cfg.inject == CREDIT_INJ_NO_CREDIT && !injected)) begin
        vif.valid <= 1'b0; t.credit_wait++; @(posedge vif.clk);
      end
      if (avail() <= 0) injected = 1;
      if (t.credit_wait) n_waits++;
      vif.valid <= 1'b1;
      vif.data  <= DW'(t.data);
      sent++;
      ap_sent.write(t);
      @(posedge vif.clk);
      vif.valid <= 1'b0;                 // overridden at once if the next item is ready (back to back)
      seq_item_port.item_done();
    end
  endtask

  function void report_phase(uvm_phase phase);
    `uvm_info("CREDIT_TX", $sformatf("%0d flits sent, %0d waited for a credit", sent, n_waits), UVM_HIGH)
  endfunction
endclass
