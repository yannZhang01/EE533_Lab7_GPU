`timescale 1ns/1ps

module tb_gpu_top;

    // ------------------------------------------------------------
    // Parameters
    // ------------------------------------------------------------
    localparam integer DMEM_DEPTH = 256;
    localparam integer DMEM_AW    = 8;
    localparam integer DMEM_DW    = 64;

    localparam integer SORT_BASE  = 0;
    localparam integer SORT_LEN   = 10;

    // ------------------------------------------------------------
    // Clock / Reset / TB Freeze (ACTIVE-HIGH reset)
    // ------------------------------------------------------------
    reg clk;
    reg reset;       // 1 = reset, 0 = run
    reg tb_freeze;   // 1 = freeze pipeline (TB-controlled)

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    initial begin
        tb_freeze = 1'b1;
        reset     = 1'b1;
        repeat (5) @(posedge clk);
        reset     = 1'b0;
    end

    // ------------------------------------------------------------
    // DUT
    // ------------------------------------------------------------
    gpu_top dut (
        .clk      (clk),
        .reset    (reset),
        .tb_freeze(tb_freeze)
    );

    // ------------------------------------------------------------
    // Tap DMEM write port (Port A) via hierarchy
    // Edit paths if instance/port names differ.
    // ------------------------------------------------------------
    wire                   dmem_wea;
    wire [DMEM_AW-1:0]     dmem_addra;
    wire [DMEM_DW-1:0]     dmem_dina;

    assign dmem_wea   = dut.dmem.wea;
    assign dmem_addra = dut.dmem.addra;
    assign dmem_dina  = dut.dmem.dina;

    // ------------------------------------------------------------
    // Shadow memory scoreboard
    // ------------------------------------------------------------
    reg [DMEM_DW-1:0] shadow_mem [0:DMEM_DEPTH-1];
    integer i;

    initial begin
        for (i = 0; i < DMEM_DEPTH; i = i + 1) begin
            shadow_mem[i] = {DMEM_DW{1'b0}};
        end
    end

    // ------------------------------------------------------------
    // Bootstrap shadow_mem from DMEM init contents using Port B
    // (sync read: doutb is valid 1 cycle after addrb)
    //
    // NOTE: ISE Verilog dislikes slicing expressions like (A+B)[7:0],
    // so we use a temporary reg [DMEM_AW-1:0] for addresses.
    // ------------------------------------------------------------
		task bootstrap_shadow_from_dmem;
			 integer idx;
			 reg [DMEM_AW-1:0] addr;
			 reg [DMEM_DW-1:0] rdata;
			 begin
				  addr = SORT_BASE;
				  force dut.dmem.addrb = addr;
				  @(posedge clk);

				  for (idx = 1; idx < SORT_LEN; idx = idx + 1) begin
						addr = SORT_BASE + idx;
						force dut.dmem.addrb = addr;
						@(posedge clk);
						rdata = dut.dmem.doutb;
						shadow_mem[SORT_BASE + idx - 1] = rdata;
				  end

				  @(posedge clk);
				  rdata = dut.dmem.doutb;
				  shadow_mem[SORT_BASE + SORT_LEN - 1] = rdata;

				  release dut.dmem.addrb;
			 end
		endtask

    // ------------------------------------------------------------
    // Runtime tracking: update shadow_mem on every DMEM write
    // ------------------------------------------------------------
    always @(posedge clk) begin
        if (!reset && dmem_wea) begin
            shadow_mem[dmem_addra] <= dmem_dina;
        end
    end

    // ------------------------------------------------------------
    // Utilities: dump & check sorted region
    // ------------------------------------------------------------
    task dump_region;
        integer idx;
        begin
            $display("---- DMEM shadow dump: base=%0d len=%0d ----", SORT_BASE, SORT_LEN);
            for (idx = 0; idx < SORT_LEN; idx = idx + 1) begin
                $display("shadow_mem[%0d] = 0x%016h", SORT_BASE + idx, shadow_mem[SORT_BASE + idx]);
            end
            $display("--------------------------------------------");
        end
    endtask

    function is_sorted_non_decreasing;
        input dummy;
        integer idx2;
        reg [DMEM_DW-1:0] a;
        reg [DMEM_DW-1:0] b;
        begin
            is_sorted_non_decreasing = 1'b1;
            for (idx2 = 0; idx2 < SORT_LEN-1; idx2 = idx2 + 1) begin
                a = shadow_mem[SORT_BASE + idx2];
                b = shadow_mem[SORT_BASE + idx2 + 1];
                if (a > b) begin
                    is_sorted_non_decreasing = 1'b0;
                end
            end
        end
    endfunction

    // ------------------------------------------------------------
    // Run control
    // ------------------------------------------------------------
    initial begin
        @(negedge reset);

        tb_freeze = 1'b1;
        bootstrap_shadow_from_dmem();

        @(posedge clk);
        tb_freeze = 1'b0;

        repeat (2000) @(posedge clk);

        dump_region();

        if (is_sorted_non_decreasing(1'b0)) begin
            $display("[PASS] Sorted region is non-decreasing.");
        end else begin
            $display("[FAIL] Sorted region is NOT sorted.");
        end

        $finish;
    end

endmodule