// ============================================================
// Simple Tensor Unit (4x16-bit signed dot product + optional ReLU)
// Verilog-2001 compatible
// ============================================================

module tensor_unit (
    input  [63:0] a,
    input  [63:0] b,
    input         relu,
    output reg [63:0] result
);

    reg signed [15:0] a0,a1,a2,a3;
    reg signed [15:0] b0,b1,b2,b3;

    reg signed [31:0] m0,m1,m2,m3;
    reg signed [63:0] sum;

    always @(*) begin

        // Unpack (lane0 = lowest 16 bits)
        a0 = a[15:0];
        a1 = a[31:16];
        a2 = a[47:32];
        a3 = a[63:48];

        b0 = b[15:0];
        b1 = b[31:16];
        b2 = b[47:32];
        b3 = b[63:48];

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

        // Optional ReLU
        if (relu && sum < 0)
            result = 64'd0;
        else
            result = sum;

    end

endmodule