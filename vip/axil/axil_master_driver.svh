// axil_master_driver.svh: pipelined AXI4-Lite master. Five independent channel threads, so
// addresses, write data and responses overlap freely (W may lead AW, up to
// cfg.max_outstanding accesses in flight). AXI4-Lite has no IDs, so responses come back in
// request order per direction. Every completed access is returned to the sequence with
// put_response (set_id_info'd).

class axil_master_driver #(int AW = 32, int DW = 32) extends uvm_driver #(axil_item);
  `uvm_component_param_utils(axil_master_driver #(AW, DW))

  typedef virtual axil_if #(.AW(AW), .DW(DW)) vif_t;
  localparam int SW = DW / 8;

  vif_t        vif;
  axil_cfg     cfg;
  axil_item    aw_q[$], w_q[$], ar_q[$];
  axil_item    wr_out[$], rd_out[$];   // issued, awaiting response (oldest first)
  int unsigned outstanding;
  bit          injected;

  function new(string name, uvm_component parent); super.new(name, parent); endfunction

  function void build_phase(uvm_phase phase);
    if (!uvm_config_db#(vif_t)::get(this, "", "vif", vif)) `uvm_fatal("NOVIF", "axil vif not set")
    if (!uvm_config_db#(axil_cfg)::get(this, "", "cfg", cfg)) `uvm_fatal("NOCFG", "axil cfg not set")
  endfunction

  function bit inject_now(axil_inject_e k);
    if (cfg.inject != k || injected) return 0;
    injected = 1;
    `uvm_info("AXIL_INJ", $sformatf("injecting %s", k.name()), UVM_LOW)
    return 1;
  endfunction

  task reset_signals();
    vif.awvalid <= 0; vif.wvalid <= 0; vif.arvalid <= 0; vif.bready <= 0; vif.rready <= 0;
    vif.awaddr <= '0; vif.awprot <= '0; vif.wdata <= '0; vif.wstrb <= '0;
    vif.araddr <= '0; vif.arprot <= '0;
  endtask

  task run_phase(uvm_phase phase);
    reset_signals();
    @(posedge vif.aclk);
    if (!vif.aresetn && inject_now(AXIL_INJ_VALID_IN_RESET)) begin
      vif.arvalid <= 1; @(posedge vif.aclk); vif.arvalid <= 0;
    end
    while (!vif.aresetn) @(posedge vif.aclk);
    fork
      get_loop();
      aw_loop();
      w_loop();
      b_loop();
      ar_loop();
      r_loop();
    join
  endtask

  task get_loop();
    forever begin
      seq_item_port.get_next_item(req);
      while (outstanding >= cfg.max_outstanding) @(posedge vif.aclk);
      outstanding++;
      if (req.dir == AXIL_WRITE) begin
        aw_q.push_back(req); w_q.push_back(req); wr_out.push_back(req);
      end else begin
        ar_q.push_back(req); rd_out.push_back(req);
      end
      seq_item_port.item_done();
    end
  endtask

  task aw_loop();
    axil_item t;
    forever begin
      while (aw_q.size() == 0) @(posedge vif.aclk);
      t = aw_q.pop_front();
      repeat (t.addr_delay) @(posedge vif.aclk);
      vif.awaddr <= AW'(t.addr); vif.awprot <= t.prot; vif.awvalid <= 1;
      @(posedge vif.aclk);
      while (!vif.awready) begin
        if (inject_now(AXIL_INJ_AW_VALID_DROP)) begin
          vif.awvalid <= 0; @(posedge vif.aclk); vif.awvalid <= 1;
        end else if (inject_now(AXIL_INJ_AW_PAYLOAD_CHANGE)) begin
          vif.awaddr <= AW'(t.addr) ^ AW'(64'h40);
        end
        @(posedge vif.aclk);
      end
      vif.awvalid <= 0;
    end
  endtask

  task w_loop();
    axil_item t;
    forever begin
      while (w_q.size() == 0) @(posedge vif.aclk);
      t = w_q.pop_front();
      repeat (t.data_delay) @(posedge vif.aclk);
      vif.wdata <= DW'(t.data); vif.wstrb <= SW'(t.strb); vif.wvalid <= 1;
      @(posedge vif.aclk);
      while (!vif.wready) begin
        if (inject_now(AXIL_INJ_W_VALID_DROP)) begin
          vif.wvalid <= 0; @(posedge vif.aclk); vif.wvalid <= 1;
        end else if (inject_now(AXIL_INJ_W_PAYLOAD_CHANGE)) begin
          vif.wdata <= ~DW'(t.data);
        end
        @(posedge vif.aclk);
      end
      vif.wvalid <= 0;
    end
  endtask

  function void complete(axil_item t);
    axil_item rsp;
    $cast(rsp, t.clone());
    rsp.set_id_info(t);
    seq_item_port.put_response(rsp);
    outstanding--;
  endfunction

  task b_loop();
    forever begin
      @(posedge vif.aclk);
      if (vif.bvalid && vif.bready) begin
        if (wr_out.size() == 0) `uvm_error("AXIL_MST", "B with no outstanding write")
        else begin
          axil_item t = wr_out.pop_front();
          t.resp = axil_resp_e'(vif.bresp);
          complete(t);
        end
      end
      vif.bready <= ($urandom_range(99) >= cfg.bready_busy_pct);
    end
  endtask

  task ar_loop();
    axil_item t;
    forever begin
      while (ar_q.size() == 0) @(posedge vif.aclk);
      t = ar_q.pop_front();
      repeat (t.addr_delay) @(posedge vif.aclk);
      vif.araddr <= AW'(t.addr); vif.arprot <= t.prot; vif.arvalid <= 1;
      @(posedge vif.aclk);
      while (!vif.arready) begin
        if (inject_now(AXIL_INJ_AR_VALID_DROP)) begin
          vif.arvalid <= 0; @(posedge vif.aclk); vif.arvalid <= 1;
        end else if (inject_now(AXIL_INJ_AR_PAYLOAD_CHANGE)) begin
          vif.araddr <= AW'(t.addr) ^ AW'(64'h40);
        end
        @(posedge vif.aclk);
      end
      vif.arvalid <= 0;
    end
  endtask

  task r_loop();
    forever begin
      @(posedge vif.aclk);
      if (vif.rvalid && vif.rready) begin
        if (rd_out.size() == 0) `uvm_error("AXIL_MST", "R with no outstanding read")
        else begin
          axil_item t = rd_out.pop_front();
          t.data = AXIL_MAX_DW'(vif.rdata);
          t.resp = axil_resp_e'(vif.rresp);
          complete(t);
        end
      end
      vif.rready <= ($urandom_range(99) >= cfg.bready_busy_pct);
    end
  endtask
endclass
