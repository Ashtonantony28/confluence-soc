// axis_monitor.svh: rebuilds packets from accepted transfers (per TID/TDEST stream) and
// publishes each on ap at its TLAST, annotated with stall cycles, idle gaps inside the
// packet and interleaving, which the coverage collector samples.

class axis_monitor #(int DW = 32, int IDW = 0, int DESTW = 0, int UW = 0) extends uvm_monitor;
  `uvm_component_param_utils(axis_monitor #(DW, IDW, DESTW, UW))

  typedef virtual axis_if #(.DW(DW), .IDW(IDW), .DESTW(DESTW), .UW(UW)) vif_t;

  vif_t        vif;
  axis_cfg     cfg;
  axis_packer  pk;
  uvm_analysis_port #(axis_item) ap;
  int unsigned stalls, gaps;    // since the previous packet ended
  int unsigned n_pkts, n_xfers;

  function new(string name, uvm_component parent); super.new(name, parent); endfunction

  function void build_phase(uvm_phase phase);
    ap = new("ap", this);
    if (!uvm_config_db#(vif_t)::get(this, "", "vif", vif)) `uvm_fatal("NOVIF", "axis vif not set")
    if (!uvm_config_db#(axis_cfg)::get(this, "", "cfg", cfg)) `uvm_fatal("NOCFG", "axis cfg not set")
    pk = axis_packer::type_id::create("pk");
    pk.cfg = cfg;
  endfunction

  task run_phase(uvm_phase phase);
    forever begin
      @(posedge vif.aclk);
      if (!vif.aresetn) begin pk.clear(); stalls = 0; gaps = 0; continue; end
      if (vif.tvalid && !vif.tready) stalls++;
      if (!vif.tvalid && pk.open_packets() > 0) gaps++;
      if (vif.tvalid && vif.tready) begin
        axis_item t = pk.push(AXIS_MAX_IDW'(IDW > 0 ? vif.tid : '0), AXIS_MAX_DESTW'(DESTW > 0 ? vif.tdest : '0),
                              AXIS_MAX_DW'(vif.tdata), (AXIS_MAX_DW/8)'(vif.tkeep),
                              AXIS_MAX_UW'(UW > 0 ? vif.tuser : '0), vif.tlast);
        n_xfers++;
        if (t != null) begin
          t.stall_cycles = stalls; t.gap_cycles = gaps;
          if (pk.open_packets() == 0) begin stalls = 0; gaps = 0; end
          n_pkts++;
          ap.write(t);
        end
      end
    end
  endtask

  function void report_phase(uvm_phase phase);
    `uvm_info("AXIS_MON", $sformatf("%0d packets in %0d transfers observed", n_pkts, n_xfers), UVM_LOW)
    if (pk.open_packets() != 0)
      `uvm_info("AXIS_MON", $sformatf("%0d packets still open (no TLAST yet) at end of test", pk.open_packets()), UVM_LOW)
  endfunction
endclass
