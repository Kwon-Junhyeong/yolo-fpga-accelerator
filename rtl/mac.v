`timescale 1ns / 1ps

module mac_dual(
input clk,
input rstn,
input vld_i,
input signed [36*8-1:0] win,
input [36*8-1:0] din0,
input [36*8-1:0] din1,
output signed [ 21:0] acc_o0,
output signed [ 21:0] acc_o1,
output        vld_o
);

wire [36*16-1:0] mul_res0;
wire [36*16-1:0] mul_res1;
wire vld_0,vld_1;
reg vld_i_d0, vld_i_d1, vld_i_d2, vld_i_d3, vld_i_d4;

assign vld_o = vld_0 & vld_1;

genvar i;
generate
    for (i = 0; i < 36; i = i + 1) begin : mul_array
        mul u_mul (
            .clk(clk),
            .w  (win[i*8 +: 8]),
            .x0 (din0[i*8 +: 8]),
            .x1 (din1[i*8 +: 8]),
            .y0 (mul_res0[i*16 +: 16]),
            .y1 (mul_res1[i*16 +: 16])
        );
    end
endgenerate

always@(posedge clk, negedge rstn) begin
	if(!rstn) begin
	    vld_i_d0 <= 0;
		vld_i_d1 <= 0;
		vld_i_d2 <= 0;
		vld_i_d3 <= 0;
	    vld_i_d4 <= 0;
	end
	else begin
		vld_i_d0 <= vld_i   ;
		vld_i_d1 <= vld_i_d0;
		vld_i_d2 <= vld_i_d1;
		vld_i_d3 <= vld_i_d2;
	    vld_i_d4 <= vld_i_d3;
	end
end

adder_tree u_adder_tree0(
.clk(clk),
.rstn(rstn),
.vld_i(vld_i_d4),
.mul_res(mul_res0),
.acc_o(acc_o0),
.vld_o(vld_0)
);

adder_tree u_adder_tree1(
.clk(clk),
.rstn(rstn),
.vld_i(vld_i_d4),
.mul_res(mul_res1),
.acc_o(acc_o1),
.vld_o(vld_1)
);

endmodule
