// ============================================================
// Tensor Unit module for GPU pipeline
// ============================================================
module gpu_tensor_unit (
    input  [63:0] tensor_input_1,
    input  [63:0] tensor_input_2,
    input         tensor_relu,
    output reg [63:0] tensor_result
);

    reg signed [15:0] a0,a1,a2,a3;
    reg signed [15:0] b0,b1,b2,b3;

    reg signed [31:0] m0,m1,m2,m3;
    reg signed [63:0] sum;

    always @(tensor_input_1 or tensor_input_2 or tensor_relu) begin

        // Unpack (lane0 = lowest 16 bits)
        a0 = tensor_input_1[15:0];
        a1 = tensor_input_1[31:16];
        a2 = tensor_input_1[47:32];
        a3 = tensor_input_1[63:48];

        b0 = tensor_input_2[15:0];
        b1 = tensor_input_2[31:16];
        b2 = tensor_input_2[47:32];
        b3 = tensor_input_2[63:48];

        // Multiply (signed)
        m0 = a0 * b0;
        m1 = a1 * b1;
        m2 = a2 * b2;
        m3 = a3 * b3;

        // Accumulate (sign-extend properly to 64 bits)
        sum = $signed(m0) + 
              $signed(m1) + 
              $signed(m2) + 
              $signed(m3);

        // Optional tensor_relu
        if (tensor_relu && sum < 0)
            tensor_result = 64'd0;
        else
            tensor_result = sum;

    end

endmodule