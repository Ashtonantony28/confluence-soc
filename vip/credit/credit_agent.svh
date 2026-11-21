// credit_agent.svh: sender (TX) or receiver (RX) agent. Passive = monitor (+ coverage) only.

typedef uvm_sequencer #(credit_item) credit_sequencer;

class credit_agent #(int DW = 48) extends uvm_agent;
  `uvm_component_param_utils(credit_agent #(DW))
  credit_cfg            cfg;
  credit_sequencer      sqr;
  credit_tx_driver #(DW) tdrv;
  credit_rx_driver #(DW) rdrv;
  credit_monitor   #(DW) mon;
  credit_coverage       cov;

  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void build_phase(uvm_phase phase);
    if (!uvm_config_db#(credit_cfg)::get(this, "", "cfg", cfg)) `uvm_fatal("NOCFG", "credit cfg not set")
    if (cfg.data_bits != DW || DW > CREDIT_MAX_DW || cfg.depth == 0)
      `uvm_fatal("CREDIT_CFG", $sformatf("cfg data_bits %0d / depth %0d do not fit agent DW %0d", cfg.data_bits, cfg.depth, DW))
    uvm_config_db#(credit_cfg)::set(this, "*", "cfg", cfg);
    is_active = cfg.is_active;
    mon = credit_monitor #(DW)::type_id::create("mon", this);
    if (cfg.has_cov) cov = credit_coverage::type_id::create("cov", this);
    if (cfg.is_active == UVM_ACTIVE) begin
      if (cfg.role == CREDIT_TX) begin
        sqr  = credit_sequencer::type_id::create("sqr", this);
        tdrv = credit_tx_driver #(DW)::type_id::create("drv", this);
      end else rdrv = credit_rx_driver #(DW)::type_id::create("drv", this);
    end
  endfunction
  function void connect_phase(uvm_phase phase);
    if (cov != null) begin cov.cfg = cfg; mon.ap.connect(cov.analysis_export); end
    if (tdrv != null) tdrv.seq_item_port.connect(sqr.seq_item_export);
  endfunction
endclass
