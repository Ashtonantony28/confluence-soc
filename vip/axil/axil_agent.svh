// axil_agent.svh: master or slave AXI4-Lite agent. Passive = monitor (+ coverage) only.

typedef uvm_sequencer #(axil_item) axil_sequencer;

class axil_agent #(int AW = 32, int DW = 32) extends uvm_agent;
  `uvm_component_param_utils(axil_agent #(AW, DW))

  axil_cfg                     cfg;
  axil_sequencer               sqr;
  axil_master_driver #(AW, DW) mdrv;
  axil_slave_driver  #(AW, DW) sdrv;
  axil_monitor       #(AW, DW) mon;
  axil_coverage                cov;

  function new(string name, uvm_component parent); super.new(name, parent); endfunction

  function void build_phase(uvm_phase phase);
    if (!uvm_config_db#(axil_cfg)::get(this, "", "cfg", cfg)) `uvm_fatal("NOCFG", "axil cfg not set")
    if (cfg.data_bytes != DW / 8 || cfg.addr_width != AW)
      `uvm_fatal("AXIL_CFG", $sformatf("cfg widths (%0d/%0d) do not match agent (%0d/%0d)",
                 cfg.addr_width, cfg.data_bytes * 8, AW, DW))
    if (DW != 32 && DW != 64) `uvm_fatal("AXIL_CFG", $sformatf("AXI4-Lite data width must be 32 or 64, not %0d", DW))
    uvm_config_db#(axil_cfg)::set(this, "*", "cfg", cfg);
    is_active = cfg.is_active;
    mon = axil_monitor #(AW, DW)::type_id::create("mon", this);
    if (cfg.has_cov) cov = axil_coverage::type_id::create("cov", this);
    if (cfg.is_active == UVM_ACTIVE) begin
      if (cfg.role == AXIL_MASTER) begin
        sqr  = axil_sequencer::type_id::create("sqr", this);
        mdrv = axil_master_driver #(AW, DW)::type_id::create("drv", this);
      end else begin
        sdrv = axil_slave_driver #(AW, DW)::type_id::create("drv", this);
      end
    end
  endfunction

  function void connect_phase(uvm_phase phase);
    if (cov != null) begin
      cov.cfg = cfg;
      mon.ap.connect(cov.analysis_export);
    end
    if (mdrv != null) mdrv.seq_item_port.connect(sqr.seq_item_export);
  endfunction
endclass
