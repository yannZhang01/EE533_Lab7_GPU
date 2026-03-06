// ============================================================
// Control Unit for GPU
// ============================================================
module gpu_control_unit (
    input wire [3:0] opcode_id,   // opcode from ID stage
    input wire [1:0] dtype_id,    // data type from ID stage

    output reg       ctrl_reg_write,       // whether to write back to reg file
    output reg       ctrl_mem_read,        // whether this is a load
    output reg       ctrl_mem_write,       // whether this is a store
    output reg       ctrl_is_itype,         // whether this is an I-type instruction (for register read logic in ID stage)
    output reg       ctrl_tensor_tdot,     // whether this is a tensor dot product
    output reg       ctrl_tensor_tdot_relu,// whether this is a tensor dot product with relu
    output reg [3:0] ctrl_alu_op,          // ALU operation (for SIMD_ALU in ID/EX)
    output reg [1:0] ctrl_alu_dtype,       // data type (for SIMD_ALU in ID/EX)

    output reg       ctrl_alu_src,         // whether to use immediate as src2 for ALU, 0 = reg, 1 = imm
    output reg       ctrl_ex_result_sel,    // whether to select alu result or tensor unit result for EX/MEM. 0 = ALU, 1 = tensor unit (for EX stage)
    output reg       ctrl_mem_to_reg      // whether to write back from memory (for ID/EX), 0 = write back from ALU, 1 = write back from memory
);

    // opcode constants
    localparam OP_NOP        = 4'b0000;
    localparam OP_ADD        = 4'b0001;
    localparam OP_SUB        = 4'b0010;
    localparam OP_AND        = 4'b0011;
    localparam OP_OR         = 4'b0100;
    localparam OP_XOR        = 4'b0101;
    localparam OP_MUL        = 4'b0110;
    localparam OP_RELU       = 4'b0111;
    localparam OP_ADDI       = 4'b1000;
    localparam OP_LD         = 4'b1001;
    localparam OP_ST         = 4'b1010;
    localparam OP_BRZ        = 4'b1011;
    localparam OP_BRNZ       = 4'b1100;
    localparam OP_JUMP       = 4'b1101;
    localparam OP_TDOT       = 4'b1110;
    localparam OP_TDOT_RELU  = 4'b1111;

    always @(opcode_id or dtype_id) begin
        // defaults
        ctrl_reg_write        = 1'b0;
        ctrl_mem_read         = 1'b0;
        ctrl_mem_write        = 1'b0;
        ctrl_is_itype         = 1'b0;
        ctrl_mem_to_reg       = 1'b0;
        ctrl_tensor_tdot      = 1'b0;
        ctrl_tensor_tdot_relu = 1'b0;
        ctrl_alu_op           = 4'b0000; // default to NOP
        ctrl_alu_dtype        = dtype_id; // pass through data type by default
        ctrl_alu_src          = 1'b0; // default to using register as src2
        ctrl_ex_result_sel    = 1'b0; // default to selecting ALU result

        case (opcode_id)

            OP_NOP: begin
                // do nothing
            end

            // R-type ALU ops: ADD, SUB, AND, OR, XOR, RELU, MUL
            OP_ADD, OP_SUB, OP_AND, OP_OR, OP_XOR, OP_RELU, OP_MUL: begin
                ctrl_reg_write        = 1'b1; // write back result to reg file
                ctrl_mem_read         = 1'b0;
                ctrl_mem_write        = 1'b0;
                ctrl_is_itype         = 1'b0;
                ctrl_mem_to_reg       = 1'b0;
                ctrl_tensor_tdot      = 1'b0;
                ctrl_tensor_tdot_relu = 1'b0;
                ctrl_alu_op           = opcode_id; // ALU op matches opcode
                ctrl_alu_dtype        = dtype_id; // pass through data type
                ctrl_alu_src          = 1'b0; // use register as src2
                ctrl_ex_result_sel    = 1'b0; // select ALU result
            end

            // ADDI: use immediate as src2
            OP_ADDI: begin
                ctrl_reg_write        = 1'b1; // write back result to reg file
                ctrl_mem_read         = 1'b0;
                ctrl_mem_write        = 1'b0;
                ctrl_is_itype         = 1'b1; // this is an I-type instruction
                ctrl_mem_to_reg       = 1'b0;
                ctrl_tensor_tdot      = 1'b0;
                ctrl_tensor_tdot_relu = 1'b0;
                ctrl_alu_op           = opcode_id; // ALU op matches opcode
                ctrl_alu_dtype        = dtype_id; // pass through data type
                ctrl_alu_src          = 1'b1; // use immediate as src2
                ctrl_ex_result_sel    = 1'b0; // select ALU result
            end

            // Load: address = rs1 + imm ; writeback from memory
            OP_LD: begin
                ctrl_reg_write        = 1'b1; // write back result to reg file
                ctrl_mem_read         = 1'b1;
                ctrl_mem_write        = 1'b0;
                ctrl_is_itype         = 1'b1; // this is an I-type instruction
                ctrl_mem_to_reg       = 1'b1; // write back from memory
                ctrl_tensor_tdot      = 1'b0;
                ctrl_tensor_tdot_relu = 1'b0;
                ctrl_alu_op           = OP_ADD; // ALU op matches opcode
                ctrl_alu_dtype        = dtype_id; // pass through data type
                ctrl_alu_src          = 1'b1; // use immediate as src2
                ctrl_ex_result_sel    = 1'b0; // select ALU result for address calculation
            end

            // Store: address = rs1 + imm ; write data from rs2
            OP_ST: begin
                ctrl_reg_write        = 1'b0; // no write back for store
                ctrl_mem_read         = 1'b0;
                ctrl_mem_write        = 1'b1; // write to memory
                ctrl_is_itype         = 1'b1; // this is an I-type instruction
                ctrl_mem_to_reg       = 1'b0; // not applicable
                ctrl_tensor_tdot      = 1'b0;
                ctrl_tensor_tdot_relu = 1'b0;
                ctrl_alu_op           = OP_ADD; // ALU op matches opcode
                ctrl_alu_dtype        = dtype_id; // pass through data type
                ctrl_alu_src          = 1'b1; // use immediate as src2
                ctrl_ex_result_sel    = 1'b0; // select ALU result for address calculation
            end

            // Branches: BRZ/BRNZ: no reg write; branch decision done in ID
            OP_BRZ, OP_BRNZ: begin
                // do nothing here; branch control signals are generated in ID stage
                ctrl_is_itype         = 1'b1; // treat branches as I-type for register read logic
            end

            // Jump
            OP_JUMP: begin
                // do nothing
            end

            // Tensor dot
            OP_TDOT: begin
                ctrl_reg_write        = 1'b1; // write back result to reg file
                ctrl_mem_read         = 1'b0;
                ctrl_mem_write        = 1'b0;
                ctrl_mem_to_reg       = 1'b0; // not applicable
                ctrl_tensor_tdot      = 1'b1; // enable tensor dot unit
                ctrl_tensor_tdot_relu = 1'b0;
                ctrl_alu_op           = OP_NOP; // ALU op matches opcode
                ctrl_alu_dtype        = 2'b00; // pass through data type
                ctrl_alu_src          = 1'b0; // use immediate as src2
                ctrl_ex_result_sel    = 1'b1; // select tensor unit result
            end

            // Tensor dot relu
            OP_TDOT_RELU: begin
                ctrl_reg_write        = 1'b1; // write back result to reg file
                ctrl_mem_read         = 1'b0;
                ctrl_mem_write        = 1'b0;
                ctrl_mem_to_reg       = 1'b0; // not applicable
                ctrl_tensor_tdot      = 1'b1; // enable tensor dot unit
                ctrl_tensor_tdot_relu = 1'b1; // enable ReLU for tensor dot
                ctrl_alu_op           = OP_NOP; // ALU op matches opcode
                ctrl_alu_dtype        = 2'b00; // pass through data type
                ctrl_alu_src          = 1'b0; // use immediate as src2
                ctrl_ex_result_sel    = 1'b1; // select tensor unit result
            end



            default: begin
                // treat unknown as NOP
            end
        endcase
    end

endmodule