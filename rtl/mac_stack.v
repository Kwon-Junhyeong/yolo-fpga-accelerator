`timescale 1ns / 1ps

module mac_stack(
    input clk,rstn,vld_i,
    input signed [36*8-1:0] wgt,
    input [36*8-1:0] ifm_00,ifm_01,ifm_10,ifm_11,
    output signed [21:0] acc_00,acc_01,acc_10,acc_11,
    output vld_o

    );
 wire vld_01,vld_00;

 assign vld_o = vld_00 & vld_01;
mac_dual mac1(.clk(clk),.rstn(rstn),.vld_i(vld_i),.win(wgt),.din0(ifm_00),.din1(ifm_01),.acc_o0(acc_00),.acc_o1(acc_01),.vld_o(vld_00));
mac_dual mac2(.clk(clk),.rstn(rstn),.vld_i(vld_i),.win(wgt),.din0(ifm_10),.din1(ifm_11),.acc_o0(acc_10),.acc_o1(acc_11),.vld_o(vld_01));

endmodule
