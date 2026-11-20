// apb_agent.svh: master or slave APB4 agent. Passive = monitor (+ coverage) only.

typedef uvm_sequencer #(apb_item) apb_sequencer;

class apb_agent #(int AW = 32, int DW = 32) extends uvm_agent;
  `uvm_component_param_utils(apb_agent #(AW, DW))

  apb_cfg                     cfg;
  apb_sequencer               sqr;
  apb_master_driver #(AW, DW) mdrv;
  apb_slave_driver  #(AW, DW) sdrv;
  apb_monitor       #(AW, DW) mon;
  apb_coverage                cov;

  function new(string name, uvm_component parent); super.new(name, parent); endfunction

  function void build_phase(uvm_phase phase);
    if (!uvm_config_db#(apb_cfg)::get(this, "", "cfg", cfg)) `uvm_fatal("NOCFG", "apb cfg not set")
    if (cfg.data_bytes != DW / 8 || cfg.addr_width != AW)
      `uvm_fatal("APB_CFG", $sformatf("cfg widths (%0d/%0d) do not match agent (%0d/%0d)",
                 cfg.addr_width, cfg.data_bytes * 8, AW, DW))
    if (!(DW inside {8, 16, 32})) `uvm_fatal("APB_CFG", $sformatf("APB4 data width must be 8, 16 or 32, not %0d", DW))
    uvm_config_db#(apb_cfg)::set(this, "*", "cfg", cfg);
    is_active = cfg.is_active;
    mon = apb_monitor #(AW, DW)::type_id::create("mon", this);
    if (cfg.has_cov) cov = apb_coverage::type_id::create("cov", this);
    if (cfg.is_active == UVM_ACTIVE) begin
      if (cfg.role == APB_MASTER) begin
        sqr  = apb_sequencer::type_id::create("sqr", this);
        mdrv = apb_master_driver #(AW, DW)::type_id::create("drv", this);
      end else begin
        sdrv = apb_slave_driver #(AW, DW)::type_id::create("drv", this);
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
