`timescale 1ns / 1ps
`include "yolo_build_config_h.v"

module compute(
    input clk,rstn,i_start,i_mode,i_vld,
`ifdef YOLO_OC_PIPELINE
    input i_last,
`endif
    input signed [36*8-1:0] i_wgt,
    input [64*8-1:0] i_ifm,
    input signed [15:0] bias_param,
    input [15:0] scale_param,
    input linear_head,
    input route8_rescale,
    input [9:0] i_len,
    input has_maxpool,
    input maxpool_stride,
    output vld_o,
    output mac_done,
    output reg out_vaild,
    output reg [32-1:0] ofm,
    output [32-1:0] ofm_raw,
    output [64-1:0] ofm16,
    output [128-1:0] ofm32
    );

wire signed [32-1:0] o_ofmRB;
wire signed [32-1:0] o_ofmLB;
wire signed [32-1:0] o_ofmRT;
wire signed [32-1:0] o_ofmLT;

wire [7:0] max_01;
wire [7:0] max_23;
wire [7:0] max_all;

reg [8-1:0] ofm0;
reg [8-1:0] ofm1;
reg [8-1:0] ofm2;
reg [8-1:0] ofm3;
reg [8-1:0] route0;
reg [8-1:0] route1;
reg [8-1:0] route2;
reg [8-1:0] route3;

wire o_vld;
reg vaild;
reg vld;
reg signed [32-1:0] p_ofm;

reg signed [32-1:0]o_relu0,o_relu1,o_relu2,o_relu3;
reg signed [32-1:0]o_head0,o_head1,o_head2,o_head3;
reg signed [32-1:0]o_head32_0,o_head32_1,o_head32_2,o_head32_3;
reg signed [32-1:0]o_route0,o_route1,o_route2,o_route3;
reg signed [32-1:0] p_scale_param,p_bias_param;
reg p_linear_head;
reg p_route8_rescale;
wire [4:0] route_shift;
wire [4:0] head16_shift;
reg [16-1:0] ofm16_0;
reg [16-1:0] ofm16_1;
reg [16-1:0] ofm16_2;
reg [16-1:0] ofm16_3;
reg [32-1:0] ofm32_0;
reg [32-1:0] ofm32_1;
reg [32-1:0] ofm32_2;
reg [32-1:0] ofm32_3;

localparam [4:0] HEAD16_FRAC_BITS = 5'd4;

`ifdef YOLO_L0_OC_BURST

wire oc_burst_mode = (i_mode == 1'b0) && ((i_len >> 2) == 10'd1);
`ifdef YOLO_OC_PIPELINE

`ifdef YOLO_IMODE_OCP

wire ocp_mode = ((i_mode == 1'b0) && ((i_len >> 2) >= 10'd2)) ||
                ((i_mode == 1'b1) && ((i_len >> 4) >= 10'd2));
`else
wire ocp_mode = (i_mode == 1'b0) && ((i_len >> 2) >= 10'd2);
`endif
wire bs_fifo_push = (oc_burst_mode && i_vld) || (ocp_mode && i_vld && i_last);
wire bs_fifo_pop  = (oc_burst_mode || ocp_mode) && o_vld;
wire use_bs_fifo  = oc_burst_mode || ocp_mode;
`else
wire bs_fifo_push = oc_burst_mode && i_vld;
wire bs_fifo_pop  = oc_burst_mode && o_vld;
wire use_bs_fifo  = oc_burst_mode;
`endif
reg [15:0] bs_fifo_bias  [0:31];
reg [15:0] bs_fifo_scale [0:31];
reg [5:0]  bs_wr_ptr;
reg [5:0]  bs_rd_ptr;
wire signed [15:0] burst_bias  = bs_fifo_bias[bs_rd_ptr[4:0]];
wire        [15:0] burst_scale = bs_fifo_scale[bs_rd_ptr[4:0]];
always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        bs_wr_ptr <= 6'd0;
        bs_rd_ptr <= 6'd0;
    end
    else begin
        if (bs_fifo_push) begin
            bs_fifo_bias[bs_wr_ptr[4:0]]  <= bias_param;
            bs_fifo_scale[bs_wr_ptr[4:0]] <= scale_param;
            bs_wr_ptr <= bs_wr_ptr + 6'd1;
        end
        if (bs_fifo_pop)
            bs_rd_ptr <= bs_rd_ptr + 6'd1;
    end
end

wire signed [31:0] eff_bias_param  = use_bs_fifo ?
    {{16{burst_bias[15]}}, burst_bias} : p_bias_param;
wire        [31:0] eff_scale_param = use_bs_fifo ?
    {16'd0, burst_scale} : p_scale_param;
`else
wire signed [31:0] eff_bias_param  = p_bias_param;
wire        [31:0] eff_scale_param = p_scale_param;
`endif

`ifdef YOLO_IMODE_OCP

