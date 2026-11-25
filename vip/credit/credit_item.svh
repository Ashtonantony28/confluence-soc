// credit_item.svh: one flit. gap is the idle cycles the TX driver inserts before it; the
// monitor fills occupancy (flits in the receiver buffer, from the sender's credit view, right
// after this one) and credit_wait (cycles the sender waited for a credit).

class credit_item extends uvm_sequence_item;
  `uvm_object_utils(credit_item)
  rand bit [CREDIT_MAX_DW-1:0] data;
  rand int unsigned            gap;
  int unsigned                 occupancy;
  int unsigned                 credit_wait;
  constraint c_gap { gap dist {0 := 70, [1:4] := 25, [5:12] := 5}; }
  function new(string name = "credit_item"); super.new(name); endfunction
  function string convert2string(); return $sformatf("flit %0h gap %0d", data, gap); endfunction
  function void do_copy(uvm_object rhs);
    credit_item r;
    super.do_copy(rhs);
    $cast(r, rhs);
    data = r.data; gap = r.gap; occupancy = r.occupancy; credit_wait = r.credit_wait;
  endfunction
endclass
