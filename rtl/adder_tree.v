`timescale 1ns / 1ps

module adder_tree(
input clk,
input rstn,
input vld_i,
input signed [36*16-1:0] mul_res,
output signed [21:0] acc_o,
output       vld_o
);

reg [17:0] y1_0,y1_1,y1_2,y1_3,y1_4,y1_5,y1_6,y1_7,y1_8,y1_9,y1_10,y1_11;

reg [19:0] y2_0,y2_1,y2_2,y2_3;

reg [20:0] y3_0,y3_1;

reg [21:0] y4;

reg vld_i_d1, vld_i_d2, vld_i_d3, vld_i_d4;

always@(posedge clk) begin
	y1_0 <= $signed(mul_res[15:0])+$signed(mul_res[31:16])+$signed(mul_res[47:32]);
	y1_1 <= $signed(mul_res[63:48])+$signed(mul_res[79:64])+$signed(mul_res[95:80]);
	y1_2 <= $signed(mul_res[111:96])+$signed(mul_res[127:112])+$signed(mul_res[143:128]);
	y1_3 <= $signed(mul_res[159:144])+$signed(mul_res[175:160])+$signed(mul_res[191:176]);
	y1_4 <= $signed(mul_res[207:192])+$signed(mul_res[223:208])+$signed(mul_res[239:224]);
	y1_5 <= $signed(mul_res[255:240])+$signed(mul_res[271:256])+$signed(mul_res[287:272]);
	y1_6 <= $signed(mul_res[303:288])+$signed(mul_res[319:304])+$signed(mul_res[335:320]);
	y1_7 <= $signed(mul_res[351:336])+$signed(mul_res[367:352])+$signed(mul_res[383:368]);
	y1_8 <= $signed(mul_res[399:384])+$signed(mul_res[415:400])+$signed(mul_res[431:416]);
	y1_9 <= $signed(mul_res[447:432])+$signed(mul_res[463:448])+$signed(mul_res[479:464]);
	y1_10 <= $signed(mul_res[495:480])+$signed(mul_res[511:496])+$signed(mul_res[527:512]);
	y1_11 <= $signed(mul_res[543:528])+$signed(mul_res[559:544])+$signed(mul_res[575:560]);
end

always@(posedge clk) begin
	y2_0 <= $signed(y1_0) + $signed(y1_1)+$signed(y1_2);
	y2_1 <= $signed(y1_3) + $signed(y1_4)+$signed(y1_5);
	y2_2 <= $signed(y1_6) + $signed(y1_7)+$signed(y1_8);
	y2_3 <= $signed(y1_9) + $signed(y1_10)+$signed(y1_11);
end

always@(posedge clk) begin
	y3_0 <= $signed(y2_0) + $signed(y2_1);
	y3_1 <= $signed(y2_2) + $signed(y2_3);
end

always@(posedge clk) begin
	y4 <= $signed(y3_0) + $signed(y3_1);
end

always@(posedge clk, negedge rstn) begin
	if(!rstn) begin
		vld_i_d1 <= 0;
		vld_i_d2 <= 0;
		vld_i_d3 <= 0;
		vld_i_d4 <= 0;
	end
	else begin
		vld_i_d1 <= vld_i   ;
		vld_i_d2 <= vld_i_d1;
		vld_i_d3 <= vld_i_d2;
		vld_i_d4 <= vld_i_d3;
	end
end

assign vld_o = vld_i_d4;
assign acc_o = $signed(y4);

endmodule
