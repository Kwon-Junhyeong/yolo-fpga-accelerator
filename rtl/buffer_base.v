`timescale 1ns / 1ps
`include "yolo_build_config_h.v"

module buffer_base(

    input clk,rstn,
    input layer_start,
    input [31 :0] i_ofm,
    input [31 :0] i_ofm_raw,
    input [63 :0] i_ofm16,
    input [127:0] i_ofm32,
    input [31:0] read_data,
    input read_data_vld,
    input read_done,
    input weight_load_start,
    input out_vaild,
    input tile_req_valid,
    input tile_fire,
    input [9:0] ch_len,
    input [15:0] read_data_cnt,
    input [8:0] o_row,o_col,
    input [4:0] layer_id,
    input i_mode,
    input load_mode,
    input has_maxpool,
    input mac_done,
    input [7:0] fill_ch_max,
    input [7:0] fill_col_max,
    input [12-1 :0] q_width,ofm_width,
    input [12-1 :0] q_height,ofm_height,
    input [11:0] bsc_addra,
    input compute_begin,
    input all_oc_done,
    input [9:0] out_ch_done,
    input [9:0] active_oc_end_run,
    input need_dram_ifm,
    input need_dram_wt,
    output ifm_rd_stall,

    input        store_mode,
    input        indata_req_wr,
`ifdef YOLO_STORE_OVERLAP
    input        dma_start_wr,
    input [31:0] dma_num_wr,
    output       store_indata_vld,
    input        store_indata_ack,
`endif

    input [9:0] ofm_ch_idx,
    output [31:0] write_data,
    input  pool11_run,
    output reg pool11_done,
    output       write_data_vld,
    output reg fill_done_latch,

    output L1_vaild,
    output signed [15:0] bias_param,
    output [15:0] scale_param,
    output reg tile_req_ready,
    output [287:0] i_weight,
    output pe_i_start,
`ifdef YOLO_OC_PIPELINE
    output issue_beat_last,
`endif
    output reg [511:0] total_read_data

    );

parameter IDLE        = 0,
          OP          = 1,
          N_TILE      = 2,
          N_XY        = 3,

          ROW0 =0,
          ROW1 =1,
          ROW2 =2,
          ROW3 =3;

localparam P_IDLE = 3'd0;
localparam P_R0   = 3'd1;
localparam P_R1   = 3'd2;
localparam P_R2   = 3'd3;
localparam P_R3   = 3'd4;
localparam P_R4   = 3'd5;
localparam P_WR   = 3'd6;

wire [7:0] ch_cnt;
reg [2:0] state,n_state;

reg [9:0] WET_addr;
wire [8:0] L2_L1_addr;

wire       we_g1;

wire [255:0] g0_Lrdata,g0_Rrdata, g1_Lrdata, g1_Rrdata;

reg ping_pong_sel;
reg read_ping_pong_sel;
reg read_ctrl_pending;
reg [8:0] read_abs_row_base_pending;
reg read_ping_pong_sel_pending;
reg [8:0] compute_read_abs_row_base;
reg compute_ping_pong_sel;
reg compute_read_page_valid;
reg first_fill;

wire       we_g0;

reg [15:0] bank_wea,bank_web;

wire [255:0] pe_Lrdata_masked, pe_Rrdata_masked;
reg [3:0] out_ch_shift;

wire [31 : 0] row_tile;

reg fill_active;
wire row_tile_vld;
reg fill_done;
reg [8:0] req_addr;
wire req_last;

wire swap_trigger;

reg [8:0] pe_last_row;
wire pe_done;

reg [2:0] ch_shift;

wire [3:0] T_row_group = (o_row + 2) >> 2;
wire [3:0] B_row_group = o_row >> 2;
wire swap_row = (o_row >> 1) & 1;

reg [3:0] fill_row_group;
reg [3:0] max_row_groups;

reg [3:0] rg_shift;

wire [8:0] pe_base_L,pe_base_R;
wire req_valid;

wire wet_wr_vld;
reg [9:0] layer_wet_base;
wire [31:0] bsc_douta;
wire [287:0] i_weight_raw;
reg  [287:0] i_weight_hold;
wire [9:0] wet_stride_words;
wire [9:0] wet_oc_base_next;
reg  [9:0] wet_oc_base;

reg [15:0] store_addr;
`ifdef YOLO_STORE_OVERLAP
reg        head_buf_sel;
`endif
wire [31:0] l2_rdata_a;

wire        l2_ena;
wire [3:0]  l2_wea;
wire [15:0] l2_addra;
wire [31:0] l2_dina;
wire ofm_write_mode;
wire [7:0] ofm_byte;
wire [15:0] ofm_halfword;
wire [31:0] ofm_word32;
wire [31:0] ofm_head16_dina;
reg [1:0] ofm_wr_cnt;
wire [15:0] ofm_wr_addr;
reg [3:0] ofm_wea;
reg [3:0] ofm_wea_hold;
reg [31:0] ofm_hold;
reg [63:0] ofm16_hold;
reg [127:0] ofm32_hold;
reg        wr_busy;
reg        maxpool_wr_pending;
reg [7:0]  maxpool_byte_hold;
reg [3:0]  maxpool_wea_hold;
reg [15:0] maxpool_addr_hold;
reg [8:0] ofm_row_hold, ofm_col_hold;
reg [15:0] ofm_ch_group_base_hold;
reg [15:0] ofm_l2_output_base_hold;
reg [31:0] ofm_pending_hold;
reg [63:0] ofm16_pending_hold;
reg [127:0] ofm32_pending_hold;
reg [3:0]  ofm_pending_wea;
reg [15:0] ofm_pending_ch_group_base;
reg [15:0] ofm_pending_l2_output_base;
reg [15:0] ofm_pending_wr_base;
reg [15:0] ofm_pending_wr_col_step;
reg [15:0] ofm_pending_wr_row_step;
reg        ofm_pending_padded_head;
reg [3:0]  ofm_pending_width_shift;
reg [3:0]  ofm_pending_out_ch_shift;
reg [15:0] ofm_pending_out_ch_groups;
reg        ofm_pending_valid;
wire [3:0] ofm_wea_live;
wire       ofm_write_busy;
reg [15:0] ofm_pixel_cnt;
wire [15:0] ofm_ch_group_base;
wire [15:0] ofm_ch_group_base_wr;
reg [31:0] route8_hold;
reg        route8_wr_busy;
(* max_fanout = 64 *) reg route8_l2_busy;
reg [1:0]  route8_wr_cnt;
reg [8:0]  route8_row_hold;
reg [8:0]  route8_col_hold;
reg [15:0] route8_ch_group_hold;
reg [3:0]  route8_wea_hold;
wire       route8_capture;
wire [31:0] route8_dina;
wire [7:0]  route8_byte;
wire [8:0]  route8_wr_row;
wire [8:0]  route8_wr_col;
wire [8:0]  route8_wr_pix;
wire [13:0] route8_wr_addr;
wire [15:0] route8_l2_addr;
wire [15:0] ofm_row_offset;
wire [15:0] tile_base;
wire [15:0] out_size_nopool;
wire new_out_ch;
reg    [9:0]  prev_ofm_ch_idx;
wire   [15:0] out_size;
wire [15:0] l2_store_offset;
wire [9:0]  wet_addr_to_gbuff;
wire [11:0] bsc_addr_to_gbuff;

wire last_ch;
wire mid_ch_done;
wire last_ch_done;

wire feed_active;

reg  [7:0] ch_cnt_r;
reg  [7:0] feed_cnt;
reg pe_done_latch;
reg first_bank_ready;
wire [9:0] local_ofm_ch_idx;

reg  [3:0] fill_rg;
wire [3:0] fill_rg_d0;
reg  [3:0] fill_rg_d1;
reg  [3:0] fill_rg_d2;

reg [8:0]  fill_col;
reg [7:0]  fill_ch;
reg [1:0]  fill_row;

wire [8:0] fill_col_d0;
wire [7:0] fill_ch_d0;
wire [1:0] fill_row_d0;
wire       fill_zero_row_d0;
wire       row_tile_vld_d0;
reg  [8:0] fill_col_d1;
reg  [7:0] fill_ch_d1;
reg  [1:0] fill_row_d1;
reg        fill_zero_row_d1;
reg        row_tile_vld_d1;
reg  [8:0] fill_col_d2;
reg  [7:0] fill_ch_d2;
reg  [1:0] fill_row_d2;
reg        fill_zero_row_d2;
reg        row_tile_vld_d2;

reg [8:0]  fill_abs_row_base;

wire [15:0] L2_addrb;
wire [15:0] L2_addrb_calc;
reg  [15:0] L2_addrb_r;
reg  [15:0] fill_l2_addr_d1;
reg  [15:0] fill_l2_addr_d2;
wire        fill_last;

wire       issue_fire;
wire       l20_read_tile_ready;
wire       read_ctrl_freeze;
reg        issue_fire_d;
reg [7:0]  issue_ch_d;
reg [9:0] issue_wet_addr_d;
reg last_consume_seen;
wire [9:0] mac_iter_max;
`ifdef YOLO_L0_OC_BURST

wire       oc_burst_layer;
reg  [9:0] issue_oc_cnt;
wire [9:0] issue_oc_max;
`ifdef YOLO_OC_PIPELINE

wire       ocp_layer;
wire       ocp_issue_last;
reg  [9:0] ocp_wet_base;
`ifdef YOLO_IMODE_OCP

wire       imode_ocp_layer;
wire       imode_ocp_issue_last;
reg  [9:0] imode_bsc_oc_d;
`endif
`endif
`endif
wire [7:0] l1_read_ch;
wire       conv1x1_phase_last;
reg [1:0]  conv1x1_phase;
reg [1:0]  conv1x1_phase_d;
reg        conv1x1_valid;
reg [127:0] conv1x1_tl;
reg [127:0] conv1x1_tr;
reg [127:0] conv1x1_bl;
reg [127:0] conv1x1_br;
wire [4:0] fill_local_slot;
wire signed [10:0] fill_abs_row_s;
wire fill_zero_row;
wire fill_row_advance;
wire [1:0] fill_row_next;
wire [3:0] fill_rg_next;
wire [8:0] fill_abs_row_base_swap;
wire signed [10:0] fill_abs_row_first_s;
wire signed [10:0] fill_abs_row_swap_s;
wire signed [10:0] fill_abs_row_next_s;
reg [8:0] read_abs_row_base;
wire [31:0] row_tile_in;

wire [255:0] readL, readR;
wire [31:0] rd_bank [0:15];
wire ifm_load_vld;

reg  [8:0] pe_addr_b [0:15];
reg        bank_valid [0:15];

reg  [31:0] lane_word [0:15];

wire [15:0] ofm_wr_row_nopool;
wire [15:0] ofm_wr_col_nopool;
wire [15:0] ofm_pixel_idx_nopool;
wire [3:0]  ofm_width_shift;
wire [3:0]  q_width_shift;
wire [15:0] ofm_out_ch_groups;
wire [15:0] ofm_tile_pixel_base_calc;
wire [15:0] ofm_wr_base_calc;
wire [15:0] ofm_wr_col_step_calc;
wire [15:0] ofm_wr_row_step_calc;
wire [15:0] ofm_tile_pixel_base_live;
wire [15:0] ofm_wr_base_live;
wire [15:0] ofm_wr_col_step_live;
wire [15:0] ofm_wr_row_step_live;
wire [15:0] ofm_wr_addr_seq;
reg         ofm_addr_ready;
reg [15:0] ofm_wr_base_hold;
reg [15:0] ofm_wr_col_step_hold;
reg [15:0] ofm_wr_row_step_hold;
reg [15:0] ofm_l2_output_base_q;
reg [15:0] l2_input_base_q;
reg        padded_head_layer_q;
reg        l1rd_l20_q;
reg        fill_zero_row_q;
reg [15:0] l2_fill_row_base_q;
reg [15:0] l20_up_row_base_q;
reg [15:0] l20_route8_row_base_q;
reg [3:0]  ofm_width_shift_q;
reg [3:0]  out_ch_shift_q;
reg [3:0]  l1rd_q_width_shift_q;
reg [11:0] l1rd_q_width_q;
reg [11:0] l1rd_q_height_q;
reg [9:0]  l1rd_ch_len_q;
reg [3:0]  l1rd_ch_shift_q;
reg [3:0]  l1rd_rg_shift_q;
reg [3:0]  l1rd_max_row_groups_q;
reg [8:0]  l1rd_q_width_m1_q;
reg [8:0]  l1rd_q_width_m2_q;
reg [7:0]  fill_ch_max_q;
reg [7:0]  fill_ch_max_m1_q;
reg [3:0]  l1rd_max_row_groups_m1_q;
reg [8:0]  l1rd_row_span_minus2_q;
reg [8:0]  l1rd_pe_last_delta_q;
reg        route8_layer_q;
reg [16:0] ifm_row_words_q;
reg        padded_head_layer_hold;
reg [3:0]  ofm_width_shift_hold;
reg [3:0]  ofm_out_ch_shift_hold;
reg [15:0] ofm_out_ch_groups_hold;
reg [2:0]  pool_state;
reg [2:0]  pool_y;
reg [2:0]  pool_x;
reg [6:0]  pool_g;

