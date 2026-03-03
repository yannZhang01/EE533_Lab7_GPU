// ============================================================
// Register File module for GPU pipeline
// ============================================================
module gpu_regfile #(
    parameter NUM_REGS = 16,
    parameter DATA_WIDTH = 64,
    parameter ADDR_WIDTH = 4  
)(
    input  wire                     clk,
    input  wire                     reset,

    // Read Port 1
    input  wire [ADDR_WIDTH-1:0]    gpu_rs1_addr,
    output reg  [DATA_WIDTH-1:0]    gpu_rs1_data,

    // Read Port 2
    input  wire [ADDR_WIDTH-1:0]    gpu_rs2_addr,
    output reg  [DATA_WIDTH-1:0]    gpu_rs2_data,

    // Write Port
    input  wire                     gpu_rd_wenable,
    input  wire [ADDR_WIDTH-1:0]    gpu_rd_addr,
    input  wire [DATA_WIDTH-1:0]    gpu_rd_data
);

    // Register array
    reg [DATA_WIDTH-1:0] regs [0:NUM_REGS-1];

    integer i;

    // Reset registers to zero
    always @(posedge clk) begin
        if (reset) begin
            for (i = 0; i < NUM_REGS; i = i + 1)
                regs[i] <= 0;
        end
        else if (gpu_rd_wenable) begin
            regs[gpu_rd_addr] <= gpu_rd_data;
        end
    end
    

    // Asynchronous read (simple and fast)
    always @(*) begin
        if (reset) begin
            gpu_rs1_data = 0;
            gpu_rs2_data = 0;
        end
        else begin
            gpu_rs1_data = regs[gpu_rs1_addr];
            gpu_rs2_data = regs[gpu_rs2_addr];
        end
    end

endmodule