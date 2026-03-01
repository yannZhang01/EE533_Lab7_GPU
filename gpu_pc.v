// ============================================================
// Program Counter (PC) module for GPU pipeline
// ============================================================
module gpu_pc #(
    parameter ADDR_WIDTH = 9,
    parameter [ADDR_WIDTH-1:0] PC_RESET = {ADDR_WIDTH{1'b0}}
)(
    input  wire                     clk,
    input  wire                     reset,

    // Stall control: 1 = update PC, 0 = hold PC
    input  wire                     pc_enable,

    // Branch redirect
    input  wire                     pc_branch_valid,
    input  wire [ADDR_WIDTH-1:0]     pc_branch_target,

    // Default next PC candidate computed in IF stage
    input  wire [ADDR_WIDTH-1:0]     pc_next,

    // Current PC value for IMEM address this cycle
    output reg  [ADDR_WIDTH-1:0]     pc_current
);

    wire [ADDR_WIDTH-1:0] pc_load_value;

    // Priority: branch > default
    assign pc_load_value = pc_branch_valid ? pc_branch_target : pc_next;

    always @(posedge clk) begin
        if (reset) begin
            pc_current <= PC_RESET;
        end else if (pc_enable) begin
            pc_current <= pc_load_value;
        end
    end

endmodule