reg [31:0] pool_d0;
reg [31:0] pool_d1;
reg [31:0] pool_d2;
reg [31:0] pool_d3;
reg [31:0] pool_max_word;

wire       pool11_active;
wire       pool11_wr;
wire       partition_start;
reg        partition_start_r;

wire [2:0] pool_xp1;
wire [2:0] pool_yp1;

wire [5:0] pool_pix0;
wire [5:0] pool_pix1;
wire [5:0] pool_pix2;
wire [5:0] pool_pix3;

wire [15:0] pool_addr0;
wire [15:0] pool_addr1;
wire [15:0] pool_addr2;
wire [15:0] pool_addr3;
wire [15:0] pool_l2_addr;
wire [15:0] pool_l2_phys_addr;
wire [31:0] pool_l2_dina;
wire [15:0] l2_input_base;
wire [15:0] l2_output_base;
wire [15:0] l2_pool_read_base;
wire [15:0] l2_pool_write_base;
wire [15:0] l2_store_addr;
wire [15:0] l2_ofm_wr_addr;
wire [15:0] l2_fill_col_offset;
wire [15:0] l20_up_col_offset;
wire [15:0] l20_route8_col_offset;
wire [15:0] l20_fill_ch_offset;
wire [15:0] l1_col_ch_offset;
wire [15:0] l1_rg_offset;
wire [15:0] L2_L1_addr_calc;
wire        padded_head_layer;
wire        head32_layer_q;
wire        head32_layer_hold;
wire [15:0] head32_partition_ch_live;
wire [15:0] head32_pixel_offset_live;
wire [15:0] head32_pixel_offset_calc;
wire        padded_head_last_valid_ch;
wire [31:0] ofm_l2_dina;

localparam [15:0] L2_REGION_A_BASE = 16'h0000;
localparam [15:0] L2_REGION_ROUTE12_BASE = 16'h2000;
localparam [15:0] L2_REGION_ROUTE8_BASE = 16'h4000;
localparam [15:0] L2_REGION_B_BASE = 16'h8000;

function [3:0] width_to_shift;
    input [11:0] width;
    begin
        case (width)
            12'd8:   width_to_shift = 4'd3;
            12'd16:  width_to_shift = 4'd4;
            12'd32:  width_to_shift = 4'd5;
            12'd64:  width_to_shift = 4'd6;
            12'd128: width_to_shift = 4'd7;
            12'd256: width_to_shift = 4'd8;
            default: width_to_shift = 4'd0;
        endcase
    end
endfunction

