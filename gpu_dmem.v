// ============================================================
// Data Memory
// ============================================================
module gpu_dmem #(
    parameter MEM_SIZE   = 256, // 256 words of data memory (1KB)
    parameter ADDR_WIDTH = 8,   // 8 bits for addressing 256 words
    parameter DATA_WIDTH = 64   // 64-bit data
)(
    input  [ADDR_WIDTH-1:0] dmem_read_addr,  // address from EX/MEM register
    input                   dmem_read_en,    // enable signal for reading from memory
    input  [ADDR_WIDTH-1:0] dmem_write_addr, // address for writing data
    input  [DATA_WIDTH-1:0] dmem_write_data, // data to write to memory
    input                   dmem_write_en,   // enable signal for writing to memory

    input                   clk,
    input                   reset,

    output [DATA_WIDTH-1:0] dmem_data        // data output to MEM stage
);

    reg [DATA_WIDTH-1:0] mem [0:MEM_SIZE-1];
    integer i;

    // Read data (combinational)
    assign dmem_data = dmem_read_en ? mem[dmem_read_addr] : 64'b0;

    // Write data (synchronous)
    always @(posedge clk) begin
        if (reset) begin
            // mem[0] <= 64'h0000000000000001;
            for (i = 0; i < MEM_SIZE; i = i + 1) begin
                mem[i] <= 64'h0000000000000000;
            end
        end else if (dmem_write_en) begin
            mem[dmem_write_addr] <= dmem_write_data;
        end
    end

endmodule