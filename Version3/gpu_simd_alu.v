// ============================================================
// SIMD ALU module for GPU pipeline
// ============================================================
module gpu_simd_alu (
    input  [3:0]  alu_op,           // ALU operation code from ID/EX register
    input  [1:0]  alu_datatype,     // data type code from ID/EX register (00 = 64-bit scalar, 01 = 2x32-bit, 10 = 4x16-bit, 11 = 8x8-bit)
    input  [63:0] alu_input1,       // first operand from ID/EX register, value of register file output 1
    input  [63:0] alu_input2,       // second operand from ID/EX register, value of register file output 2 or immediate value (after sign-extension)

    output reg [63:0] alu_output    // ALU result, will be selected to sent to EX/MEM register, the result from tensor unit will also be selected to EX/MEM register, the control signal ctrl_ex_result_sel from control unit will determine which one to send
);

    localparam OP_ADD  = 4'b0001;
    localparam OP_SUB  = 4'b0010;
    localparam OP_AND  = 4'b0011;
    localparam OP_OR   = 4'b0100;
    localparam OP_XOR  = 4'b0101;
    localparam OP_MUL  = 4'b0110;
    localparam OP_RELU = 4'b0111;
    localparam OP_ADDI = 4'b1000;

    integer i;

    reg [31:0] a32[1:0], b32[1:0], r32[1:0];
    reg [15:0] a16[3:0], b16[3:0], r16[3:0];
    reg [7:0]  a8[7:0],  b8[7:0],  r8[7:0];

    always @(alu_op or alu_datatype or alu_input1 or alu_input2) begin
        alu_output = 64'b0;

        case (alu_datatype)

        // ================= 64-bit scalar =================
        2'b00: begin
            case (alu_op)
                OP_ADD:  alu_output = alu_input1 + alu_input2;
                OP_SUB:  alu_output = alu_input1 - alu_input2;
                OP_AND:  alu_output = alu_input1 & alu_input2;
                OP_OR:   alu_output = alu_input1 | alu_input2;
                OP_XOR:  alu_output = alu_input1 ^ alu_input2;
                OP_MUL:  alu_output = alu_input1 * alu_input2;
                OP_ADDI: alu_output = alu_input1 + alu_input2;
                OP_RELU: alu_output = ($signed(alu_input1) < 0) ? 64'b0 : alu_input1;
                default: alu_output = 64'b0;
            endcase
        end

        // ================= 2x32 =================
        2'b01: begin
            a32[0] = alu_input1[31:0];
            a32[1] = alu_input1[63:32];
            b32[0] = alu_input2[31:0];
            b32[1] = alu_input2[63:32];

            for(i=0;i<2;i=i+1) begin
                case(alu_op)
                    OP_ADD:  r32[i] = a32[i] + b32[i];
                    OP_SUB:  r32[i] = a32[i] - b32[i];
                    OP_AND:  r32[i] = a32[i] & b32[i];
                    OP_OR:   r32[i] = a32[i] | b32[i];
                    OP_XOR:  r32[i] = a32[i] ^ b32[i];
                    OP_MUL:  r32[i] = a32[i] * b32[i];
                    OP_ADDI:  r32[i] = a32[i] + b32[i];
                    OP_RELU: r32[i] = ($signed(a32[i]) < 0) ? 32'b0 : a32[i];
                    default: r32[i] = 32'b0;
                endcase
            end

            alu_output = {r32[1], r32[0]};
        end

        // ================= 4x16 =================
        2'b10: begin
            for(i=0;i<4;i=i+1) begin
                a16[i] = alu_input1[i*16 +: 16];
                b16[i] = alu_input2[i*16 +: 16];

                case(alu_op)
                    OP_ADD:  r16[i] = a16[i] + b16[i];
                    OP_SUB:  r16[i] = a16[i] - b16[i];
                    OP_AND:  r16[i] = a16[i] & b16[i];
                    OP_OR:   r16[i] = a16[i] | b16[i];
                    OP_XOR:  r16[i] = a16[i] ^ b16[i];
                    OP_MUL:  r16[i] = a16[i] * b16[i];
                    OP_ADDI:  r16[i] = a16[i] + b16[i];
                    OP_RELU: r16[i] = ($signed(a16[i]) < 0) ? 16'b0 : a16[i];
                    default: r16[i] = 16'b0;
                endcase
            end

            alu_output = {r16[3],r16[2],r16[1],r16[0]};
        end

        // ================= 8x8 =================
        2'b11: begin
            for(i=0;i<8;i=i+1) begin
                a8[i] = alu_input1[i*8 +: 8];
                b8[i] = alu_input2[i*8 +: 8];

                case(alu_op)
                    OP_ADD:  r8[i] = a8[i] + b8[i];
                    OP_SUB:  r8[i] = a8[i] - b8[i];
                    OP_AND:  r8[i] = a8[i] & b8[i];
                    OP_OR:   r8[i] = a8[i] | b8[i];
                    OP_XOR:  r8[i] = a8[i] ^ b8[i];
                    OP_MUL:  r8[i] = a8[i] * b8[i];
                    OP_ADDI:  r8[i] = a8[i] + b8[i];
                    OP_RELU: r8[i] = ($signed(a8[i]) < 0) ? 8'b0 : a8[i];
                    default: r8[i] = 8'b0;
                endcase
            end

            alu_output = {r8[7],r8[6],r8[5],r8[4],r8[3],r8[2],r8[1],r8[0]};
        end

        default: alu_output = 64'b0;

        endcase
    end

endmodule