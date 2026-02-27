// control_unit.v
// Verilog-2001
// Generates pipeline control signals for a 5-stage pipeline:
// IF -> ID -> EX -> MEM -> WB
//
// - Decodes instruction class in ID
// - Produces control bundle for ID->EX pipeline register
// - Detects load-use hazard (1-cycle stall)
// - Produces forwarding control for EX stage (forwardA, forwardB)
// - Handles branch/jump flush & pc control via branch_taken_id/branch_target_id
//
// Integration notes:
// - All register numbers are 4-bit (0..15).
// - imm/branch decision is expected to be computed by the ID stage logic (or external comparator).
// - If you evaluate branch in EX stage, feed branch_taken_ex / branch_target_ex instead and adjust wiring.
// - treat opcode 0000 as NOP
//

module control_unit (
    input  wire         clk,
    input  wire         rst_n,

    // ----- Inputs from IF/ID (ID stage) -----
    input  wire [3:0]   opcode_id,
    input  wire [1:0]   dtype_id,
    input  wire [3:0]   rd_id,
    input  wire [3:0]   rs1_id,
    input  wire [3:0]   rs2_id,
    // If you compute branch condition in ID (recommended), provide:
    input  wire         branch_cond_id,      // 1 => branch condition true (BRZ/BRNZ decided)
    input  wire         is_branch_id,        // 1 => this ID opcode is BRZ/BRNZ
    input  wire [31:0]  branch_target_id,    // byte address computed in ID for branch target

    // ----- Pipeline state info for hazards/forwarding -----
    // EX stage
    input  wire [3:0]   rd_ex,
    input  wire         regwrite_ex,
    input  wire         memread_ex,    // EX stage instruction is a load?

    // MEM stage
    input  wire [3:0]   rd_mem,
    input  wire         regwrite_mem,
    input  wire         memread_mem, // mem stage load (rare but keep)

    // WB stage
    input  wire [3:0]   rd_wb,
    input  wire         regwrite_wb,

    // ----- Outputs -----
    // Stall / Flush / PC control
    output reg          stall,            // when 1: stall IF/ID and freeze PC
    output reg          flush_if_id,      // when 1: clear IF/ID (write NOP)
    output reg          pc_write_en,      // 1 = allow PC to update, 0 = hold PC
    output reg [1:0]    pc_src_sel,       // 00 = pc+4, 01 = branch_target_id, 10 = jump_target (if used)
    output reg [31:0]   pc_branch_target, // target byte address (used when pc_src_sel != 00)

    // Forwarding controls for EX stage (select for ALU source A/B)
    // 00 -> use register file (no forward)
    // 01 -> forward from EX/MEM (ALU result in MEM stage)
    // 10 -> forward from MEM/WB (value in WB stage)
    output reg [1:0]    forwardA,
    output reg [1:0]    forwardB,

    // Control bundle to go into ID/EX pipeline register
    output reg [3:0]    ctrl_alu_op,     // alu opcode for EX stage
    output reg [1:0]    ctrl_dtype,
    output reg          ctrl_mem_read,
    output reg          ctrl_mem_write,
    output reg          ctrl_reg_write,
    output reg          ctrl_mem_to_reg, // when 1: writeback from memory; else from ALU/tensor
    output reg          ctrl_is_tdot     // treat specially if tensor instruction
);

    // local opcode constants (must match your ISA)
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

    // -----------------------
    // 1) ID-stage decode -> generate control signals for ID/EX (combinational)
    // -----------------------
    always @(*) begin
        // default control signals
        ctrl_alu_op     = 4'd0;
        ctrl_dtype      = dtype_id;
        ctrl_mem_read   = 1'b0;
        ctrl_mem_write  = 1'b0;
        ctrl_reg_write  = 1'b0;
        ctrl_mem_to_reg = 1'b0;
        ctrl_is_tdot    = 1'b0;

        case (opcode_id)
            OP_NOP: begin
                // NOP: all zeros
            end
            OP_ADD, OP_SUB, OP_AND, OP_OR, OP_XOR, OP_MUL, OP_RELU: begin
                ctrl_alu_op    = opcode_id;
                ctrl_reg_write = 1'b1;
                ctrl_mem_to_reg = 1'b0;
                ctrl_mem_read  = 1'b0;
                ctrl_mem_write = 1'b0;
                ctrl_is_tdot   = 1'b0;
            end
            OP_ADDI: begin
                ctrl_alu_op    = OP_ADD;
                ctrl_reg_write = 1'b1;
                ctrl_mem_to_reg = 1'b0;
            end
            OP_LD: begin
                ctrl_alu_op    = OP_ADD; // address calc (rs1 + imm)
                ctrl_mem_read  = 1'b1;
                ctrl_reg_write = 1'b1;
                ctrl_mem_to_reg = 1'b1;
            end
            OP_ST: begin
                ctrl_alu_op    = OP_ADD; // address calc
                ctrl_mem_write = 1'b1;
                ctrl_reg_write = 1'b0;
            end
            OP_BRZ, OP_BRNZ, OP_JUMP: begin
                // branches don't write registers here
            end
            OP_TDOT: begin
                ctrl_alu_op    = OP_TDOT; // EX stage should route to tensor unit
                ctrl_reg_write = 1'b1;
                ctrl_is_tdot   = 1'b1;
            end
            default: begin
                // treat unknown as NOP
            end
        endcase
    end

    // -----------------------
    // 2) Load-use hazard detection (ID stage needs values but EX stage is loading)
    //    If EX is a load and its destination equals rs1_id or rs2_id, we must stall
    //    Typical behavior: insert one bubble (freeze IF/ID and ID signals), and insert NOP into ID/EX
    // -----------------------
    wire load_use_hazard;
    assign load_use_hazard = (memread_ex && (rd_ex != 4'd0) &&
                              ((rd_ex == rs1_id) || (rd_ex == rs2_id)));

    // -----------------------
    // 3) Forwarding unit for ALU operands in EX stage
    //    We compute forwarding based on EX-stage Rs (signals come from EX stage)
    //    EX stage sources are compared to rd in MEM and WB stages.
    //    forward priority: EX stage result (if available) > MEM stage > WB stage.
    //    Here we output control for EX stage multiplexer.
    // -----------------------
    // For compute of forward signals we need rs1_ex/rs2_ex; top-level should feed them
    // However we can compute forwarding based on rs1_id/rs2_id when used in EX next cycle if you choose.
    // We'll compute forwarding for current EX stage using rd_ex/rd_mem/rd_wb and regwrite signals.
    //
    // NOTE: The top-level must call this module every cycle with current pipeline register contents:
    //       rs1_id/rs2_id used for hazard detection; forwarding logic uses rd_ex/rd_mem/rd_wb and regwrite flags.
    //
    // We'll implement forwarding as follows:
    //   forwardX = 2'b01 -> take value from MEM stage (rd_mem)
    //   forwardX = 2'b10 -> take value from WB stage  (rd_wb)
    //   forwardX = 2'b00 -> use register file value (no forward)
    //

    always @(*) begin
        // default: no forward
        forwardA = 2'b00;
        forwardB = 2'b00;

        // Check EX hazard: if EX stage will write and rd_ex matches ID/EX rs1/rs2? (this is for next cycle)
        // Usually forwarding checks compare EX/MEM (which holds ALU result) and MEM/WB.
        // Use rd_mem/regwrite_mem for MEM source; rd_wb/regwrite_wb for WB source.

        // Forwarding for the value needed in EX stage (sources are from ID/EX in real pipeline).
        // The top-level should compare rs1_ex/rs2_ex (not rs1_id). Here we approximate by using rs1_id/rs2_id
        // which is valid if forwarding is computed for the next cycle (ID->EX). For safe operation, top-level
        // can re-evaluate forwarding using actual rs1_ex/rs2_ex or simply pass them here.
        //
        // We adopt a common scheme:
        // If (rd_mem != 0 && regwrite_mem && (rd_mem == rs1_id)) forwardA = 2'b01;
        // else if (rd_wb != 0 && regwrite_wb && (rd_wb == rs1_id)) forwardA = 2'b10;
        // Same for B.

        if ((rd_mem != 4'd0) && regwrite_mem && (rd_mem == rs1_id)) begin
            forwardA = 2'b01;
        end else if ((rd_wb != 4'd0) && regwrite_wb && (rd_wb == rs1_id)) begin
            forwardA = 2'b10;
        end else begin
            forwardA = 2'b00;
        end

        if ((rd_mem != 4'd0) && regwrite_mem && (rd_mem == rs2_id)) begin
            forwardB = 2'b01;
        end else if ((rd_wb != 4'd0) && regwrite_wb && (rd_wb == rs2_id)) begin
            forwardB = 2'b10;
        end else begin
            forwardB = 2'b00;
        end
    end

    // -----------------------
    // 4) Branch handling & pipeline flush logic
    //    We assume branch condition is evaluated in ID stage (branch_cond_id).
    //    If branch is taken in ID stage:
    //      - we want to flush IF/ID (insert NOP)
    //      - update PC to branch_target_id in next cycle (pc_src_sel, pc_branch_target)
    //    Note: If your branches are decided in EX stage, adapt inputs to branch_cond_ex/target_ex.
    // -----------------------
    always @(*) begin
        // default outputs
        stall = 1'b0;
        flush_if_id = 1'b0;
        pc_write_en = 1'b1;         // allow PC to update by default
        pc_src_sel = 2'b00;         // default pc+4
        pc_branch_target = 32'd0;

        // 1) load-use hazard: stall pipeline
        if (load_use_hazard) begin
            stall = 1'b1;
            // when stalling due to load-use, we also must prevent IF from writing new IF/ID
            // and insert bubble in ID/EX (top-level will write a NOP into ID/EX).
            pc_write_en = 1'b0; // freeze PC
            flush_if_id = 1'b0; // do not flush, just freeze IF/ID
        end

        // 2) branch taken in ID stage -> flush IF/ID and redirect PC
        //    branch_cond_id is asserted by ID stage comparator
        else if (is_branch_id && branch_cond_id) begin
            flush_if_id = 1'b1;
            pc_src_sel = 2'b01;
            pc_branch_target = branch_target_id;
            pc_write_en = 1'b1;
        end

        // 3) JUMP: treat like branch (unconditional)
        else if (opcode_id == OP_JUMP) begin
            flush_if_id = 1'b1;
            pc_src_sel = 2'b01;
            pc_branch_target = branch_target_id;
            pc_write_en = 1'b1;
        end
    end

endmodule