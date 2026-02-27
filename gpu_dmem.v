// ============================================================
// GPU Data Memory (64-bit Block RAM)
// Fully aligned with Instruction Memory program
// ============================================================

module gpu_dmem (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        mem_read,
    input  wire        mem_write,
    input  wire [31:0] addr,
    input  wire [63:0] write_data,

    output reg  [63:0] read_data
);

    reg [63:0] mem [0:255];

    wire [7:0] index;
    assign index = addr[10:3];   // 8-byte aligned

    integer i;

    // ============================
    // Synchronous Access
    // ============================
    always @(posedge clk) begin
        if (!rst_n)
            read_data <= 64'd0;
        else begin
            if (mem_write)
                mem[index] <= write_data;

            if (mem_read)
                read_data <= mem[index];
        end
    end

    // ============================
    // INITIAL DATA (MATCH IMEM)
    // ============================
    initial begin

        // Clear all memory
        for (i = 0; i < 256; i = i + 1)
            mem[i] = 64'd0;

        // ----------------------------------------
        // Scalar Test Data
        // ----------------------------------------
        mem[0] = 64'd10;   // addr 0
        mem[1] = 64'd20;   // addr 8

        // ----------------------------------------
        // Tensor Test Data
        // ----------------------------------------
        // Vector A at addr 16
        mem[2] = {16'd2,16'd3,16'd4,16'd5};

        // Vector B at addr 24
        mem[3] = {16'd1,16'd2,16'd3,16'd4};

        // ----------------------------------------
        // Reserved result location (addr 32)
        // ----------------------------------------
        mem[4] = 64'd0;   // will store dot result (expect 40)

    end

endmodule