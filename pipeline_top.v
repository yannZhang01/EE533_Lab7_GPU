`timescale 1ns / 1ps
// pipeline_top.v
// 5-stage pipeline top that matches uploaded submodules' ports/names.
// - IF -> ID -> EX -> MEM -> WB
// - Integrates with control_unit.v (stall/flush/forwarding/pc control)
// - Uses gpu_pc, gpu_imem, regfile, gpu_alu, tensor_unit, gpu_dmem

module pipeline_top (
    input  wire clk,
    input  wire rst_n
);

    // -------------------------
    // IF Stage: PC + I-Mem
    // -------------------------
    wire [31:0] pc;
    wire [31:0] pc_plus1;

    // control signals from control_unit
    wire        stall;           // stall pipeline (freeze IF/ID & PC)
    wire        flush_if_id;     // clear IF/ID
    wire        pc_write_en;     // allow PC update (not used directly here; we map to gpu_pc stall)
    wire [1:0]  pc_src_sel;      // 00 = pc+1, 01 = branch_target, 10 = jump (not used separately)
    wire [31:0] pc_branch_target;

    // gpu_pc has: clk, rst_n, stall, branch_valid, branch_target -> pc, pc_plus1
    // We'll map branch_valid = (pc_src_sel != 2'b00)
    wire branch_valid;
    assign branch_valid = (pc_src_sel != 2'b00);
    wire pc_freeze; // signal to freeze PC updates (stall or EX freeze)
    assign pc_freeze = (ex_freeze || !pc_write_en); // freeze PC when not allowed to update

    gpu_pc #(
        .ADDR_WIDTH(32)
    ) u_pc (
        .clk(clk),
        .rst_n(rst_n),
        .stall(stall), 
        .pc_freeze(pc_freeze), // freeze PC when pc_write_en is 0 or ex_freeze is 1 (i.e., not allowed to update)
        .branch_valid(branch_valid),  // taken when control says so
        .branch_target(pc_branch_target),
        .pc(pc),
        .pc_plus1(pc_plus1)
    );

    // Instruction memory (module name in file: gpu_imem)
    wire [31:0] instr;
    gpu_imem u_imem (
        .addr(pc),
        .instr(instr)
    );

    // IF/ID pipeline register
    reg [31:0] ifid_instr;
    reg [31:0] ifid_pc;

    always @(posedge clk) begin
        if (!rst_n) begin
            ifid_instr <= 32'b0;
            ifid_pc    <= 32'b0;
        end else begin
            if (flush_if_id) begin
                // write NOP into IF/ID
                ifid_instr <= 32'b0;
                ifid_pc    <= 32'b0;
            end else if (stall) begin
                // hold IF/ID (don't update)
                ifid_instr <= ifid_instr;
                ifid_pc    <= ifid_pc;
            end else if (ex_freeze) begin
                // EX stage freeze: hold IF/ID but allow PC to update (for branch delay slot)
                ifid_instr <= ifid_instr;
                ifid_pc    <= ifid_pc;
            end else begin
                ifid_instr <= instr;
                ifid_pc    <= pc;
            end
        end
    end


    // -------------------------
    // ID Stage: decode & regfile
    // -------------------------
    wire [3:0] id_opcode = ifid_instr[31:28];
    wire [1:0] id_dtype  = ifid_instr[27:26];

    wire [3:0] id_rd     = ifid_instr[25:22];  
    wire [3:0] id_rs1    = ifid_instr[21:18];  
    wire [3:0] id_rs2    = ifid_instr[17:14];   
    wire [17:0] imm18    = ifid_instr[17:0];

    wire [31:0] id_branch_target = ifid_pc + 1 + {{14{imm18[17]}}, imm18};

    // regfile ports: rs1_addr, rs2_addr -> rs1_data, rs2_data ; rd, write_data, regwrite
    wire [63:0] id_rs1_data;
    wire [63:0] id_rs2_data;

    // WB stage writeback wires (declared later, but referenced by regfile)
    wire [3:0]  wb_rd;
    wire [63:0] wb_result;
    wire        wb_regwrite;

    regfile u_regfile (
        .clk(clk),
        .rst_n(rst_n),

        .rs1_addr(id_rs1),
        .rs1_data(id_rs1_data),

        .rs2_addr(id_rs2),
        .rs2_data(id_rs2_data),

        // writeback port
        .rd_addr(wb_rd),
        .rd_data(wb_result),
        .rd_we(wb_regwrite)
    );

    // Compute branch condition in ID (BRZ/BRNZ): treat zero/non-zero on rs1
    // Control unit expects branch_cond_id and is_branch_id
    wire id_is_brz; // OP_BRZ
    assign id_is_brz = (id_opcode == 4'b1011); // OP_BRZ
    wire id_is_brnz; // OP_BRNZ
    assign id_is_brnz = (id_opcode == 4'b1100); // OP_BRNZ
    wire id_is_branch;
    assign id_is_branch = id_is_brz | id_is_brnz;
    wire id_branch_cond;
    assign id_branch_cond = (id_is_brz && (id_rs1_data == 64'd0)) ||
                          (id_is_brnz && (id_rs1_data != 64'd0));

    // -------------------------
    // Control unit instantiation
    // -------------------------
    // add wire to receive new ctrl_alu_src output
    wire        ctrl_alu_src;

    wire [3:0]  rd_ex_sig;
    wire        regwrite_ex_sig;
    wire        memread_ex_sig;

    wire [3:0]  rd_wb_sig;
    wire        regwrite_wb_sig;

    wire [1:0] forwardA;
    wire [1:0] forwardB;

    // control outputs into ID/EX (control bundle)
    wire [3:0] ctrl_alu_op;
    wire [1:0] ctrl_dtype;
    wire       ctrl_mem_read;
    wire       ctrl_mem_write;
    wire       ctrl_reg_write;
    wire       ctrl_mem_to_reg;
    wire       ctrl_is_tdot;
    wire       ctrl_tensor_relu;
    wire       ctrl_ex_freeze;

    control_unit u_ctrl (
        .clk(clk),
        .rst_n(rst_n),

        // ID inputs
        .opcode_id(id_opcode),
        .dtype_id(id_dtype),
        .rd_id(id_rd),
        .rs1_id(id_rs1),
        .rs2_id(id_rs2),
        .branch_cond_id(id_branch_cond),
        .is_branch_id(id_is_branch),
        .branch_target_id(id_branch_target),

        // pipeline state inputs for hazard/forwarding
        .rd_ex(rd_ex_sig),
        .regwrite_ex(regwrite_ex_sig),
        .memread_ex(memread_ex_sig),

        .rd_mem(mem_rd),
        .regwrite_mem(mem_regwrite),
        .memread_mem(mem_memread),

        .rd_wb(rd_wb_sig),
        .regwrite_wb(regwrite_wb_sig),

        // outputs
        .stall(stall),
        .flush_if_id(flush_if_id),
        .pc_write_en(pc_write_en),
        .pc_src_sel(pc_src_sel),
        .pc_branch_target(pc_branch_target),

        .forwardA(forwardA),
        .forwardB(forwardB),

        .ctrl_alu_op(ctrl_alu_op),
        .ctrl_dtype(ctrl_dtype),
        .ctrl_mem_read(ctrl_mem_read),
        .ctrl_mem_write(ctrl_mem_write),
        .ctrl_reg_write(ctrl_reg_write),
        .ctrl_mem_to_reg(ctrl_mem_to_reg),
        .ctrl_is_tdot(ctrl_is_tdot),
        .ctrl_tensor_relu(ctrl_tensor_relu),
        .ctrl_ex_freeze(ctrl_ex_freeze),
        .ctrl_alu_src(ctrl_alu_src)
    );

    // -------------------------
    // ID/EX pipeline register
    // -------------------------
    reg [63:0] ex_rs1_data;
    reg [63:0] ex_rs2_data;
    reg [1:0]  ex_dtype;
    reg [3:0]  ex_rd;
    reg        ex_regwrite;
    reg        ex_memread;
    reg        ex_memwrite;
    reg        ex_memtoreg;
    reg        ex_is_tdot;
    reg        ex_tensor_relu;
    reg        ex_freeze;
    reg [3:0]  ex_alu_op;

    // *** CHANGED: need to carry immediate and alu_src into EX stage ***
    reg [17:0] ex_imm18;       // immediate latched into EX
    reg        ex_alu_src;     // 1 = use immediate for ALU src2; 0 = use rs2

    // For hazard insertion: when stall asserted, we need to insert a bubble into EX stage:
    // i.e., freeze IF/ID & PC, but write zeros into ID/EX control fields.
    always @(posedge clk) begin
        if (!rst_n) begin
            ex_rs1_data  <= 64'd0;
            ex_rs2_data  <= 64'd0;
            ex_dtype     <= 2'b00;
            ex_rd        <= 4'd0;
            ex_regwrite  <= 1'b0;
            ex_memread   <= 1'b0;
            ex_memwrite  <= 1'b0;
            ex_memtoreg  <= 1'b0;
            ex_is_tdot   <= 1'b0;
            ex_alu_op    <= 4'd0;
            ex_tensor_relu <= 1'b0;
            ex_freeze     <= 1'b0;
            ex_imm18     <= 18'd0;
            ex_alu_src   <= 1'b0;
        end else begin
            if (stall) begin
                // insert bubble: keep pipeline state but insert NOP control into EX stage
                ex_rs1_data  <= ex_rs1_data; // hold (not strictly necessary)
                ex_rs2_data  <= ex_rs2_data;
                ex_dtype     <= 2'b00;
                ex_rd        <= 4'd0;
                ex_regwrite  <= 1'b0;
                ex_memread   <= 1'b0;
                ex_memwrite  <= 1'b0;
                ex_memtoreg  <= 1'b0;
                ex_is_tdot   <= 1'b0;
                ex_alu_op    <= 4'd0;
                ex_imm18     <= 18'd0;
                ex_tensor_relu <= 1'b0;
                ex_freeze    <= 1'b0;
                ex_alu_src   <= 1'b0;
            end
            
            else if (ex_freeze) begin
                // EX stage freeze: hold EX register values but don't update them
                ex_rs1_data  <= ex_rs1_data;
                ex_rs2_data  <= ex_rs2_data;
                ex_dtype     <= ex_dtype;
                ex_rd        <= ex_rd;
                ex_regwrite  <= ex_regwrite;
                ex_memread   <= ex_memread;
                ex_memwrite  <= ex_memwrite;
                ex_memtoreg  <= ex_memtoreg;
                ex_is_tdot   <= ex_is_tdot;
                ex_alu_op    <= ex_alu_op;
                ex_imm18     <= ex_imm18;
                ex_tensor_relu <= ex_tensor_relu;
                ex_freeze    <= 1'b0; // set freeze flag
                ex_alu_src   <= ctrl_alu_src; // reset alu_src to default value
            end
            
            else begin
                ex_rs1_data  <= id_rs1_data;
                ex_rs2_data  <= id_rs2_data;
                ex_dtype     <= ctrl_dtype;     // from control_unit
                ex_rd        <= id_rd;
                ex_regwrite  <= ctrl_reg_write;
                ex_memread   <= ctrl_mem_read;
                ex_memwrite  <= ctrl_mem_write;
                ex_memtoreg  <= ctrl_mem_to_reg;
                ex_is_tdot   <= ctrl_is_tdot;
                ex_tensor_relu <= ctrl_tensor_relu;
                ex_freeze     <= ctrl_ex_freeze;
                ex_alu_op    <= ctrl_alu_op;
                ex_imm18     <= imm18;          // latch immediate into EX
                ex_alu_src   <= ctrl_alu_src;   // latch ctrl selection
            end
        end
    end

    // -------------------------
    // EX Stage: ALU / Tensor unit + forwarding mux
    // -------------------------
    wire [63:0] alu_src1;
    wire [63:0] alu_src2;

    // EX/MEM and MEM/WB register values needed for forwarding
    reg [63:0] mem_alu_result;
    reg [3:0]  mem_rd;
    reg        mem_regwrite;
    reg        mem_memread;
    reg        mem_memwrite;
    reg        mem_memtoreg;
    reg [63:0] mem_write_data;

    reg [63:0] wb_value;
    reg [3:0]  wb_rd_reg;
    reg        wb_regwrite_reg;

    // For forwarding we use forwardA/forwardB control from control_unit:
    // 00 -> ex_rsX (no forward)
    // 01 -> forward from MEM stage (mem_alu_result)
    // 10 -> forward from WB stage (wb_value)
    // Forwarded operand selection (shared by ALU and Tensor)
    // Forwarded EX src1
    wire [63:0] ex_op_src1;
    assign ex_op_src1 = (forwardA == 2'b01) ? mem_alu_result :
                        (forwardA == 2'b10) ? wb_value :
                                            ex_rs1_data;

    // Forwarded EX register src2 (before imm/reg select)
    wire [63:0] ex_reg_src2;
    assign ex_reg_src2 = (forwardB == 2'b01) ? mem_alu_result :
                        (forwardB == 2'b10) ? wb_value :
                                            ex_rs2_data;

    // Sign-extend ex_imm18 to 64-bit
    wire [63:0] ex_imm_ext;
    assign ex_imm_ext = {{46{ex_imm18[17]}}, ex_imm18};

    // Final EX src2 selection: if ex_alu_src==1 use imm, else use forwarded register value
    wire [63:0] ex_op_src2;
    assign ex_op_src2 = (ex_alu_src) ? ex_imm_ext : ex_reg_src2;

    // ALU instantiation (gpu_alu expects alu_op, datatype, src1, src2)
    wire [63:0] alu_result;
    gpu_alu u_alu (
        .alu_op(ex_alu_op),
        .datatype(ex_dtype),
        .src1(ex_op_src1),
        .src2(ex_op_src2),
        .result(alu_result)
    );

    // tensor unit (use forwarded sources; control selects between tensor or ALU)
    wire [63:0] tdot_result;
    tensor_unit u_tensor (
        .a(ex_op_src1),
        .b(ex_op_src2),
        .relu(ex_tensor_relu),
        .result(tdot_result)
    );

    wire [63:0] ex_result = ex_is_tdot ? tdot_result : alu_result;

    // -------------------------
    // EX/MEM pipeline register
    // -------------------------
    always @(posedge clk) begin
        if (!rst_n) begin
            mem_alu_result <= 64'd0;
            mem_write_data <= 64'd0;
            mem_rd         <= 4'd0;
            mem_regwrite   <= 1'b0;
            mem_memread    <= 1'b0;
            mem_memwrite   <= 1'b0;
            mem_memtoreg   <= 1'b0;
        end 
        
        else if (ex_freeze) begin
            // EX stage freeze: hold MEM register values but don't update them
            mem_alu_result <= mem_alu_result;
            mem_write_data <= mem_write_data;
            mem_rd         <= mem_rd;
            mem_regwrite   <= mem_regwrite;
            mem_memread    <= mem_memread;
            mem_memwrite   <= mem_memwrite;
            mem_memtoreg   <= mem_memtoreg;
        end
        
        else begin
            mem_alu_result <= ex_result;
            mem_write_data <= ex_rs2_data;  // carry store data into MEM stage
            mem_rd         <= ex_rd;
            mem_regwrite   <= ex_regwrite;
            mem_memread    <= ex_memread;
            mem_memwrite   <= ex_memwrite;
            mem_memtoreg   <= ex_memtoreg;
        end
    end

    // -------------------------
    // MEM Stage: Data memory (gpu_dmem)
    // -------------------------
    wire [63:0] mem_read_data;
    gpu_dmem u_dmem (
        .clk(clk),
        .rst_n(rst_n),
        .mem_read(mem_memread),
        .mem_write(mem_memwrite),
        .addr(mem_alu_result[31:0]),
        .write_data(mem_write_data),
        .read_data(mem_read_data)
    );

    // -------------------------
    // MEM/WB pipeline register
    // -------------------------
    always @(posedge clk) begin
        if (!rst_n) begin
            wb_value       <= 64'd0;
            wb_rd_reg      <= 4'd0;
            wb_regwrite_reg<= 1'b0;
        end 
        
        else if (ex_freeze) begin
            // EX stage freeze: hold WB register values but don't update them
            wb_value       <= wb_value;
            wb_rd_reg      <= wb_rd_reg;
            wb_regwrite_reg<= wb_regwrite_reg;
        end
        
        else begin
            // writeback value: from memory if memtoreg else from ALU result
            wb_value        <= mem_memtoreg ? mem_read_data : mem_alu_result;
            wb_rd_reg       <= mem_rd;
            wb_regwrite_reg <= mem_regwrite;
        end
    end

    // Assign the externally visible WB signals (wired to regfile write port)
    assign wb_result = wb_value;
    assign wb_rd     = wb_rd_reg;
    assign wb_regwrite = wb_regwrite_reg;

    // -------------------------
    // Hook up pipeline state signals required by control_unit
    // -------------------------
    // Drive EX-stage info:
    assign rd_ex_sig = ex_rd;
    assign regwrite_ex_sig = ex_regwrite;
    assign memread_ex_sig = ex_memread;

    // MEM/WB stage info
    assign rd_wb_sig = wb_rd_reg;
    assign regwrite_wb_sig = wb_regwrite_reg;

endmodule