wire signed [31:0] head_bias_param = use_bs_fifo ? eff_bias_param : p_bias_param;
wire        [4:0]  head_scale_lsb  = use_bs_fifo ? burst_scale[4:0] : p_scale_param[4:0];
`else
wire signed [31:0] head_bias_param = p_bias_param;
wire        [4:0]  head_scale_lsb  = p_scale_param[4:0];
`endif

`ifdef YOLO_OC_PIPELINE

wire signed [31:0] route_bias_param = ocp_mode ? eff_bias_param : p_bias_param;
wire        [4:0]  route_scale_lsb  = ocp_mode ? burst_scale[4:0] : p_scale_param[4:0];
`else
wire signed [31:0] route_bias_param = p_bias_param;
wire        [4:0]  route_scale_lsb  = p_scale_param[4:0];
`endif

assign mac_done = o_vld;
assign max_01 = (ofm3 > ofm2) ? ofm3 : ofm2;
assign max_23 = (ofm1 > ofm0) ? ofm1 : ofm0;
assign max_all = (max_01 > max_23) ? max_01 : max_23;
assign route_shift = (p_route8_rescale && (route_scale_lsb != 5'd0)) ?
                     (route_scale_lsb - 5'd1) : route_scale_lsb;
assign head16_shift = (head_scale_lsb > HEAD16_FRAC_BITS) ?
                      (head_scale_lsb - HEAD16_FRAC_BITS) : 5'd0;
assign ofm_raw = p_route8_rescale ? {route0, route1, route2, route3} :
                                     {ofm0, ofm1, ofm2, ofm3};
assign ofm16 = {ofm16_0, ofm16_1, ofm16_2, ofm16_3};
assign ofm32 = {ofm32_0, ofm32_1, ofm32_2, ofm32_3};

function signed [31:0] signed_shift_trunc;
    input signed [31:0] value;
    input [4:0] shift;
    reg signed [31:0] abs_value;
    begin
        if (shift == 5'd0) begin
            signed_shift_trunc = value;
        end
        else if (value < 0) begin
            abs_value = -value;
            signed_shift_trunc = -(abs_value >>> shift);
        end
        else begin
            signed_shift_trunc = value >>> shift;
        end
    end
endfunction

function [15:0] clamp_s16;
    input signed [31:0] value;
    begin
        if (value > 32'sd32767) begin
            clamp_s16 = 16'h7fff;
        end
        else if (value < -32'sd32768) begin
            clamp_s16 = 16'h8000;
        end
        else begin
            clamp_s16 = value[15:0];
        end
    end
endfunction

always @(*) begin
    if (has_maxpool)
        ofm = {24'd0, max_all};
    else
        ofm = {ofm0, ofm1, ofm2, ofm3};
end

always @ (posedge clk or negedge rstn) begin
    if(rstn == 0) begin
    vaild   <= 0;
    o_relu0 <= 0;
    o_relu1 <= 0;
    o_relu2 <= 0;
    o_relu3 <= 0;
    o_head0 <= 0;
    o_head1 <= 0;
    o_head2 <= 0;
    o_head3 <= 0;
    o_head32_0 <= 0;
    o_head32_1 <= 0;
    o_head32_2 <= 0;
    o_head32_3 <= 0;
    o_route0 <= 0;
    o_route1 <= 0;
    o_route2 <= 0;
    o_route3 <= 0;
    p_scale_param <= 0;
    p_bias_param <= 0;
    p_linear_head <= 1'b0;
    p_route8_rescale <= 1'b0;
    ofm0 <= 0;
    ofm1 <= 0;
    ofm2 <= 0;
    ofm3 <= 0;
    ofm16_0 <= 0;
    ofm16_1 <= 0;
    ofm16_2 <= 0;
    ofm16_3 <= 0;
    ofm32_0 <= 0;
    ofm32_1 <= 0;
    ofm32_2 <= 0;
    ofm32_3 <= 0;
    route0 <= 0;
    route1 <= 0;
    route2 <= 0;
    route3 <= 0;
    out_vaild <= 0;
    end
    else begin
        if(i_start == 1) begin
            vaild   <= 0;
            out_vaild <= 0;
            p_scale_param <= scale_param;
            p_bias_param <= bias_param;
            p_linear_head <= linear_head;
            p_route8_rescale <= route8_rescale;
            ofm0 <= 0;
            ofm1 <= 0;
            ofm2 <= 0;
            ofm3 <= 0;
            ofm16_0 <= 0;
            ofm16_1 <= 0;
            ofm16_2 <= 0;
            ofm16_3 <= 0;
            o_head32_0 <= 0;
            o_head32_1 <= 0;
            o_head32_2 <= 0;
            o_head32_3 <= 0;
            ofm32_0 <= 0;
            ofm32_1 <= 0;
            ofm32_2 <= 0;
            ofm32_3 <= 0;
            route0 <= 0;
            route1 <= 0;
            route2 <= 0;
            route3 <= 0;
        end
        else begin
            vaild   <= 0;
            out_vaild <= 0;
            p_scale_param <= p_scale_param;
            p_bias_param <= p_bias_param;
            p_linear_head <= p_linear_head;
            p_route8_rescale <= p_route8_rescale;
        end
        if(o_vld == 1) begin
            vaild   <= 1;
            if(p_linear_head) begin
`ifdef YOLO_HEAD32_PARTITION_DDR
                o_relu0 <= 32'sd0;
                o_relu1 <= 32'sd0;
                o_relu2 <= 32'sd0;
                o_relu3 <= 32'sd0;
                o_head0 <= 32'sd0;
                o_head1 <= 32'sd0;
                o_head2 <= 32'sd0;
                o_head3 <= 32'sd0;
                o_head32_0 <= $signed(o_ofmRB + head_bias_param);
                o_head32_1 <= $signed(o_ofmLB + head_bias_param);
                o_head32_2 <= $signed(o_ofmRT + head_bias_param);
                o_head32_3 <= $signed(o_ofmLT + head_bias_param);
