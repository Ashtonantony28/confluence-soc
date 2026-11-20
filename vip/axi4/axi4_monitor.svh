// axi4_monitor.svh: rebuilds complete bursts from the five channels and publishes them.
//   ap       one item per completed burst (write: at B, read: at the last R beat)
//   ap_req   one item per address handshake (for performance monitors and early checks)
// Pairs AW with W bursts in order (W may lead AW), matches B/R to the oldest outstanding
// burst of the same ID, and annotates items with outstanding depth, out-of-order
// completion and read interleaving, which the coverage collector samples.

class axi4_monitor #(int AW = 32, int DW = 128, int IDW = 4) extends uvm_monitor;
  `uvm_component_param_utils(axi4_monitor #(AW, DW, IDW))

  typedef virtual axi4_if #(.AW(AW), .DW(DW), .IDW(IDW)) vif_t;

  vif_t vif;
  axi4_cfg cfg;
  uvm_analysis_port #(axi4_item) ap;
  uvm_analysis_port #(axi4_item) ap_req;

  axi4_item aw_q[$];        // addresses without data yet
  axi4_item w_q[$];         // data bursts without address yet
  axi4_item w_cur;
  axi4_item wr_pend[$];     // address + data seen, waiting for B
  axi4_item rd_pend[$];     // waiting for (more) read data
  axi4_item last_r;          // burst that received the previous R beat, if unfinished
  int unsigned n_writes, n_reads;

  function new(string name, uvm_component parent); super.new(name, parent); endfunction

  function void build_phase(uvm_phase phase);
    ap = new("ap", this);
    ap_req = new("ap_req", this);
    if (!uvm_config_db#(vif_t)::get(this, "", "vif", vif)) `uvm_fatal("NOVIF", "axi4 vif not set")
    if (!uvm_config_db#(axi4_cfg)::get(this, "", "cfg", cfg)) `uvm_fatal("NOCFG", "axi4 cfg not set")
  endfunction

  function axi4_item addr_item(axi4_dir_e d);
    axi4_item t = axi4_item::type_id::create(d == AXI4_WRITE ? "wr" : "rd");
    t.dir = d; t.dbytes = cfg.data_bytes; t.id_width = cfg.id_width; t.addr_width = cfg.addr_width;
    t.t_addr = $time;
    if (d == AXI4_WRITE) begin
      t.id = AXI4_MAX_IDW'(vif.awid); t.addr = AXI4_MAX_AW'(vif.awaddr); t.len = vif.awlen;
      t.size = vif.awsize; t.burst = axi4_burst_e'(vif.awburst); t.lock = vif.awlock;
      t.cache = vif.awcache; t.prot = vif.awprot; t.qos = vif.awqos;
      t.outstanding_at_issue = wr_pend.size() + aw_q.size();
    end else begin
      t.id = AXI4_MAX_IDW'(vif.arid); t.addr = AXI4_MAX_AW'(vif.araddr); t.len = vif.arlen;
      t.size = vif.arsize; t.burst = axi4_burst_e'(vif.arburst); t.lock = vif.arlock;
      t.cache = vif.arcache; t.prot = vif.arprot; t.qos = vif.arqos;
      t.outstanding_at_issue = rd_pend.size();
    end
    return t;
  endfunction

  function void pair_writes();
    while (aw_q.size() > 0 && w_q.size() > 0) begin
      axi4_item a = aw_q.pop_front();
      axi4_item w = w_q.pop_front();
      a.data = w.data; a.strb = w.strb;
      wr_pend.push_back(a);
    end
  endfunction

  function int oldest(ref axi4_item q[$], input bit [AXI4_MAX_IDW-1:0] id);
    foreach (q[i]) if (q[i].id == id) return i;
    return -1;
  endfunction

  task run_phase(uvm_phase phase);
    forever begin
      @(posedge vif.aclk);
      if (!vif.aresetn) begin
        aw_q.delete(); w_q.delete(); wr_pend.delete(); rd_pend.delete(); w_cur = null;
        continue;
      end
      if (vif.awvalid && vif.awready) begin
        axi4_item t = addr_item(AXI4_WRITE);
        aw_q.push_back(t);
        ap_req.write(t);
      end
      if (vif.wvalid && vif.wready) begin
        int unsigned n;
        if (w_cur == null) w_cur = axi4_item::type_id::create("wd");
        n = w_cur.data.size();
        w_cur.data = new[n + 1](w_cur.data);
        w_cur.strb = new[n + 1](w_cur.strb);
        w_cur.data[n] = AXI4_MAX_DW'(vif.wdata);
        w_cur.strb[n] = (AXI4_MAX_DW/8)'(vif.wstrb);
        if (vif.wlast) begin w_q.push_back(w_cur); w_cur = null; end
      end
      pair_writes();
      if (vif.bvalid && vif.bready) begin
        int i = oldest(wr_pend, AXI4_MAX_IDW'(vif.bid));
        if (i >= 0) begin
          axi4_item t = wr_pend[i];
          t.completed_out_of_order = (i != 0);
          wr_pend.delete(i);
          t.resp = new[1];
          t.resp[0] = axi4_resp_e'(vif.bresp);
          t.t_done = $time;
          n_writes++;
          ap.write(t);
        end
        // A B with no matching write is a protocol error reported by axi4_checker.
      end
      if (vif.arvalid && vif.arready) begin
        axi4_item t = addr_item(AXI4_READ);
        rd_pend.push_back(t);
        ap_req.write(t);
      end
      if (vif.rvalid && vif.rready) begin
        int i = oldest(rd_pend, AXI4_MAX_IDW'(vif.rid));
        if (i >= 0) begin
          axi4_item t = rd_pend[i];
          int unsigned n = t.data.size();
          // last_r != null means another burst stopped mid-way: the data is interleaved.
          if (last_r != null && last_r != t) begin
            t.interleaved = 1;
            last_r.interleaved = 1;
          end
          t.data = new[n + 1](t.data);
          t.resp = new[n + 1](t.resp);
          t.data[n] = AXI4_MAX_DW'(vif.rdata);
          t.resp[n] = axi4_resp_e'(vif.rresp);
          last_r = t;
          if (vif.rlast) begin
            t.completed_out_of_order = (i != 0);
            rd_pend.delete(i);
            last_r = null;
            t.t_done = $time;
            n_reads++;
            ap.write(t);
          end
        end
      end
    end
  endtask

  function void report_phase(uvm_phase phase);
    `uvm_info("AXI4_MON", $sformatf("%0d writes, %0d reads observed", n_writes, n_reads), UVM_LOW)
  endfunction
endclass
