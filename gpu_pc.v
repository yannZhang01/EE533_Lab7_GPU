
module gpu_pc #(
    parameter ADDR_WIDTH = 32,
    parameter PC_RESET_ADDR = 32'h0000_0000
)(
    input  wire                   clk,
    input  wire                   rst_n,          // Active-low synchronous reset
    input  wire                   stall,          // 1 = hold PC
    input  wire                   branch_valid,   // 1 = take branch
    input  wire [ADDR_WIDTH-1:0]  branch_target,  // Branch target address

    output reg  [ADDR_WIDTH-1:0]  pc,             // Current PC
    output wire [ADDR_WIDTH-1:0]  pc_plus4        // PC + 4
);

    assign pc_plus4 = pc + 4;

    always @(posedge clk) begin
        if (!rst_n) begin
            pc <= PC_RESET_ADDR;
        end
        else if (stall) begin
            pc <= pc;   // Hold current PC
        end
        else if (branch_valid) begin
            pc <= branch_target;
        end
        else begin
            pc <= pc + 4;
        end
    end

endmodule