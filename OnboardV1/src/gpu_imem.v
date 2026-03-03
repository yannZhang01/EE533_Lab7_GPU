// ============================================================
// Instruction Memory
// ============================================================
module gpu_imem #(
    parameter MEM_SIZE   = 512, // 512 words of instruction memory (2KB)
    parameter ADDR_WIDTH = 9,   // 9 bits for addressing 512 words
    parameter DATA_WIDTH = 32   // 32-bit instructions
)(
    input  [ADDR_WIDTH-1:0] imem_read_addr,  // address from IF1/IF2 register

    // In simulation, we disable writing to instruction memory.
    input  [ADDR_WIDTH-1:0] imem_write_addr, // address for writing instruction
    input  [DATA_WIDTH-1:0] imem_write_data, // instruction data to write
    input                   imem_write_en,   // enable signal for writing instruction

    input                   clk,
    input                   reset,

    output [DATA_WIDTH-1:0] imem_instr       // instruction output to IF2 stage
);

    reg [DATA_WIDTH-1:0] mem [0:MEM_SIZE-1];
    integer i;

    initial begin
        $readmemh("bubble_sort_10_clean.hex", mem);
    end

    // Read instruction (combinational)
    assign imem_instr = mem[imem_read_addr];

    // Write instruction (synchronous)
    always @(posedge clk) begin
        if (reset) begin
            // onboard version do nothing
        end else if (imem_write_en) begin
            mem[imem_write_addr] <= imem_write_data;
        end
    end

endmodule