// vip_common_pkg.sv: protocol-independent helpers shared by every Confluence VIP (ADR 0002).
//   vip_mem      sparse byte-addressed memory used by reactive slaves and scoreboards
//   vip_delay    small helper for "mostly zero, sometimes long" random delays
package vip_common_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"

  // What an unwritten byte reads as. ADDR_HASH lets an independent scoreboard predict
  // reads of never-written memory without sharing state with the slave.
  typedef enum int { UNINIT_ZERO, UNINIT_ADDR_HASH } vip_uninit_e;

  function automatic bit [7:0] vip_addr_hash(bit [63:0] a);
    return a[7:0] ^ a[15:8] ^ a[23:16] ^ a[31:24] ^ 8'h5A;
  endfunction

  class vip_mem extends uvm_object;
    `uvm_object_utils(vip_mem)
    bit [7:0]    mem[bit [63:0]];
    vip_uninit_e uninit = UNINIT_ADDR_HASH;

    function new(string name = "vip_mem"); super.new(name); endfunction

    function bit [7:0] read_byte(bit [63:0] a);
      if (mem.exists(a)) return mem[a];
      return (uninit == UNINIT_ZERO) ? 8'h00 : vip_addr_hash(a);
    endfunction

    function void write_byte(bit [63:0] a, bit [7:0] d);
      mem[a] = d;
    endfunction

    function bit written(bit [63:0] a);
      return mem.exists(a);
    endfunction

    function void clear();
      mem.delete();
    endfunction
  endclass

  class vip_delay;
    // Returns 0 with probability (100 - busy_pct)%, else uniform in [1, max].
    static function int unsigned pick(int unsigned busy_pct, int unsigned max);
      if (max == 0 || ($urandom_range(99) >= busy_pct)) return 0;
      return $urandom_range(max, 1);
    endfunction
  endclass

  // Shared record of protocol-checker failures. Checkers (modules) call record(); tests read
  // hits[] to prove that an injected violation was caught by the intended rule.
  class vip_checker_db;
    static int unsigned hits[string];
    static bit          expect_violations = 0;
    static function void record(string rule);
      if (hits.exists(rule)) hits[rule]++;
      else hits[rule] = 1;
    endfunction
    static function int unsigned count(string rule);
      return hits.exists(rule) ? hits[rule] : 0;
    endfunction
  endclass
endpackage
