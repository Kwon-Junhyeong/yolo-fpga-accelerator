`timescale 1ns / 1ps
`include "yolo_build_config_h.v"

module cnn_ctrl_v2(
    clk,
    rstn,

    q_width,
    ofm_width,
    q_height,
    ofm_height,
    q_vsync_delay,
    q_hsync_delay,
    q_frame_size,
    q_start,

    o_ctrl_vsync_run,
    o_ctrl_vsync_cnt,
    o_ctrl_hsync_run,
    o_ctrl_hsync_cnt,
    o_ctrl_data_run,
    o_row,
    o_col,
    o_data_count,

    ch_done,
    L1_vaild,
    tile_req_valid,
    tile_req_ready,
    o_mode,
    ch_len,
    layer_id,
    tile_fire,

    read_done,
    write_done,
    need_dram_ifm,
    need_dram_wt,
    need_dram_wr,
    dram_ifm_addr,
    dram_ifm_size,
    dram_wt_addr,
    dram_wt_size,
    dram_ofm_addr,
    dma_start_rd,
    dma_start_wr,
    dma_addr_rd,
    dma_addr_wr,
    dma_num_rd,
    dma_num_wr,
    loading_mode,
    weight_load_start,
    network_done,
    store_mode,
    fill_done_latch,

    has_maxpool,
    ofm_ch_idx,

    o_end_frame,
    out_ch_done,
    fill_ch_max,
    all_oc_done,
    pool11_done,
    pool11_run,
    fill_col_max,
    layer_start,
    compute_begin,
    bsc_addra,
    active_oc_end_run

);

parameter W_SIZE  = 12;
parameter W_FRAME_SIZE  = 2 * W_SIZE + 1;
parameter W_DELAY = 12;

parameter T_IDLE = 0;
parameter T_RUN = 1;

input clk, rstn;
input [W_DELAY-1:0] q_vsync_delay;
input [W_DELAY-1:0] q_hsync_delay;
input [W_FRAME_SIZE-1:0] q_frame_size;
input q_start;

output reg [W_SIZE-1 :0] q_width,ofm_width ;
output reg [W_SIZE-1 :0] q_height,ofm_height;

output 					 o_ctrl_vsync_run;
output [W_DELAY-1:0]	 o_ctrl_vsync_cnt;
output 					 o_ctrl_hsync_run;
output [W_DELAY-1:0]	 o_ctrl_hsync_cnt;
output 					 o_ctrl_data_run;
output [W_SIZE-1:0] 	 o_row;
output [W_SIZE-1:0] 	 o_col;
output [W_FRAME_SIZE-1:0]o_data_count;
output layer_start;
output o_end_frame;

input ch_done,L1_vaild;
input tile_req_ready;
input fill_done_latch;

output reg [7:0] fill_ch_max;
output reg [7:0] fill_col_max;

output reg tile_req_valid;

output reg o_mode;
output reg [9:0] ch_len;

output reg [4:0] layer_id;

output tile_fire ;

input        read_done;
input        write_done;
input  pool11_done;
output pool11_run;
output reg        need_dram_ifm;
output reg        need_dram_wt;
output reg        need_dram_wr;
output reg [31:0] dram_ifm_addr;
output reg [31:0] dram_ifm_size;
output reg [31:0] dram_wt_addr;
output reg [31:0] dram_wt_size;
output reg [31:0] dram_ofm_addr;
output            dma_start_rd;
output            dma_start_wr;
output reg [31:0] dma_addr_rd;
output reg [31:0] dma_addr_wr;
output reg [31:0] dma_num_rd;
output reg [31:0] dma_num_wr;
output reg [1:0]  loading_mode;
output            weight_load_start;
output            network_done;
output store_mode;

output reg  has_maxpool;
output reg [9:0] ofm_ch_idx;
output all_oc_done;
output [11:0] bsc_addra;
output reg [9: 0] out_ch_done;
output compute_begin;

output [9:0] active_oc_end_run;

localparam		ST_IDLE 	= 2'b00,
				ST_VSYNC	= 2'b01,
				ST_HSYNC	= 2'b10,
				ST_DATA		= 2'b11;

localparam S_IDLE      = 3'd0;
localparam S_LOAD_IFM  = 3'd1;
localparam S_LOAD_WT   = 3'd2;
localparam S_COMPUTE   = 3'd3;
localparam S_STORE_OFM = 3'd4;
localparam S_NEXT_LAYER= 3'd5;
localparam S_POOL11    = 3'd6;

