// axis_agent.svh: master or slave AXI4-Stream agent. Passive = monitor (+ coverage) only.

typedef uvm_sequencer #(axis_item) axis_sequencer;

class axis_agent #(int DW = 32, int IDW = 0, int DESTW = 0, int UW = 0) extends uvm_agent;
  `uvm_component_param_utils(axis_agent #(DW, IDW, DESTW, UW))

  axis_cfg                                 cfg;
  axis_sequencer                           sqr;
  axis_master_driver #(DW, IDW, DESTW, UW) mdrv;
  axis_slave_driver  #(DW, IDW, DESTW, UW) sdrv;
  axis_monitor       #(DW, IDW, DESTW, UW) mon;
  axis_coverage                            cov;

  function new(string name, uvm_component parent); super.new(name, parent); endfunction

  function void build_phase(uvm_phase phase);
    if (!uvm_config_db#(axis_cfg)::get(this, "", "cfg", cfg)) `uvm_fatal("NOCFG", "axis cfg not set")
    if (cfg.data_bytes != DW / 8 || cfg.id_width != IDW || cfg.dest_width != DESTW || cfg.user_width != UW)
      `uvm_fatal("AXIS_CFG", $sformatf("cfg widths (%0d/%0d/%0d/%0d) do not match agent (%0d/%0d/%0d/%0d)",
                 cfg.data_bytes * 8, cfg.id_width, cfg.dest_width, cfg.user_width, DW, IDW, DESTW, UW))
    if (DW % 8 != 0 || DW > AXIS_MAX_DW || IDW > AXIS_MAX_IDW || DESTW > AXIS_MAX_DESTW || UW > AXIS_MAX_UW)
      `uvm_fatal("AXIS_CFG", "widths exceed the axis_pkg maxima or DW is not a whole number of bytes")
    uvm_config_db#(axis_cfg)::set(this, "*", "cfg", cfg);
    is_active = cfg.is_active;
    mon = axis_monitor #(DW, IDW, DESTW, UW)::type_id::create("mon", this);
    if (cfg.has_cov) cov = axis_coverage::type_id::create("cov", this);
    if (cfg.is_active == UVM_ACTIVE) begin
      if (cfg.role == AXIS_MASTER) begin
        sqr  = axis_sequencer::type_id::create("sqr", this);
        mdrv = axis_master_driver #(DW, IDW, DESTW, UW)::type_id::create("drv", this);
      end else begin
        sdrv = axis_slave_driver #(DW, IDW, DESTW, UW)::type_id::create("drv", this);
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
