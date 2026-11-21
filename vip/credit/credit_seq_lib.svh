// credit_seq_lib.svh: n random flits with the item's default gap distribution, or a burst
// (gap 0) that exhausts the receiver's credits.

class credit_random_seq extends uvm_sequence #(credit_item);
  `uvm_object_utils(credit_random_seq)
  int unsigned n = 50;
  function new(string name = "credit_random_seq"); super.new(name); endfunction
  task body();
    repeat (n) begin
      credit_item t = credit_item::type_id::create("t");
      start_item(t);
      if (!t.randomize()) `uvm_fatal("RAND", "credit_item randomize failed")
      finish_item(t);
    end
  endtask
endclass

class credit_burst_seq extends credit_random_seq;
  `uvm_object_utils(credit_burst_seq)
  function new(string name = "credit_burst_seq"); super.new(name); endfunction
  task body();
    repeat (n) begin
      credit_item t = credit_item::type_id::create("t");
      start_item(t);
      if (!t.randomize() with { gap == 0; }) `uvm_fatal("RAND", "credit_item randomize failed")
      finish_item(t);
    end
  endtask
endclass
