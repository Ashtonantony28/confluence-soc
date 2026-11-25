// axi4_agent.svh: master or slave AXI4 agent. Passive = monitor (+ coverage) only.

typedef uvm_sequencer #(axi4_item) axi4_sequencer;

class axi4_agent #(int AW = 32, int DW = 128, int IDW = 4) extends uvm_agent;
  `uvm_component_param_utils(axi4_agent #(AW, DW, IDW))

  axi4_cfg                              cfg;
  axi4_sequencer                        sqr;
  axi4_master_driver #(AW, DW, IDW)     mdrv;
  axi4_slave_driver  #(AW, DW, IDW)     sdrv;
  axi4_monitor       #(AW, DW, IDW)     mon;
  axi4_coverage                         cov;

  function new(string name, uvm_component parent); super.new(name, parent); endfunction

  function void build_phase(uvm_phase phase);
    if (!uvm_config_db#(axi4_cfg)::get(this, "", "cfg", cfg)) `uvm_fatal("NOCFG", "axi4 cfg not set")
    if (cfg.data_bytes != DW / 8 || cfg.id_width != IDW || cfg.addr_width != AW)
      `uvm_fatal("AXI4_CFG", $sformatf("cfg widths (%0d/%0d/%0d) do not match agent (%0d/%0d/%0d)",
                 cfg.addr_width, cfg.data_bytes * 8, cfg.id_width, AW, DW, IDW))
    uvm_config_db#(axi4_cfg)::set(this, "*", "cfg", cfg);
    is_active = cfg.is_active;
    mon = axi4_monitor #(AW, DW, IDW)::type_id::create("mon", this);
    if (cfg.has_cov) cov = axi4_coverage::type_id::create("cov", this);
    if (cfg.is_active == UVM_ACTIVE) begin
      if (cfg.role == AXI4_MASTER) begin
        sqr  = axi4_sequencer::type_id::create("sqr", this);
        mdrv = axi4_master_driver #(AW, DW, IDW)::type_id::create("drv", this);
      end else begin
        sdrv = axi4_slave_driver #(AW, DW, IDW)::type_id::create("drv", this);
      end
    end
  endfunction

  function void connect_phase(uvm_phase phase);
    if (cov != null) begin
      cov.cfg = cfg;
      mon.ap.connect(cov.analysis_export);
    end
    if (mdrv != null) begin
      mdrv.seq_item_port.connect(sqr.seq_item_export);
    end
  endfunction
endclass
