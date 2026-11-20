// axis_master_driver.svh: AXI4-Stream transmitter. Sends each packet item transfer by
// transfer with random idle gaps (item.gap_before before the packet, cfg.beat_gap_pct inside
// it); with no gap the next packet follows the previous TLAST directly. Every packet is
// published on ap_sent once its last transfer is accepted (the self-test scoreboard's
// expected stream), then item_done is called.

class axis_master_driver #(int DW = 32, int IDW = 0, int DESTW = 0, int UW = 0) extends uvm_driver #(axis_item);
  `uvm_component_param_utils(axis_master_driver #(DW, IDW, DESTW, UW))

  typedef virtual axis_if #(.DW(DW), .IDW(IDW), .DESTW(DESTW), .UW(UW)) vif_t;
  localparam int KW    = DW / 8;
  localparam int IDW_I = (IDW > 0) ? IDW : 1;
  localparam int DSW_I = (DESTW > 0) ? DESTW : 1;
  localparam int UW_I  = (UW > 0) ? UW : 1;

  vif_t        vif;
  axis_cfg     cfg;
  bit          injected;
  bit          busy;
  int unsigned n_sent;
  uvm_analysis_port #(axis_item) ap_sent;

  function new(string name, uvm_component parent); super.new(name, parent); endfunction

  function void build_phase(uvm_phase phase);
    ap_sent = new("ap_sent", this);
    if (!uvm_config_db#(vif_t)::get(this, "", "vif", vif)) `uvm_fatal("NOVIF", "axis vif not set")
    if (!uvm_config_db#(axis_cfg)::get(this, "", "cfg", cfg)) `uvm_fatal("NOCFG", "axis cfg not set")
  endfunction

  function bit inject_now(axis_inject_e k);
    if (cfg.inject != k || injected) return 0;
    injected = 1;
    `uvm_info("AXIS_INJ", $sformatf("injecting %s", k.name()), UVM_LOW)
    return 1;
  endfunction

  task run_phase(uvm_phase phase);
    vif.tvalid <= 0; vif.tdata <= '0; vif.tkeep <= '0; vif.tlast <= 0;
    vif.tuser <= '0; vif.tid <= '0; vif.tdest <= '0;
    @(posedge vif.aclk);
    if (!vif.aresetn && inject_now(AXIS_INJ_VALID_IN_RESET)) begin
      vif.tvalid <= 1; @(posedge vif.aclk); vif.tvalid <= 0;
    end
    while (!vif.aresetn) @(posedge vif.aclk);
    forever begin
      seq_item_port.try_next_item(req);
      if (req == null) begin
        vif.tvalid <= 0;
        @(posedge vif.aclk);
        continue;
      end
      busy = 1;
      if (req.gap_before > 0) begin
        vif.tvalid <= 0;
        repeat (req.gap_before) @(posedge vif.aclk);
      end
      send(req);
      begin
        axis_item c;
        $cast(c, req.clone());
        ap_sent.write(c);
      end
      n_sent++;
      seq_item_port.item_done();
      busy = 0;
    end
  endtask

  task send(axis_item t);
    int unsigned nb = t.beats();
    for (int unsigned n = 0; n < nb; n++) begin
      bit [AXIS_MAX_DW/8-1:0] k = t.keep[n];
      if (n > 0 && $urandom_range(99) < cfg.beat_gap_pct) begin
        vif.tvalid <= 0;
        repeat ($urandom_range(cfg.beat_gap_max, 1)) @(posedge vif.aclk);
      end
      if (KW > 1 && cfg.keep_mode == AXIS_KEEP_PACKED && k[0] && k[1] && inject_now(AXIS_INJ_KEEP_HOLE))
        k[0] = 0;
      if (KW > 1 && n + 1 < nb && inject_now(AXIS_INJ_KEEP_SHORT_MID))
        k[KW-1] = 0;
      vif.tdata <= DW'(t.data[n]); vif.tkeep <= KW'(k); vif.tlast <= (n + 1 == nb);
      vif.tuser <= UW_I'(t.user[n]); vif.tid <= IDW_I'(t.tid); vif.tdest <= DSW_I'(t.tdest);
      vif.tvalid <= 1;
      @(posedge vif.aclk);
      while (!vif.tready) begin
        if (inject_now(AXIS_INJ_VALID_DROP)) begin
          vif.tvalid <= 0; @(posedge vif.aclk); vif.tvalid <= 1;
        end else if (inject_now(AXIS_INJ_DATA_CHANGE)) vif.tdata <= ~DW'(t.data[n]);
        else if (inject_now(AXIS_INJ_LAST_CHANGE)) vif.tlast <= !(n + 1 == nb);
        else if (IDW > 0 && inject_now(AXIS_INJ_ID_CHANGE)) vif.tid <= ~IDW_I'(t.tid);
        @(posedge vif.aclk);
      end
    end
    vif.tvalid <= 0; vif.tlast <= 0;
  endtask
endclass
