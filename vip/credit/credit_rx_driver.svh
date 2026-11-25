// credit_rx_driver.svh: models the receiver's depth-entry buffer. A flit is pushed in the cycle
// it arrives; the head is popped after a random delay, and each pop returns one credit (credit
// high for one cycle). Receiving into a full buffer is an overflow (the checker's CREDIT-R01
// sees it too). Popped flits are published on ap_rcvd (consumer view).

class credit_rx_driver #(int DW = 48) extends uvm_component;
  `uvm_component_param_utils(credit_rx_driver #(DW))
  typedef virtual credit_if #(.DW(DW)) vif_t;
  vif_t          vif;
  credit_cfg     cfg;
  uvm_analysis_port #(credit_item) ap_rcvd;
  bit [DW-1:0]   q[$];
  int unsigned   n_pop, n_overflow, max_fill;
  bit            injected;

  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void build_phase(uvm_phase phase);
    ap_rcvd = new("ap_rcvd", this);
    if (!uvm_config_db#(vif_t)::get(this, "", "vif", vif)) `uvm_fatal("NOVIF", "credit vif not set")
    if (!uvm_config_db#(credit_cfg)::get(this, "", "cfg", cfg)) `uvm_fatal("NOCFG", "credit cfg not set")
  endfunction

  task run_phase(uvm_phase phase);
    int unsigned wait_cnt = 0;
    vif.credit <= 1'b0;
    forever begin
      @(posedge vif.clk);
      vif.credit <= 1'b0;
      if (!vif.rst_n) begin q.delete(); wait_cnt = 0; continue; end
      if (vif.valid) begin
        if (q.size() >= cfg.depth) begin
          n_overflow++;
          if (!vip_checker_db::expect_violations) `uvm_error("CREDIT_RX", "flit received into a full buffer")
        end else q.push_back(vif.data);
        if (q.size() > max_fill) max_fill = q.size();
      end
      if (q.size() > 0) begin
        if (wait_cnt > 0) wait_cnt--;
        else begin
          credit_item t = credit_item::type_id::create("rcvd");
          t.data = CREDIT_MAX_DW'(q.pop_front());
          ap_rcvd.write(t);
          vif.credit <= 1'b1;
          n_pop++;
          wait_cnt = vip_delay::pick(cfg.rx_busy_pct, cfg.rx_delay_max);
        end
      end else if (cfg.inject == CREDIT_INJ_EXTRA_CREDIT && !injected && n_pop >= 4) begin
        vif.credit <= 1'b1;
        injected = 1;
      end
    end
  endtask

  function void check_phase(uvm_phase phase);
    if (q.size() != 0 && !vip_checker_db::expect_violations)
      `uvm_error("CREDIT_RX", $sformatf("%0d flits still buffered at end of test", q.size()))
  endfunction
endclass
