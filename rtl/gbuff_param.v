`timescale 1ns / 1ps

module gbuff_param(
   input clk,rstn,
   input wet_wr_vld,
   input [31:0] read_data,
   input [9:0] WET_addr,
   input weight_load_start,
   input use_static_wet,
   input [11:0]    bsc_addra,
   output [31:0]   bsc_douta,
   output [287:0] i_weight
    );

wire [71:0] w_read_data;
wire [287:0] dyn_i_weight;

wire dpram_wr_en;

reg [1:0] pack_cnt;

reg [23:0] pack_buf0;
reg [23:0] pack_buf1;
reg [11:0] wet_wr_addr;
reg        weight_load_start_d;

reg [31:0] bsc_rom [0:2559];
reg [31:0] bsc_douta_r;
(* rom_style = "block" *) reg [287:0] static_wet_rom [0:1023];
reg [287:0] static_i_weight;

assign w_read_data = {read_data[23:0], pack_buf1, pack_buf0};
assign dpram_wr_en = wet_wr_vld & (pack_cnt == 2'd2);
assign bsc_douta = bsc_douta_r;
assign i_weight = use_static_wet ? static_i_weight : dyn_i_weight;

initial begin
    $readmemh("rom/bias_scale.hex", bsc_rom);
    $readmemh("rom/weight_1024x288.hex", static_wet_rom);
end

always @(posedge clk) begin
    bsc_douta_r <= bsc_rom[bsc_addra];
end

always @(posedge clk) begin
    static_i_weight <= static_wet_rom[WET_addr];
end

always @(posedge clk or negedge rstn) begin
    if (!rstn)
        pack_cnt <= 2'd0;
    else if (wet_wr_vld)
        pack_cnt <= (pack_cnt == 2'd2) ? 2'd0 : pack_cnt + 1;
end

always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        pack_buf0 <= 24'd0;
        pack_buf1 <= 24'd0;
    end
    else if (wet_wr_vld) begin
        if (pack_cnt == 2'd0) pack_buf0 <= read_data[23:0];
        if (pack_cnt == 2'd1) pack_buf1 <= read_data[23:0];
    end
end

always @(posedge clk or negedge rstn) begin
    if (!rstn)
        weight_load_start_d <= 1'b0;
    else
        weight_load_start_d <= weight_load_start;
end

always @(posedge clk or negedge rstn) begin
    if (!rstn)
        wet_wr_addr <= 12'd0;
    else if (weight_load_start_d)
        wet_wr_addr <= 12'd0;
    else if (dpram_wr_en)
        wet_wr_addr <= wet_wr_addr + 1;
end

dpram_4096x72_ u_dpram_4096x72 (

			.clka    (clk),
			.ena     (1'b1),
			.wea     (dpram_wr_en),
			.addra   (wet_wr_addr),
			.dina    (w_read_data),

			.clkb    (clk),
			.enb     (1'b1),
			.addrb   (WET_addr),
			.doutb   (dyn_i_weight)
		);

endmodule
