// axi4_master_driver.svh: pipelined AXI4 master. Five independent channel threads, so
// addresses, write data and responses overlap freely (W may lead AW, up to
// cfg.max_outstanding bursts in flight, responses matched per ID in issue order).
// Every completed burst is returned to the sequence with put_response (set_id_info'd).

class axi4_master_driver #(int AW = 32, int DW = 128, int IDW = 4) extends uvm_driver #(axi4_item);
  `uvm_component_param_utils(axi4_master_driver #(AW, DW, IDW))

  typedef virtual axi4_if #(.AW(AW), .DW(DW), .IDW(IDW)) vif_t;
  localparam int SW = DW / 8;

  vif_t        vif;
  axi4_cfg     cfg;
  axi4_item    aw_q[$], w_q[$], ar_q[$];
  axi4_item    wr_out[$], rd_out[$];   // issued, awaiting response (oldest first)
  int unsigned outstanding;
  bit          injected;

  function new(string name, uvm_component parent); super.new(name, parent); endfunction

  function void build_phase(uvm_phase phase);
    if (!uvm_config_db#(vif_t)::get(this, "", "vif", vif)) `uvm_fatal("NOVIF", "axi4 vif not set")
    if (!uvm_config_db#(axi4_cfg)::get(this, "", "cfg", cfg)) `uvm_fatal("NOCFG", "axi4 cfg not set")
  endfunction

  function bit inject_now(axi4_inject_e k);
    if (cfg.inject != k || injected) return 0;
    injected = 1;
    `uvm_info("AXI4_INJ", $sformatf("injecting %s", k.name()), UVM_LOW)
    return 1;
  endfunction

  task reset_signals();
    vif.awvalid <= 0; vif.wvalid <= 0; vif.arvalid <= 0; vif.bready <= 0; vif.rready <= 0;
    vif.awid <= '0; vif.awaddr <= '0; vif.awlen <= '0; vif.awsize <= '0; vif.awburst <= '0;
    vif.awlock <= 0; vif.awcache <= '0; vif.awprot <= '0; vif.awqos <= '0;
    vif.wdata <= '0; vif.wstrb <= '0; vif.wlast <= 0;
    vif.arid <= '0; vif.araddr <= '0; vif.arlen <= '0; vif.arsize <= '0; vif.arburst <= '0;
    vif.arlock <= 0; vif.arcache <= '0; vif.arprot <= '0; vif.arqos <= '0;
  endtask

  task run_phase(uvm_phase phase);
    reset_signals();
    @(posedge vif.aclk);
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

  // Item-shape injections are applied before the burst is queued, so W beats stay consistent.
  function void shape_injections(axi4_item t);
    int unsigned maxsz = $clog2(cfg.data_bytes);
    if (t.dir == AXI4_WRITE && inject_now(AXI4_INJ_WRAP_BAD_LEN)) begin
      t.burst = AXI4_WRAP; t.len = 2; t.size = 3'(maxsz); t.addr = t.aligned_addr();
      t.fill_write_data();
    end else if (t.dir == AXI4_WRITE && inject_now(AXI4_INJ_CROSS_4K)) begin
      t.burst = AXI4_INCR; t.size = 3'(maxsz); t.len = 3;
      t.addr = 64'h1000 - 64'(cfg.data_bytes);
      t.fill_write_data();
    end else if (t.dir == AXI4_READ && inject_now(AXI4_INJ_SIZE_TOO_BIG)) begin
      t.size = 3'(maxsz + 1); t.len = 0; t.burst = AXI4_INCR; t.addr = t.aligned_addr();
    end else if (t.dir == AXI4_READ && inject_now(AXI4_INJ_BURST_RSVD)) begin
      t.burst = AXI4_RSVD; t.len = 0;
    end
  endfunction

  task get_loop();
    forever begin
      seq_item_port.get_next_item(req);
      while (outstanding >= cfg.max_outstanding) @(posedge vif.aclk);
      outstanding++;
      shape_injections(req);
      if (req.dir == AXI4_WRITE) begin
        aw_q.push_back(req); w_q.push_back(req); wr_out.push_back(req);
      end else begin
        req.data.delete(); req.strb.delete(); req.resp.delete();
        ar_q.push_back(req); rd_out.push_back(req);
      end
      seq_item_port.item_done();
    end
  endtask

  task aw_loop();
    axi4_item t;
    bit dropped, changed;
    forever begin
      while (aw_q.size() == 0) @(posedge vif.aclk);
      t = aw_q.pop_front();
      repeat (t.addr_delay) @(posedge vif.aclk);
      vif.awid <= IDW'(t.id); vif.awaddr <= AW'(t.addr); vif.awlen <= t.len; vif.awsize <= t.size;
      vif.awburst <= t.burst; vif.awlock <= t.lock; vif.awcache <= t.cache; vif.awprot <= t.prot;
      vif.awqos <= t.qos; vif.awvalid <= 1;
      dropped = 0; changed = 0;
      @(posedge vif.aclk);
      while (!vif.awready) begin
        if (!dropped && inject_now(AXI4_INJ_AW_VALID_DROP)) begin
          vif.awvalid <= 0; @(posedge vif.aclk); vif.awvalid <= 1; dropped = 1;
        end else if (!changed && inject_now(AXI4_INJ_AW_PAYLOAD_CHANGE)) begin
          vif.awaddr <= AW'(t.addr) ^ AW'(64'h40); changed = 1;
        end
        @(posedge vif.aclk);
      end
      vif.awvalid <= 0;
    end
  endtask

  task w_loop();
    axi4_item t;
    int unsigned nb;
    forever begin
      while (w_q.size() == 0) @(posedge vif.aclk);
      t = w_q.pop_front();
      repeat (t.data_delay) @(posedge vif.aclk);
      nb = t.beats();
      for (int unsigned n = 0; n < nb; n++) begin
        bit last = (n == nb - 1);
        if (nb > 1 && n == nb - 2 && inject_now(AXI4_INJ_WLAST_EARLY)) last = 1;
        else if (last && inject_now(AXI4_INJ_WLAST_MISSING)) begin
          last = 0;
          nb++;                                  // one extra beat carries the late wlast
        end
        vif.wdata <= DW'(n < t.data.size() ? t.data[n] : t.data[t.data.size() - 1]);
        if (t.size < $clog2(SW) && inject_now(AXI4_INJ_WSTRB_OUTSIDE)) vif.wstrb <= '1;
        else vif.wstrb <= SW'(n < t.strb.size() ? t.strb[n] : '0);
        vif.wlast <= last; vif.wvalid <= 1;
        @(posedge vif.aclk);
        while (!vif.wready) begin
          if (inject_now(AXI4_INJ_W_VALID_DROP)) begin
            vif.wvalid <= 0; @(posedge vif.aclk); vif.wvalid <= 1;
          end
          @(posedge vif.aclk);
        end
        if (n + 1 < nb && $urandom_range(99) < 10) begin
          vif.wvalid <= 0; @(posedge vif.aclk);
        end
      end
      vif.wvalid <= 0; vif.wlast <= 0;
    end
  endtask

  function int find_id(ref axi4_item q[$], input bit [AXI4_MAX_IDW-1:0] id);
    foreach (q[i]) if (q[i].id == id) return i;
    return -1;
  endfunction

  function void complete(axi4_item t);
    axi4_item rsp;
    $cast(rsp, t.clone());
    rsp.set_id_info(t);
    seq_item_port.put_response(rsp);
    outstanding--;
  endfunction

  task b_loop();
    forever begin
      @(posedge vif.aclk);
      if (vif.bvalid && vif.bready) begin
        int i = find_id(wr_out, AXI4_MAX_IDW'(vif.bid));
        if (i < 0) `uvm_error("AXI4_MST", $sformatf("B for id %0h with no outstanding write", vif.bid))
        else begin
          axi4_item t = wr_out[i];
          wr_out.delete(i);
          t.resp = new[1];
          t.resp[0] = axi4_resp_e'(vif.bresp);
          complete(t);
        end
      end
      vif.bready <= ($urandom_range(99) >= cfg.bready_busy_pct);
    end
  endtask

  task ar_loop();
    axi4_item t;
    bit dropped;
    forever begin
      while (ar_q.size() == 0) @(posedge vif.aclk);
      t = ar_q.pop_front();
      repeat (t.addr_delay) @(posedge vif.aclk);
      vif.arid <= IDW'(t.id); vif.araddr <= AW'(t.addr); vif.arlen <= t.len; vif.arsize <= t.size;
      vif.arburst <= t.burst; vif.arlock <= t.lock; vif.arcache <= t.cache; vif.arprot <= t.prot;
      vif.arqos <= t.qos; vif.arvalid <= 1;
      dropped = 0;
      @(posedge vif.aclk);
      while (!vif.arready) begin
        if (!dropped && inject_now(AXI4_INJ_AR_VALID_DROP)) begin
          vif.arvalid <= 0; @(posedge vif.aclk); vif.arvalid <= 1; dropped = 1;
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
        int i = find_id(rd_out, AXI4_MAX_IDW'(vif.rid));
        if (i < 0) `uvm_error("AXI4_MST", $sformatf("R for id %0h with no outstanding read", vif.rid))
        else begin
          axi4_item t = rd_out[i];
          int unsigned n = t.data.size();
          t.data = new[n + 1](t.data);
          t.resp = new[n + 1](t.resp);
          t.data[n] = AXI4_MAX_DW'(vif.rdata);
          t.resp[n] = axi4_resp_e'(vif.rresp);
          if (vif.rlast || n + 1 >= t.beats()) begin
            if (!vif.rlast || n + 1 != t.beats())
              `uvm_error("AXI4_MST", $sformatf("read id %0h: rlast=%0b on beat %0d of %0d",
                                                vif.rid, vif.rlast, n + 1, t.beats()))
            rd_out.delete(i);
            complete(t);
          end
        end
      end
      vif.rready <= ($urandom_range(99) >= cfg.bready_busy_pct);
    end
  endtask
endclass
