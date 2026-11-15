`timescale 1ns / 1ps
`include "yolo_build_config_h.v"

module mac_kernel(
    input clk,rstn,i_start,i_mode,i_vld,
`ifdef YOLO_OC_PIPELINE
    input i_last,
`endif
    input [9:0] i_len,
    input signed [36*8-1:0] i_wgt,
    input [64*8-1:0] i_ifm,

    output vld,
    output reg o_vld,
    output reg signed [31:0] psum_00,psum_01,psum_10,psum_11
    );

wire [36*8-1 :0] wgt;
wire signed [21: 0] p_ofm0,p_ofm1,p_ofm2,p_ofm3;
reg [9:0] len;
reg [3:0] mode_param;
reg [36*8-1: 0] i_ifm_00,i_ifm_01,i_ifm_10,i_ifm_11;

reg [2:0] state,n_state;

integer idx,i,j,k;
integer b00, b01, b10, b11;

parameter IDLE = 0,
          OP   = 1,
          DONE  = 2;

`ifdef YOLO_L0_OC_BURST

wire single_beat = (i_mode == 1'b0) && ((i_len >> 2) == 10'd1);
reg  burst_vld_d;
always @(posedge clk or negedge rstn) begin
    if (!rstn)
        burst_vld_d <= 1'b0;
    else
        burst_vld_d <= single_beat && vld;
end
`endif

`ifdef YOLO_OC_PIPELINE

`ifdef YOLO_IMODE_OCP

wire ocp_mode = ((i_mode == 1'b0) && ((i_len >> 2) >= 10'd2)) ||
                ((i_mode == 1'b1) && ((i_len >> 4) >= 10'd2));
`else
wire ocp_mode = (i_mode == 1'b0) && ((i_len >> 2) >= 10'd2);
`endif
reg [8:0] ocp_last_pipe;
reg       ocp_vld_d;
reg signed [31:0] ocp_acc_00, ocp_acc_01, ocp_acc_10, ocp_acc_11;
wire ocp_last_at_acc = ocp_last_pipe[8];
always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        ocp_last_pipe <= 9'd0;
        ocp_vld_d     <= 1'b0;
    end
    else begin
        ocp_last_pipe <= {ocp_last_pipe[7:0], ocp_mode && i_vld && i_last};
        ocp_vld_d     <= ocp_mode && vld && ocp_last_at_acc;
    end
end
`endif

 always @ (posedge clk or negedge rstn) begin
    if(rstn == 0)begin
        state <= IDLE;
        psum_00<=0;
        psum_01<=0;
        psum_10<=0;
        psum_11<=0;
        len <= 0;
`ifdef YOLO_OC_PIPELINE
        ocp_acc_00 <= 32'sd0;
        ocp_acc_01 <= 32'sd0;
        ocp_acc_10 <= 32'sd0;
        ocp_acc_11 <= 32'sd0;
`endif
        end
    else begin
        state <= n_state;
`ifdef YOLO_OC_PIPELINE

        if (ocp_mode) begin
            if (vld == 1) begin
                if (ocp_last_at_acc) begin
                    psum_00 <= $signed(ocp_acc_00) + $signed(p_ofm0);
                    psum_01 <= $signed(ocp_acc_01) + $signed(p_ofm1);
                    psum_10 <= $signed(ocp_acc_10) + $signed(p_ofm2);
                    psum_11 <= $signed(ocp_acc_11) + $signed(p_ofm3);
                    ocp_acc_00 <= 32'sd0;
                    ocp_acc_01 <= 32'sd0;
                    ocp_acc_10 <= 32'sd0;
                    ocp_acc_11 <= 32'sd0;
                end
                else begin
                    ocp_acc_00 <= $signed(ocp_acc_00) + $signed(p_ofm0);
                    ocp_acc_01 <= $signed(ocp_acc_01) + $signed(p_ofm1);
                    ocp_acc_10 <= $signed(ocp_acc_10) + $signed(p_ofm2);
                    ocp_acc_11 <= $signed(ocp_acc_11) + $signed(p_ofm3);
                end
            end
        end
        else
`endif
`ifdef YOLO_L0_OC_BURST
        if(single_beat) begin
            if(vld == 1) begin
                psum_00 <= p_ofm0;
                psum_01 <= p_ofm1;
                psum_10 <= p_ofm2;
                psum_11 <= p_ofm3;
            end
        end
        else
