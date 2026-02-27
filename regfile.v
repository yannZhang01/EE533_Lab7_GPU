//regfile
module regfile #(
    parameter NUM_REGS = 16,
    parameter DATA_WIDTH = 64,
    parameter ADDR_WIDTH = 4  // log2(16) = 4
)(
    input  wire                     clk,
    input  wire                     rst_n,

    // Read Port 1
    input  wire [ADDR_WIDTH-1:0]    rs1_addr,
    output wire [DATA_WIDTH-1:0]    rs1_data,

    // Read Port 2
    input  wire [ADDR_WIDTH-1:0]    rs2_addr,
    output wire [DATA_WIDTH-1:0]    rs2_data,

    // Write Port
    input  wire                     rd_we,
    input  wire [ADDR_WIDTH-1:0]    rd_addr,
    input  wire [DATA_WIDTH-1:0]    rd_data
);

    // Register array
    reg [DATA_WIDTH-1:0] regs [0:NUM_REGS-1];

    integer i;

    // Reset registers to zero
    always @(posedge clk) begin
        if (!rst_n) begin
            for (i = 0; i < NUM_REGS; i = i + 1)
                regs[i] <= 0;
        end
        else if (rd_we) begin
            regs[rd_addr] <= rd_data;
        end
    end

    // Asynchronous read (simple and fast)
    assign rs1_data = regs[rs1_addr];
    assign rs2_data = regs[rs2_addr];

endmodule