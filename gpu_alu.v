module gpu_alu (
    input  [3:0]  alu_op,
    input  [1:0]  datatype,
    input  [63:0] src1,
    input  [63:0] src2,
    //input  [63:0] src3,
    output reg [63:0] result
);

    // localparam OP_ADD  = 4'b0000;
    // localparam OP_SUB  = 4'b0001;
    // localparam OP_AND  = 4'b0010;
    // localparam OP_OR   = 4'b0011;
    // localparam OP_XOR  = 4'b0100;
    // localparam OP_MUL  = 4'b0101;
    // //localparam OP_MAC  = 4'b0110;
    // localparam OP_RELU = 4'b0111;

    localparam OP_ADD  = 4'b0001;
    localparam OP_SUB  = 4'b0010;
    localparam OP_AND  = 4'b0011;
    localparam OP_OR   = 4'b0100;
    localparam OP_XOR  = 4'b0101;
    localparam OP_MUL  = 4'b0110;
    localparam OP_RELU = 4'b0111;

    integer i;

    reg [31:0] a32[1:0], b32[1:0], r32[1:0];
    reg [15:0] a16[3:0], b16[3:0], r16[3:0];
    reg [7:0]  a8[7:0],  b8[7:0],  r8[7:0];

    always @(*) begin
        result = 64'b0;

        case(datatype)

        // ================= 64-bit scalar =================
        2'b00: begin
            case(alu_op)
                OP_ADD:  result = src1 + src2;
                OP_SUB:  result = src1 - src2;
                OP_AND:  result = src1 & src2;
                OP_OR:   result = src1 | src2;
                OP_XOR:  result = src1 ^ src2;
                OP_MUL:  result = src1 * src2;
                //OP_MAC:  result = (src1 * src2) + src3;
                OP_RELU: result = ($signed(src1) < 0) ? 64'b0 : src1;
                default: result = 0;
            endcase
        end

        // ================= 2x32 =================
        2'b01: begin
            a32[0] = src1[31:0];
            a32[1] = src1[63:32];
            b32[0] = src2[31:0];
            b32[1] = src2[63:32];

            for(i=0;i<2;i=i+1) begin
                case(alu_op)
                    OP_ADD:  r32[i] = a32[i] + b32[i];
                    OP_SUB:  r32[i] = a32[i] - b32[i];
                    OP_AND:  r32[i] = a32[i] & b32[i];
                    OP_OR:   r32[i] = a32[i] | b32[i];
                    OP_XOR:  r32[i] = a32[i] ^ b32[i];
                    OP_MUL:  r32[i] = a32[i] * b32[i];
                    //OP_MAC:  r32[i] = (a32[i] * b32[i]) + src3[i*32 +: 32];
                    OP_RELU: r32[i] = ($signed(a32[i]) < 0) ? 32'b0 : a32[i];
                    default: r32[i] = 0;
                endcase
            end

            result = {r32[1], r32[0]};
        end

        // ================= 4x16 =================
        2'b10: begin
            for(i=0;i<4;i=i+1) begin
                a16[i] = src1[i*16 +: 16];
                b16[i] = src2[i*16 +: 16];

                case(alu_op)
                    OP_ADD:  r16[i] = a16[i] + b16[i];
                    OP_SUB:  r16[i] = a16[i] - b16[i];
                    OP_AND:  r16[i] = a16[i] & b16[i];
                    OP_OR:   r16[i] = a16[i] | b16[i];
                    OP_XOR:  r16[i] = a16[i] ^ b16[i];
                    OP_MUL:  r16[i] = a16[i] * b16[i];
                    //OP_MAC:  r16[i] = (a16[i] * b16[i]) + src3[i*16 +: 16];
                    OP_RELU: r16[i] = ($signed(a16[i]) < 0) ? 16'b0 : a16[i];
                    default: r16[i] = 0;
                endcase
            end

            result = {r16[3],r16[2],r16[1],r16[0]};
        end

        // ================= 8x8 =================
        2'b11: begin
            for(i=0;i<8;i=i+1) begin
                a8[i] = src1[i*8 +: 8];
                b8[i] = src2[i*8 +: 8];

                case(alu_op)
                    OP_ADD:  r8[i] = a8[i] + b8[i];
                    OP_SUB:  r8[i] = a8[i] - b8[i];
                    OP_AND:  r8[i] = a8[i] & b8[i];
                    OP_OR:   r8[i] = a8[i] | b8[i];
                    OP_XOR:  r8[i] = a8[i] ^ b8[i];
                    OP_MUL:  r8[i] = a8[i] * b8[i];
                    //OP_MAC:  r8[i] = (a8[i] * b8[i]) + src3[i*8 +: 8];
                    OP_RELU: r8[i] = ($signed(a8[i]) < 0) ? 8'b0 : a8[i];
                    default: r8[i] = 0;
                endcase
            end

            result = {r8[7],r8[6],r8[5],r8[4],r8[3],r8[2],r8[1],r8[0]};
        end

        endcase
    end

endmodule