`endif
        if(vld == 0 && state == OP) begin
        psum_00<= psum_00;
        psum_01<= psum_01;
        psum_10<= psum_10;
        psum_11<= psum_11;
        len <= len;
        end
        else if(vld == 1 && state == OP) begin
        psum_00<=$signed(psum_00)+$signed(p_ofm0);
        psum_01<=$signed(psum_01)+$signed(p_ofm1);
        psum_10<=$signed(psum_10)+$signed(p_ofm2);
        psum_11<=$signed(psum_11)+$signed(p_ofm3);
        len <= len +1;
        end
        else if(i_start == 1 && (state == IDLE || state == DONE)) begin
        psum_00 <= 0;
        psum_01 <= 0;
        psum_10 <= 0;
        psum_11 <= 0;
        len <= 0;
        end
        end
 end

 always @ (*) begin
`ifdef YOLO_OC_PIPELINE

  if (ocp_mode)
      n_state = IDLE;
  else
`endif
  case (state)
   IDLE : if(i_start == 0) n_state = IDLE;
          else n_state =OP;
   OP   : if( (vld==1) && (len == ((i_len >> mode_param))-1)) n_state = DONE;
          else n_state = OP;
   DONE : if(i_start == 0) n_state = IDLE ;
          else n_state = OP ;
   default : n_state = IDLE;
  endcase
  end

 always @ (*) begin
  o_vld = 0;
`ifdef YOLO_L0_OC_BURST
  if (single_beat)
      o_vld = burst_vld_d;
  else
`endif
`ifdef YOLO_OC_PIPELINE
  if (ocp_mode)
      o_vld = ocp_vld_d;
  else
`endif
  case (state)
   IDLE :begin
        o_vld = 0 ;
        end
   OP   : o_vld = 0;
   DONE :o_vld = 1;
   default : o_vld = 0;
  endcase
 end

always@(*) begin
i_ifm_00 = 0; i_ifm_01 = 0; i_ifm_10 = 0; i_ifm_11 = 0;
idx = 0;
mode_param = 2;
    if(i_mode == 0) begin
    mode_param = 2;

    for (i=0; i<3; i=i+1) begin
        for (j=0; j<3; j=j+1) begin
            for (k=0; k<4; k=k+1) begin

                b00 = (j   < 2) ? (256 + (i*2 + j    )*32)       : ((i*2 + (j-2))*32);
                b01 = (j+1 < 2) ? (256 + (i*2 + (j+1))*32)       : ((i*2 + (j-1))*32);
                b10 = (j   < 2) ? (256 + ((i+1)*2 + j    )*32)   : (((i+1)*2 + (j-2))*32);
                b11 = (j+1 < 2) ? (256 + ((i+1)*2 + (j+1))*32)   : (((i+1)*2 + (j-1))*32);

                idx = k*9 + i*3 + j;

                i_ifm_00[idx*8 +: 8] = i_ifm[b00 + k*8 +: 8];
                i_ifm_01[idx*8 +: 8] = i_ifm[b01 + k*8 +: 8];
                i_ifm_10[idx*8 +: 8] = i_ifm[b10 + k*8 +: 8];
                i_ifm_11[idx*8 +: 8] = i_ifm[b11 + k*8 +: 8];
            end
        end
    end
end
    else begin
    mode_param = 4;
        for (k=0; k<16; k=k+1) begin
            i_ifm_00[k*8 +: 8] = i_ifm[((0)*16 + k)*8 +: 8];
            i_ifm_01[k*8 +: 8] = i_ifm[((1)*16 + k)*8 +: 8];
            i_ifm_10[k*8 +: 8] = i_ifm[((1*2)*16 + k)*8 +: 8];
            i_ifm_11[k*8 +: 8] = i_ifm[((1*2 + 1)*16 + k)*8 +: 8];
        end
    end
 end

 mac_stack mac_stack1(.clk(clk),.rstn(rstn),.vld_i(i_vld),.wgt(i_wgt),.ifm_00(i_ifm_00),.ifm_01(i_ifm_01),.ifm_10(i_ifm_10),.ifm_11(i_ifm_11),
 .acc_00(p_ofm0),.acc_01(p_ofm1),.acc_10(p_ofm2),.acc_11(p_ofm3),.vld_o(vld));

endmodule
