`timescale 1ns/1ps
`include "../include/registers.v"

// ============================================================
// Wrapper GPU top: NetFPGA-style streaming passthrough + reg-ring
// IMEM/DMEM instantiated here with CPU interact mux (pipeline_top style)
// ============================================================

module gpu_top #(
    parameter DATA_WIDTH        = 64,
    parameter CTRL_WIDTH        = DATA_WIDTH/8,
    parameter UDP_REG_SRC_WIDTH = 2,

    parameter INST_WIDTH        = 32,
    parameter INST_ADDR_WIDTH   = 9,
    parameter DATA_ADDR_WIDTH   = 8,
    parameter REG_ADDR_WIDTH    = 4
)(
    input  wire                         clk,
    input  wire                         reset,

    // Streaming datapath in/out
    input  wire [DATA_WIDTH-1:0]        in_data,
    input  wire [CTRL_WIDTH-1:0]        in_ctrl,
    input  wire                         in_wr,
    output wire                         in_rdy,

    output wire [DATA_WIDTH-1:0]        out_data,
    output wire [CTRL_WIDTH-1:0]        out_ctrl,
    output wire                         out_wr,
    input  wire                         out_rdy,

    // Register ring in/out
    input  wire                         reg_req_in,
    input  wire                         reg_ack_in,
    input  wire                         reg_rd_wr_L_in,
    input  wire [`UDP_REG_ADDR_WIDTH-1:0]  reg_addr_in,
    input  wire [`CPCI_NF2_DATA_WIDTH-1:0] reg_data_in,
    input  wire [UDP_REG_SRC_WIDTH-1:0]    reg_src_in,

    output wire                         reg_req_out,
    output wire                         reg_ack_out,
    output wire                         reg_rd_wr_L_out,
    output wire [`UDP_REG_ADDR_WIDTH-1:0]  reg_addr_out,
    output wire [`CPCI_NF2_DATA_WIDTH-1:0] reg_data_out,
    output wire [UDP_REG_SRC_WIDTH-1:0]    reg_src_out
);

    // ----------------------------
    // Datapath passthrough
    // ----------------------------
    assign out_data = in_data;
    assign out_ctrl = in_ctrl;
    assign out_wr   = in_wr;
    assign in_rdy   = out_rdy;

    // ----------------------------
    // SW regs
    // ----------------------------
    wire [31:0] imem_interact;
    wire [31:0] imem_write;
    wire [31:0] imem_rw_address;
    wire [31:0] imem_wdata;

    wire [31:0] dmem_interact;
    wire [31:0] dmem_write;
    wire [31:0] dmem_rw_address;
    wire [31:0] dmem_wdata_upper;
    wire [31:0] dmem_wdata_lower;

    // ----------------------------
    // HW regs
    // ----------------------------
    reg  [31:0] imem_rdata;
    reg  [31:0] dmem_rdata_upper;
    reg  [31:0] dmem_rdata_lower;

    // ----------------------------
    // generic_regs (pipeline_top style)
    // ----------------------------
    generic_regs #(
        .UDP_REG_SRC_WIDTH (UDP_REG_SRC_WIDTH),
        .TAG(`GPU_BLOCK_ADDR),
        .REG_ADDR_WIDTH(`GPU_REG_ADDR_WIDTH),
        .NUM_COUNTERS      (0),
        .NUM_SOFTWARE_REGS (9),
        .NUM_HARDWARE_REGS (3)
    ) u_regs (
        .reg_req_in      (reg_req_in),
        .reg_ack_in      (reg_ack_in),
        .reg_rd_wr_L_in  (reg_rd_wr_L_in),
        .reg_addr_in     (reg_addr_in),
        .reg_data_in     (reg_data_in),
        .reg_src_in      (reg_src_in),

        .reg_req_out     (reg_req_out),
        .reg_ack_out     (reg_ack_out),
        .reg_rd_wr_L_out (reg_rd_wr_L_out),
        .reg_addr_out    (reg_addr_out),
        .reg_data_out    (reg_data_out),
        .reg_src_out     (reg_src_out),

        .counter_updates   (),
        .counter_decrement (),

        .software_regs ({
            dmem_wdata_lower,
            dmem_wdata_upper,
            dmem_rw_address,
            dmem_write,
            dmem_interact,
            imem_wdata,
            imem_rw_address,
            imem_write,
            imem_interact
        }),

        .hardware_regs ({
            dmem_rdata_lower,
            dmem_rdata_upper,
            imem_rdata
        }),

        .clk   (clk),
        .reset (reset)
    );

    // ============================================================
    // Hook core <-> wrapper signals
    // ============================================================

    // --- IMEM ---
    wire [INST_ADDR_WIDTH-1:0] core_imem_read_addr;
    wire [INST_WIDTH-1:0]      core_if_imem_instr;

    // --- DMEM ---
    wire                       core_dmem_read_en;
    wire [DATA_ADDR_WIDTH-1:0] core_dmem_read_addr;
    wire [DATA_ADDR_WIDTH-1:0] core_dmem_write_addr;
    wire [DATA_WIDTH-1:0]      core_dmem_write_data;
    wire                       core_dmem_write_en;
    wire [DATA_WIDTH-1:0]      core_dmem_rdata;

    // ============================================================
    // IMEM instance in TOP + CPU interact mux
    // (Preserve core-side behavior: core provides read_addr and consumes instr)
    // ============================================================

    reg  [INST_ADDR_WIDTH-1:0] imem_read_addr_mux;
    reg  [INST_ADDR_WIDTH-1:0] imem_write_addr_mux;
    reg  [INST_WIDTH-1:0]      imem_write_data_mux;
    reg                        imem_write_en_mux;
    wire [INST_WIDTH-1:0]      imem_instr_wire;

    gpu_imem #(
        .MEM_SIZE(512),
        .ADDR_WIDTH(INST_ADDR_WIDTH),
        .DATA_WIDTH(INST_WIDTH)
    ) imem (
        .imem_read_addr (imem_read_addr_mux),
        .imem_write_addr(imem_write_addr_mux),
        .imem_write_data(imem_write_data_mux),
        .imem_write_en  (imem_write_en_mux),
        .clk            (clk),
        .reset          (reset),
        .imem_instr     (imem_instr_wire)
    );

    always @(*) begin
        // default: core drives read address, no write
        imem_read_addr_mux  = core_imem_read_addr;
        imem_write_addr_mux = {INST_ADDR_WIDTH{1'b0}};
        imem_write_data_mux = {INST_WIDTH{1'b0}};
        imem_write_en_mux   = 1'b0;

        // CPU interact overrides (pipeline_top style)
        if (imem_interact[0]) begin
            imem_read_addr_mux  = imem_rw_address[INST_ADDR_WIDTH-1:0];
            imem_write_addr_mux = imem_rw_address[INST_ADDR_WIDTH-1:0];
            imem_write_data_mux = imem_wdata[INST_WIDTH-1:0];
            imem_write_en_mux   = imem_write[0];
        end
    end

    assign core_if_imem_instr = imem_instr_wire;

    // ============================================================
    // DMEM instance in TOP + CPU interact mux
    // ============================================================

    reg                        dmem_read_en_mux;
    reg  [DATA_ADDR_WIDTH-1:0] dmem_read_addr_mux;
    reg  [DATA_ADDR_WIDTH-1:0] dmem_write_addr_mux;
    reg  [DATA_WIDTH-1:0]      dmem_write_data_mux;
    reg                        dmem_write_en_mux;
    wire [DATA_WIDTH-1:0]      dmem_data_wire;

    gpu_dmem #(
        .MEM_SIZE(256),
        .ADDR_WIDTH(DATA_ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH)
    ) dmem (
        .dmem_read_en   (dmem_read_en_mux),
        .dmem_read_addr (dmem_read_addr_mux),
        .dmem_write_addr(dmem_write_addr_mux),
        .dmem_write_data(dmem_write_data_mux),
        .dmem_write_en  (dmem_write_en_mux),
        .clk            (clk),
        .reset          (reset),
        .dmem_data      (dmem_data_wire)
    );

    always @(*) begin
        // default: core drives dmem
        dmem_read_en_mux    = core_dmem_read_en;
        dmem_read_addr_mux  = core_dmem_read_addr;
        dmem_write_addr_mux = core_dmem_write_addr;
        dmem_write_data_mux = core_dmem_write_data;
        dmem_write_en_mux   = core_dmem_write_en;

        // CPU interact overrides (pipeline_top style)
        if (dmem_interact[0]) begin
            dmem_read_en_mux    = 1'b1; // allow readback
            dmem_read_addr_mux  = dmem_rw_address[DATA_ADDR_WIDTH-1:0];
            dmem_write_addr_mux = dmem_rw_address[DATA_ADDR_WIDTH-1:0];
            dmem_write_data_mux = {dmem_wdata_upper, dmem_wdata_lower};
            dmem_write_en_mux   = dmem_write[0];
        end
    end

    assign core_dmem_rdata = dmem_data_wire;

    // ============================================================
    // Readback regs (pipeline_top style)
    // ============================================================
    always @(posedge clk) begin
        if (reset) begin
            imem_rdata       <= 32'hBADABDAB;
            dmem_rdata_upper <= 32'hBADABDAB;
            dmem_rdata_lower <= 32'hBADABDAB;
        end else begin
            // IMEM readback (only when interact and not writing)
            if (imem_interact[0] && !imem_write_en_mux) begin
                imem_rdata <= imem_instr_wire;
            end

            // DMEM readback (when interact)
            if (dmem_interact[0]) begin
                dmem_rdata_upper <= dmem_data_wire[63:32];
                dmem_rdata_lower <= dmem_data_wire[31:0];
            end
        end
    end

    // ============================================================
    // Instantiate core (NO enable added; core logic preserved)
    // ============================================================
    gpu_core #(
        .DATA_WIDTH      (DATA_WIDTH),
        .INST_WIDTH      (INST_WIDTH),
        .INST_ADDR_WIDTH (INST_ADDR_WIDTH),
        .DATA_ADDR_WIDTH (DATA_ADDR_WIDTH),
        .REG_ADDR_WIDTH  (REG_ADDR_WIDTH),

        .OP_BRZ          (4'b1011),
        .OP_BRNZ         (4'b1100),
        .OP_MUL          (4'b0110),
        .OP_TDOT         (4'b1110),
        .OP_TDOT_RELU    (4'b1111),

        .FREEZE_CLOCK    (1)
    ) u_core (
        .clk               (clk),
        .reset             (reset),

        .if_imem_read_addr (core_imem_read_addr),
        .if_imem_instr     (core_if_imem_instr),

        .mem_dmem_read_en    (core_dmem_read_en),
        .mem_dmem_read_addr  (core_dmem_read_addr),
        .mem_dmem_write_addr (core_dmem_write_addr),
        .mem_dmem_write_data (core_dmem_write_data),
        .mem_dmem_write_en   (core_dmem_write_en),
        .mem_dmem_rdata      (core_dmem_rdata)
    );

endmodule