function signed [10:0] calc_fill_abs_row;
    input [8:0] row_base;
    input [3:0] row_group;
    input [1:0] row_in_group;
    reg [4:0] local_slot;
    begin
        local_slot = ({1'b0, row_group} << 2) + {3'd0, row_in_group};
        calc_fill_abs_row = $signed({1'b0, row_base}) +
                            $signed({6'd0, local_slot}) -
                            11'sd1;
    end
endfunction

function [15:0] normal_l2_row_base;
    input [15:0] input_base;
    input signed [10:0] abs_row;
    input [3:0] width_shift;
    input [3:0] ch_group_shift;
    begin
        normal_l2_row_base = input_base +
                             (({7'd0, abs_row[8:0]} << width_shift) << ch_group_shift);
    end
endfunction

function [15:0] l20_up_l2_row_base;
    input signed [10:0] abs_row;
    begin
        l20_up_l2_row_base = L2_REGION_B_BASE + ({8'd0, abs_row[8:1]} << 8);
    end
endfunction

function [15:0] l20_route8_l2_row_base;
    input signed [10:0] abs_row;
    begin
        l20_route8_l2_row_base = L2_REGION_ROUTE8_BASE + ({7'd0, abs_row[8:0]} << 10);
    end
endfunction

assign pool11_active = (pool_state != P_IDLE);
assign pool11_wr     = (pool_state == P_WR);
assign partition_start = compute_begin;

always @(posedge clk or negedge rstn) begin
    if (!rstn)
        partition_start_r <= 1'b0;
    else
        partition_start_r <= partition_start;
end

`ifdef YOLO_REFILL_SKIP

wire refill_single_page = ({3'd0, l1rd_row_span_minus2_q} > l1rd_q_height_q);
wire refill_skip_pass   = refill_single_page && (out_ch_done != 10'd0);
wire fill_restart_r     = partition_start_r && !refill_skip_pass;
`endif

assign pool_xp1 = (pool_x == 3'd7) ? pool_x : (pool_x + 3'd1);
assign pool_yp1 = (pool_y == 3'd7) ? pool_y : (pool_y + 3'd1);

assign pool_pix0 = {pool_y,   3'b000} + pool_x;
assign pool_pix1 = {pool_y,   3'b000} + pool_xp1;
assign pool_pix2 = {pool_yp1, 3'b000} + pool_x;
assign pool_pix3 = {pool_yp1, 3'b000} + pool_xp1;

assign pool_addr0 = ({10'd0, pool_pix0} << 7) | {9'd0, pool_g};
assign pool_addr1 = ({10'd0, pool_pix1} << 7) | {9'd0, pool_g};
assign pool_addr2 = ({10'd0, pool_pix2} << 7) | {9'd0, pool_g};
assign pool_addr3 = ({10'd0, pool_pix3} << 7) | {9'd0, pool_g};

assign pool_l2_addr =
    (pool_state == P_R1) ? pool_addr1 :
    (pool_state == P_R2) ? pool_addr2 :
    (pool_state == P_R3) ? pool_addr3 :
                           pool_addr0;

assign l2_input_base =
    ((layer_id == 5'd8) || (layer_id == 5'd14)) ? L2_REGION_B_BASE :
    ((layer_id == 5'd13) || (layer_id == 5'd17)) ? L2_REGION_ROUTE12_BASE :
                         L2_REGION_A_BASE;

`ifdef YOLO_STORE_OVERLAP

wire [15:0] head_stage_toggle_off =
    (head_buf_sel && (layer_id == 5'd14)) ? 16'h0800 :
    (head_buf_sel && (layer_id == 5'd20)) ? 16'h2000 :
                                            16'h0000;
assign l2_output_base =
    (((layer_id == 5'd6) || (layer_id == 5'd10)) ? L2_REGION_B_BASE :
    (layer_id == 5'd12) ? L2_REGION_ROUTE12_BASE :
    ((layer_id == 5'd13) || (layer_id == 5'd17)) ? L2_REGION_B_BASE :
    (layer_id == 5'd20) ? (L2_REGION_B_BASE + 16'h0800) :
                                                   L2_REGION_A_BASE)
    + head_stage_toggle_off;
`else
assign l2_output_base =
    ((layer_id == 5'd6) || (layer_id == 5'd10)) ? L2_REGION_B_BASE :
    (layer_id == 5'd12) ? L2_REGION_ROUTE12_BASE :
    ((layer_id == 5'd13) || (layer_id == 5'd17)) ? L2_REGION_B_BASE :
    (layer_id == 5'd20) ? (L2_REGION_B_BASE + 16'h0800) :
                                                   L2_REGION_A_BASE;
`endif

assign l2_pool_read_base  = L2_REGION_B_BASE;
assign l2_pool_write_base = L2_REGION_A_BASE;
assign pool_l2_phys_addr  = pool11_wr ? (l2_pool_write_base + pool_addr0)
                                      : (l2_pool_read_base  + pool_l2_addr);

always @(posedge clk) begin
    if (!rstn) begin
        ofm_l2_output_base_q <= 16'd0;
        l2_input_base_q      <= 16'd0;
        padded_head_layer_q  <= 1'b0;
        l1rd_l20_q           <= 1'b0;
        ofm_width_shift_q    <= 4'd0;
        out_ch_shift_q       <= 4'd0;
        l1rd_q_width_shift_q <= 4'd0;
        l1rd_q_width_q       <= 12'd0;
        l1rd_q_height_q      <= 12'd0;
        l1rd_ch_len_q        <= 10'd0;
        l1rd_ch_shift_q      <= 4'd0;
        l1rd_rg_shift_q      <= 4'd0;
        l1rd_max_row_groups_q <= 4'd0;
        l1rd_q_width_m1_q    <= 9'd0;
        l1rd_q_width_m2_q    <= 9'd0;
        fill_ch_max_q        <= 8'd0;
        fill_ch_max_m1_q     <= 8'd0;
        l1rd_max_row_groups_m1_q <= 4'd0;
        l1rd_row_span_minus2_q <= 9'd0;
        l1rd_pe_last_delta_q <= 9'd0;
        route8_layer_q       <= 1'b0;
        ifm_row_words_q      <= 17'd0;
    end
    else begin
        ofm_l2_output_base_q <= l2_output_base;
        l2_input_base_q      <= l2_input_base;
        padded_head_layer_q  <= padded_head_layer;
        l1rd_l20_q           <= (layer_id == 5'd20);
        ofm_width_shift_q    <= ofm_width_shift;
        out_ch_shift_q       <= out_ch_shift;
        l1rd_q_width_shift_q <= q_width_shift;
        l1rd_q_width_q       <= q_width;
        l1rd_q_height_q      <= q_height;
        l1rd_ch_len_q        <= ch_len;
        l1rd_ch_shift_q      <= ch_shift;
        l1rd_rg_shift_q      <= rg_shift;
        l1rd_max_row_groups_q <= max_row_groups;
        l1rd_q_width_m1_q    <= q_width[8:0] - 9'd1;
        l1rd_q_width_m2_q    <= q_width[8:0] - 9'd2;
        fill_ch_max_q        <= fill_ch_max;
        fill_ch_max_m1_q     <= fill_ch_max - 8'd1;
        l1rd_max_row_groups_m1_q <= max_row_groups - 4'd1;
        l1rd_row_span_minus2_q <= ({5'd0, max_row_groups} << 2) - 9'd2;
        l1rd_pe_last_delta_q <= ({5'd0, max_row_groups} << 2) - 9'd4;
        route8_layer_q       <= (layer_id == 5'd8);
        ifm_row_words_q      <= {5'd0, q_width} << ch_shift;
    end
end

integer bi, ry, cx, idx;
integer patch_r0, patch_c0;
integer top_slot_mod, left_col_mod;
integer row_off, col_off;
integer abs_r_b, abs_c_b;
integer local_slot_b, row_grp_b;
integer abs_r, abs_c, local_slot_p;
integer bank_sel;
reg [8:0] read_stage_row_q;
reg [8:0] read_stage_col_q;
reg [8:0] read_stage_abs_row_base_q;

function [1:0] bank_rslot_mod;
    input integer b;
    begin
        case (b)
            0,1,8,9:      bank_rslot_mod = 2'd0;
            2,3,10,11:    bank_rslot_mod = 2'd1;
            4,5,12,13:    bank_rslot_mod = 2'd2;
            default:      bank_rslot_mod = 2'd3;
        endcase
    end
endfunction

function [1:0] bank_cmod;
    input integer b;
    begin
        case (b)
            0,2,4,6:      bank_cmod = 2'd0;
            1,3,5,7:      bank_cmod = 2'd1;
            8,10,12,14:   bank_cmod = 2'd2;
            default:      bank_cmod = 2'd3;
        endcase
    end
endfunction

function [4:0] bank_id_from_mod;
    input [1:0] rmod;
    input [1:0] cmod;
    begin
        case ({rmod,cmod})
            4'b00_00: bank_id_from_mod = 5'd0;
            4'b00_01: bank_id_from_mod = 5'd1;
            4'b00_10: bank_id_from_mod = 5'd8;
            4'b00_11: bank_id_from_mod = 5'd9;

            4'b01_00: bank_id_from_mod = 5'd2;
            4'b01_01: bank_id_from_mod = 5'd3;
            4'b01_10: bank_id_from_mod = 5'd10;
            4'b01_11: bank_id_from_mod = 5'd11;

            4'b10_00: bank_id_from_mod = 5'd4;
            4'b10_01: bank_id_from_mod = 5'd5;
            4'b10_10: bank_id_from_mod = 5'd12;
            4'b10_11: bank_id_from_mod = 5'd13;

            4'b11_00: bank_id_from_mod = 5'd6;
            4'b11_01: bank_id_from_mod = 5'd7;
            4'b11_10: bank_id_from_mod = 5'd14;
            default:  bank_id_from_mod = 5'd15;
        endcase
    end
endfunction

function [31:0] max4_word_u8;
    input [31:0] a;
    input [31:0] b;
    input [31:0] c;
    input [31:0] d;
    reg [7:0] m0;
    reg [7:0] m1;
    reg [7:0] m2;
    reg [7:0] m3;
    begin
        m0 = (a[7:0]   > b[7:0])   ? a[7:0]   : b[7:0];
        m0 = (m0       > c[7:0])   ? m0       : c[7:0];
        m0 = (m0       > d[7:0])   ? m0       : d[7:0];

        m1 = (a[15:8]  > b[15:8])  ? a[15:8]  : b[15:8];
        m1 = (m1       > c[15:8])  ? m1       : c[15:8];
        m1 = (m1       > d[15:8])  ? m1       : d[15:8];

        m2 = (a[23:16] > b[23:16]) ? a[23:16] : b[23:16];
        m2 = (m2       > c[23:16]) ? m2       : c[23:16];
        m2 = (m2       > d[23:16]) ? m2       : d[23:16];

        m3 = (a[31:24] > b[31:24]) ? a[31:24] : b[31:24];
        m3 = (m3       > c[31:24]) ? m3       : c[31:24];
        m3 = (m3       > d[31:24]) ? m3       : d[31:24];

        max4_word_u8 = {m3, m2, m1, m0};
    end
endfunction

function [31:0] max2_word_u8;
    input [31:0] a;
    input [31:0] b;
    begin
        max2_word_u8[7:0]   = (a[7:0]   > b[7:0])   ? a[7:0]   : b[7:0];
        max2_word_u8[15:8]  = (a[15:8]  > b[15:8])  ? a[15:8]  : b[15:8];
        max2_word_u8[23:16] = (a[23:16] > b[23:16]) ? a[23:16] : b[23:16];
        max2_word_u8[31:24] = (a[31:24] > b[31:24]) ? a[31:24] : b[31:24];
    end
endfunction

assign readL = read_ping_pong_sel ? g0_Lrdata : g1_Lrdata;
assign readR = read_ping_pong_sel ? g0_Rrdata : g1_Rrdata;

assign rd_bank[0]  = readL[ 31:  0];
assign rd_bank[1]  = readL[ 63: 32];
assign rd_bank[2]  = readL[ 95: 64];
assign rd_bank[3]  = readL[127: 96];
assign rd_bank[4]  = readL[159:128];
assign rd_bank[5]  = readL[191:160];
assign rd_bank[6]  = readL[223:192];
assign rd_bank[7]  = readL[255:224];

assign rd_bank[8]  = readR[ 31:  0];
assign rd_bank[9]  = readR[ 63: 32];
assign rd_bank[10] = readR[ 95: 64];
assign rd_bank[11] = readR[127: 96];
assign rd_bank[12] = readR[159:128];
assign rd_bank[13] = readR[191:160];
assign rd_bank[14] = readR[223:192];
assign rd_bank[15] = readR[255:224];

assign fill_local_slot = (fill_rg << 2) | fill_row;

assign fill_abs_row_s = calc_fill_abs_row(fill_abs_row_base, fill_rg, fill_row);

`ifdef YOLO_L0_IFM_OVERLAP

reg  [16:0] ifm_l2_wr_cnt;
wire [16:0] ifm_row_need_end = ({1'b0, l2_fill_row_base_q} -
                                {1'b0, l2_input_base_q}) + ifm_row_words_q;
wire fill_dma_stall = need_dram_ifm && !fill_zero_row_q &&
                      (ifm_row_need_end > ifm_l2_wr_cnt);
wire fill_issue = fill_active && !fill_dma_stall;
`else
wire fill_issue = fill_active;
`endif

assign fill_zero_row = fill_zero_row_q;
assign fill_row_advance = fill_issue &&
                          (fill_ch == fill_ch_max_m1_q) &&
                          (fill_col == l1rd_q_width_m1_q);
assign fill_row_next = (fill_row == 2'd3) ? 2'd0 : (fill_row + 1'b1);
assign fill_rg_next  = (fill_row == 2'd3) ? (fill_rg + 1'b1) : fill_rg;
assign fill_abs_row_base_swap = fill_abs_row_base + l1rd_row_span_minus2_q;
assign fill_abs_row_first_s = calc_fill_abs_row(9'd0, 4'd0, 2'd0);
assign fill_abs_row_swap_s = calc_fill_abs_row(fill_abs_row_base_swap, 4'd0, 2'd0);
assign fill_abs_row_next_s = calc_fill_abs_row(fill_abs_row_base, fill_rg_next, fill_row_next);

assign fill_col_d0      = fill_col;
assign fill_ch_d0       = fill_ch;
assign fill_row_d0      = fill_row;
assign fill_rg_d0       = fill_rg;
assign fill_zero_row_d0 = fill_zero_row;
assign row_tile_vld_d0  = req_valid;
assign row_tile_vld     = row_tile_vld_d2;

assign q_width_shift = width_to_shift(q_width);
assign l2_fill_col_offset = {7'd0, fill_col} << l1rd_ch_shift_q;
assign l20_up_col_offset = {12'd0, fill_col[8:1]} << 5;
assign l20_route8_col_offset = {7'd0, fill_col} << 6;
assign l20_fill_ch_offset = (fill_ch < 8'd32) ? {11'd0, fill_ch[4:0]} :
                                                   ({8'd0, fill_ch} - 16'd32);

assign L2_addrb_calc = fill_zero_row_q ? 16'd0 :
                       l1rd_l20_q ? ((fill_ch < 8'd32) ?
                                     (l20_up_row_base_q + l20_up_col_offset + l20_fill_ch_offset) :
                                     (l20_route8_row_base_q + l20_route8_col_offset + l20_fill_ch_offset)) :
                                    (l2_fill_row_base_q + l2_fill_col_offset + {8'd0, fill_ch});
assign L2_addrb = L2_addrb_r;

always @(posedge clk) begin
    if (!rstn)
        L2_addrb_r <= 16'd0;
    else if (layer_start || partition_start_r || swap_trigger)
        L2_addrb_r <= 16'd0;
    else if (req_valid)
        L2_addrb_r <= L2_addrb_calc;
end

always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        fill_zero_row_q       <= 1'b1;
        l2_fill_row_base_q    <= 16'd0;
        l20_up_row_base_q     <= 16'd0;
        l20_route8_row_base_q <= 16'd0;
    end
    else if (layer_start || partition_start_r || compute_begin) begin
        fill_zero_row_q       <= 1'b1;
        l2_fill_row_base_q    <= 16'd0;
        l20_up_row_base_q     <= 16'd0;
        l20_route8_row_base_q <= 16'd0;
    end
    else if (swap_trigger) begin
        fill_zero_row_q       <= (fill_abs_row_swap_s < 0) ||
                                 (fill_abs_row_swap_s >= $signed({1'b0, l1rd_q_height_q}));
        l2_fill_row_base_q    <= normal_l2_row_base(l2_input_base_q,
                                                     fill_abs_row_swap_s,
                                                     l1rd_q_width_shift_q,
                                                     l1rd_ch_shift_q);
        l20_up_row_base_q     <= l20_up_l2_row_base(fill_abs_row_swap_s);
        l20_route8_row_base_q <= l20_route8_l2_row_base(fill_abs_row_swap_s);
    end
    else if (fill_row_advance) begin
        fill_zero_row_q       <= (fill_abs_row_next_s < 0) ||
                                 (fill_abs_row_next_s >= $signed({1'b0, l1rd_q_height_q}));
        l2_fill_row_base_q    <= normal_l2_row_base(l2_input_base_q,
                                                     fill_abs_row_next_s,
                                                     l1rd_q_width_shift_q,
                                                     l1rd_ch_shift_q);
        l20_up_row_base_q     <= l20_up_l2_row_base(fill_abs_row_next_s);
        l20_route8_row_base_q <= l20_route8_l2_row_base(fill_abs_row_next_s);
    end
end

assign row_tile_in = fill_zero_row_d2 ? 32'd0 : row_tile;

assign mac_iter_max = i_mode ? (l1rd_ch_len_q >> 4) : (l1rd_ch_len_q >> 2);
assign wet_stride_words = i_mode ? mac_iter_max : {2'd0, fill_ch_max_q};
assign wet_oc_base_next = all_oc_done ? layer_wet_base :
                                         (wet_oc_base + wet_stride_words);
assign l1_read_ch = i_mode ? ((ch_cnt_r << 2) | {6'd0, conv1x1_phase}) : ch_cnt_r;
assign conv1x1_phase_last = (conv1x1_phase == 2'd3);

assign pe_i_start = L1_vaild && (issue_ch_d == 8'd0);

assign l20_read_tile_ready = !i_mode ? 1'b1 :
                             l1rd_l20_q ? (read_abs_row_base == o_row) :
                             ((l1rd_max_row_groups_q == 4'd2) &&
                              (o_row >= l1rd_row_span_minus2_q)) ?
                             (read_abs_row_base == o_row) : 1'b1;
assign read_ctrl_freeze = i_mode && (state == OP) && first_bank_ready &&
                          l20_read_tile_ready && !out_vaild;
`ifdef YOLO_WT_STREAM

reg        wt_load_start_d;
reg [3:0]  wet_beat_mod12;
reg [10:0] wet_ready_entries;
always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        wt_load_start_d   <= 1'b0;
        wet_beat_mod12    <= 4'd0;
        wet_ready_entries <= 11'd0;
    end
    else begin
        wt_load_start_d <= weight_load_start;
        if (layer_start || wt_load_start_d) begin
            wet_beat_mod12    <= 4'd0;
            wet_ready_entries <= 11'd0;
        end
        else if (wet_wr_vld) begin
            if (wet_beat_mod12 == 4'd11) begin
                wet_beat_mod12    <= 4'd0;
                wet_ready_entries <= wet_ready_entries + 11'd1;
            end
            else begin
                wet_beat_mod12 <= wet_beat_mod12 + 4'd1;
            end
        end
    end
end
wire weight_ready_for_issue = !need_dram_wt ||
                              ({1'b0, WET_addr} < wet_ready_entries);
`else
wire weight_ready_for_issue = 1'b1;
`endif
`ifdef YOLO_L0_OC_BURST

assign oc_burst_layer = (mac_iter_max == 10'd1) && !i_mode;
assign issue_oc_max   = active_oc_end_run - out_ch_done;
`ifdef YOLO_OC_PIPELINE
assign ocp_layer      = (mac_iter_max >= 10'd2) && !i_mode;
assign ocp_issue_last = issue_fire && ocp_layer &&
                        ({2'd0, ch_cnt_r} == mac_iter_max - 10'd1);

assign issue_beat_last = ({2'd0, issue_ch_d} == mac_iter_max - 10'd1);
`ifdef YOLO_IMODE_OCP
assign imode_ocp_layer = i_mode && (mac_iter_max >= 10'd2);
assign imode_ocp_issue_last = issue_fire && imode_ocp_layer &&
                              conv1x1_phase_last &&
                              ({2'd0, ch_cnt_r} == mac_iter_max - 10'd1);
`endif
`endif

`ifdef YOLO_OC_PIPELINE

`ifdef YOLO_IMODE_OCP

assign issue_fire  = (state == OP) && first_bank_ready && !pe_done_latch &&
                     l20_read_tile_ready && weight_ready_for_issue &&
                     ((oc_burst_layer || ocp_layer || imode_ocp_layer)
                                     ? (issue_oc_cnt < issue_oc_max)
                                     : ({2'd0, ch_cnt_r} < mac_iter_max));
`else
assign issue_fire  = (state == OP) && first_bank_ready && !pe_done_latch &&
                     l20_read_tile_ready && weight_ready_for_issue &&
                     ((oc_burst_layer || ocp_layer)
                                     ? (issue_oc_cnt < issue_oc_max)
                                     : ({2'd0, ch_cnt_r} < mac_iter_max));
`endif
`else
assign issue_fire  = (state == OP) && first_bank_ready && !pe_done_latch &&
                     l20_read_tile_ready && weight_ready_for_issue &&
                     (oc_burst_layer ? (issue_oc_cnt < issue_oc_max)
                                     : ({2'd0, ch_cnt_r} < mac_iter_max));
`endif
`else
assign issue_fire  = (state == OP) && first_bank_ready && !pe_done_latch &&
                     l20_read_tile_ready && weight_ready_for_issue &&
                     ({2'd0, ch_cnt_r} < mac_iter_max);
`endif
assign feed_active = issue_fire;
assign L1_vaild    = i_mode ? conv1x1_valid : issue_fire_d;

assign ofm_ch_group_base_wr = has_maxpool ? ofm_ch_group_base : ofm_ch_group_base_hold;
assign padded_head_layer = (layer_id == 5'd14) || (layer_id == 5'd20);
`ifdef YOLO_HEAD32_PARTITION_DDR
assign head32_layer_q = padded_head_layer_q;
assign head32_layer_hold = padded_head_layer_hold;
assign head32_partition_ch_live = (out_ch_done >= 10'd192) ? 16'd3 : 16'd32;
assign head32_pixel_offset_live =
    (head32_partition_ch_live == 16'd3) ? ((ofm_tile_pixel_base_live << 1) + ofm_tile_pixel_base_live) :
                                          (ofm_tile_pixel_base_live << 5);
assign head32_pixel_offset_calc =
    (ofm_out_ch_groups_hold == 16'd3) ? ((ofm_tile_pixel_base_calc << 1) + ofm_tile_pixel_base_calc) :
                                        (ofm_tile_pixel_base_calc << 5);
`else
assign head32_layer_q = 1'b0;
assign head32_layer_hold = 1'b0;
assign head32_partition_ch_live = 16'd0;
assign head32_pixel_offset_live = 16'd0;
assign head32_pixel_offset_calc = 16'd0;
`endif
assign ofm_width_shift = width_to_shift(ofm_width);
assign ofm_out_ch_groups = head32_layer_q ? head32_partition_ch_live :
                            padded_head_layer_q ? 16'd98 : (16'd1 << out_ch_shift_q);
assign ofm_tile_pixel_base_calc =
    ({7'd0, ofm_row_hold} << ofm_width_shift_hold) + {7'd0, ofm_col_hold};
assign ofm_wr_base_calc =
    ofm_l2_output_base_hold + ofm_ch_group_base_hold +
    (head32_layer_hold ? head32_pixel_offset_calc :
     padded_head_layer_hold ? ((ofm_tile_pixel_base_calc << 6) +
                               (ofm_tile_pixel_base_calc << 5) +
                               (ofm_tile_pixel_base_calc << 1)) :
                              (ofm_tile_pixel_base_calc << ofm_out_ch_shift_hold));
assign ofm_wr_col_step_calc = ofm_out_ch_groups_hold;
assign ofm_wr_row_step_calc = ofm_out_ch_groups_hold << ofm_width_shift_hold;
assign ofm_tile_pixel_base_live =
    ({7'd0, o_row} << ofm_width_shift_q) + {7'd0, o_col};
assign ofm_wr_base_live =
    ofm_l2_output_base_q + ofm_ch_group_base +
    (head32_layer_q ? head32_pixel_offset_live :
     padded_head_layer_q ? ((ofm_tile_pixel_base_live << 6) +
                            (ofm_tile_pixel_base_live << 5) +
                            (ofm_tile_pixel_base_live << 1)) :
                           (ofm_tile_pixel_base_live << out_ch_shift_q));
assign ofm_wr_col_step_live = ofm_out_ch_groups;
assign ofm_wr_row_step_live = ofm_out_ch_groups << ofm_width_shift_q;
assign ofm_wr_addr_seq =
    ofm_wr_base_hold +
    (ofm_wr_cnt[1] ? ofm_wr_row_step_hold : 16'd0) +
    (ofm_wr_cnt[0] ? ofm_wr_col_step_hold : 16'd0);
assign ofm_wr_addr = (ofm_pixel_cnt << out_ch_shift_q) | ofm_ch_group_base_wr;
assign req_last = fill_last;
assign local_ofm_ch_idx = ofm_ch_idx - out_ch_done;
assign l1_col_ch_offset = (l1rd_ch_len_q == 10'd384) ?
                          (({7'd0, fill_col_d2[8:2]} << 6) + ({7'd0, fill_col_d2[8:2]} << 5)) :
                          ({7'd0, fill_col_d2[8:2]} << l1rd_ch_shift_q);
assign l1_rg_offset = (l1rd_ch_len_q == 10'd384) ? 16'd0 : ({12'd0, fill_rg_d2} << l1rd_rg_shift_q);
assign L2_L1_addr_calc = l1_rg_offset + l1_col_ch_offset + {8'd0, fill_ch_d2};
assign L2_L1_addr = L2_L1_addr_calc[8:0];

assign ofm_ch_group_base = head32_layer_q ? {6'd0, local_ofm_ch_idx} :
                            padded_head_layer_q ? (ofm_ch_idx >> 1) : (ofm_ch_idx >> 2);

assign ch_cnt       = ch_cnt_r;
assign last_ch      = last_consume_seen;
assign mid_ch_done  = mac_done && !last_consume_seen;
assign last_ch_done = mac_done &&  last_consume_seen;

assign out_size = ofm_width*ofm_height;

`ifdef YOLO_STORE_OVERLAP
assign write_data_vld = store_indata_vld;
`else
assign write_data_vld = store_mode && indata_req_wr;
`endif
assign new_out_ch = (ofm_ch_idx != prev_ofm_ch_idx);
assign out_size_nopool = q_width * q_height;

assign l2_store_offset = store_addr;
assign wet_addr_to_gbuff = WET_addr;
`ifdef YOLO_L0_OC_BURST

`ifdef YOLO_OC_PIPELINE

`ifdef YOLO_IMODE_OCP

assign bsc_addr_to_gbuff = (oc_burst_layer || ocp_layer) ?
    (bsc_addra - {2'd0, ofm_ch_idx} + {2'd0, out_ch_done} + {2'd0, issue_oc_cnt}) :
    imode_ocp_layer ?
    (bsc_addra - {2'd0, ofm_ch_idx} + {2'd0, out_ch_done} + {2'd0, imode_bsc_oc_d}) :
    bsc_addra;
`else
assign bsc_addr_to_gbuff = (oc_burst_layer || ocp_layer) ?
    (bsc_addra - {2'd0, ofm_ch_idx} + {2'd0, out_ch_done} + {2'd0, issue_oc_cnt}) :
    bsc_addra;
`endif
`else
assign bsc_addr_to_gbuff = oc_burst_layer ?
    (bsc_addra - {2'd0, ofm_ch_idx} + {2'd0, out_ch_done} + {2'd0, issue_oc_cnt}) :
    bsc_addra;
`endif
`else
assign bsc_addr_to_gbuff = bsc_addra;
`endif

assign tile_base = ofm_ch_group_base + ofm_row_offset + ofm_col_hold;

assign ofm_wr_row_nopool = {7'd0, ofm_row_hold} + {15'd0, ofm_wr_cnt[1]};
assign ofm_wr_col_nopool = {7'd0, ofm_col_hold} + {15'd0, ofm_wr_cnt[0]};

assign ofm_pixel_idx_nopool = (ofm_wr_row_nopool * ofm_width) + ofm_wr_col_nopool;

assign ifm_load_vld = read_data_vld && (load_mode == 1'b0);

`ifdef YOLO_STORE_OVERLAP

reg         store_start_r;
reg  [15:0] store_words_r;
reg  [15:0] store_pf_issued;
reg         store_pf_inflight;
reg  [15:0] l2_store_base_r;
reg  [31:0] store_fifo_mem [0:7];
reg  [2:0]  store_fifo_wr_ptr;
reg  [2:0]  store_fifo_rd_ptr;
reg  [3:0]  store_fifo_cnt;

wire store_pf_pending = (store_pf_issued != store_words_r) && !store_start_r;
wire store_porta_free = !route8_l2_busy && !pool11_active && !ofm_write_mode;
wire store_pf_grant   = store_pf_pending && store_porta_free &&
                        (({1'b0, store_fifo_cnt} + {4'd0, store_pf_inflight}) < 5'd8);

assign store_indata_vld = (store_fifo_cnt != 4'd0);

always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        store_start_r     <= 1'b0;
        store_words_r     <= 16'd0;
        store_pf_issued   <= 16'd0;
        store_pf_inflight <= 1'b0;
        l2_store_base_r   <= 16'd0;
        store_fifo_wr_ptr <= 3'd0;
        store_fifo_rd_ptr <= 3'd0;
        store_fifo_cnt    <= 4'd0;
    end
    else begin
        store_start_r <= dma_start_wr;
        if (store_start_r) begin

            store_words_r     <= dma_num_wr[15:0];
            store_pf_issued   <= 16'd0;
            store_pf_inflight <= 1'b0;
            l2_store_base_r   <= l2_output_base;
            store_fifo_wr_ptr <= 3'd0;
            store_fifo_rd_ptr <= 3'd0;
            store_fifo_cnt    <= 4'd0;
        end
        else begin
            store_pf_inflight <= store_pf_grant;
            if (store_pf_grant)
                store_pf_issued <= store_pf_issued + 16'd1;
            if (store_pf_inflight) begin

                store_fifo_mem[store_fifo_wr_ptr] <= l2_rdata_a;
                store_fifo_wr_ptr <= store_fifo_wr_ptr + 3'd1;
            end
            if (store_indata_ack)
                store_fifo_rd_ptr <= store_fifo_rd_ptr + 3'd1;
            store_fifo_cnt <= store_fifo_cnt
                              + (store_pf_inflight ? 4'd1 : 4'd0)
                              - (store_indata_ack ? 4'd1 : 4'd0);
        end
    end
end

always @(posedge clk or negedge rstn) begin
    if (!rstn)
        head_buf_sel <= 1'b0;
    else if (layer_start)
        head_buf_sel <= 1'b0;
    else if (store_start_r)
        head_buf_sel <= ~head_buf_sel;
end
`endif

`ifdef YOLO_L0_IFM_OVERLAP

reg  [31:0] ifm_fifo_mem [0:31];
reg  [5:0]  ifm_fifo_wr_ptr;
reg  [5:0]  ifm_fifo_rd_ptr;
wire [5:0]  ifm_fifo_count = ifm_fifo_wr_ptr - ifm_fifo_rd_ptr;
wire        ifm_fifo_empty = (ifm_fifo_count == 6'd0);
`ifdef YOLO_STORE_OVERLAP

wire        l2_porta_free  = !route8_l2_busy && !pool11_active &&
                             !ofm_write_mode && !store_pf_grant;
`else
wire        l2_porta_free  = !route8_l2_busy && !pool11_active &&
                             !ofm_write_mode && !store_mode;
`endif
wire        ifm_fifo_pop   = !ifm_fifo_empty && l2_porta_free;
wire [31:0] ifm_fifo_dout  = ifm_fifo_mem[ifm_fifo_rd_ptr[4:0]];
assign      ifm_rd_stall   = (ifm_fifo_count >= 6'd28);

always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        ifm_fifo_wr_ptr <= 6'd0;
        ifm_fifo_rd_ptr <= 6'd0;
        ifm_l2_wr_cnt   <= 17'd0;
    end
    else if (layer_start) begin
        ifm_fifo_wr_ptr <= 6'd0;
        ifm_fifo_rd_ptr <= 6'd0;
        ifm_l2_wr_cnt   <= 17'd0;
    end
    else begin
        if (ifm_load_vld) begin
            ifm_fifo_mem[ifm_fifo_wr_ptr[4:0]] <= read_data;
            ifm_fifo_wr_ptr <= ifm_fifo_wr_ptr + 6'd1;
        end
        if (ifm_fifo_pop) begin
            ifm_fifo_rd_ptr <= ifm_fifo_rd_ptr + 6'd1;
            ifm_l2_wr_cnt   <= ifm_l2_wr_cnt + 17'd1;
        end
    end
end

`ifdef YOLO_STORE_OVERLAP
assign l2_ena = route8_l2_busy ? 1'b1 : pool11_active ? 1'b1 : ofm_write_mode ? 1'b1 : store_pf_grant ? 1'b1 : ifm_fifo_pop;

assign l2_wea = route8_l2_busy ? route8_wea_hold : pool11_wr ? 4'b1111 : ofm_write_mode ? (has_maxpool ? maxpool_wea_hold : ofm_wea_hold) : store_pf_grant ? 4'b0000 : ifm_fifo_pop ? 4'b1111 : 4'b0000;

assign l2_store_addr  = l2_store_base_r + store_pf_issued;
assign l2_ofm_wr_addr = has_maxpool ? maxpool_addr_hold : ofm_wr_addr_seq;

assign l2_addra = route8_l2_busy ? route8_l2_addr : pool11_active ? pool_l2_phys_addr : ofm_write_mode ? l2_ofm_wr_addr : store_pf_grant ? l2_store_addr : ifm_fifo_pop ? ifm_l2_wr_cnt[15:0] : 16'd0;
`else
assign l2_ena = route8_l2_busy ? 1'b1 : pool11_active ? 1'b1 : ofm_write_mode ? 1'b1 : store_mode ? 1'b1 : ifm_fifo_pop;

assign l2_wea = route8_l2_busy ? route8_wea_hold : pool11_wr ? 4'b1111 : ofm_write_mode ? (has_maxpool ? maxpool_wea_hold : ofm_wea_hold) : store_mode ? 4'b0000 : ifm_fifo_pop ? 4'b1111 : 4'b0000;

assign l2_store_addr  = l2_output_base + l2_store_offset;
assign l2_ofm_wr_addr = has_maxpool ? maxpool_addr_hold : ofm_wr_addr_seq;

assign l2_addra = route8_l2_busy ? route8_l2_addr : pool11_active ? pool_l2_phys_addr : ofm_write_mode ? l2_ofm_wr_addr : store_mode ? l2_store_addr : ifm_fifo_pop ? ifm_l2_wr_cnt[15:0] : 16'd0;
`endif
`else
assign ifm_rd_stall = 1'b0;
`ifdef YOLO_STORE_OVERLAP
assign l2_ena = route8_l2_busy ? 1'b1 : pool11_active ? 1'b1 : ofm_write_mode ? 1'b1 : store_pf_grant ? 1'b1 : ifm_load_vld;

assign l2_wea = route8_l2_busy ? route8_wea_hold : pool11_wr ? 4'b1111 : ofm_write_mode ? (has_maxpool ? maxpool_wea_hold : ofm_wea_hold) : store_pf_grant ? 4'b0000 : ifm_load_vld ? 4'b1111 : 4'b0000;

assign l2_store_addr  = l2_store_base_r + store_pf_issued;
assign l2_ofm_wr_addr = has_maxpool ? maxpool_addr_hold : ofm_wr_addr_seq;

assign l2_addra = route8_l2_busy ? route8_l2_addr : pool11_active ? pool_l2_phys_addr : ofm_write_mode ? l2_ofm_wr_addr : store_pf_grant ? l2_store_addr : ifm_load_vld ? read_data_cnt : 16'd0;
`else
assign l2_ena = route8_l2_busy ? 1'b1 : pool11_active ? 1'b1 : ofm_write_mode ? 1'b1 : store_mode ? 1'b1 : ifm_load_vld;

assign l2_wea = route8_l2_busy ? route8_wea_hold : pool11_wr ? 4'b1111 : ofm_write_mode ? (has_maxpool ? maxpool_wea_hold : ofm_wea_hold) : store_mode ? 4'b0000 : ifm_load_vld ? 4'b1111 : 4'b0000;

assign l2_store_addr  = l2_output_base + l2_store_offset;
assign l2_ofm_wr_addr = has_maxpool ? maxpool_addr_hold : ofm_wr_addr_seq;

assign l2_addra = route8_l2_busy ? route8_l2_addr : pool11_active ? pool_l2_phys_addr : ofm_write_mode ? l2_ofm_wr_addr : store_mode ? l2_store_addr : ifm_load_vld ? read_data_cnt : 16'd0;
`endif
`endif

assign padded_head_last_valid_ch = padded_head_layer_q && (ofm_ch_idx == 10'd194);
assign ofm_wea_live = head32_layer_q ? 4'b1111 :
                       padded_head_layer_q ? (padded_head_last_valid_ch ? 4'b1111 :
                                             (ofm_ch_idx[0] ? 4'b1100 : 4'b0011)) :
                                             ofm_wea;
assign ofm_write_busy = wr_busy || ofm_pending_valid;
assign ofm_head16_dina = (ofm_wea_hold == 4'b1100) ? {ofm_halfword, 16'd0} : {16'd0, ofm_halfword};
assign ofm_l2_dina = has_maxpool ? {maxpool_byte_hold, maxpool_byte_hold, maxpool_byte_hold, maxpool_byte_hold}
                                  : (head32_layer_hold ? ofm_word32
                                    : padded_head_layer_hold ? ofm_head16_dina
                                                             : {ofm_byte, ofm_byte, ofm_byte, ofm_byte});
`ifdef YOLO_L0_IFM_OVERLAP
assign l2_dina = route8_l2_busy ? route8_dina : pool11_wr     ? pool_l2_dina : ofm_write_mode ? ofm_l2_dina : ifm_fifo_dout;
`else
assign l2_dina = route8_l2_busy ? route8_dina : pool11_wr     ? pool_l2_dina : ofm_write_mode ? ofm_l2_dina : read_data;
`endif

assign pool_l2_dina = pool_max_word;

assign ofm_byte = (ofm_wr_cnt == 0) ? ofm_hold[31:24] :  (ofm_wr_cnt == 1) ? ofm_hold[23:16] :  (ofm_wr_cnt == 2) ? ofm_hold[15:8]  : ofm_hold[7:0];
assign ofm_halfword = (ofm_wr_cnt == 0) ? ofm16_hold[63:48] : (ofm_wr_cnt == 1) ? ofm16_hold[47:32] : (ofm_wr_cnt == 2) ? ofm16_hold[31:16] : ofm16_hold[15:0];
assign ofm_word32 = (ofm_wr_cnt == 0) ? ofm32_hold[127:96] :
                    (ofm_wr_cnt == 1) ? ofm32_hold[95:64]  :
                    (ofm_wr_cnt == 2) ? ofm32_hold[63:32]  :
                                        ofm32_hold[31:0];
assign ofm_write_mode = (has_maxpool && maxpool_wr_pending) || (!has_maxpool && wr_busy && ofm_addr_ready);
`ifdef YOLO_STORE_OVERLAP

assign write_data = store_fifo_mem[store_fifo_rd_ptr];
`else
assign write_data = l2_rdata_a;
`endif

assign route8_capture = route8_layer_q && has_maxpool && out_vaild;
assign route8_byte =
    (route8_wr_cnt == 2'd0) ? route8_hold[31:24] :
    (route8_wr_cnt == 2'd1) ? route8_hold[23:16] :
    (route8_wr_cnt == 2'd2) ? route8_hold[15:8]  :
                               route8_hold[7:0];
assign route8_wr_row = route8_row_hold + {8'd0, route8_wr_cnt[1]};
assign route8_wr_col = route8_col_hold + {8'd0, route8_wr_cnt[0]};
assign route8_wr_pix = {1'b0, route8_wr_row[3:0], route8_wr_col[3:0]};
assign route8_wr_addr = {route8_wr_pix[7:0], route8_ch_group_hold[5:0]};
assign route8_l2_addr = L2_REGION_ROUTE8_BASE + {2'b00, route8_wr_addr};
assign route8_dina = {route8_byte, route8_byte, route8_byte, route8_byte};

assign wet_wr_vld = read_data_vld && (load_mode == 1);
assign bias_param  = bsc_douta[31:16];
assign scale_param = bsc_douta[15:0];
assign i_weight = i_mode ? i_weight_hold : i_weight_raw;

assign fill_last = (fill_rg == l1rd_max_row_groups_m1_q) &&
                   (fill_row == 2'd3) &&
                   (fill_col == l1rd_q_width_m1_q) &&
                   (fill_ch == fill_ch_max_m1_q) &&
                   fill_issue;

assign pe_done = (o_row == pe_last_row) && (o_col == l1rd_q_width_m2_q) && all_oc_done;

assign swap_trigger = fill_done_latch && (pe_done_latch || pe_done || first_fill);

assign req_valid = fill_issue;

assign we_g0   = (ping_pong_sel == 1'b0) ? row_tile_vld : 1'b0;

assign we_g1   = (ping_pong_sel == 1'b1) ? row_tile_vld : 1'b0;

always @(*) begin
    patch_r0      = $signed({1'b0, o_row}) - 1;
    patch_c0      = $signed({1'b0, o_col}) - 1;
    top_slot_mod  = (o_row - read_abs_row_base) & 2'h3;
    left_col_mod  = (patch_c0) & 2'h3;

    for (bi = 0; bi < 16; bi = bi + 1) begin
        row_off = (bank_rslot_mod(bi) - top_slot_mod + 4) & 3;
        col_off = (bank_cmod(bi)      - left_col_mod + 4) & 3;

        abs_r_b = patch_r0 + row_off;
        abs_c_b = patch_c0 + col_off;

        local_slot_b = abs_r_b - read_abs_row_base + 1;

        if ((abs_r_b < 0) || (abs_r_b >= l1rd_q_height_q) ||
            (abs_c_b < 0) || (abs_c_b >= l1rd_q_width_q)  ||
            (local_slot_b < 0) || (local_slot_b > ((l1rd_max_row_groups_q << 2) - 1))) begin
            bank_valid[bi] = 1'b0;
            pe_addr_b[bi]  = 9'd0;
        end
        else begin
            bank_valid[bi] = 1'b1;
            row_grp_b      = local_slot_b >> 2;
            if (l1rd_ch_len_q == 10'd384) begin
                pe_addr_b[bi] = ((abs_c_b >> 2) << 6)
                              + ((abs_c_b >> 2) << 5)
                              + l1_read_ch;
            end
            else begin
                pe_addr_b[bi]  = (row_grp_b << l1rd_rg_shift_q)
                               | ((abs_c_b >> 2) << l1rd_ch_shift_q)
                               | l1_read_ch;
            end
        end
    end
end

always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        pool_state  <= P_IDLE;
        pool_y      <= 3'd0;
        pool_x      <= 3'd0;
        pool_g      <= 7'd0;
        pool_d0     <= 32'd0;
        pool_d1     <= 32'd0;
        pool_d2     <= 32'd0;
        pool_d3     <= 32'd0;
        pool_max_word <= 32'd0;
        pool11_done <= 1'b0;
    end
    else if (layer_start) begin
        pool_state  <= P_IDLE;
        pool_y      <= 3'd0;
        pool_x      <= 3'd0;
        pool_g      <= 7'd0;
        pool_d0     <= 32'd0;
        pool_d1     <= 32'd0;
        pool_d2     <= 32'd0;
        pool_d3     <= 32'd0;
        pool_max_word <= 32'd0;
        pool11_done <= 1'b0;
    end
    else begin
        pool11_done <= 1'b0;

        case (pool_state)
            P_IDLE: begin

                if (pool11_run && !ofm_write_busy && !ofm_write_mode) begin
                    pool_y     <= 3'd0;
                    pool_x     <= 3'd0;
                    pool_g     <= 7'd0;
                    pool_state <= P_R0;
                end
            end

            P_R0: begin
                pool_state <= P_R1;
            end

            P_R1: begin
                pool_d0 <= l2_rdata_a;
                pool_max_word <= l2_rdata_a;
                pool_state <= P_R2;
            end

            P_R2: begin
                pool_d1 <= l2_rdata_a;
                pool_max_word <= max2_word_u8(pool_max_word, l2_rdata_a);
                pool_state <= P_R3;
            end

            P_R3: begin
                pool_d2 <= l2_rdata_a;
                pool_max_word <= max2_word_u8(pool_max_word, l2_rdata_a);
                pool_state <= P_R4;
            end

            P_R4: begin
                pool_d3 <= l2_rdata_a;
                pool_max_word <= max2_word_u8(pool_max_word, l2_rdata_a);
                pool_state <= P_WR;
            end

            P_WR: begin

                if (pool_g == 7'd127) begin
                    pool_g <= 7'd0;

                    if (pool_x == 3'd7) begin
                        pool_x <= 3'd0;

                        if (pool_y == 3'd7) begin
                            pool_y      <= 3'd0;
                            pool11_done <= 1'b1;
                            pool_state  <= P_IDLE;
                        end
                        else begin
                            pool_y     <= pool_y + 3'd1;
                            pool_state <= P_R0;
                        end
                    end
                    else begin
                        pool_x     <= pool_x + 3'd1;
                        pool_state <= P_R0;
                    end
                end
                else begin
                    pool_g     <= pool_g + 7'd1;
                    pool_state <= P_R0;
                end
            end

            default: begin
                pool_state <= P_IDLE;
            end
        endcase
    end
end

always @(*) begin
    for (idx = 0; idx < 16; idx = idx + 1)
        lane_word[idx] = 32'd0;

    for (ry = 0; ry < 4; ry = ry + 1) begin
        for (cx = 0; cx < 4; cx = cx + 1) begin
            idx = ry*4 + cx;

            abs_r = $signed({1'b0, read_stage_row_q}) + ry - 1;
            abs_c = $signed({1'b0, read_stage_col_q}) + cx - 1;

            if ((abs_r < 0) || (abs_r >= l1rd_q_height_q) ||
                (abs_c < 0) || (abs_c >= l1rd_q_width_q)) begin
                lane_word[idx] = 32'd0;
            end
            else begin
                local_slot_p = abs_r - read_stage_abs_row_base_q + 1;
                if ((local_slot_p < 0) || (local_slot_p > ((l1rd_max_row_groups_q << 2) - 1))) begin
                lane_word[idx] = 32'd0;
                end
                else begin
                    bank_sel = bank_id_from_mod(local_slot_p[1:0], abs_c[1:0]);
                    lane_word[idx] = rd_bank[bank_sel];
                end
            end
        end
    end

    if (i_mode) begin
        total_read_data = {conv1x1_br, conv1x1_bl, conv1x1_tr, conv1x1_tl};
    end
    else begin
        total_read_data = 512'd0;

        total_read_data[256 + 0*32 +: 32] = lane_word[0];
        total_read_data[256 + 1*32 +: 32] = lane_word[1];
        total_read_data[256 + 2*32 +: 32] = lane_word[4];
        total_read_data[256 + 3*32 +: 32] = lane_word[5];
        total_read_data[256 + 4*32 +: 32] = lane_word[8];
        total_read_data[256 + 5*32 +: 32] = lane_word[9];
        total_read_data[256 + 6*32 +: 32] = lane_word[12];
        total_read_data[256 + 7*32 +: 32] = lane_word[13];

        total_read_data[0*32 +: 32] = lane_word[2];
        total_read_data[1*32 +: 32] = lane_word[3];
        total_read_data[2*32 +: 32] = lane_word[6];
        total_read_data[3*32 +: 32] = lane_word[7];
        total_read_data[4*32 +: 32] = lane_word[10];
        total_read_data[5*32 +: 32] = lane_word[11];
        total_read_data[6*32 +: 32] = lane_word[14];
        total_read_data[7*32 +: 32] = lane_word[15];
    end
end

always @(posedge clk) begin
    if (!rstn) begin
        read_stage_row_q <= 9'd0;
        read_stage_col_q <= 9'd0;
        read_stage_abs_row_base_q <= 9'd0;
    end
    else if (issue_fire) begin
        read_stage_row_q <= o_row;
        read_stage_col_q <= o_col;
        read_stage_abs_row_base_q <= read_abs_row_base;
    end
end

always @(posedge clk) begin
    if (!rstn) begin
        read_abs_row_base <= 9'd0;
        read_ping_pong_sel <= 1'b0;
        read_ctrl_pending <= 1'b0;
        read_abs_row_base_pending <= 9'd0;
        read_ping_pong_sel_pending <= 1'b0;
    end
`ifdef YOLO_REFILL_SKIP

    else if (layer_start || fill_restart_r) begin
`else
    else if (layer_start || partition_start_r) begin
`endif
        read_abs_row_base <= 9'd0;
        read_ping_pong_sel <= 1'b0;
        read_ctrl_pending <= 1'b0;
        read_abs_row_base_pending <= 9'd0;
        read_ping_pong_sel_pending <= 1'b0;
    end
    else if (swap_trigger) begin
        if (read_ctrl_freeze) begin
            read_ctrl_pending <= 1'b1;
            read_abs_row_base_pending <= fill_abs_row_base;
            read_ping_pong_sel_pending <= ~ping_pong_sel;
        end
        else begin
            read_abs_row_base <= fill_abs_row_base;
            read_ping_pong_sel <= ~ping_pong_sel;
            read_ctrl_pending <= 1'b0;
        end
    end
    else if ((state != OP || out_vaild) && read_ctrl_pending) begin
        read_abs_row_base <= read_abs_row_base_pending;
        read_ping_pong_sel <= read_ping_pong_sel_pending;
        read_ctrl_pending <= 1'b0;
    end
end

always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        compute_read_abs_row_base <= 9'd0;
        compute_ping_pong_sel <= 1'b0;
        compute_read_page_valid <= 1'b0;
    end
    else if (state != OP || out_vaild) begin
        compute_read_abs_row_base <= 9'd0;
        compute_ping_pong_sel <= 1'b0;
        compute_read_page_valid <= 1'b0;
    end
    else if (l1rd_l20_q && i_mode && issue_fire &&
             (ch_cnt_r == 8'd0) && (conv1x1_phase == 2'd0)) begin
        compute_read_abs_row_base <= read_abs_row_base;
        compute_ping_pong_sel <= read_ping_pong_sel;
        compute_read_page_valid <= 1'b1;
    end
end

always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        last_consume_seen <= 1'b0;
    end
    else if (state != OP || out_vaild) begin
        last_consume_seen <= 1'b0;
    end
    else if (L1_vaild) begin
        last_consume_seen <= ({2'd0, issue_ch_d} == mac_iter_max - 1'b1);
    end
end
always @(posedge clk) begin
    if (!rstn) begin
        issue_wet_addr_d <= 10'd0;
    end
    else if (issue_fire) begin
        issue_wet_addr_d <= WET_addr;
    end
end

always @(posedge clk or negedge rstn) begin
    if (!rstn)
        first_bank_ready <= 1'b0;
`ifdef YOLO_REFILL_SKIP

    else if (layer_start || fill_restart_r)
`else
    else if (layer_start || partition_start_r)
`endif
        first_bank_ready <= 1'b0;
    else if (swap_trigger)
        first_bank_ready <= 1'b1;
end

always @(posedge clk or negedge rstn) begin
    if (!rstn)
        pe_done_latch <= 0;
    else if (layer_start || partition_start_r)
        pe_done_latch <= 0;
    else if (swap_trigger)
        pe_done_latch <= 0;
    else if (pe_done)
        pe_done_latch <= 1;
end

always @(posedge clk or negedge rstn) begin
    if (!rstn)
        state <= IDLE;
    else if (layer_start || partition_start_r)
        state <= IDLE;
    else
        state <= n_state;
end

always @(posedge clk) begin
    if (!rstn) begin
        ch_cnt_r        <= 8'd0;
        feed_cnt        <= 8'd0;
        issue_fire_d    <= 1'b0;
        issue_ch_d      <= 8'd0;
        conv1x1_phase   <= 2'd0;
        conv1x1_phase_d <= 2'd0;
    end
`ifdef YOLO_L0_OC_BURST

`ifdef YOLO_OC_PIPELINE

`ifdef YOLO_IMODE_OCP

    else if (state != OP ||
             (out_vaild && !oc_burst_layer && !ocp_layer && !imode_ocp_layer)) begin
`else
    else if (state != OP || (out_vaild && !oc_burst_layer && !ocp_layer)) begin
`endif
`else
    else if (state != OP || (out_vaild && !oc_burst_layer)) begin
`endif
`else
    else if (state != OP || out_vaild) begin
`endif
        ch_cnt_r        <= 8'd0;
        feed_cnt        <= 8'd0;
        issue_fire_d    <= 1'b0;
        issue_ch_d      <= 8'd0;
        conv1x1_phase   <= 2'd0;
        conv1x1_phase_d <= 2'd0;
    end
    else begin
        issue_fire_d <= issue_fire;
        if (issue_fire)
            conv1x1_phase_d <= conv1x1_phase;

        if (issue_fire) begin
            if (i_mode) begin
                if (conv1x1_phase_last) begin
                    issue_ch_d    <= ch_cnt_r;
`ifdef YOLO_IMODE_OCP

                    if (imode_ocp_layer &&
                        ({2'd0, ch_cnt_r} == mac_iter_max - 10'd1))
                        ch_cnt_r <= 8'd0;
                    else
                        ch_cnt_r <= ch_cnt_r + 1'b1;
`else
                    ch_cnt_r      <= ch_cnt_r + 1'b1;
`endif
                    conv1x1_phase <= 2'd0;
                end
                else begin
                    conv1x1_phase <= conv1x1_phase + 1'b1;
                end
            end
            else begin
                issue_ch_d <= ch_cnt_r;
`ifdef YOLO_L0_OC_BURST

                if (!oc_burst_layer)
`endif
`ifdef YOLO_OC_PIPELINE
                begin

                    if (ocp_layer && ({2'd0, ch_cnt_r} == mac_iter_max - 10'd1))
                        ch_cnt_r <= 8'd0;
                    else
                        ch_cnt_r <= ch_cnt_r + 1'b1;
                end
`else
                ch_cnt_r   <= ch_cnt_r + 1'b1;
`endif
            end
        end

        if (L1_vaild)
            feed_cnt <= feed_cnt + 1'b1;
    end
end

`ifdef YOLO_L0_OC_BURST

always @(posedge clk) begin
    if (!rstn)
        issue_oc_cnt <= 10'd0;
    else if (state != OP)
        issue_oc_cnt <= 10'd0;
`ifdef YOLO_OC_PIPELINE

`ifdef YOLO_IMODE_OCP

    else if ((issue_fire && oc_burst_layer) || ocp_issue_last ||
             imode_ocp_issue_last)
        issue_oc_cnt <= issue_oc_cnt + 10'd1;
`else
    else if ((issue_fire && oc_burst_layer) || ocp_issue_last)
        issue_oc_cnt <= issue_oc_cnt + 10'd1;
`endif
`else
    else if (issue_fire && oc_burst_layer)
        issue_oc_cnt <= issue_oc_cnt + 10'd1;
`endif
end

`ifdef YOLO_IMODE_OCP

always @(posedge clk) begin
    if (!rstn)
        imode_bsc_oc_d <= 10'd0;
    else if (state != OP)
        imode_bsc_oc_d <= 10'd0;
    else
        imode_bsc_oc_d <= issue_oc_cnt;
end
`endif

`ifdef YOLO_OC_PIPELINE

always @(posedge clk) begin
    if (!rstn)
        ocp_wet_base <= 10'd0;
    else if (state != OP)
        ocp_wet_base <= wet_oc_base;
`ifdef YOLO_IMODE_OCP

    else if (ocp_issue_last || imode_ocp_issue_last)
        ocp_wet_base <= ocp_wet_base + wet_stride_words;
`else
    else if (ocp_issue_last)
        ocp_wet_base <= ocp_wet_base + wet_stride_words;
`endif
end
`endif
`endif

always @(posedge clk or negedge rstn) begin
    if (!rstn)
        prev_ofm_ch_idx <= 10'd0;
    else if (layer_start || partition_start_r)
        prev_ofm_ch_idx <= 10'd0;
    else
        prev_ofm_ch_idx <= ofm_ch_idx;
end

always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        conv1x1_valid <= 1'b0;
        conv1x1_tl    <= 128'd0;
        conv1x1_tr    <= 128'd0;
        conv1x1_bl    <= 128'd0;
        conv1x1_br    <= 128'd0;
    end
`ifdef YOLO_IMODE_OCP

    else if (state != OP || (out_vaild && !imode_ocp_layer)) begin
`else
    else if (state != OP || out_vaild) begin
`endif
        conv1x1_valid <= 1'b0;
        conv1x1_tl    <= 128'd0;
        conv1x1_tr    <= 128'd0;
        conv1x1_bl    <= 128'd0;
        conv1x1_br    <= 128'd0;
    end
    else begin
        conv1x1_valid <= 1'b0;
        if (i_mode && issue_fire_d) begin
            case (conv1x1_phase_d)
                2'd0: begin
                    conv1x1_tl[31:0]  <= lane_word[5];
                    conv1x1_tr[31:0]  <= lane_word[6];
                    conv1x1_bl[31:0]  <= lane_word[9];
                    conv1x1_br[31:0]  <= lane_word[10];
                end
                2'd1: begin
                    conv1x1_tl[63:32] <= lane_word[5];
                    conv1x1_tr[63:32] <= lane_word[6];
                    conv1x1_bl[63:32] <= lane_word[9];
                    conv1x1_br[63:32] <= lane_word[10];
                end
                2'd2: begin
                    conv1x1_tl[95:64] <= lane_word[5];
                    conv1x1_tr[95:64] <= lane_word[6];
                    conv1x1_bl[95:64] <= lane_word[9];
                    conv1x1_br[95:64] <= lane_word[10];
                end
                default: begin
                    conv1x1_tl[127:96] <= lane_word[5];
                    conv1x1_tr[127:96] <= lane_word[6];
                    conv1x1_bl[127:96] <= lane_word[9];
                    conv1x1_br[127:96] <= lane_word[10];
                    conv1x1_valid      <= 1'b1;
                end
            endcase
        end
    end
end

always @(posedge clk or negedge rstn) begin
    if (!rstn)
        i_weight_hold <= 288'd0;
    else if (i_mode && issue_fire_d && (conv1x1_phase_d == 2'd3))
        i_weight_hold <= i_weight_raw;
end

always @(posedge clk) begin
    if (!rstn)
        wet_oc_base <= 10'd0;
    else if (layer_start || partition_start_r || weight_load_start)
        wet_oc_base <= layer_wet_base;
`ifdef YOLO_L0_OC_BURST

`ifdef YOLO_OC_PIPELINE

`ifdef YOLO_IMODE_OCP

    else if (out_vaild && !oc_burst_layer && !ocp_layer && !imode_ocp_layer)
`else
    else if (out_vaild && !oc_burst_layer && !ocp_layer)
`endif
`else
    else if (out_vaild && !oc_burst_layer)
`endif
`else
    else if (out_vaild)
`endif
        wet_oc_base <= wet_oc_base_next;
end

always @(posedge clk) begin
    if (!rstn)
        pe_last_row <= 9'd0;
    else if (layer_start || partition_start_r)
        pe_last_row <= l1rd_pe_last_delta_q;
    else if (swap_trigger)
        pe_last_row <= fill_abs_row_base + l1rd_pe_last_delta_q;
end

always @(*) begin
    case (ofm_ch_idx[1:0])
        2'd0: ofm_wea = 4'b0001;
        2'd1: ofm_wea = 4'b0010;
        2'd2: ofm_wea = 4'b0100;
        2'd3: ofm_wea = 4'b1000;
        default: ofm_wea = 4'b0000;
    endcase
end

always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        ofm_pixel_cnt <= 0;
    end
    else if (layer_start || partition_start_r) begin
        ofm_pixel_cnt <= 0;
    end
    else if (all_oc_done && has_maxpool) begin
        ofm_pixel_cnt <= ofm_pixel_cnt + 1;
    end
end

always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        ofm_row_hold <= 0;
        ofm_col_hold <= 0;
    end
    else if (out_vaild && !has_maxpool) begin
        ofm_row_hold <= o_row;
        ofm_col_hold <= o_col;
    end
end

always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        ofm_pending_hold <= 32'd0;
        ofm16_pending_hold <= 64'd0;
        ofm32_pending_hold <= 128'd0;
        ofm_pending_wea <= 4'b0000;
        ofm_pending_ch_group_base <= 16'd0;
        ofm_pending_l2_output_base <= 16'd0;
        ofm_pending_wr_base <= 16'd0;
        ofm_pending_wr_col_step <= 16'd0;
        ofm_pending_wr_row_step <= 16'd0;
        ofm_pending_padded_head <= 1'b0;
        ofm_pending_width_shift <= 4'd0;
        ofm_pending_out_ch_shift <= 4'd0;
        ofm_pending_out_ch_groups <= 16'd0;
        ofm_pending_valid <= 1'b0;
    end
    else if (out_vaild && !has_maxpool && ofm_write_busy) begin
        ofm_pending_hold <= i_ofm;
        ofm16_pending_hold <= i_ofm16;
        ofm32_pending_hold <= i_ofm32;
        ofm_pending_wea <= ofm_wea_live;
        ofm_pending_ch_group_base <= ofm_ch_group_base;
        ofm_pending_l2_output_base <= ofm_l2_output_base_q;
        ofm_pending_wr_base <= ofm_wr_base_live;
        ofm_pending_wr_col_step <= ofm_wr_col_step_live;
        ofm_pending_wr_row_step <= ofm_wr_row_step_live;
        ofm_pending_padded_head <= padded_head_layer_q;
        ofm_pending_width_shift <= ofm_width_shift_q;
        ofm_pending_out_ch_shift <= out_ch_shift_q;
        ofm_pending_out_ch_groups <= ofm_out_ch_groups;
        ofm_pending_valid <= 1'b1;
    end
    else if (!wr_busy && ofm_pending_valid) begin
        ofm_pending_valid <= 1'b0;
    end
end

always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        ofm_hold   <= 0;
        ofm16_hold <= 64'd0;
        ofm32_hold <= 128'd0;
        wr_busy    <= 0;
        ofm_wr_cnt <= 0;
        ofm_wea_hold <= 4'b0000;
        ofm_ch_group_base_hold <= 16'd0;
        ofm_l2_output_base_hold <= 16'd0;
        ofm_addr_ready <= 1'b0;
        ofm_wr_base_hold <= 16'd0;
        ofm_wr_col_step_hold <= 16'd0;
        ofm_wr_row_step_hold <= 16'd0;
        padded_head_layer_hold <= 1'b0;
        ofm_width_shift_hold <= 4'd0;
        ofm_out_ch_shift_hold <= 4'd0;
        ofm_out_ch_groups_hold <= 16'd0;
    end
    else if (!wr_busy && ofm_pending_valid) begin
        ofm_hold   <= ofm_pending_hold;
        ofm16_hold <= ofm16_pending_hold;
        ofm32_hold <= ofm32_pending_hold;
        wr_busy    <= 1'b1;
        ofm_wr_cnt <= 2'd0;
        ofm_wea_hold <= ofm_pending_wea;
        ofm_ch_group_base_hold <= ofm_pending_ch_group_base;
        ofm_l2_output_base_hold <= ofm_pending_l2_output_base;
        ofm_addr_ready <= 1'b1;
        ofm_wr_base_hold <= ofm_pending_wr_base;
        ofm_wr_col_step_hold <= ofm_pending_wr_col_step;
        ofm_wr_row_step_hold <= ofm_pending_wr_row_step;
        padded_head_layer_hold <= ofm_pending_padded_head;
        ofm_width_shift_hold <= ofm_pending_width_shift;
        ofm_out_ch_shift_hold <= ofm_pending_out_ch_shift;
        ofm_out_ch_groups_hold <= ofm_pending_out_ch_groups;
    end
    else if ((layer_start || partition_start_r) && !wr_busy) begin
        ofm_hold   <= 0;
        ofm16_hold <= 64'd0;
        ofm32_hold <= 128'd0;
        wr_busy    <= 0;
        ofm_wr_cnt <= 0;
        ofm_wea_hold <= 4'b0000;
        ofm_ch_group_base_hold <= 16'd0;
        ofm_l2_output_base_hold <= 16'd0;
        ofm_addr_ready <= 1'b0;
        ofm_wr_base_hold <= 16'd0;
        ofm_wr_col_step_hold <= 16'd0;
        ofm_wr_row_step_hold <= 16'd0;
        padded_head_layer_hold <= 1'b0;
        ofm_width_shift_hold <= 4'd0;
        ofm_out_ch_shift_hold <= 4'd0;
        ofm_out_ch_groups_hold <= 16'd0;
    end
    else if (out_vaild && !has_maxpool && !ofm_write_busy) begin
        ofm_hold   <= i_ofm;
        ofm16_hold <= i_ofm16;
        ofm32_hold <= i_ofm32;
        wr_busy    <= 1'b1;
        ofm_wr_cnt <= 2'd0;
        ofm_addr_ready <= 1'b1;
        ofm_wea_hold <= ofm_wea_live;
        ofm_ch_group_base_hold <= ofm_ch_group_base;
        ofm_l2_output_base_hold <= ofm_l2_output_base_q;
        padded_head_layer_hold <= padded_head_layer_q;
        ofm_width_shift_hold <= ofm_width_shift_q;
        ofm_out_ch_shift_hold <= out_ch_shift_q;
        ofm_out_ch_groups_hold <= ofm_out_ch_groups;
        ofm_wr_base_hold <= ofm_wr_base_live;
        ofm_wr_col_step_hold <= ofm_wr_col_step_live;
        ofm_wr_row_step_hold <= ofm_wr_row_step_live;
    end
    else if (wr_busy && !ofm_addr_ready) begin
        ofm_addr_ready <= 1'b1;
        ofm_wr_base_hold <= ofm_wr_base_calc;
        ofm_wr_col_step_hold <= ofm_wr_col_step_calc;
        ofm_wr_row_step_hold <= ofm_wr_row_step_calc;
        ofm_wr_cnt <= 2'd0;
    end
    else if (wr_busy) begin
        if (ofm_wr_cnt == 2'd3) begin
            wr_busy    <= 1'b0;
            ofm_addr_ready <= 1'b0;
            ofm_wr_cnt <= 2'd0;
        end
        else begin
            ofm_wr_cnt <= ofm_wr_cnt + 1'b1;
        end
    end
end

always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        maxpool_wr_pending <= 1'b0;
        maxpool_byte_hold  <= 8'd0;
        maxpool_wea_hold   <= 4'b0000;
        maxpool_addr_hold  <= 16'd0;
    end
    else if (layer_start || partition_start_r) begin
        maxpool_wr_pending <= 1'b0;
        maxpool_byte_hold  <= 8'd0;
        maxpool_wea_hold   <= 4'b0000;
        maxpool_addr_hold  <= 16'd0;
    end
    else if (has_maxpool && out_vaild) begin
        maxpool_wr_pending <= 1'b1;
        maxpool_byte_hold  <= i_ofm[7:0];
        maxpool_wea_hold   <= ofm_wea;
        maxpool_addr_hold  <= l2_output_base + ofm_wr_addr;
    end
    else if (maxpool_wr_pending && !route8_wr_busy && !pool11_active) begin
        maxpool_wr_pending <= 1'b0;
    end
end

always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        route8_hold          <= 32'd0;
        route8_wr_busy       <= 1'b0;
        route8_l2_busy       <= 1'b0;
        route8_wr_cnt        <= 2'd0;
        route8_row_hold      <= 9'd0;
        route8_col_hold      <= 9'd0;
        route8_ch_group_hold <= 16'd0;
        route8_wea_hold      <= 4'b0000;
    end
    else if (route8_capture) begin
        route8_hold          <= i_ofm_raw;
        route8_wr_busy       <= 1'b1;
        route8_l2_busy       <= 1'b1;
        route8_wr_cnt        <= 2'd0;
        route8_row_hold      <= o_row;
        route8_col_hold      <= o_col;
        route8_ch_group_hold <= ofm_ch_group_base;
        route8_wea_hold      <= ofm_wea;
    end
    else if (route8_wr_busy) begin
        if (route8_wr_cnt == 2'd3) begin
            route8_wr_busy <= 1'b0;
            route8_l2_busy <= 1'b0;
            route8_wr_cnt  <= 2'd0;
        end
        else begin
            route8_wr_cnt <= route8_wr_cnt + 1'b1;
        end
    end
end

always @(posedge clk) begin
    if (!rstn) begin
        fill_ch  <= 0;
        fill_col <= 0;
        fill_row <= 0;
        fill_rg  <= 0;
    end
    else if (layer_start || partition_start_r || swap_trigger) begin
        fill_ch  <= 0;
        fill_col <= 0;
        fill_row <= 0;
        fill_rg  <= 0;
    end
    else if (fill_issue) begin
        if (fill_ch < fill_ch_max_m1_q) begin
            fill_ch <= fill_ch + 1;
        end
        else begin
            fill_ch <= 0;
            if (fill_col < l1rd_q_width_m1_q) begin
                fill_col <= fill_col + 1;
            end
            else begin
                fill_col <= 0;
                if (fill_row < 2'd3) begin
                    fill_row <= fill_row + 1;
                end
                else begin
                    fill_row <= 0;
                    if (fill_rg < l1rd_max_row_groups_m1_q)
                        fill_rg <= fill_rg + 1;
                end
            end
        end
    end
end

always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        fill_col_d1      <= 0;
        fill_ch_d1       <= 0;
        fill_row_d1      <= 0;
        fill_rg_d1       <= 0;
        fill_zero_row_d1 <= 1'b0;
        row_tile_vld_d1  <= 1'b0;
        fill_l2_addr_d1 <= 16'd0;
        fill_col_d2      <= 0;
        fill_ch_d2       <= 0;
        fill_row_d2      <= 0;
        fill_rg_d2       <= 0;
        fill_zero_row_d2 <= 1'b0;
        row_tile_vld_d2  <= 1'b0;
        fill_l2_addr_d2 <= 16'd0;
    end
    else if (layer_start || partition_start_r || swap_trigger) begin
        fill_col_d1      <= 0;
        fill_ch_d1       <= 0;
        fill_row_d1      <= 0;
        fill_rg_d1       <= 0;
        fill_zero_row_d1 <= 1'b0;
        row_tile_vld_d1  <= 1'b0;
        fill_l2_addr_d1 <= 16'd0;
        fill_col_d2      <= 0;
        fill_ch_d2       <= 0;
        fill_row_d2      <= 0;
        fill_rg_d2       <= 0;
        fill_zero_row_d2 <= 1'b0;
        row_tile_vld_d2  <= 1'b0;
        fill_l2_addr_d2 <= 16'd0;
    end
    else begin
        fill_col_d1      <= fill_col_d0;
        fill_ch_d1       <= fill_ch_d0;
        fill_row_d1      <= fill_row_d0;
        fill_rg_d1       <= fill_rg_d0;
        fill_zero_row_d1 <= fill_zero_row_d0;
        row_tile_vld_d1  <= row_tile_vld_d0;
        fill_l2_addr_d1 <= L2_addrb_calc;
        fill_col_d2      <= fill_col_d1;
        fill_ch_d2       <= fill_ch_d1;
        fill_row_d2      <= fill_row_d1;
        fill_rg_d2       <= fill_rg_d1;
        fill_zero_row_d2 <= fill_zero_row_d1;
        row_tile_vld_d2  <= row_tile_vld_d1;
        fill_l2_addr_d2 <= fill_l2_addr_d1;
    end
end

always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        store_addr <= 16'd0;
    end
    else if (store_mode && indata_req_wr) begin
        store_addr <= store_addr + 1;
    end
    else if (!store_mode) begin
        store_addr <= 16'd0;
    end
end

always @(posedge clk or negedge rstn) begin
    if (!rstn)
        fill_done <= 0;
    else if (layer_start || partition_start_r || swap_trigger)
        fill_done <= 0;
    else
        fill_done <= fill_last;
end

always @(posedge clk) begin
    if (!rstn)
        fill_abs_row_base <= 0;
    else if (layer_start || partition_start_r)
        fill_abs_row_base <= 0;
    else if (swap_trigger)
        fill_abs_row_base <= fill_abs_row_base + l1rd_row_span_minus2_q;
end

always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        first_fill    <= 1;
        ping_pong_sel <= 0;
    end
`ifdef YOLO_REFILL_SKIP

    else if (layer_start || fill_restart_r) begin
`else
    else if (layer_start || partition_start_r) begin
`endif
        first_fill    <= 1;
        ping_pong_sel <= 0;
    end
    else if (swap_trigger) begin
        first_fill    <= 0;
        ping_pong_sel <= ~ping_pong_sel;
    end
end

always @(*) begin
    case(ch_len)
        10'd4:   ch_shift = 3'd0;
        10'd16:  ch_shift = 3'd2;
        10'd32:  ch_shift = 3'd3;
        10'd64:  ch_shift = 3'd4;
        10'd128: ch_shift = 3'd5;
        10'd256: ch_shift = 3'd6;
        10'd512: ch_shift = 3'd7;
        default: ch_shift = 3'd0;
    endcase
end

always @(*) begin
    case (layer_id)
        5'd0:    out_ch_shift = 2;
        5'd2:    out_ch_shift = 3;
        5'd4:    out_ch_shift = 4;
        5'd6:    out_ch_shift = 5;
        5'd8:    out_ch_shift = 6;
        5'd10:   out_ch_shift = 7;
        5'd12:   out_ch_shift = 6;
        5'd13:   out_ch_shift = 7;
        5'd17:   out_ch_shift = 5;
        default: out_ch_shift = 2;
    endcase
end

always @(*) begin
    case (layer_id)
        5'd0:    layer_wet_base = 10'd0;
        5'd2:    layer_wet_base = 10'd128;
        5'd4:    layer_wet_base = 10'd512;
        default: layer_wet_base = 10'd0;
    endcase
end

always @(*) begin
`ifdef YOLO_L0_OC_BURST

    if (oc_burst_layer)
        WET_addr = wet_oc_base + issue_oc_cnt;
    else
`ifdef YOLO_OC_PIPELINE

`ifdef YOLO_IMODE_OCP

    if (ocp_layer || imode_ocp_layer)
`else
    if (ocp_layer)
`endif
        WET_addr = ocp_wet_base + {2'd0, ch_cnt};
    else
`endif
`endif
    WET_addr = wet_oc_base + {2'd0, ch_cnt};
end

always @(*) begin
    case(layer_id)
        5'd0:    begin
                rg_shift = 6;
                max_row_groups = 8;
                end
        5'd12,
        5'd14:   begin
                rg_shift = 8;
                max_row_groups = 2;
                end
        5'd20:   begin
                rg_shift = 0;
                max_row_groups = 1;
                end
        default: begin
                rg_shift = 7;
                max_row_groups = 4;
                end
    endcase
end

always @(posedge clk or negedge rstn) begin
    if (!rstn)
        fill_active <= 1'b0;
    else if (layer_start)
        fill_active <= 1'b0;
`ifdef YOLO_REFILL_SKIP

    else if (compute_begin && !refill_skip_pass)
        fill_active <= 1'b1;
`else
    else if (compute_begin)
        fill_active <= 1'b1;
`endif
    else if (swap_trigger)
        fill_active <= 1'b1;
    else if (req_last)
        fill_active <= 1'b0;
end

always @(*) begin
    bank_wea = 16'd0;
    bank_web = 16'd0;

    if (row_tile_vld) begin

        case ({fill_row_d2, fill_col_d2[1:0]})

            4'b00_00: begin if(!ping_pong_sel) bank_wea[0]  = 1; else bank_web[0]  = 1; end
            4'b00_01: begin if(!ping_pong_sel) bank_wea[1]  = 1; else bank_web[1]  = 1; end
            4'b00_10: begin if(!ping_pong_sel) bank_wea[8]  = 1; else bank_web[8]  = 1; end
            4'b00_11: begin if(!ping_pong_sel) bank_wea[9]  = 1; else bank_web[9]  = 1; end

            4'b01_00: begin if(!ping_pong_sel) bank_wea[2]  = 1; else bank_web[2]  = 1; end
            4'b01_01: begin if(!ping_pong_sel) bank_wea[3]  = 1; else bank_web[3]  = 1; end
            4'b01_10: begin if(!ping_pong_sel) bank_wea[10] = 1; else bank_web[10] = 1; end
            4'b01_11: begin if(!ping_pong_sel) bank_wea[11] = 1; else bank_web[11] = 1; end

            4'b10_00: begin if(!ping_pong_sel) bank_wea[4]  = 1; else bank_web[4]  = 1; end
            4'b10_01: begin if(!ping_pong_sel) bank_wea[5]  = 1; else bank_web[5]  = 1; end
            4'b10_10: begin if(!ping_pong_sel) bank_wea[12] = 1; else bank_web[12] = 1; end
            4'b10_11: begin if(!ping_pong_sel) bank_wea[13] = 1; else bank_web[13] = 1; end

            4'b11_00: begin if(!ping_pong_sel) bank_wea[6]  = 1; else bank_web[6]  = 1; end
            4'b11_01: begin if(!ping_pong_sel) bank_wea[7]  = 1; else bank_web[7]  = 1; end
            4'b11_10: begin if(!ping_pong_sel) bank_wea[14] = 1; else bank_web[14] = 1; end
            4'b11_11: begin if(!ping_pong_sel) bank_wea[15] = 1; else bank_web[15] = 1; end
        endcase
    end
end

always @(posedge clk or negedge rstn) begin
    if (!rstn)
        fill_done_latch <= 0;
`ifdef YOLO_REFILL_SKIP

    else if (layer_start || fill_restart_r)
`else
    else if (layer_start || partition_start_r)
`endif
        fill_done_latch <= 0;
    else if (swap_trigger)
        fill_done_latch <= 0;
    else if (fill_done)
        fill_done_latch <= 1;
end

always @(*) begin
    n_state = state;
    tile_req_ready = 0;

    case(state)
        IDLE: begin
            tile_req_ready = 1;
            if (tile_fire)
                n_state = OP;
            else
                n_state = IDLE;
        end

        OP: begin
            if (out_vaild) begin
                if (all_oc_done)
                    n_state = N_XY;
`ifdef YOLO_L0_OC_BURST

                else if (oc_burst_layer)
                    n_state = OP;
`ifdef YOLO_OC_PIPELINE

                else if (ocp_layer)
                    n_state = OP;
`ifdef YOLO_IMODE_OCP

                else if (imode_ocp_layer)
                    n_state = OP;
`endif
`endif
`endif
                else
                    n_state = N_TILE;
            end
            else
                n_state = OP;
        end

        N_TILE: begin

            if (!has_maxpool && ofm_pending_valid)
                n_state = N_TILE;
            else
                n_state = OP;
            end

        N_XY: begin
            if ((!has_maxpool && ofm_write_busy) || (has_maxpool && maxpool_wr_pending) || route8_wr_busy)
                n_state = N_XY;
            else
                n_state = IDLE;
            end

        default: n_state = IDLE;
    endcase
end

L2_buffer #(
    .DEPTH  (65536    ),
    .AW     (16 ),
    .DW     (32 ),
    .R_DW   (32),
    .AW_B   (16)
    )
L2_buffer(
    .clk	(clk		    ),
    .rstn(rstn),
    .ena	(l2_ena	),
	.addra(l2_addra),
	.doa     (l2_rdata_a),
	.wea	(l2_wea),
	.dia	(l2_dina),
    .enb    (1'd1          ),
    .addrb	(L2_addrb ),
    .dob	(row_tile     )
);

genvar i;
generate
    for (i = 0; i < 4; i = i + 1) begin : gen_fmap_bank0RT
        dpram_512x32_ u_dpram_512x32 (
            .clka(clk),
            .rstn(rstn),
            .ena(1'b1),
            .addra(L2_L1_addr),
            .addrb(pe_addr_b[i+8]),
            .dina(row_tile_in),
            .wea((!ping_pong_sel && bank_wea[i+8])),
            .clkb    (clk),
            .enb     (1'b1),
            .doutb(g0_Rrdata[i*32 +: 32])
        );
    end
endgenerate

genvar m;
generate
    for (m = 0; m < 4; m = m + 1) begin : gen_fmap_bank0RB
        dpram_512x32_ u_dpram_512x32 (
            .clka(clk),
            .rstn(rstn),
            .ena(1'b1),
            .addra(L2_L1_addr),
            .addrb(pe_addr_b[m+12]),
            .dina(row_tile_in),
            .wea((!ping_pong_sel && bank_wea[m+8+4])),
            .clkb    (clk),
            .enb     (1'b1),
            .doutb(g0_Rrdata[(m+4)*32 +: 32])
        );
    end
endgenerate

genvar k;
generate
    for (k = 0; k < 4; k = k + 1) begin : gen_fmap_bank0LT
        dpram_512x32_ u_dpram_512x32(
            .clka(clk),
            .rstn(rstn),
            .ena(1'b1),
            .addra(L2_L1_addr),
            .addrb(pe_addr_b[k]),
            .wea((!ping_pong_sel && bank_wea[k])),
            .clkb    (clk),
            .enb     (1'b1),
            .dina(row_tile_in),
            .doutb(g0_Lrdata[k*32 +: 32])
        );
    end
endgenerate

genvar o;
generate
    for (o = 0; o < 4; o = o + 1) begin : gen_fmap_bank0LB
        dpram_512x32_ u_dpram_512x32(
            .clka(clk),
            .rstn(rstn),
            .ena(1'b1),
            .addra(L2_L1_addr),
            .addrb(pe_addr_b[o+4]),
            .wea((!ping_pong_sel && bank_wea[o+4])),
            .clkb    (clk),
            .enb     (1'b1),
            .dina(row_tile_in),
            .doutb(g0_Lrdata[(o+4)*32 +: 32])
        );
    end
endgenerate

genvar j;
generate
    for (j = 0; j < 4; j = j + 1) begin : gen_fmap_banks1LT
       dpram_512x32_ u_dpram_512x32 (
            .clka(clk),
            .rstn(rstn),
            .ena(1'b1),
            .addra(L2_L1_addr),
            .addrb(pe_addr_b[j]),
            .wea((ping_pong_sel && bank_web[j])),
            .enb  (1'b1),
            .clkb    (clk),
            .dina(row_tile_in),
            .doutb(g1_Lrdata[j*32 +: 32])
        );
    end
endgenerate

genvar p;
generate
    for (p = 0; p < 4; p = p + 1) begin : gen_fmap_banks1LB
       dpram_512x32_ u_dpram_512x32 (
            .clka(clk),
            .rstn(rstn),
            .ena(1'b1),
            .addra(L2_L1_addr),
            .addrb(pe_addr_b[p+4]),
            .wea((ping_pong_sel && bank_web[p+4])),
            .enb  (1'b1),
            .clkb    (clk),
            .dina(row_tile_in),
            .doutb(g1_Lrdata[(p+4)*32 +: 32])
        );
    end
endgenerate

genvar l;
generate
    for (l = 0; l < 4; l = l + 1) begin : gen_fmap_banks1RT
        dpram_512x32_ u_dpram_512x32 (
            .clka(clk),
            .rstn(rstn),
            .addra(L2_L1_addr),
            .addrb(pe_addr_b[l+8]),
            .ena     (1'b1),
            .wea((ping_pong_sel && bank_web[l+8])),
            .enb(1'b1),
            .clkb    (clk),
            .dina(row_tile_in),
            .doutb(g1_Rrdata[l*32 +: 32])
        );
    end
endgenerate

genvar q;
generate
    for (q = 0 ; q < 4 ; q = q + 1) begin : gen_fmap_banks1RB
        dpram_512x32_ u_dpram_512x32 (
            .clka(clk),
            .rstn(rstn),
            .addra(L2_L1_addr),
            .addrb(pe_addr_b[q+12]),
            .ena     (1'b1),
            .wea((ping_pong_sel && bank_web[q+8+4])),
            .enb(1'b1),
            .clkb    (clk),
            .dina(row_tile_in),
            .doutb(g1_Rrdata[(q+4)*32 +: 32])
        );
    end
endgenerate

gbuff_param W_S_Buffer(
      .clk(clk),
      .rstn(rstn),
      .wet_wr_vld(wet_wr_vld),
      .weight_load_start(weight_load_start),
      .use_static_wet((layer_id == 5'd0) || (layer_id == 5'd2) || (layer_id == 5'd4)),
      .read_data(read_data),
      .WET_addr(wet_addr_to_gbuff),
      .bsc_addra(bsc_addr_to_gbuff),
      .bsc_douta(bsc_douta),
      .i_weight(i_weight_raw)
);

endmodule
