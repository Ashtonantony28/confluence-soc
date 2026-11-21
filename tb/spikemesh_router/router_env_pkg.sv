// router_env_pkg.sv: SpikeMesh router-level environment (M5). One router_env drives one
// router (rtl/noc/router.sv) through credit VIP agents on N/E/S/W and AXI4-Stream VIP agents
// on the local port (router_harness.sv), and checks it against an independent model of
// SPEC §4 routing:
//   routing   every flit leaves on the XY-routed output port (or is dropped if its destination
//             is outside the mesh, counted against drop_cnt / err)
//   ordering  flits from one input to one output leave in the order they arrived
//   no loss   every flit that entered leaves (or is dropped) before the router goes idle
// Stimulus obeys the mesh contract of the router's formal environment: a flit arriving on a
// mesh port has a destination that XY routing upstream could send there; the local port (and
// the host port of (0,0)) may carry any destination.
package router_env_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import vip_common_pkg::*;
  import axis_pkg::*;
  import credit_pkg::*;

  localparam int FW = 48, FB = FW / 8;
  localparam int PN = 0, PE = 1, PS = 2, PW = 3, PL = 4, PDROP = 5;
  localparam int HOST_X = 15;
  localparam int DRAIN_MAX = 100_000;
  typedef credit_agent #(FW) c_agent_t;
  typedef axis_agent #(FW)   s_agent_t;
  typedef virtual router_status_if st_vif_t;

  function automatic string pname(int p);
    case (p) PN: return "N"; PE: return "E"; PS: return "S"; PW: return "W"; PL: return "L"; default: return "drop"; endcase
  endfunction

  // ------------------------------------------------------------------ configuration
  class router_env_cfg extends uvm_object;
    `uvm_object_utils(router_env_cfg)
    int unsigned x, y, mesh_x = 3, mesh_y = 3, depth = 4;
    int unsigned n_per_port = 300;          // flits per input port
    int unsigned gap_pct = 30;              // % of flits after an idle gap
    int unsigned drop_pct = 0;              // % of local-port flits with an out-of-mesh destination
    int          hotspot = -1;              // >= 0: send every flit that can go there to this output
    int unsigned rx_busy_pct = 30, rx_delay_max = 4, lout_busy_pct = 30;
    function new(string name = "router_env_cfg"); super.new(name); endfunction

    // the router has a neighbour (or the host link) on mesh port p
    function bit has_port(int p);
      case (p)
        PN: return y + 1 < mesh_y;
        PS: return y > 0;
        PE: return x + 1 < mesh_x;
        PW: return x > 0 || y == 0;        // (0,0)'s W port is the host link
        default: return 1;
      endcase
    endfunction
    function bit host_port(int p); return p == PW && x == 0 && y == 0; endfunction

    // destination (dx, dy) may arrive on input p (SPEC §4 XY routing upstream)
    function bit legal(int p, int dx, int dy);
      bit host = (dx == HOST_X), inmesh = dx < mesh_x && dy < mesh_y;
      if (!has_port(p)) return 0;
      if (host_port(p)) return inmesh;                           // host sends to cores only
      case (p)
        PN: return (inmesh && dx == x && dy <= y) || (host && x == 0);   // travelling south
        PS: return inmesh && dx == x && dy >= y;                        // travelling north
        PE: return (inmesh && dx <= x) || host;                         // travelling west
        PW: return inmesh && dx >= x;                                   // travelling east
        default: return inmesh || host;                                 // local core
      endcase
    endfunction

    // independent model of the output port (SPEC §4)
    function int route(bit [FW-1:0] f);
      int dx = f[45:42], dy = f[41:38];
      if (dx == HOST_X) return (x == 0 && y != 0) ? PS : PW;
      if (dx >= mesh_x || dy >= mesh_y) return PDROP;
      if (dx != x) return dx > x ? PE : PW;
      if (dy != y) return dy > y ? PN : PS;
      return PL;
    endfunction

    // a random flit for input p (header from the legal set, random type and payload)
    function bit [FW-1:0] pick(int p);
      int dxs[$], dys[$], k;
      bit [FW-1:0] f = {$urandom, $urandom};
      if (p == PL && drop_pct != 0 && $urandom_range(99) < drop_pct) begin
        f[45:42] = $urandom_range(14, mesh_x);
        f[41:38] = $urandom_range(15);
        if (f[45:42] < mesh_x) f[41:38] = $urandom_range(15, mesh_y);
        return f;
      end
      for (int dx = 0; dx < 16; dx++)
        for (int dy = 0; dy < (dx == HOST_X ? 1 : mesh_y); dy++)
          if ((dx < mesh_x || dx == HOST_X) && legal(p, dx, dy)) begin
            bit [FW-1:0] g = f;
            g[45:42] = dx; g[41:38] = dy;
            if (hotspot >= 0 && route(g) != hotspot && $urandom_range(9) != 0) continue;
            dxs.push_back(dx); dys.push_back(dy);
          end
      if (dxs.size() == 0)                     // hotspot unreachable from p: any legal destination
        for (int dx = 0; dx < 16; dx++)
          for (int dy = 0; dy < (dx == HOST_X ? 1 : mesh_y); dy++)
            if ((dx < mesh_x || dx == HOST_X) && legal(p, dx, dy)) begin dxs.push_back(dx); dys.push_back(dy); end
      k = $urandom_range(dxs.size() - 1);
      f[45:42] = dxs[k]; f[41:38] = dys[k];
      return f;
    endfunction
  endclass

  // ------------------------------------------------------------------ scoreboard
  class router_sb extends uvm_component;
    `uvm_component_utils(router_sb)
    router_env_cfg cfg;
    bit [FW-1:0]   exp[5][5][$];               // exp[out][in]: flits in arrival order
    int unsigned   n_in[5], n_out[5], n_drop_exp, n_ok, n_bad;
    int unsigned   route_hits[5][6];
    int unsigned   c_in, c_out, c_contend;
    covergroup cg_route;          // per-port views; legal (in, out) pairs are counted by routes_hit()
      cp_in:  coverpoint c_in  { bins p[] = {[0:4]}; }
      cp_out: coverpoint c_out { bins p[] = {[0:5]}; }
    endgroup
    covergroup cg_contend;
      cp_out: coverpoint c_out { bins p[] = {[0:4]}; }
      cp_n:   coverpoint c_contend { bins alone = {1}; bins two = {2}; bins three_plus = {[3:5]}; }
      x_out_n: cross cp_out, cp_n;
    endgroup
    function new(string name, uvm_component parent); super.new(name, parent); cg_route = new(); cg_contend = new(); endfunction

    function void flit_in(int p, bit [FW-1:0] f);
      int o = cfg.route(f);
      n_in[p]++;
      route_hits[p][o]++;
      c_in = p; c_out = o; cg_route.sample();
      if (o == PDROP) n_drop_exp++;
      else exp[o][p].push_back(f);
    endfunction

    function void flit_out(int o, bit [FW-1:0] f);
      n_out[o]++;
      c_out = o; c_contend = 0;
      for (int i = 0; i < 5; i++) if (exp[o][i].size() != 0) c_contend++;
      cg_contend.sample();
      for (int i = 0; i < 5; i++)
        if (exp[o][i].size() != 0 && exp[o][i][0] == f) begin
          void'(exp[o][i].pop_front()); n_ok++; return;
        end
      n_bad++;
      for (int i = 0; i < 5; i++)
        foreach (exp[o][i][k]) if (exp[o][i][k] == f) begin
          `uvm_error("ROUTER_SB", $sformatf("%s: flit %012h from %s left %s out of order (%0d older flits from that input still queued)",
                     get_parent().get_name(), f, pname(i), pname(o), k))
          exp[o][i].delete(k); return;
        end
      for (int oo = 0; oo < 5; oo++) for (int i = 0; i < 5; i++)
        foreach (exp[oo][i][k]) if (exp[oo][i][k] == f) begin
          `uvm_error("ROUTER_SB", $sformatf("%s: flit %012h from %s misrouted to %s (expected %s)",
                     get_parent().get_name(), f, pname(i), pname(o), pname(oo)))
          exp[oo][i].delete(k); return;
        end
      `uvm_error("ROUTER_SB", $sformatf("%s: flit %012h on %s was never sent (corrupted or duplicated)",
                 get_parent().get_name(), f, pname(o)))
    endfunction

    function int unsigned pending();
      int unsigned n = 0;
      for (int o = 0; o < 5; o++) for (int i = 0; i < 5; i++) n += exp[o][i].size();
      return n;
    endfunction

    // XY routes this router can see: (in, out) pairs some legal flit takes (drops excluded)
    function bit legal_pair(int i, int o);
      for (int dx = 0; dx < 16; dx++)
        for (int dy = 0; dy < 16; dy++) begin
          bit [FW-1:0] f = '0;
          f[45:42] = dx; f[41:38] = dy;
          if (cfg.legal(i, dx, dy) && cfg.route(f) == o) return 1;
        end
      return 0;
    endfunction
    function real routes_hit(output int unsigned hit, output int unsigned total);
      hit = 0; total = 0;
      for (int i = 0; i < 5; i++) for (int o = 0; o < 5; o++)
        if (legal_pair(i, o)) begin total++; if (route_hits[i][o] != 0) hit++; end
      return total ? 100.0 * hit / total : 0.0;
    endfunction

    function void check_phase(uvm_phase phase);
      for (int o = 0; o < 5; o++) for (int i = 0; i < 5; i++)
        if (exp[o][i].size() != 0)
          `uvm_error("ROUTER_SB", $sformatf("%s: %0d flits %s -> %s lost (first %012h)", get_parent().get_name(),
                     exp[o][i].size(), pname(i), pname(o), exp[o][i][0]))
    endfunction

    function void report_phase(uvm_phase phase);
      string s = "";
      int unsigned legal_pairs = 0, hit_pairs = 0;
      for (int i = 0; i < 5; i++) for (int o = 0; o < 6; o++) begin
        if (route_hits[i][o]) begin hit_pairs++; s = {s, $sformatf(" %s>%s:%0d", pname(i), pname(o), route_hits[i][o])}; end
      end
      `uvm_info("ROUTER_SB", $sformatf("%s (%0d,%0d): %0d flits checked, %0d dropped as expected, %0d bad; routes%s",
                get_parent().get_name(), cfg.x, cfg.y, n_ok, n_drop_exp, n_bad, s), UVM_LOW)
    endfunction
  endclass

  // forwarders: one per port, so a single scoreboard knows which port a flit used
  class credit_fwd extends uvm_subscriber #(credit_item);
    `uvm_component_utils(credit_fwd)
    router_sb sb; int port; bit is_out;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void write(credit_item t);
      if (is_out) sb.flit_out(port, FW'(t.data)); else sb.flit_in(port, FW'(t.data));
    endfunction
  endclass
  class axis_fwd extends uvm_subscriber #(axis_item);
    `uvm_component_utils(axis_fwd)
    router_sb sb; bit is_out;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void write(axis_item t);
      foreach (t.data[i]) if (is_out) sb.flit_out(PL, FW'(t.data[i])); else sb.flit_in(PL, FW'(t.data[i]));
    endfunction
  endclass

  // ------------------------------------------------------------------ sequences
  typedef class router_env;

  class router_one_seq extends uvm_sequence #(credit_item);
    `uvm_object_utils(router_one_seq)
    credit_item t;
    function new(string name = "router_one_seq"); super.new(name); endfunction
    task body(); start_item(t); finish_item(t); endtask
  endclass

  class router_local_seq extends axis_base_seq;
    `uvm_object_utils(router_local_seq)
    router_env env;
    function new(string name = "router_local_seq"); super.new(name); endfunction
    task body();
      repeat (env.cfg.n_per_port) begin
        axis_item t = make();
        t.len = FB;
        t.gap_before = ($urandom_range(99) < env.cfg.gap_pct) ? $urandom_range(6, 1) : 0;
        t.data = new[1]; t.keep = new[1]; t.user = new[1];
        t.data[0] = env.cfg.pick(PL); t.keep[0] = '1; t.user[0] = '0;
        start_item(t);
        finish_item(t);
      end
    endtask
  endclass

  // ------------------------------------------------------------------ environment
  class router_env extends uvm_env;
    `uvm_component_utils(router_env)
    router_env_cfg cfg;
    credit_cfg     tcfg[4], rcfg[4];
    axis_cfg       icfg, ocfg;
    c_agent_t      tx[4], rx[4];
    s_agent_t      lin, lout;
    credit_fwd     fin[4], fout[4];
    axis_fwd       lfin, lfout;
    router_sb      sb;
    st_vif_t       svif;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction

    function void build_phase(uvm_phase phase);
      if (!uvm_config_db#(router_env_cfg)::get(this, "", "cfg", cfg)) `uvm_fatal("NOCFG", "router_env_cfg not set")
      if (!uvm_config_db#(st_vif_t)::get(this, "", "svif", svif)) `uvm_fatal("NOVIF", "router_status_if not set")
      for (int p = 0; p < 4; p++) begin
        tcfg[p] = credit_cfg::type_id::create($sformatf("tcfg%0d", p));
        tcfg[p].role = CREDIT_TX; tcfg[p].depth = cfg.depth;
        rcfg[p] = credit_cfg::type_id::create($sformatf("rcfg%0d", p));
        rcfg[p].role = CREDIT_RX; rcfg[p].depth = cfg.depth;
        uvm_config_db#(credit_cfg)::set(this, $sformatf("tx%0d", p), "cfg", tcfg[p]);
        uvm_config_db#(credit_cfg)::set(this, $sformatf("rx%0d", p), "cfg", rcfg[p]);
        tx[p] = c_agent_t::type_id::create($sformatf("tx%0d", p), this);
        rx[p] = c_agent_t::type_id::create($sformatf("rx%0d", p), this);
        fin[p]  = credit_fwd::type_id::create($sformatf("fin%0d", p), this);
        fout[p] = credit_fwd::type_id::create($sformatf("fout%0d", p), this);
      end
      icfg = axis_cfg::type_id::create("icfg");
      icfg.role = AXIS_MASTER; icfg.data_bytes = FB; icfg.has_cov = 0; icfg.beat_gap_pct = 0;
      ocfg = axis_cfg::type_id::create("ocfg");
      ocfg.role = AXIS_SLAVE; ocfg.data_bytes = FB; ocfg.has_cov = 0;
      uvm_config_db#(axis_cfg)::set(this, "lin", "cfg", icfg);
      uvm_config_db#(axis_cfg)::set(this, "lout", "cfg", ocfg);
      lin  = s_agent_t::type_id::create("lin", this);
      lout = s_agent_t::type_id::create("lout", this);
      lfin  = axis_fwd::type_id::create("lfin", this);
      lfout = axis_fwd::type_id::create("lfout", this);
      sb = router_sb::type_id::create("sb", this);
    endfunction

    function void connect_phase(uvm_phase phase);
      sb.cfg = cfg;
      for (int p = 0; p < 4; p++) begin
        fin[p].sb = sb;  fin[p].port = p;  fin[p].is_out = 0;
        fout[p].sb = sb; fout[p].port = p; fout[p].is_out = 1;
        tx[p].mon.ap.connect(fin[p].analysis_export);
        rx[p].mon.ap.connect(fout[p].analysis_export);
      end
      lfin.sb = sb; lfin.is_out = 0; lfout.sb = sb; lfout.is_out = 1;
      lin.mon.ap.connect(lfin.analysis_export);
      lout.mon.ap.connect(lfout.analysis_export);
    endfunction

    // knobs from cfg into the agents (call before run)
    function void apply_profile();
      for (int p = 0; p < 4; p++) begin rcfg[p].rx_busy_pct = cfg.rx_busy_pct; rcfg[p].rx_delay_max = cfg.rx_delay_max; end
      ocfg.slave_ready_busy_pct = cfg.lout_busy_pct;
    endfunction

    // all traffic, then wait until every expected flit left and the router is idle
    // A watchdog bounds the stimulus: a sender starved of credits is a failure, not a hang.
    task run_traffic();
      bit done = 0;
      fork
        begin
          for (int p = 0; p < 4; p++) begin
            automatic int pp = p;
            if (cfg.has_port(pp)) fork send_credit(pp); join_none
          end
          fork send_local(); join_none
          wait fork;                       // the senders are this block's own children
          done = 1;
        end
        begin
          int unsigned c = 0, last = 0, still = 0;
          while (!done) begin
            int unsigned now;
            @(posedge svif.clk);
            now = sb.n_in[0] + sb.n_in[1] + sb.n_in[2] + sb.n_in[3] + sb.n_in[4];
            still = (now == last) ? still + 1 : 0;
            last = now;
            if (still > DRAIN_MAX) begin
              `uvm_error("ROUTER", $sformatf("%s: stimulus stalled, no flit accepted for %0d cycles (%0d sent)", get_name(), DRAIN_MAX, now))
              break;
            end
          end
        end
      join_any
      disable fork;
      drain();
    endtask

    task send_credit(int p);
      repeat (cfg.n_per_port) begin
        credit_item t = credit_item::type_id::create("t");
        router_one_seq s = router_one_seq::type_id::create("s");
        t.data = CREDIT_MAX_DW'(cfg.pick(p));
        t.gap = ($urandom_range(99) < cfg.gap_pct) ? $urandom_range(6, 1) : 0;
        s.t = t;
        s.start(tx[p].sqr);
      end
    endtask

    task send_local();
      router_local_seq s = router_local_seq::type_id::create("s");
      s.env = this;
      s.start(lin.sqr);
    endtask

    task drain();
      int unsigned c = 0, idle = 0;
      while (idle < 8) begin
        @(posedge svif.clk);
        idle = (sb.pending() == 0 && !svif.busy) ? idle + 1 : 0;
        if (++c > DRAIN_MAX) begin
          `uvm_error("ROUTER", $sformatf("%s did not drain: %0d flits still expected, busy=%0b", get_name(), sb.pending(), svif.busy))
          break;
        end
      end
    endtask

    function void check_phase(uvm_phase phase);
      int unsigned want = sb.n_drop_exp > 255 ? 255 : sb.n_drop_exp;
      for (int p = 0; p < 5; p++)
        if (sb.n_in[p] != ((p == PL || cfg.has_port(p)) ? cfg.n_per_port : 0))
          `uvm_error("ROUTER", $sformatf("%s: input %s took %0d flits, %0d were to be sent", get_name(), pname(p),
                     sb.n_in[p], (p == PL || cfg.has_port(p)) ? cfg.n_per_port : 0))
      if (svif.err !== (sb.n_drop_exp != 0) || svif.drop_cnt !== 8'(want))
        `uvm_error("ROUTER", $sformatf("%s: err=%0b drop_cnt=%0d, expected err=%0b drop_cnt=%0d", get_name(),
                   svif.err, svif.drop_cnt, sb.n_drop_exp != 0, want))
    endfunction
  endclass

  // ------------------------------------------------------------------ tests
  // Both routers (centre (1,1) and corner (0,0) of a 3x3 mesh) run concurrently.
  class router_base_test extends uvm_test;
    `uvm_component_utils(router_base_test)
    router_env     rc, rh;
    router_env_cfg ccfg, hcfg;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void build_phase(uvm_phase phase);
      ccfg = router_env_cfg::type_id::create("ccfg"); ccfg.x = 1; ccfg.y = 1;
      hcfg = router_env_cfg::type_id::create("hcfg"); hcfg.x = 0; hcfg.y = 0;
      set_profile(ccfg); set_profile(hcfg);
      uvm_config_db#(router_env_cfg)::set(this, "rc", "cfg", ccfg);
      uvm_config_db#(router_env_cfg)::set(this, "rh", "cfg", hcfg);
      rc = router_env::type_id::create("rc", this);
      rh = router_env::type_id::create("rh", this);
    endfunction
    virtual function void set_profile(router_env_cfg c);
      c.rx_busy_pct = $urandom_range(0, 50); c.rx_delay_max = $urandom_range(1, 5);
      c.lout_busy_pct = $urandom_range(0, 50); c.gap_pct = $urandom_range(0, 60);
    endfunction
    function void end_of_elaboration_phase(uvm_phase phase); rc.apply_profile(); rh.apply_profile(); endfunction
    task run_phase(uvm_phase phase);
      phase.raise_objection(this);
      while (!rc.svif.rst_n) @(posedge rc.svif.clk);
      repeat (5) @(posedge rc.svif.clk);
      fork rc.run_traffic(); rh.run_traffic(); join
      repeat (10) @(posedge rc.svif.clk);
      phase.drop_objection(this);
    endtask
    function void report_phase(uvm_phase phase);
      uvm_report_server rs = uvm_report_server::get_server();
      int unsigned ch, ct, hh, ht;
      real cp = rc.sb.routes_hit(ch, ct), hp = rh.sb.routes_hit(hh, ht);
      `uvm_info("ROUTER_COV", $sformatf("centre: XY routes %0d/%0d (%.1f%%), contention %.1f%%; corner: XY routes %0d/%0d (%.1f%%), contention %.1f%%",
                ch, ct, cp, rc.sb.cg_contend.get_inst_coverage(), hh, ht, hp, rh.sb.cg_contend.get_inst_coverage()), UVM_LOW)
      if (rs.get_severity_count(UVM_ERROR) + rs.get_severity_count(UVM_FATAL) == 0) $display("*** TEST PASSED ***");
      else $display("*** TEST FAILED ***");
    endfunction
  endclass

  // random legal traffic, random backpressure
  class router_random_test extends router_base_test;
    `uvm_component_utils(router_random_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
  endclass

  // congestion storm: every input back to back, slow receivers on every output
  class router_storm_test extends router_base_test;
    `uvm_component_utils(router_storm_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void set_profile(router_env_cfg c);
      c.gap_pct = 0; c.rx_busy_pct = $urandom_range(60, 90); c.rx_delay_max = $urandom_range(4, 12);
      c.lout_busy_pct = $urandom_range(60, 90);
    endfunction
  endclass

  // hotspot: almost all traffic to one output (local or, on the corner, the host link)
  class router_hotspot_test extends router_base_test;
    `uvm_component_utils(router_hotspot_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void set_profile(router_env_cfg c);
      super.set_profile(c);
      c.gap_pct = 0;
      c.hotspot = (c.x == 0 && c.y == 0 && $urandom_range(1)) ? PW : PL;
    endfunction
  endclass

  // out-of-mesh destinations on the local port: dropped, counted in drop_cnt, err set,
  // and the router keeps routing everything else
  class router_drop_test extends router_base_test;
    `uvm_component_utils(router_drop_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void set_profile(router_env_cfg c);
      super.set_profile(c);
      c.drop_pct = 15;
    endfunction
  endclass
endpackage