localparam [31:0] DRAM_IFM_BASE   = 32'd0;
localparam [31:0] DRAM_W6_BASE    = 32'd262144;
localparam [31:0] DRAM_W8_BASE    = 32'd360448;
localparam [31:0] DRAM_W10_BASE   = 32'd753664;
localparam [31:0] DRAM_W12_BASE   = 32'd2326528;
localparam [31:0] DRAM_W13_BASE   = 32'd2719744;
localparam [31:0] DRAM_W14_BASE   = 32'd4292608;
localparam [31:0] DRAM_W17_BASE   = 32'd4592128;
localparam [31:0] DRAM_W20_BASE   = 32'd4690432;
localparam [31:0] DRAM_OUT14_BASE = 32'd4915072;
localparam [31:0] DRAM_OUT20_HEAD32_BASE = 32'd4964992;
localparam [31:0] DRAM_OUT20_HEAD16_BASE = 32'd4940160;

reg [1:0] cstate, nstate;
reg 				ctrl_vsync_run;
reg [W_DELAY-1:0]	ctrl_vsync_cnt;
reg 				ctrl_hsync_run;
reg [W_DELAY-1:0]	ctrl_hsync_cnt;
reg 				ctrl_data_run;
reg [W_SIZE-1:0] 	row;
reg [W_SIZE-1:0] 	col;
reg [W_FRAME_SIZE-1:0] data_count;
wire end_frame;
wire last_tile;

reg [1:0] T_state,T_N_state;

reg [9:0] out_ch;
reg [4:0] next_layer_id;

reg [2:0] main_state, main_nstate;
reg [31:0] wt_offset;
reg [31:0] per_load_wt_words,last_load_wt_words;
reg [31:0] dram_ofm_size;
reg [9:0]  out_ch_per_load;
reg [9:0]  store_out_ch_start;
reg [9:0]  store_out_ch_count;

wire advance_fire;
wire line_done;
wire last_tile_calc;
reg  last_tile_r;
reg  [W_FRAME_SIZE-1:0] frame_last_idx_q;
reg  [W_FRAME_SIZE-1:0] next_frame_last_idx;

reg [11:0] bsc_base_acc;

wire partition_done;

wire [10:0] active_out_ch_end_ext;
wire [9:0]  active_out_ch_end;
reg  [9:0]  active_out_ch_end_run;
wire        oc_last_in_partition;
wire [10:0] active_out_ch_sum;
wire        last_load;
reg         compute_done_pending;
reg         compute_more_pending;
reg         compute_pool_pending;
wire        head_output_layer;
wire        head32_partition_store;
wire        store_more_partition;
wire [31:0] head32_plane_words;
wire [31:0] head32_store_word_offset;
wire [31:0] head32_store_words;

assign pool11_run = (main_state == S_POOL11);
assign active_oc_end_run = active_out_ch_end_run;

assign active_out_ch_sum =  {1'b0, out_ch_done} + {1'b0, out_ch_per_load};

