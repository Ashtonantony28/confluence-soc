// axis_slave_driver.svh: AXI4-Stream receiver with random TREADY backpressure (TREADY does
// not wait for TVALID). Rebuilds the packets it accepts and publishes them on ap_rcvd, the
// consumer's view of the stream; cfg.slave_corrupt_pct flips a data bit in that view so a
// scoreboard can be proven to notice (sanity tests only).

class axis_slave_driver #(int DW = 32, int IDW = 0, int DESTW = 0, int UW = 0) extends uvm_component;
  `uvm_component_param_utils(axis_slave_driver #(DW, IDW, DESTW, UW))

  typedef virtual axis_if #(.DW(DW), .IDW(IDW), .DESTW(DESTW), .UW(UW)) vif_t;

  vif_t        vif;
  axis_cfg     cfg;
  axis_packer  pk;
  int unsigned n_rcvd;
  uvm_analysis_port #(axis_item) ap_rcvd;

  function new(string name, uvm_component parent); super.new(name, parent); endfunction

  function void build_phase(uvm_phase phase);
    ap_rcvd = new("ap_rcvd", this);
    if (!uvm_config_db#(vif_t)::get(this, "", "vif", vif)) `uvm_fatal("NOVIF", "axis vif not set")
    if (!uvm_config_db#(axis_cfg)::get(this, "", "cfg", cfg)) `uvm_fatal("NOCFG", "axis cfg not set")
    pk = axis_packer::type_id::create("pk");
    pk.cfg = cfg;
  endfunction

  function void corrupt(axis_item t);
    foreach (t.keep[n])
      for (int unsigned b = 0; b < cfg.data_bytes; b++)
        if (t.keep[n][b]) begin t.data[n][8 * b + $urandom_range(7)] ^= 1'b1; return; end
  endfunction

  task run_phase(uvm_phase phase);
    vif.tready <= 0;
    forever begin
      @(posedge vif.aclk);
      if (!vif.aresetn) begin vif.tready <= 0; pk.clear(); continue; end
      if (vif.tvalid && vif.tready) begin
        axis_item t = pk.push(AXIS_MAX_IDW'(IDW > 0 ? vif.tid : '0), AXIS_MAX_DESTW'(DESTW > 0 ? vif.tdest : '0),
                              AXIS_MAX_DW'(vif.tdata), (AXIS_MAX_DW/8)'(vif.tkeep),
                              AXIS_MAX_UW'(UW > 0 ? vif.tuser : '0), vif.tlast);
        if (t != null) begin
          if (cfg.slave_corrupt_pct && $urandom_range(99) < cfg.slave_corrupt_pct) corrupt(t);
          n_rcvd++;
          ap_rcvd.write(t);
        end
      end
      vif.tready <= ($urandom_range(99) >= cfg.slave_ready_busy_pct);
    end
  endtask
endclass
