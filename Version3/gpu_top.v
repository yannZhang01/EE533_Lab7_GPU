`timescale 1ns / 1ps

// ============================================================
// Top-level GPU module integrating all components
// ============================================================

module gpu_top (
    input wire clk,
    input wire reset
);

// Parameter definitions
localparam DATA_WIDTH      = 64;
localparam INST_WIDTH      = 32;
localparam INST_ADDR_WIDTH = 9;
localparam DATA_ADDR_WIDTH = 8;
localparam REG_ADDR_WIDTH  = 4;
localparam OP_BRZ        = 4'b1011;
localparam OP_BRNZ       = 4'b1100;
localparam OP_MUL        = 4'b0110;
localparam OP_TDOT       = 4'b1110;
localparam OP_TDOT_RELU  = 4'b1111;

localparam FREEZE_CLOCK = 1;

// ============================================================
// IF stage
// ============================================================

wire [INST_ADDR_WIDTH-1:0] if_pc_current;
wire [INST_ADDR_WIDTH-1:0] if_pc_plus1;
wire [INST_ADDR_WIDTH-1:0] if_pc_next_default;
wire [INST_WIDTH-1:0]      if_imem_instr;

// Sequential next PC (PC + 1).
assign if_pc_plus1        = if_pc_current + 1'b1;
assign if_pc_next_default = pipeline_freeze ? if_pc_current : if_pc_plus1;

// PC state register with redirect support
gpu_pc #(.ADDR_WIDTH(INST_ADDR_WIDTH)) pc (
    .clk(clk),
    .reset(reset),

    .pc_enable(1'b1),  // TODO: connect to hazard stall later

    .pc_branch_valid(id_branch_taken),
    .pc_branch_target(id_branch_target),

    .pc_next(if_pc_next_default),

    .pc_current(if_pc_current)
);

// Instruction memory read address comes from IF PC (NOT id_pc)
gpu_imem #(.MEM_SIZE(512), .ADDR_WIDTH(INST_ADDR_WIDTH), .DATA_WIDTH(INST_WIDTH)) imem (
    .imem_read_addr(if_pc_current),
    .imem_write_addr(9'b0),
    .imem_write_data(32'b0),
    .imem_write_en(1'b0),
    .clk(clk),
    .reset(reset),
    .imem_instr(if_imem_instr)
);

// IF/ID pipeline register (pc tag + instr)

reg [INST_WIDTH-1:0]       if_id_instr;
reg [INST_ADDR_WIDTH-1:0]  if_id_pc;

wire if_id_flush;
assign if_id_flush = id_branch_taken;

// Update IF/ID pipeline register on clock edge
always @(posedge clk or posedge reset) begin
    if (reset) begin
        if_id_instr <= {INST_WIDTH{1'b0}};
        if_id_pc    <= {INST_ADDR_WIDTH{1'b0}};
    end else if (pipeline_freeze) begin
        // remain current value
    end else if (if_id_flush) begin
        if_id_instr <= {INST_WIDTH{1'b0}};   // NOP
        if_id_pc    <= if_pc_current;        // not critical for NOP, but keeps waveform sane
    end else begin
        if_id_instr <= if_imem_instr;
        if_id_pc    <= if_pc_current;        // tag the fetched instruction with its PC
    end
end

// ============================================================
// ID stage
// ============================================================

wire [INST_WIDTH-1:0] id_instr;
wire [INST_ADDR_WIDTH-1:0] id_pc; // real current instruction address

assign id_pc = if_id_pc;
assign id_instr = if_id_instr;

// device instruction format:
// [31:28] opcode
// [27:26] data type
// [25:22] rd (destination register)
// [21:18] rs1 (source register 1)
// [17:14] rs2 (source register 2)
// [17:0]  imm (immediate value, can be sign-extended)
wire [3:0] id_instr_opcode_id;
wire [1:0] id_instr_dtype_id;
wire [3:0] id_instr_rd_addr;
wire [3:0] id_instr_rs1_addr;
wire [3:0] id_instr_rs2_addr;
wire [17:0]id_instr_imm;

assign id_instr_opcode_id = id_instr[31:28];
assign id_instr_dtype_id  = id_instr[27:26];
assign id_instr_rd_addr   = id_instr[25:22];
assign id_instr_rs1_addr  = id_instr[21:18];
assign id_instr_rs2_addr  = id_instr[17:14];
assign id_instr_imm       = id_instr[17:0];

wire [REG_ADDR_WIDTH-1:0] id_reg_rs1_addr;
wire [REG_ADDR_WIDTH-1:0] id_reg_rs2_addr;
wire id_is_itype;


assign id_reg_rs1_addr = id_instr_rs1_addr;
assign id_reg_rs2_addr = id_is_itype ? id_instr_rd_addr : id_instr_rs2_addr;

wire [DATA_WIDTH-1:0] id_imm_ext64;
wire [INST_WIDTH-1:0] id_imm_ext32;

assign id_imm_ext32 = {{14{id_instr_imm[17]}}, id_instr_imm}; // sign-extend to 32 bits
assign id_imm_ext64 = {{32{id_imm_ext32[31]}}, id_imm_ext32}; // sign-extend to 64 bits

// accept output of register file
wire [DATA_WIDTH-1:0] id_rs1_data;
wire [DATA_WIDTH-1:0] id_rs2_data;

gpu_regfile #(.NUM_REGS(16), .DATA_WIDTH(DATA_WIDTH), .ADDR_WIDTH(REG_ADDR_WIDTH)) regfile (
    // inputs
    .clk(clk),
    .reset(reset),
    .gpu_rs1_addr(id_reg_rs1_addr),
    .gpu_rs2_addr(id_reg_rs2_addr),
    .gpu_rd_wenable(wb_reg_write_en),
    .gpu_rd_addr(wb_reg_write_addr),
    .gpu_rd_data(wb_reg_write_data),

    // outputs
    .gpu_rs1_data(id_rs1_data),
    .gpu_rs2_data(id_rs2_data)
);

// accept control signals from control unit
wire id_reg_write_en;
wire id_mread_en;
wire id_mwrite_en;
wire id_tensor_tdot_en;
wire id_tensor_tdot_relu_en;
wire [3:0] id_alu_op;
wire [1:0] id_alu_dtype;
wire id_alu_src;
wire id_exresult_sel;
wire id_mem2reg;

gpu_control_unit control_unit (
    // inputs
    .opcode_id(id_instr_opcode_id),
    .dtype_id(id_instr_dtype_id),

    // outputs
    .ctrl_reg_write(id_reg_write_en),
    .ctrl_mem_read(id_mread_en),
    .ctrl_mem_write(id_mwrite_en),
    .ctrl_tensor_tdot(id_tensor_tdot_en),
    .ctrl_tensor_tdot_relu(id_tensor_tdot_relu_en),
    .ctrl_alu_op(id_alu_op),
    .ctrl_alu_dtype(id_alu_dtype),
    .ctrl_alu_src(id_alu_src),
    .ctrl_ex_result_sel(id_exresult_sel),
    .ctrl_mem_to_reg(id_mem2reg),
    .ctrl_is_itype(id_is_itype)
);

// ============================================================
// Branch Unit
// ============================================================
wire id_branch_taken;
assign id_branch_taken = (id_instr_opcode_id == OP_BRZ) ? (id_rs1_data == 0) :
                         (id_instr_opcode_id == OP_BRNZ) ? (id_rs1_data != 0) : 1'b0;

// Treat PC and offset as signed for branch target computation
wire signed [INST_ADDR_WIDTH:0] id_pc_s;
wire signed [INST_ADDR_WIDTH:0] id_off_s;
wire signed [INST_ADDR_WIDTH:0] id_br_s;
wire [INST_ADDR_WIDTH-1:0] id_branch_target;

assign id_pc_s  = $signed({1'b0, id_pc});  // widen by 1 to reduce overflow weirdness
assign id_off_s = $signed(id_imm_ext32[INST_ADDR_WIDTH:0]); // signed, includes sign bit
assign id_br_s  = id_pc_s + id_off_s;

assign id_branch_target = id_br_s[INST_ADDR_WIDTH-1:0]; // wraps naturally in 9-bit space

// ID/EX pipeline register
reg id_ex_reg_write_en;
reg id_ex_mread_en;
reg id_ex_mwrite_en;
reg id_ex_tensor_tdot_en;
reg id_ex_tensor_tdot_relu_en;
reg [3:0] id_ex_alu_op;
reg [1:0] id_ex_alu_dtype;
reg id_ex_alu_src;
reg id_ex_result_sel;
reg id_ex_mem2reg;

reg [REG_ADDR_WIDTH-1:0] id_ex_rd_addr;
reg [DATA_WIDTH-1:0] id_ex_rs1_data;
reg [DATA_WIDTH-1:0] id_ex_rs2_data;
reg [DATA_WIDTH-1:0] id_ex_imm_ext64;

// Update ID/EX pipeline register on clock edge
always @(posedge clk or posedge reset) begin
    if (reset) begin
        id_ex_reg_write_en <= 0;
        id_ex_mread_en <= 0;
        id_ex_mwrite_en <= 0;
        id_ex_tensor_tdot_en <= 0;
        id_ex_tensor_tdot_relu_en <= 0;
        id_ex_alu_op <= 0;
        id_ex_alu_dtype <= 0;
        id_ex_alu_src <= 0;
        id_ex_result_sel <= 0;
        id_ex_mem2reg <= 0;

        id_ex_rd_addr <= 0;
        id_ex_rs1_data <= 0;
        id_ex_rs2_data <= 0;
        id_ex_imm_ext64 <= 0;
    end else if (pipeline_freeze) begin
        // remain current value
    end else begin
        // control signals
        id_ex_reg_write_en <= id_reg_write_en;
        id_ex_mread_en <= id_mread_en;
        id_ex_mwrite_en <= id_mwrite_en;
        id_ex_tensor_tdot_en <= id_tensor_tdot_en;
        id_ex_tensor_tdot_relu_en <= id_tensor_tdot_relu_en;
        id_ex_alu_op <= id_alu_op;
        id_ex_alu_dtype <= id_alu_dtype;
        id_ex_alu_src <= id_alu_src;
        id_ex_result_sel <= id_exresult_sel;
        id_ex_mem2reg <= id_mem2reg;

        // data signals
        id_ex_rd_addr <= id_instr_rd_addr; // pass through rd address
        id_ex_rs1_data <= id_rs1_data;     // pass through rs1 data
        id_ex_rs2_data <= id_rs2_data;     // pass through rs2 data
        id_ex_imm_ext64 <= id_imm_ext64; // pass through sign-extended immediate
    end
end

// ============================================================
// EX stage
// ============================================================

// accept data signals from ID/EX register
wire [DATA_WIDTH-1:0] ex_rs1_data;
wire [DATA_WIDTH-1:0] ex_rs2_data;
wire [DATA_WIDTH-1:0] ex_alu_src1;
wire [DATA_WIDTH-1:0] ex_alu_src2;
wire [REG_ADDR_WIDTH-1:0] ex_reg_write_addr;

// accept control signals from ID/EX register
wire ex_reg_write_en;
wire ex_mread_en;
wire ex_mwrite_en;
wire ex_tensor_tdot_en;
wire ex_tensor_tdot_relu_en;
wire [3:0] ex_alu_op;
wire [1:0] ex_alu_dtype;
wire ex_alu_src;
wire ex_result_sel;
wire ex_mem2reg;

assign ex_rs1_data = id_ex_rs1_data;
assign ex_rs2_data = id_ex_rs2_data;
assign ex_reg_write_addr = id_ex_rd_addr;

assign ex_alu_src1 = id_ex_rs1_data;
assign ex_alu_src2 = ex_alu_src ? id_ex_imm_ext64 : id_ex_rs2_data;

assign ex_reg_write_en = id_ex_reg_write_en;
assign ex_mread_en = id_ex_mread_en;
assign ex_mwrite_en = id_ex_mwrite_en;
assign ex_tensor_tdot_en = id_ex_tensor_tdot_en;
assign ex_tensor_tdot_relu_en = id_ex_tensor_tdot_relu_en;
assign ex_alu_op = id_ex_alu_op;
assign ex_alu_dtype = id_ex_alu_dtype;
assign ex_alu_src = id_ex_alu_src;
assign ex_result_sel = id_ex_result_sel;
assign ex_mem2reg = id_ex_mem2reg;

wire [DATA_WIDTH-1:0] ex_alu_result;
wire [DATA_WIDTH-1:0] ex_tensor_result;

wire [DATA_WIDTH-1:0] ex_final_result;
assign ex_final_result = ex_result_sel ? ex_tensor_result : ex_alu_result;

// ============================================================
// Freeze Unit
// ============================================================
reg [3:0] freeze_counter;

wire is_multi_cycle =
       (id_ex_alu_op == OP_MUL) ||
       (id_ex_alu_op == OP_TDOT) ||
       (id_ex_alu_op == OP_TDOT_RELU);

always @(posedge clk or posedge reset) begin
    if (reset) begin
        freeze_counter <= 0;
    end
    else if (is_multi_cycle && freeze_counter == 0) begin
        freeze_counter <= FREEZE_CLOCK - 1;
    end
    else if (freeze_counter != 0) begin
        freeze_counter <= freeze_counter - 1;
    end
end

assign pipeline_freeze = is_multi_cycle || (freeze_counter != 0);

gpu_simd_alu simd_alu (
    // inputs
    .alu_op(ex_alu_op), 
    .alu_datatype(ex_alu_dtype), 
    .alu_input1(ex_alu_src1), 
    .alu_input2(ex_alu_src2),

    // outputs
    .alu_output(ex_alu_result)
);

gpu_tensor_unit tensor_unit (
    // inputs
    .tensor_input_1(ex_rs1_data),
    .tensor_input_2(ex_rs2_data),
    .tensor_relu(ex_tensor_tdot_relu_en),

    // outputs
    .tensor_result(ex_tensor_result)
);

// EX/MEM pipeline register
reg ex_mem_reg_write_en;
reg ex_mem_mread_en;
reg ex_mem_mwrite_en;
reg ex_mem_mem2reg;

reg [REG_ADDR_WIDTH-1:0] ex_mem_rd_addr;
reg [DATA_WIDTH-1:0] ex_mem_final_result;
reg [DATA_WIDTH-1:0] ex_mem_rs2_data; // for store data

// Update EX/MEM pipeline register on clock edge
always @(posedge clk or posedge reset) begin
    if(reset) begin
        ex_mem_reg_write_en <= 0;
        ex_mem_mread_en <= 0;
        ex_mem_mwrite_en <= 0;
        ex_mem_mem2reg <= 0;

        ex_mem_rd_addr <= 0;
        ex_mem_final_result <= 0;
        ex_mem_rs2_data <= 0;
    end else if (pipeline_freeze) begin
        // remain current value
    end else begin
        // control signals
        ex_mem_reg_write_en <= ex_reg_write_en;
        ex_mem_mread_en <= ex_mread_en;
        ex_mem_mwrite_en <= ex_mwrite_en;
        ex_mem_mem2reg <= ex_mem2reg;

        // data signals
        ex_mem_rd_addr <= ex_reg_write_addr; // pass through rd address from ID/EX register
        ex_mem_final_result <= ex_final_result; // pass ALU/tensor result to MEM stage
        ex_mem_rs2_data <= id_ex_rs2_data; // pass rs2 data for store instructions
    end

end
// ============================================================
// MEM stage
// ============================================================

// accept data signals from EX/MEM register
wire [DATA_WIDTH-1:0] mem_final_result;
wire [DATA_WIDTH-1:0] mem_rs2_data; // for store data
wire [REG_ADDR_WIDTH-1:0] mem_reg_write_addr;

assign mem_final_result = ex_mem_final_result;
assign mem_rs2_data = ex_mem_rs2_data;
assign mem_reg_write_addr = ex_mem_rd_addr;

// accept control signals from EX/MEM register
wire mem_reg_write_en;
wire mem_mread_en;
wire mem_mwrite_en;
wire mem_mem2reg;

assign mem_reg_write_en = ex_mem_reg_write_en;
assign mem_mread_en = ex_mem_mread_en;
assign mem_mwrite_en = ex_mem_mwrite_en;
assign mem_mem2reg = ex_mem_mem2reg;

wire [DATA_WIDTH-1:0] mem_dmem_rdata;

gpu_dmem #(.MEM_SIZE(256), .ADDR_WIDTH(DATA_ADDR_WIDTH), .DATA_WIDTH(DATA_WIDTH)) dmem (
    // inputs
    .dmem_read_en(mem_mread_en),
    .dmem_read_addr(mem_final_result[DATA_ADDR_WIDTH-1:0]), // use lower bits of address for memory indexing
    .dmem_write_addr(mem_final_result[DATA_ADDR_WIDTH-1:0]), // use lower bits of address for memory indexing
    .dmem_write_data(mem_rs2_data),
    .dmem_write_en(mem_mwrite_en),
    .clk(clk),
    .reset(reset),

    // outputs
    .dmem_data(mem_dmem_rdata)
);

// MEM/WB pipeline register
reg mem_wb_reg_write_en;
reg mem_wb_mem2reg;
reg [REG_ADDR_WIDTH-1:0] mem_wb_rd_addr;
reg [DATA_WIDTH-1:0] mem_wb_alu_result;
reg [DATA_WIDTH-1:0] mem_wb_dmem_rdata;

// Update MEM/WB pipeline register on clock edge
always @(posedge clk or posedge reset) begin
    if (reset) begin
        mem_wb_reg_write_en <= 0;
        mem_wb_mem2reg <= 0;
        mem_wb_rd_addr <= 0;
        mem_wb_alu_result <= 0;
        mem_wb_dmem_rdata <= 0;
    end else if (pipeline_freeze) begin
        // remain current value
    end else begin
        mem_wb_reg_write_en <= mem_reg_write_en;
        mem_wb_mem2reg <= mem_mem2reg;
        mem_wb_rd_addr <= mem_reg_write_addr; // pass through rd address from EX/MEM register
        mem_wb_alu_result <= mem_final_result; // pass ALU/tensor result for write back
        mem_wb_dmem_rdata <= mem_dmem_rdata; // pass memory read data for write back
    end
end

// ============================================================
// WB stage
// ============================================================

// accept control signals from MEM/WB register
wire wb_reg_write_en;
wire wb_mem2reg;

assign wb_mem2reg = mem_wb_mem2reg;
assign wb_reg_write_en = mem_wb_reg_write_en;

// accept data signals from MEM/WB register
wire [REG_ADDR_WIDTH-1:0] wb_reg_write_addr;
wire [DATA_WIDTH-1:0]     wb_reg_write_data;
wire [DATA_WIDTH-1:0]     wb_alu_result;
wire [DATA_WIDTH-1:0]     wb_dmem_rdata;
 
assign wb_alu_result = mem_wb_alu_result;
assign wb_dmem_rdata = mem_wb_dmem_rdata;
assign wb_reg_write_addr = mem_wb_rd_addr;
assign wb_reg_write_data = wb_mem2reg ? wb_dmem_rdata : wb_alu_result;

endmodule