assign active_out_ch_end_ext =({1'b0, out_ch_done} + {1'b0, out_ch_per_load} >= {1'b0, out_ch}) ?{1'b0, out_ch} : ({1'b0, out_ch_done} + {1'b0, out_ch_per_load});

assign active_out_ch_end =(active_out_ch_sum >= {1'b0, out_ch}) ?out_ch : active_out_ch_sum[9:0];

assign oc_last_in_partition = ctrl_data_run && ch_done && (active_out_ch_end_run != 10'd0) && (ofm_ch_idx == active_out_ch_end_run - 10'd1);
assign head_output_layer = (layer_id == 5'd14) || (layer_id == 5'd20);
`ifdef YOLO_HEAD32_PARTITION_DDR
assign head32_partition_store = head_output_layer;
`else
assign head32_partition_store = 1'b0;
`endif
assign store_more_partition = ({1'b0, store_out_ch_start} + {1'b0, store_out_ch_count}) < {1'b0, out_ch};
assign head32_plane_words = (layer_id == 5'd20) ? 32'd256 : 32'd64;
assign head32_store_word_offset = (layer_id == 5'd20) ? ({22'd0, store_out_ch_start} << 8) :
                                                        ({22'd0, store_out_ch_start} << 6);
assign head32_store_words = (layer_id == 5'd20) ? ({22'd0, store_out_ch_count} << 8) :
                                                  ({22'd0, store_out_ch_count} << 6);

assign all_oc_done = oc_last_in_partition;
assign end_frame    = advance_fire && last_tile;
assign partition_done = (main_state == S_COMPUTE) && end_frame;

assign compute_begin = (main_state != S_COMPUTE && main_nstate == S_COMPUTE);
assign bsc_addra = bsc_base_acc + ofm_ch_idx;
assign tile_fire = tile_req_ready && tile_req_valid;
assign last_tile_calc = (data_count == frame_last_idx_q);
assign last_tile = last_tile_r;

assign advance_fire = all_oc_done;
assign line_done    = advance_fire && (col == q_width - 2);

assign store_mode = (main_state == S_STORE_OFM);

assign network_done = (main_state == S_NEXT_LAYER && layer_id == 5'd20);

assign layer_start = (main_state == S_NEXT_LAYER) || (main_state == S_IDLE && q_start);

assign weight_load_start = (main_state == S_LOAD_WT && main_nstate == S_COMPUTE);

assign dma_start_rd = (main_state == S_IDLE && main_nstate == S_LOAD_IFM && need_dram_ifm) || (main_state != S_LOAD_WT && main_nstate == S_LOAD_WT && need_dram_wt);

`ifdef YOLO_L0_IFM_OVERLAP

reg ifm_dma_overlap_active;
always @(posedge clk or negedge rstn) begin
    if (!rstn)
        ifm_dma_overlap_active <= 1'b0;
    else if (main_state == S_IDLE && main_nstate == S_LOAD_IFM && need_dram_ifm)
        ifm_dma_overlap_active <= 1'b1;
    else if (read_done)
        ifm_dma_overlap_active <= 1'b0;
end
`endif
`ifdef YOLO_WT_STREAM

reg        wt_dma_stream_active;
reg [1:0]  wt_read_done_d;
reg        store_done_pending;

wire       wt_more_target_load = (active_out_ch_end < out_ch) && !head32_partition_store;

always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        wt_dma_stream_active <= 1'b0;
        wt_read_done_d       <= 2'b00;
    end
    else begin
        wt_read_done_d <= {wt_read_done_d[0], wt_dma_stream_active && read_done};
        if (main_state != S_LOAD_WT && main_nstate == S_LOAD_WT && need_dram_wt)
            wt_dma_stream_active <= 1'b1;
        else if (main_state == S_NEXT_LAYER)
            wt_dma_stream_active <= 1'b0;
        else if (wt_read_done_d[1])
            wt_dma_stream_active <= 1'b0;
    end
end

always @(posedge clk or negedge rstn) begin
    if (!rstn)
        store_done_pending <= 1'b0;
    else if (main_state != S_STORE_OFM)
        store_done_pending <= 1'b0;
    else if (write_done)
        store_done_pending <= 1'b1;
end
`endif
`ifdef YOLO_STORE_OVERLAP

reg        store_dma_active;
reg [1:0]  store_write_done_d;

always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        store_dma_active   <= 1'b0;
        store_write_done_d <= 2'b00;
    end
    else begin
        store_write_done_d <= {store_write_done_d[0], store_dma_active && write_done};
        if (dma_start_wr)
            store_dma_active <= 1'b1;
        else if (store_write_done_d[1])
            store_dma_active <= 1'b0;
    end
end
`endif
assign last_load = (active_out_ch_sum >= {1'b0, out_ch});
assign dma_start_wr = (main_state != S_STORE_OFM && main_nstate == S_STORE_OFM && need_dram_wr);

always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        ofm_ch_idx <= 10'd0;
    end
    else if (main_state == S_NEXT_LAYER) begin
        ofm_ch_idx <= 10'd0;
    end
    else if (weight_load_start) begin

        ofm_ch_idx <= out_ch_done;
    end
    else if (ctrl_data_run && ch_done) begin
        if (ofm_ch_idx >= active_out_ch_end_run - 10'd1) begin
            if (last_tile)
                ofm_ch_idx <= active_out_ch_end_run;
            else
                ofm_ch_idx <= out_ch_done;
        end
        else begin
            ofm_ch_idx <= ofm_ch_idx + 10'd1;
        end
    end
end

always @(posedge clk or negedge rstn) begin
    if (!rstn)
        active_out_ch_end_run <= 10'd0;
    else if (main_state == S_NEXT_LAYER)
        active_out_ch_end_run <= 10'd0;
    else if (weight_load_start)
        active_out_ch_end_run <= active_out_ch_end;
end

always @(posedge clk or negedge rstn) begin
    if (!rstn)
        bsc_base_acc <= 0;
    else if (main_state == S_NEXT_LAYER)
        bsc_base_acc <= bsc_base_acc + out_ch;
end

always @(posedge clk or negedge rstn) begin
    if (!rstn)
        main_state <= S_IDLE;
    else
        main_state <= main_nstate;
end

always @(posedge clk or negedge rstn) begin
    if (!rstn)
        out_ch_done <= 10'd0;
    else begin
        if (main_state == S_NEXT_LAYER)
            out_ch_done <= 10'd0;
        else if (partition_done)
            out_ch_done <= active_out_ch_end;
    end
end

always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        store_out_ch_start <= 10'd0;
        store_out_ch_count <= 10'd0;
    end
    else if (main_state == S_NEXT_LAYER) begin
        store_out_ch_start <= 10'd0;
        store_out_ch_count <= 10'd0;
    end
    else if (partition_done) begin
        store_out_ch_start <= out_ch_done;
        store_out_ch_count <= active_out_ch_end - out_ch_done;
    end
end

always @(posedge clk or negedge rstn) begin
    if (!rstn)
        wt_offset <= 32'd0;
    else if (main_state == S_NEXT_LAYER)
        wt_offset <= 32'd0;
    else if (partition_done && (active_out_ch_end < out_ch))
        wt_offset <= wt_offset + (per_load_wt_words << 2);
end
always @(*) begin
    dma_addr_wr = 32'd0;
    dma_num_wr  = 32'd0;
    if (main_state == S_STORE_OFM) begin
        if (head32_partition_store) begin
            dma_addr_wr = dram_ofm_addr + (head32_store_word_offset << 2);
            dma_num_wr  = head32_store_words;
        end
        else begin
            dma_addr_wr = dram_ofm_addr;
            dma_num_wr  = dram_ofm_size;
        end
    end
end

always @(*) begin
    dma_addr_rd = 32'd0;
    dma_num_rd  = 32'd0;
    case (main_state)
        S_LOAD_IFM: begin
            dma_addr_rd = dram_ifm_addr;
            dma_num_rd  = dram_ifm_size;
        end
        S_LOAD_WT: begin
            dma_addr_rd = dram_wt_addr + wt_offset;
            dma_num_rd  = last_load ? last_load_wt_words : per_load_wt_words;
        end
    endcase
end

always @(*) begin
    case (main_state)
        S_LOAD_IFM: loading_mode = 2'd0;
`ifdef YOLO_L0_IFM_OVERLAP
        S_LOAD_WT:  loading_mode = ifm_dma_overlap_active ? 2'd0 : 2'd1;
`else
        S_LOAD_WT:  loading_mode = 2'd1;
`endif
`ifdef YOLO_WT_STREAM

        default:    loading_mode = wt_dma_stream_active ? 2'd1 : 2'd0;
`else
        default:    loading_mode = 2'd0;
`endif
    endcase
end

always @(*) begin
    main_nstate = main_state;
    case (main_state)
        S_IDLE: begin
`ifdef YOLO_WT_STREAM

            if (q_start && !wt_dma_stream_active)
`else
            if (q_start)
`endif
                main_nstate = S_LOAD_IFM;
        end
        S_LOAD_IFM: begin
`ifdef YOLO_WT_STREAM

            if (wt_dma_stream_active)
                main_nstate = S_LOAD_IFM;
            else if (!need_dram_ifm)
                main_nstate = S_LOAD_WT;
`else
            if (!need_dram_ifm)
                main_nstate = S_LOAD_WT;
`endif
`ifdef YOLO_L0_IFM_OVERLAP

            else
                main_nstate = S_LOAD_WT;
`else
            else if (read_done)
                main_nstate = S_LOAD_WT;
`endif
        end
        S_LOAD_WT: begin
            if (!need_dram_wt)
                main_nstate = S_COMPUTE;
`ifdef YOLO_WT_STREAM

            else
                main_nstate = S_COMPUTE;
`else
            else if (read_done)
                main_nstate = S_COMPUTE;
`endif
        end
        S_COMPUTE: begin
            if (end_frame && tile_req_ready) begin
                if (active_out_ch_end < out_ch) begin
`ifdef YOLO_STORE_OVERLAP

                    if (head32_partition_store) begin
                        if (!store_dma_active)
                            main_nstate = S_STORE_OFM;
                    end
                    else if (!wt_dma_stream_active)
                        main_nstate = S_LOAD_WT;
`else
`ifdef YOLO_WT_STREAM

                    if (head32_partition_store)
                        main_nstate = S_STORE_OFM;
                    else if (!wt_dma_stream_active)
                        main_nstate = S_LOAD_WT;
`else
                    main_nstate = head32_partition_store ? S_STORE_OFM : S_LOAD_WT;
`endif
`endif
                end
                else if (layer_id == 5'd10)
                    main_nstate = S_POOL11;
`ifdef YOLO_STORE_OVERLAP

                else if (!store_dma_active)
                    main_nstate = S_STORE_OFM;
`else
                else
                    main_nstate = S_STORE_OFM;
`endif
            end
            else if (compute_done_pending && tile_req_ready) begin
                if (compute_more_pending) begin
`ifdef YOLO_STORE_OVERLAP
                    if (head32_partition_store) begin
                        if (!store_dma_active)
                            main_nstate = S_STORE_OFM;
                    end
                    else if (!wt_dma_stream_active)
                        main_nstate = S_LOAD_WT;
`else
`ifdef YOLO_WT_STREAM
                    if (head32_partition_store)
                        main_nstate = S_STORE_OFM;
                    else if (!wt_dma_stream_active)
                        main_nstate = S_LOAD_WT;
`else
                    main_nstate = head32_partition_store ? S_STORE_OFM : S_LOAD_WT;
`endif
`endif
                end
                else if (compute_pool_pending)
                    main_nstate = S_POOL11;
`ifdef YOLO_STORE_OVERLAP
                else if (!store_dma_active)
                    main_nstate = S_STORE_OFM;
`else
                else
                    main_nstate = S_STORE_OFM;
`endif
            end
        end
        S_POOL11: begin
            if (pool11_done)
                main_nstate = S_NEXT_LAYER;
        end
                S_STORE_OFM: begin
            if (!need_dram_wr && tile_req_ready)
                main_nstate = S_NEXT_LAYER;
`ifdef YOLO_STORE_OVERLAP

            else if (head32_partition_store && store_more_partition) begin
                if (!wt_dma_stream_active)
                    main_nstate = S_LOAD_WT;
            end
            else if (write_done || store_done_pending)
                main_nstate = S_NEXT_LAYER;
`else
`ifdef YOLO_WT_STREAM
            else if (write_done || store_done_pending) begin
                if (head32_partition_store && store_more_partition) begin

                    if (!wt_dma_stream_active)
                        main_nstate = S_LOAD_WT;
                end
                else
                    main_nstate = S_NEXT_LAYER;
            end
`else
            else if (write_done) begin
                if (head32_partition_store && store_more_partition)
                    main_nstate = S_LOAD_WT;
                else
                    main_nstate = S_NEXT_LAYER;
            end
`endif
`endif
        end
        S_NEXT_LAYER: begin
            if (layer_id == 5'd20)
                main_nstate = S_IDLE;
            else
                main_nstate = S_LOAD_IFM;
            end
    endcase
end

always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        compute_done_pending <= 1'b0;
        compute_more_pending <= 1'b0;
        compute_pool_pending <= 1'b0;
    end
    else if (main_state != S_COMPUTE) begin
        compute_done_pending <= 1'b0;
        compute_more_pending <= 1'b0;
        compute_pool_pending <= 1'b0;
    end
    else if (end_frame) begin
`ifdef YOLO_STORE_OVERLAP

        compute_done_pending <= !tile_req_ready ||
                                (wt_dma_stream_active && wt_more_target_load) ||
                                (store_dma_active && head32_partition_store);
`else
`ifdef YOLO_WT_STREAM

        compute_done_pending <= !tile_req_ready ||
                                (wt_dma_stream_active && wt_more_target_load);
`else
        compute_done_pending <= !tile_req_ready;
`endif
`endif
        compute_more_pending <= (active_out_ch_end < out_ch);
        compute_pool_pending <= (layer_id == 5'd10);
    end
end

always@(posedge clk, negedge rstn)
begin
        if(!rstn) begin
            T_state <= T_IDLE;
        end
        else begin
            T_state <= T_N_state;
        end
end

always @(posedge clk or negedge rstn) begin
    if (!rstn)
        layer_id <= 5'd0;
    else if (main_state == S_NEXT_LAYER)
        layer_id <= next_layer_id;
end

always @(posedge clk or negedge rstn) begin
    if (!rstn)
        frame_last_idx_q <= 25'd16383;
    else if (main_state == S_IDLE && q_start)
        frame_last_idx_q <= 25'd16383;
    else if (main_state == S_NEXT_LAYER)
        frame_last_idx_q <= next_frame_last_idx;
end

always @(posedge clk or negedge rstn) begin
    if (!rstn)
        last_tile_r <= 1'b0;
    else
        last_tile_r <= last_tile_calc;
end

always @(*) begin
    T_N_state = T_state;
    tile_req_valid = 1'b0;

    case (T_state)
        T_IDLE: begin
            if (cstate == ST_DATA && !compute_done_pending) begin
                tile_req_valid = 1'b1;
                if (tile_fire)
                    T_N_state = T_RUN;
                else
                    T_N_state = T_IDLE;
            end
            else begin
                T_N_state = T_IDLE;
            end
        end

        T_RUN: begin
            tile_req_valid = 1'b0;
            if (all_oc_done)
                T_N_state = T_IDLE;
            else
                T_N_state = T_RUN;
        end

        default: begin
            T_N_state = T_IDLE;
            tile_req_valid = 1'b0;
        end
    endcase
end

always @(*) begin
    need_dram_ifm = 1'b0;
    need_dram_wt  = 1'b0;
    need_dram_wr  = 1'b0;
    dram_ifm_addr = 32'd0;
    dram_ifm_size = 32'd0;
    dram_wt_addr  = 32'd0;
    dram_wt_size  = 32'd0;
    dram_ofm_addr = 32'd0;
    out_ch_per_load = 10'd1;
    dram_ofm_size = 32'd0;
    per_load_wt_words = 32'd0;
    last_load_wt_words = 32'd0;
    o_mode      = 1'b0;

    case (layer_id)
        5'd0: begin
            ch_len      = 10'd4;
            out_ch      = 10'd16;
            fill_ch_max = 8'd1;
            q_width     = 12'd256;
            ofm_width   = 12'd128;
            ofm_height  = 12'd128;
            q_height    = 12'd256;
            fill_col_max= 8'd64;
            o_mode      = 1'b0;

            need_dram_ifm = 1'b1;
            need_dram_wt  = 1'b0;
            need_dram_wr  = 1'b0;
            dram_ifm_addr = DRAM_IFM_BASE;
            dram_ifm_size = 32'd65536;
            dram_wt_addr  = 32'd0;
            dram_wt_size  = 32'd0;
            dram_ofm_addr = 32'd0;
            out_ch_per_load = 10'd16;
            per_load_wt_words = 32'd432;
            last_load_wt_words = 32'd432;
            has_maxpool = 1'b1;

        end
        5'd2: begin
            ch_len      = 10'd16;
            out_ch      = 10'd32;
            fill_ch_max = 8'd4;
            q_width     = 12'd128;
            ofm_width   = 12'd64;
            ofm_height  = 12'd64;
            q_height    = 12'd128;
            fill_col_max= 8'd32;
            o_mode      = 1'b0;
            out_ch_per_load = 10'd32;
            per_load_wt_words = 32'd4608;
            last_load_wt_words = 32'd4608;
            has_maxpool = 1'b1;

        end
        5'd4: begin
            ch_len      = 10'd32;
            out_ch      = 10'd64;
            fill_ch_max = 8'd8;
            q_width     = 12'd64;
            q_height    = 12'd64;
            ofm_width   = 12'd32;
            ofm_height  = 12'd32;
            fill_col_max= 8'd16;
            o_mode      = 1'b0;
            out_ch_per_load = 10'd64;
            per_load_wt_words = 32'd18432;
            last_load_wt_words = 32'd18432;
            has_maxpool = 1'b1;

        end
        5'd6: begin
            ch_len      = 10'd64;
            out_ch      = 10'd128;
            fill_ch_max = 8'd16;
            q_width     = 12'd32;
            q_height    = 12'd32;
            ofm_width   = 12'd16;
            ofm_height  = 12'd16;
            fill_col_max= 8'd8;
            o_mode      = 1'b0;

            need_dram_ifm = 1'b0;
            need_dram_wt  = 1'b1;
            need_dram_wr  = 1'b0;
            dram_ifm_addr = 32'd0;
            dram_ifm_size = 32'd0;
            dram_wt_addr  = DRAM_W6_BASE;
            dram_wt_size  = 32'd24576;
            dram_ofm_addr = 32'd0;
            out_ch_per_load = 10'd64;
            per_load_wt_words = 32'd12288;
            last_load_wt_words = 32'd12288;
            has_maxpool = 1'b1;

        end
        5'd8: begin
            ch_len      = 10'd128;
            out_ch      = 10'd256;
            fill_ch_max = 8'd32;
            q_width     = 12'd16;
            q_height    = 12'd16;
            ofm_width   = 12'd8;
            ofm_height  = 12'd8;
            fill_col_max= 8'd4;
            o_mode      = 1'b0;

            need_dram_ifm = 1'b0;
            need_dram_wt  = 1'b1;
            need_dram_wr  = 1'b0;
            dram_ifm_addr = 32'd0;
            dram_ifm_size = 32'd0;
            dram_wt_addr  = DRAM_W8_BASE;
            dram_wt_size  = 32'd98304;
            dram_ofm_addr = 32'd0;
            out_ch_per_load = 10'd32;
            per_load_wt_words = 32'd12288;
            last_load_wt_words = 32'd12288;
            has_maxpool = 1'b1;

        end
        5'd10: begin
            ch_len      = 10'd256;
            out_ch      = 10'd512;
            fill_ch_max = 8'd64;
            q_width     = 12'd8;
            q_height    = 12'd8;
            ofm_width   = 12'd8;
            ofm_height  = 12'd8;
            fill_col_max= 8'd2;
            o_mode      = 1'b0;

            need_dram_ifm = 1'b0;
            need_dram_wt  = 1'b1;
            need_dram_wr  = 1'b0;
            dram_ifm_addr = 32'd0;
            dram_ifm_size = 32'd0;
            dram_wt_addr  = DRAM_W10_BASE;
            dram_wt_size  = 32'd393216;
            dram_ofm_addr = 32'd0;
            out_ch_per_load = 10'd16;
            per_load_wt_words = 32'd12288;
            last_load_wt_words = 32'd12288;
            has_maxpool = 1'b0;
        end
        5'd12: begin
            ch_len      = 10'd512;
            out_ch      = 10'd256;
            fill_ch_max = 8'd128;
            q_width     = 12'd8;
            q_height    = 12'd8;
            ofm_width   = 12'd8;
            ofm_height  = 12'd8;
            fill_col_max= 8'd2;
            o_mode      = 1'b1;

            need_dram_ifm = 1'b0;
            need_dram_wt  = 1'b1;
            need_dram_wr  = 1'b0;
            dram_ifm_addr = 32'd0;
            dram_ifm_size = 32'd0;
            dram_wt_addr  = DRAM_W12_BASE;
            dram_wt_size  = 32'd98304;
            dram_ofm_addr = 32'd0;
            out_ch_per_load = 10'd32;
            per_load_wt_words = 32'd12288;
            last_load_wt_words = 32'd12288;
            has_maxpool = 1'b0;
        end
        5'd13: begin
            ch_len      = 10'd256;
            out_ch      = 10'd512;
            fill_ch_max = 8'd64;
            q_width     = 12'd8;
            q_height    = 12'd8;
            ofm_width   = 12'd8;
            ofm_height  = 12'd8;
            fill_col_max= 8'd2;
            dram_wt_size  = 32'd393216;

            need_dram_ifm = 1'b0;
            need_dram_wt  = 1'b1;
            need_dram_wr  = 1'b0;
            dram_ifm_addr = 32'd0;
            dram_ifm_size = 32'd0;
            dram_wt_addr  = DRAM_W13_BASE;
            dram_wt_size  = 32'd393216;
            dram_ofm_addr = 32'd0;
            out_ch_per_load = 10'd16;
            per_load_wt_words = 32'd12288;
            last_load_wt_words = 32'd12288;
            has_maxpool = 1'b0;
        end
        5'd14: begin
            ch_len      = 10'd512;
            out_ch      = 10'd195;
            fill_ch_max = 8'd128;
            q_width     = 12'd8;
            q_height    = 12'd8;
            ofm_width   = 12'd8;
            ofm_height  = 12'd8;
            fill_col_max= 8'd2;
            o_mode      = 1'b1;

            need_dram_ifm = 1'b0;
            need_dram_wt  = 1'b1;
            need_dram_wr  = 1'b1;
            dram_ifm_addr = 32'd0;
            dram_ifm_size = 32'd0;
            dram_wt_addr  = DRAM_W14_BASE;
            dram_wt_size  = 32'd74880;
            dram_ofm_addr = DRAM_OUT14_BASE;
            out_ch_per_load = 10'd32;
            per_load_wt_words = 32'd12288;
            last_load_wt_words = 32'd1152;
`ifdef YOLO_HEAD32_PARTITION_DDR
            dram_ofm_size = 32'd12480;
`else
            dram_ofm_size = 32'd6272;
`endif
            has_maxpool = 1'b0;
        end
        5'd17: begin
            ch_len      = 10'd256;
            out_ch      = 10'd128;
            fill_ch_max = 8'd64;
            q_width     = 12'd8;
            q_height    = 12'd8;
            ofm_width   = 12'd8;
            ofm_height  = 12'd8;
            fill_col_max= 8'd2;
            o_mode      = 1'b1;

            need_dram_ifm = 1'b0;
            need_dram_wt  = 1'b1;
            need_dram_wr  = 1'b0;
            dram_ifm_addr = 32'd0;
            dram_ifm_size = 32'd0;
            dram_wt_addr  = DRAM_W17_BASE;
            dram_wt_size  = 32'd24576;
            dram_ofm_addr = 32'd0;
            out_ch_per_load = 10'd64;
            per_load_wt_words = 32'd12288;
            last_load_wt_words = 32'd12288;
            has_maxpool = 1'b0;
        end
        5'd20: begin
            ch_len      = 10'd384;
            out_ch      = 10'd195;
            fill_ch_max = 8'd96;
            q_width     = 12'd16;
            q_height    = 12'd16;
            ofm_width   = 12'd16;
            ofm_height  = 12'd16;
            fill_col_max= 8'd4;
            o_mode      = 1'b1;

            need_dram_ifm = 1'b0;
            need_dram_wt  = 1'b1;
            need_dram_wr  = 1'b1;
            dram_ifm_addr = 32'd0;
            dram_ifm_size = 32'd0;
            dram_wt_addr  = DRAM_W20_BASE;
            dram_wt_size  = 32'd56160;
`ifdef YOLO_HEAD32_PARTITION_DDR
            dram_ofm_addr = DRAM_OUT20_HEAD32_BASE;
`else
            dram_ofm_addr = DRAM_OUT20_HEAD16_BASE;
`endif
            out_ch_per_load = 10'd32;
            per_load_wt_words = 32'd9216;
            last_load_wt_words = 32'd864;
`ifdef YOLO_HEAD32_PARTITION_DDR
            dram_ofm_size = 32'd49920;
`else
            dram_ofm_size = 32'd25088;
`endif
            has_maxpool = 1'b0;
        end
        default: begin
            ch_len      = 10'd0;
            out_ch      = 10'd0;
            fill_ch_max = 8'd0;
            q_width     = 12'd0;
            q_height    = 12'd0;
            ofm_width   = 12'd0;
            ofm_height  = 12'd0;
            fill_col_max= 8'd0;
            o_mode      = 1'b0;

            need_dram_ifm = 1'b0;
            need_dram_wt  = 1'b0;
            need_dram_wr  = 1'b0;
            dram_ifm_addr = 32'd0;
            dram_ifm_size = 32'd0;
            dram_wt_addr  = 32'd0;
            dram_wt_size  = 32'd0;
            dram_ofm_addr = 32'd0;
            out_ch_per_load = 10'd1;
            dram_ofm_size = 32'd0;
            per_load_wt_words = 32'd0;
            last_load_wt_words = 32'd0;
            has_maxpool = 1'b0;

        end
    endcase
end

always @(*) begin
    case (layer_id)
        5'd0:  next_layer_id = 5'd2;
        5'd2:  next_layer_id = 5'd4;
        5'd4:  next_layer_id = 5'd6;
        5'd6:  next_layer_id = 5'd8;
        5'd8:  next_layer_id = 5'd10;
        5'd10: next_layer_id = 5'd12;
        5'd12: next_layer_id = 5'd13;
        5'd13: next_layer_id = 5'd14;
        5'd14: next_layer_id = 5'd17;
        5'd17: next_layer_id = 5'd20;
        5'd20: next_layer_id = 5'd0;
        default: next_layer_id = 5'd0;
    endcase
end

always @(*) begin
    case (next_layer_id)
        5'd0:  next_frame_last_idx = 25'd16383;
        5'd2:  next_frame_last_idx = 25'd4095;
        5'd4:  next_frame_last_idx = 25'd1023;
        5'd6:  next_frame_last_idx = 25'd255;
        5'd8:  next_frame_last_idx = 25'd63;
        5'd10: next_frame_last_idx = 25'd15;
        5'd12: next_frame_last_idx = 25'd15;
        5'd13: next_frame_last_idx = 25'd15;
        5'd14: next_frame_last_idx = 25'd15;
        5'd17: next_frame_last_idx = 25'd15;
        5'd20: next_frame_last_idx = 25'd63;
        default: next_frame_last_idx = 25'd0;
    endcase
end

always@(posedge clk, negedge rstn)
begin
    if(!rstn) begin
        cstate <= ST_IDLE;
    end
    else if (main_state != S_COMPUTE) begin
        cstate <= ST_IDLE;
    end
    else begin
        cstate <= nstate;
    end
end

always @(*) begin
    case(cstate)
		ST_IDLE: begin
			if(main_state == S_COMPUTE && !compute_done_pending)
				nstate = ST_VSYNC;
			else
				nstate = ST_IDLE;
        end
        ST_VSYNC: begin
        if (fill_done_latch)
            nstate = ST_HSYNC;
        else
            nstate = ST_VSYNC;
        end
        ST_HSYNC: begin
			if(ctrl_hsync_cnt == q_hsync_delay)
				nstate = ST_DATA;
			else
				nstate = ST_HSYNC;
        end
        ST_DATA: begin
            if (end_frame)
                nstate = ST_IDLE;
            else if (line_done)
                nstate = ST_HSYNC;
            else
                nstate = ST_DATA;
        end
        default: nstate = ST_IDLE;
    endcase
end

always @(*) begin
	ctrl_vsync_run = 0;
	ctrl_hsync_run = 0;
	ctrl_data_run  = 0;
	case(cstate)
		ST_VSYNC: 	begin ctrl_vsync_run = 1; end
		ST_HSYNC: 	begin ctrl_hsync_run = 1; end
		ST_DATA: 	begin ctrl_data_run  = 1; end
	endcase
end

always@(posedge clk, negedge rstn)
begin
    if(!rstn) begin
        ctrl_vsync_cnt <= 0;
		ctrl_hsync_cnt <= 0;
    end
    else begin
        if(ctrl_vsync_run)
			ctrl_vsync_cnt <= ctrl_vsync_cnt + 1;
		else
			ctrl_vsync_cnt <= 0;

        if(ctrl_hsync_run)
			ctrl_hsync_cnt <= ctrl_hsync_cnt + 1;
		else
			ctrl_hsync_cnt <= 0;
    end
end

always@(posedge clk, negedge rstn)
begin
    if(!rstn) begin
        row <= 0;
		col <= 0;
    end
	else begin
		if(ctrl_data_run) begin
			if(col == q_width - 2 && all_oc_done == 1) begin
				if(end_frame)
					row <= 0;
				else if(all_oc_done == 1)
					row <= row + 2;
			end
			if(col == q_width - 2 && all_oc_done == 1)
				col <= 0;
			else if(all_oc_done == 1)
				col <= col + 2;
		end
	end
end

always@(posedge clk, negedge rstn)
begin
    if(!rstn) begin
        data_count <= 0;
    end
    else begin
        if(ctrl_data_run) begin
			if(!end_frame && all_oc_done)
				data_count <= data_count + 1;
			else if(!end_frame) data_count <= data_count;
			else if(end_frame && all_oc_done) data_count <= 0;
			else data_count <= data_count;
		end
    end
end

assign o_ctrl_vsync_run = ctrl_vsync_run;
assign o_ctrl_vsync_cnt = ctrl_vsync_cnt;
assign o_ctrl_hsync_run = ctrl_hsync_run;
assign o_ctrl_hsync_cnt = ctrl_hsync_cnt;
assign o_ctrl_data_run  = ctrl_data_run ;
assign o_row = row;
assign o_col = col;
assign o_data_count = data_count;
assign o_end_frame = end_frame;
endmodule
