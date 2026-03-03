`timescale 1ns / 1ps
module control_unit (
    input  wire         clk,
    input  wire         rst_n,

    // ----- Inputs from IF/ID (ID stage) -----
    input  wire [3:0]   opcode_id,
    input  wire [1:0]   dtype_id,
    input  wire [3:0]   rd_id,         // now matches mapping: rd = bits[25:22]
    input  wire [3:0]   rs1_id,        // rs1 = bits[21:18]
    input  wire [3:0]   rs2_id,        // rs2 = bits[17:14]
    input  wire         branch_cond_id,
    input  wire         is_branch_id,
    input  wire [31:0]  branch_target_id,

    // ----- Pipeline state info for hazards/forwarding -----
    // EX stage
    input  wire [3:0]   rd_ex,
    input  wire         regwrite_ex,
    input  wire         memread_ex,    // EX stage instruction is a load?

    // MEM stage
    input  wire [3:0]   rd_mem,
    input  wire         regwrite_mem,
    input  wire         memread_mem,

    // WB stage
    input  wire [3:0]   rd_wb,
    input  wire         regwrite_wb,

    // ----- Outputs -----
    // Stall / Flush / PC control
    output reg          stall,
    output reg          flush_if_id,
    output reg          pc_write_en,
    output reg [1:0]    pc_src_sel,
    output reg [31:0]   pc_branch_target,

    // Forwarding controls for EX stage
    output reg [1:0]    forwardA,
    output reg [1:0]    forwardB,

    // Control bundle to go into ID/EX pipeline register
    output reg [3:0]    ctrl_alu_op,
    output reg [1:0]    ctrl_dtype,
    output reg          ctrl_mem_read,
    output reg          ctrl_mem_write,
    output reg          ctrl_reg_write,
    output reg          ctrl_mem_to_reg,
    output reg          ctrl_is_tdot,
    output reg          ctrl_tensor_relu,
    output reg          ctrl_ex_freeze,

    // NEW: choose ALU second operand: 0 = use reg2 (rs2), 1 = use imm (sign-extended imm18)
    output reg          ctrl_alu_src
);

    // opcode constants
    localparam OP_NOP  = 4'b0000;
    localparam OP_ADD  = 4'b0001;
    localparam OP_SUB  = 4'b0010;
    localparam OP_AND  = 4'b0011;
    localparam OP_OR   = 4'b0100;
    localparam OP_XOR  = 4'b0101;
    localparam OP_MUL  = 4'b0110;
    localparam OP_RELU = 4'b0111;
    localparam OP_ADDI = 4'b1000;
    localparam OP_LD   = 4'b1001;
    localparam OP_ST   = 4'b1010;
    localparam OP_BRZ  = 4'b1011;
    localparam OP_BRNZ = 4'b1100;
    localparam OP_JUMP = 4'b1101;
    localparam OP_TDOT = 4'b1110;
    localparam OP_TDOT_RELU = 4'b1111;

    // -----------------------
    // 1) ID-stage decode -> generate control signals for ID/EX (combinational)
    // -----------------------
    always @(*) begin
        // defaults
        ctrl_alu_op     = 4'd0;
        ctrl_dtype      = dtype_id;
        ctrl_mem_read   = 1'b0;
        ctrl_mem_write  = 1'b0;
        ctrl_reg_write  = 1'b0;
        ctrl_mem_to_reg = 1'b0;
        ctrl_is_tdot    = 1'b0;
        ctrl_tensor_relu = 1'b0;
        ctrl_alu_src    = 1'b0; // default: ALU src2 comes from register rs2

        case (opcode_id)
            OP_NOP: begin
                // all zeros
            end

            // R-type ALU ops: ADD, SUB, AND, OR, XOR, MUL, RELU
            OP_ADD, OP_SUB, OP_AND, OP_OR, OP_XOR, OP_RELU: begin
                ctrl_alu_op    = opcode_id;
                ctrl_reg_write = 1'b1;
                ctrl_mem_to_reg = 1'b0;
                ctrl_is_tdot   = 1'b0;
                ctrl_alu_src   = 1'b0; // use rs2
            end

            // For Multiply
            OP_MUL: begin
                ctrl_alu_op    = opcode_id;
                ctrl_reg_write = 1'b1;
                ctrl_mem_to_reg = 1'b0;
                ctrl_is_tdot   = 1'b0;
                ctrl_alu_src   = 1'b0; // use rs2
                ctrl_ex_freeze = 1'b1; // freeze EX stage for multi-cycle op
            end

            // ADDI: use immediate as src2
            OP_ADDI: begin
                ctrl_alu_op    = OP_ADD;
                ctrl_reg_write = 1'b1;
                ctrl_mem_to_reg = 1'b0;
                ctrl_alu_src   = 1'b1; // use immediate (imm18) as ALU src2
            end

            // Load: address = rs1 + imm ; writeback from memory
            OP_LD: begin
                ctrl_alu_op    = OP_ADD; // address calc
                ctrl_mem_read  = 1'b1;
                ctrl_reg_write = 1'b1;
                ctrl_mem_to_reg = 1'b1;
                ctrl_alu_src   = 1'b1; // use imm as src2 (rs1 + imm)
            end

            // Store: address = rs1 + imm ; write data from rs2
            OP_ST: begin
                ctrl_alu_op    = OP_ADD; // address calc
                ctrl_mem_write = 1'b1;
                ctrl_reg_write = 1'b0;
                ctrl_alu_src   = 1'b1; // use imm as src2 for address calculation
            end

            // Branches: BRZ/BRNZ: no reg write; branch decision done in ID
            OP_BRZ, OP_BRNZ: begin
                // nothing to write back
                ctrl_reg_write = 1'b0;
                ctrl_alu_src   = 1'b1; // branches may use imm for target calc in ID (we compute target in ID)
            end

            // Jump
            OP_JUMP: begin
                ctrl_reg_write = 1'b0;
                ctrl_alu_src   = 1'b1;
            end

            // Tensor dot
            OP_TDOT: begin
                ctrl_alu_op    = OP_TDOT;
                ctrl_reg_write = 1'b1;
                ctrl_is_tdot   = 1'b1;
                ctrl_mem_to_reg = 1'b0;
                ctrl_alu_src   = 1'b0; // tensor consumes two registers (or forwarded values)
                ctrl_tensor_relu = 1'b0;
                ctrl_ex_freeze = 1'b1; // freeze EX stage for multi-cycle op
            end

            // Tensor dot relu
            OP_TDOT_RELU: begin
                ctrl_alu_op    = OP_TDOT_RELU;
                ctrl_reg_write = 1'b1;
                ctrl_is_tdot   = 1'b1;
                ctrl_mem_to_reg = 1'b0;
                ctrl_alu_src   = 1'b0;
                ctrl_tensor_relu = 1'b1;
                ctrl_ex_freeze = 1'b1; // freeze EX stage for multi-cycle op
            end



            default: begin
                // treat unknown as NOP
            end
        endcase
    end

    // -----------------------
    // 2) Load-use hazard detection (ID stage)
    // If EX stage is a load and it writes to a reg that ID next needs as source, stall.
    // Note: for stores, rs2 is data; for loads/addi/etc we compare the appropriate sources.
    // -----------------------
    wire load_use_hazard;
    assign load_use_hazard = (memread_ex && (rd_ex != 4'd0) &&
                              ( (rd_ex == rs1_id) || (rd_ex == rs2_id) ));

    // -----------------------
    // 3) Forwarding unit for EX stage (combinational)
    //    forward priority: MEM stage > WB stage
    // -----------------------
    always @(*) begin
        forwardA = 2'b00;
        forwardB = 2'b00;

        // forward for A (source from rs1_id)
        if ((rd_mem != 4'd0) && (rs1_id != 4'd0) && regwrite_mem && (rd_mem == rs1_id)) begin
            forwardA = 2'b01; // from MEM stage (ex_ result in mem_alu_result)
        end else if ((rd_wb != 4'd0) && (rs1_id != 4'd0) && regwrite_wb && (rd_wb == rs1_id)) begin
            forwardA = 2'b10; // from WB stage (wb_value)
        end else begin
            forwardA = 2'b00;
        end

        // forward for B (source from rs2_id) - used when ALU expects rs2
        if ((rd_mem != 4'd0) && (rs2_id != 4'd0) && regwrite_mem && (rd_mem == rs2_id)) begin
            forwardB = 2'b01;
        end else if ((rd_wb != 4'd0) && regwrite_wb && (rd_wb == rs2_id)) begin
            forwardB = 2'b10;
        end else begin
            forwardB = 2'b00;
        end
    end

    // -----------------------
    // 4) Branch handling & pipeline flush / stall logic (combinational)
    //    branch_cond_id and is_branch_id are evaluated in ID stage by top-level.
    // -----------------------
    always @(*) begin
        // defaults
        stall = 1'b0;
        flush_if_id = 1'b0;
        pc_write_en = 1'b1;
        pc_src_sel = 2'b00;
        pc_branch_target = 32'd0;

        // 1) load-use hazard: stall a cycle
        if (load_use_hazard) begin
            stall = 1'b1;
            pc_write_en = 1'b0; // freeze PC while stalling
            flush_if_id = 1'b0; // keep IF/ID as-is (we will inject bubble into ID/EX)
        end

        // 2) branch taken in ID stage
        else if (is_branch_id && branch_cond_id) begin
            flush_if_id = 1'b1;
            pc_src_sel = 2'b01;
            pc_branch_target = branch_target_id;
            pc_write_en = 1'b1;
        end

        // 3) jump
        else if (opcode_id == OP_JUMP) begin
            flush_if_id = 1'b1;
            pc_src_sel = 2'b01;
            pc_branch_target = branch_target_id;
            pc_write_en = 1'b1;
        end
    end

endmodule