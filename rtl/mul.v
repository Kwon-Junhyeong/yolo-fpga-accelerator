`timescale 1ns / 1ps
module mul(
    input clk,
    input signed [7:0] w,
    input [7:0] x0,
    input [7:0] x1,
    output signed [15:0] y0,
    output signed [15:0] y1
);

`ifdef SYNTHESIS
`define MUL_LOCAL_USE_DSP_PACKED
`endif
`ifdef USE_DSP_PACKED
`define MUL_LOCAL_USE_DSP_PACKED
`endif

`ifdef MUL_LOCAL_USE_DSP_PACKED
    wire        s;
    wire [8:0] w_abs;
    wire [24:0] dsp_A;
    wire [17:0] dsp_B;
    wire [42:0] dsp_product;
    wire [15:0] y0_raw;
    wire [15:0] y1_raw;
    reg         s_r;
    reg [24:0]  dsp_A_r;
    reg [17:0]  dsp_B_r;

    (* use_dsp = "yes" *) reg [47:0] dsp_P0;
    (* shreg_extract = "no" *) reg [47:0] dsp_P1;
    (* shreg_extract = "no" *) reg [47:0] dsp_P2;
    (* shreg_extract = "no" *) reg [47:0] dsp_P3;
    (* shreg_extract = "no" *) reg [3:0] sign_d;

    assign s     = w[7];
    assign w_abs = s ? ({1'b0, ~w} + 9'd1) : {1'b0, w};
    assign dsp_A = {x1, 9'b0, x0};
    assign dsp_B = {9'b0, w_abs};
    assign dsp_product = dsp_A_r * dsp_B_r;

    always @(posedge clk) begin
        s_r <= s;
        dsp_A_r <= dsp_A;
        dsp_B_r <= dsp_B;

        dsp_P0 <= {5'b0, dsp_product};
        dsp_P1 <= dsp_P0;
        dsp_P2 <= dsp_P1;
        dsp_P3 <= dsp_P2;

        sign_d[0] <= s_r;
        sign_d[1] <= sign_d[0];
        sign_d[2] <= sign_d[1];
        sign_d[3] <= sign_d[2];
    end

    assign y0_raw = dsp_P3[15:0];
    assign y1_raw = dsp_P3[32:17];
    assign y0 = sign_d[3] ? (~y0_raw + 16'd1) : y0_raw;
    assign y1 = sign_d[3] ? (~y1_raw + 16'd1) : y1_raw;
`else
    reg signed [7:0] w_r;
    reg [7:0] x0_r;
    reg [7:0] x1_r;
    reg [15:0] dsp_P0[0:3];
    reg [15:0] dsp_P1[0:3];

    always @(posedge clk) begin
        w_r <= w;
        x0_r <= x0;
        x1_r <= x1;

        dsp_P0[0] <= $signed(w_r) * $signed({1'b0, x0_r});
        dsp_P1[0] <= $signed(w_r) * $signed({1'b0, x1_r});

        dsp_P0[1] <= dsp_P0[0];
        dsp_P1[1] <= dsp_P1[0];

        dsp_P0[2] <= dsp_P0[1];
        dsp_P1[2] <= dsp_P1[1];

        dsp_P0[3] <= dsp_P0[2];
        dsp_P1[3] <= dsp_P1[2];

    end

    assign y0 = dsp_P0[3];
    assign y1 = dsp_P1[3];
`endif

`ifdef MUL_LOCAL_USE_DSP_PACKED
`undef MUL_LOCAL_USE_DSP_PACKED
`endif
endmodule