`else
                o_relu0 <= signed_shift_trunc($signed(o_ofmRB + head_bias_param), head_scale_lsb);
                o_relu1 <= signed_shift_trunc($signed(o_ofmLB + head_bias_param), head_scale_lsb);
                o_relu2 <= signed_shift_trunc($signed(o_ofmRT + head_bias_param), head_scale_lsb);
                o_relu3 <= signed_shift_trunc($signed(o_ofmLT + head_bias_param), head_scale_lsb);
                o_head0 <= signed_shift_trunc($signed(o_ofmRB + head_bias_param), head16_shift);
                o_head1 <= signed_shift_trunc($signed(o_ofmLB + head_bias_param), head16_shift);
                o_head2 <= signed_shift_trunc($signed(o_ofmRT + head_bias_param), head16_shift);
                o_head3 <= signed_shift_trunc($signed(o_ofmLT + head_bias_param), head16_shift);
                o_head32_0 <= $signed(o_ofmRB + head_bias_param);
                o_head32_1 <= $signed(o_ofmLB + head_bias_param);
                o_head32_2 <= $signed(o_ofmRT + head_bias_param);
                o_head32_3 <= $signed(o_ofmLT + head_bias_param);
`endif
            end
            else begin
                if((o_ofmRB+eff_bias_param) < 0) o_relu0 <= 0;
                else o_relu0 <= ((o_ofmRB+eff_bias_param) >> eff_scale_param);
                if((o_ofmLB+eff_bias_param) < 0) o_relu1 <= 0;
                else o_relu1 <= ((o_ofmLB+eff_bias_param) >> eff_scale_param);
                if((o_ofmRT+eff_bias_param) < 0) o_relu2 <= 0;
                else o_relu2 <= ((o_ofmRT+eff_bias_param) >> eff_scale_param);
                if((o_ofmLT + eff_bias_param) < 0) o_relu3 <= 0;
                else o_relu3 <= ((o_ofmLT + eff_bias_param) >> eff_scale_param);

                if((o_ofmRB+route_bias_param) < 0) o_route0 <= 0;
                else o_route0 <= ((o_ofmRB+route_bias_param) >> route_shift);
                if((o_ofmLB+route_bias_param) < 0) o_route1 <= 0;
                else o_route1 <= ((o_ofmLB+route_bias_param) >> route_shift);
                if((o_ofmRT+route_bias_param) < 0) o_route2 <= 0;
                else o_route2 <= ((o_ofmRT+route_bias_param) >> route_shift);
                if((o_ofmLT + route_bias_param) < 0) o_route3 <= 0;
                else o_route3 <= ((o_ofmLT + route_bias_param) >> route_shift);
            end
        end
