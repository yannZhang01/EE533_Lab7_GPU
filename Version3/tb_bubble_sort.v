`timescale 1ns/1ps

module tb_gpu;

reg clk;
reg reset;

integer i;

gpu_top uut (
    .clk(clk),
    .reset(reset)
);

////////////////////////
// Clock generation
////////////////////////
initial begin
    clk = 0;
    forever #5 clk = ~clk;   // 100MHz clock
end

////////////////////////
// Reset sequence
////////////////////////
initial begin
    reset = 1;
    #20;
    reset = 0;
end

////////////////////////
// Load instruction memory from hex
////////////////////////
initial begin
	 wait(reset == 0);
    $readmemh("bubble_sort_10_clean.hex", uut.imem.mem);
end

////////////////////////
// Initialize data memory
////////////////////////
initial begin
	 wait(reset == 0);
    #1;

    uut.dmem.mem[0] = 64'd45;
    uut.dmem.mem[1] = 64'd3;
    uut.dmem.mem[2] = 64'd99;
    uut.dmem.mem[3] = 64'd12;
    uut.dmem.mem[4] = 64'd77;
    uut.dmem.mem[5] = 64'd5;
    uut.dmem.mem[6] = 64'd1;
    uut.dmem.mem[7] = 64'd88;
    uut.dmem.mem[8] = 64'd42;
    uut.dmem.mem[9] = 64'd17;
end

////////////////////////
// Simulation end and result check
////////////////////////
initial begin
    #6000;

    $display("Sorted result:");
    for ( i = 0; i < 10; i = i + 1) begin
        $display("%d", uut.dmem.mem[i]);
    end

    $stop;
end

endmodule