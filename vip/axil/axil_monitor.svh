// axil_monitor.svh: rebuilds complete AXI4-Lite accesses from the five channels.
//   ap       one item per completed access (write: at B, read: at R)
//   ap_req   one item per address handshake (for scoreboards that track in-flight accesses)
// Pairs AW with W in order (W may lead AW) and matches B/R to the oldest outstanding access
// of that direction (AXI4-Lite responses are in order). Items are annotated with the
// outstanding depth, latency and W-before-AW, which the coverage collector samples.

class axil_monitor #(int AW = 32, int DW = 32) extends uvm_monitor;
  `uvm_component_param_utils(axil_monitor #(AW, DW))

  typedef virtual axil_if #(.AW(AW), .DW(DW)) vif_t;

  vif_t    vif;
  axil_cfg cfg;
  uvm_analysis_port #(axil_item) ap;
  uvm_analysis_port #(axil_item) ap_req;

  axil_item        aw_q[$];      // addresses without data yet
  axil_item        w_q[$];       // data without address yet (data, strb, t_addr = W time)
  axil_item        wr_pend[$];   // address + data seen, waiting for B
  axil_item        rd_pend[$];   // waiting for R
  longint unsigned cycle;
  int unsigned     n_writes, n_reads;

  function new(string name, uvm_component parent); super.new(name, parent); endfunction

  function void build_phase(uvm_phase phase);
    ap = new("ap", this);
    ap_req = new("ap_req", this);
    if (!uvm_config_db#(vif_t)::get(this, "", "vif", vif)) `uvm_fatal("NOVIF", "axil vif not set")
    if (!uvm_config_db#(axil_cfg)::get(this, "", "cfg", cfg)) `uvm_fatal("NOCFG", "axil cfg not set")
  endfunction

  function axil_item new_item(axil_dir_e d);
    axil_item t = axil_item::type_id::create(d == AXIL_WRITE ? "wr" : "rd");
    t.dir = d; t.dbytes = cfg.data_bytes; t.addr_width = cfg.addr_width;
    t.t_addr = $time;
    t.cyc_addr = cycle;
    return t;
  endfunction

  function void finish(axil_item t, bit [1:0] resp);
    t.resp = axil_resp_e'(resp);
    t.t_done = $time;
    t.latency = int'(cycle - t.cyc_addr);
    ap.write(t);
  endfunction

  task run_phase(uvm_phase phase);
    forever begin
      @(posedge vif.aclk);
      cycle++;
      if (!vif.aresetn) begin
        aw_q.delete(); w_q.delete(); wr_pend.delete(); rd_pend.delete();
        continue;
      end
      if (vif.awvalid && vif.awready) begin
        axil_item t = new_item(AXIL_WRITE);
        t.addr = AXIL_MAX_AW'(vif.awaddr); t.prot = vif.awprot;
        t.outstanding_at_issue = wr_pend.size() + aw_q.size();
        aw_q.push_back(t);
        ap_req.write(t);
      end
      if (vif.wvalid && vif.wready) begin
        axil_item w = axil_item::type_id::create("wd");
        w.data = AXIL_MAX_DW'(vif.wdata); w.strb = (AXIL_MAX_DW/8)'(vif.wstrb); w.t_addr = $time;
        w_q.push_back(w);
      end
      while (aw_q.size() > 0 && w_q.size() > 0) begin
        axil_item a = aw_q.pop_front();
        axil_item w = w_q.pop_front();
        a.data = w.data; a.strb = w.strb; a.w_before_aw = (w.t_addr < a.t_addr);
        wr_pend.push_back(a);
      end
      // A B or R with nothing outstanding is a protocol error reported by axil_checker.
      if (vif.bvalid && vif.bready && wr_pend.size() > 0) begin
        n_writes++;
        finish(wr_pend.pop_front(), vif.bresp);
      end
      if (vif.arvalid && vif.arready) begin
        axil_item t = new_item(AXIL_READ);
        t.addr = AXIL_MAX_AW'(vif.araddr); t.prot = vif.arprot;
        t.outstanding_at_issue = rd_pend.size();
        rd_pend.push_back(t);
        ap_req.write(t);
      end
      if (vif.rvalid && vif.rready && rd_pend.size() > 0) begin
        axil_item t = rd_pend.pop_front();
        t.data = AXIL_MAX_DW'(vif.rdata);
        n_reads++;
        finish(t, vif.rresp);
      end
    end
  endtask

  function void report_phase(uvm_phase phase);
    `uvm_info("AXIL_MON", $sformatf("%0d writes, %0d reads observed", n_writes, n_reads), UVM_LOW)
  endfunction
endclass