`ifdef YOLO_L0_OC_BURST

        if(vaild == 1 && (oc_burst_mode || o_vld == 0)) begin
`else
        else if(vaild == 1) begin
`endif
            if(p_linear_head) begin
`ifdef YOLO_HEAD32_PARTITION_DDR
                ofm0 <= 8'd0;
                ofm1 <= 8'd0;
                ofm2 <= 8'd0;
                ofm3 <= 8'd0;
                ofm16_0 <= 16'd0;
                ofm16_1 <= 16'd0;
                ofm16_2 <= 16'd0;
                ofm16_3 <= 16'd0;
                ofm32_0 <= o_head32_0;
                ofm32_1 <= o_head32_1;
                ofm32_2 <= o_head32_2;
                ofm32_3 <= o_head32_3;
`else
                if(o_relu0 > 32'sd127) ofm0 <= 8'h7f;
                else if(o_relu0 < -32'sd128) ofm0 <= 8'h80;
                else ofm0 <= o_relu0[7:0];
                if(o_relu1 > 32'sd127) ofm1 <= 8'h7f;
                else if(o_relu1 < -32'sd128) ofm1 <= 8'h80;
                else ofm1 <= o_relu1[7:0];
                if(o_relu2 > 32'sd127) ofm2 <= 8'h7f;
                else if(o_relu2 < -32'sd128) ofm2 <= 8'h80;
                else ofm2 <= o_relu2[7:0];
                if(o_relu3 > 32'sd127) ofm3 <= 8'h7f;
                else if(o_relu3 < -32'sd128) ofm3 <= 8'h80;
                else ofm3 <= o_relu3[7:0];
                ofm16_0 <= clamp_s16(o_head0);
                ofm16_1 <= clamp_s16(o_head1);
                ofm16_2 <= clamp_s16(o_head2);
                ofm16_3 <= clamp_s16(o_head3);
                ofm32_0 <= o_head32_0;
                ofm32_1 <= o_head32_1;
                ofm32_2 <= o_head32_2;
                ofm32_3 <= o_head32_3;
`endif
            end
            else begin
                if(o_relu0[31: 8] == 0) ofm0 <= o_relu0[7 : 0];
                else ofm0 <= 255;
                if(o_relu1[31: 8] == 0) ofm1 <= o_relu1[7 : 0];
                else ofm1 <= 255;
                if(o_relu2[31: 8] == 0) ofm2 <= o_relu2[7 : 0];
                else ofm2 <= 255;
                if(o_relu3[31: 8] == 0) ofm3 <= o_relu3[7 : 0];
                else ofm3 <= 255;

                if(o_route0[31: 8] == 0) route0 <= o_route0[7 : 0];
                else route0 <= 255;
                if(o_route1[31: 8] == 0) route1 <= o_route1[7 : 0];
                else route1 <= 255;
                if(o_route2[31: 8] == 0) route2 <= o_route2[7 : 0];
                else route2 <= 255;
                if(o_route3[31: 8] == 0) route3 <= o_route3[7 : 0];
                else route3 <= 255;
                ofm16_0 <= 16'd0;
                ofm16_1 <= 16'd0;
                ofm16_2 <= 16'd0;
                ofm16_3 <= 16'd0;
                ofm32_0 <= 32'd0;
                ofm32_1 <= 32'd0;
                ofm32_2 <= 32'd0;
                ofm32_3 <= 32'd0;
            end
        out_vaild <= 1;
        end
    end
end

mac_kernel mac_kern1(
    .clk(clk),
    .rstn(rstn),
    .i_start(i_start),
    .i_mode(i_mode),
    .i_vld(i_vld),
`ifdef YOLO_OC_PIPELINE
    .i_last(i_last),
`endif
    .i_len(i_len),
    .i_wgt(i_wgt),
    .i_ifm(i_ifm),
    .o_vld(o_vld),
    .vld(vld_o),
    .psum_00(o_ofmRB),
    .psum_01(o_ofmLB),
    .psum_10(o_ofmRT),
    .psum_11(o_ofmLT)
);

endmodule
