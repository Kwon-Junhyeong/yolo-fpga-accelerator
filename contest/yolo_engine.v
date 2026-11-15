//----------------------------------------------------------------+
// Project: Deep Learning Hardware Design Contest
// Module: yolo_engine
// Description:
//		Load parameters and input feature map from DRAM via AXI4
//
// 2023.04.05 by NXT (truongnx@capp.snu.ac.kr)
//----------------------------------------------------------------+
`include "yolo_build_config_h.v"
module yolo_engine #(
    parameter AXI_WIDTH_AD = 32,
    parameter AXI_WIDTH_ID = 4,
    parameter AXI_WIDTH_DA = 32,
    parameter AXI_WIDTH_DS = AXI_WIDTH_DA/8,
    parameter OUT_BITS_TRANS = 21,
    parameter WBUF_AW = 9,
    parameter WBUF_DW = 8*3*3*16,
    parameter WBUF_DS = WBUF_DW/8,
    parameter MEM_BASE_ADDR = 'h8000_0000,
    parameter MEM_DATA_BASE_ADDR = 4096
)
(
      input                          clk
    , input                          rstn

    , input [31:0] i_ctrl_reg0    // bit0 start, bit2 soft reset
    , input [31:0] i_ctrl_reg1    // Read address base
    , input [31:0] i_ctrl_reg2    // Write address base
	, input [31:0] i_ctrl_reg3    // reserved/config
    , output [31:0] inference_cycles

    , output                         M_ARVALID
    , input                          M_ARREADY
    , output  [AXI_WIDTH_AD-1:0]     M_ARADDR
    , output  [AXI_WIDTH_ID-1:0]     M_ARID
    , output  [7:0]                  M_ARLEN
    , output  [2:0]                  M_ARSIZE
    , output  [1:0]                  M_ARBURST
    , output  [1:0]                  M_ARLOCK
    , output  [3:0]                  M_ARCACHE
    , output  [2:0]                  M_ARPROT
    , output  [3:0]                  M_ARQOS
    , output  [3:0]                  M_ARREGION
    , output  [3:0]                  M_ARUSER
    , input                          M_RVALID
    , output                         M_RREADY
    , input  [AXI_WIDTH_DA-1:0]      M_RDATA
    , input                          M_RLAST
    , input  [AXI_WIDTH_ID-1:0]      M_RID
    , input  [3:0]                   M_RUSER
    , input  [1:0]                   M_RRESP
       
    , output                         M_AWVALID
    , input                          M_AWREADY
    , output  [AXI_WIDTH_AD-1:0]     M_AWADDR
    , output  [AXI_WIDTH_ID-1:0]     M_AWID
    , output  [7:0]                  M_AWLEN
    , output  [2:0]                  M_AWSIZE
    , output  [1:0]                  M_AWBURST
    , output  [1:0]                  M_AWLOCK
    , output  [3:0]                  M_AWCACHE
    , output  [2:0]                  M_AWPROT
    , output  [3:0]                  M_AWQOS
    , output  [3:0]                  M_AWREGION
    , output  [3:0]                  M_AWUSER
    
    , output                         M_WVALID
    , input                          M_WREADY
    , output  [AXI_WIDTH_DA-1:0]     M_WDATA
    , output  [AXI_WIDTH_DS-1:0]     M_WSTRB
    , output                         M_WLAST
    , output  [AXI_WIDTH_ID-1:0]     M_WID
    , output  [3:0]                  M_WUSER
    
    , input                          M_BVALID
    , output                         M_BREADY
    , input  [1:0]                   M_BRESP
    , input  [AXI_WIDTH_ID-1:0]      M_BID
    , input                          M_BUSER
    
    , output network_done
    , output network_done_led
);
`include "user_define_h.v"
`include "user_param_h.v"

localparam BIT_TRANS = OUT_BITS_TRANS;

//CSR
reg ap_start;
reg ap_ready;
reg ap_done;
reg interrupt;

reg [31:0] dram_base_addr_rd;
reg [31:0] dram_base_addr_wr;
reg [31:0] reserved_register;
reg [31:0] inference_cycle_count;
reg [31:0] inference_cycles_latch;
reg        inference_cycle_running;

// Signals for dma read  
wire ctrl_read;
wire read_done;
wire [AXI_WIDTH_AD-1:0] read_addr;
wire [BIT_TRANS   -1:0] read_data_cnt;
wire [AXI_WIDTH_DA-1:0] read_data;
wire                    read_data_vld;

// Signals for dma write
wire ctrl_write_done;
wire ctrl_write;
wire write_done;
wire indata_req_wr;
wire [BIT_TRANS   -1:0] write_data_cnt;
wire [AXI_WIDTH_AD-1:0] write_addr;
wire [AXI_WIDTH_DA-1:0] write_data;
`ifdef YOLO_STORE_OVERLAP
wire store_indata_vld; // buffer_base prefetch FIFO -> axi_dma_wr (data valid)
wire store_indata_ack; // axi_dma_wr -> buffer_base (word captured, pop FIFO)
`endif

/* FIX ME
wire[BIT_TRANS   -1:0] num_trans        = 16;           // BURST_LENGTH = 16
wire[            15:0] max_req_blk_idx  = (256*256)/16; // The number of blocks
*/

//add signal
wire [288-1: 0]i_weight;
wire        dma_start_rd,dma_start_wr;
wire [31:0] dma_addr_rd,dma_addr_wr;
wire [31:0] dma_num_rd,dma_num_wr;
wire [15:0] dma_max_req_blk_idx_rd;
wire [1:0]  loading_mode;
wire        weight_load_start;
wire        need_dram_ifm, need_dram_wt, need_dram_wr;
wire [31:0] dram_ifm_addr, dram_ifm_size;
wire [31:0] dram_wt_addr, dram_wt_size;
wire [31:0] dram_ofm_addr;
wire        net_done;
wire        fill_done_latch;
wire        pool11_run;
wire        pool11_done;
wire [9:0]  active_oc_end_run;
wire        ifm_rd_stall;
wire        core_rstn;
wire        start_fire;
wire        done_fire;
reg  [1:0]  core_soft_reset_sync;
// axi_dma_rd/axi_dma_wr already split num_trans into AXI bursts internally.
// Keep axi_dma_ctrl to one top-level request per layer/partition transfer.
assign dma_max_req_blk_idx_rd = 16'd1;
assign core_rstn = rstn & ~core_soft_reset_sync[1];

assign start_fire     = !ap_start && i_ctrl_reg0[0];
assign done_fire      = ap_done && inference_cycle_running;
assign inference_cycles = inference_cycles_latch;

always @(posedge clk or negedge rstn) begin
    if (!rstn)
        core_soft_reset_sync <= 2'b11;
    else
        core_soft_reset_sync <= {core_soft_reset_sync[0], i_ctrl_reg0[2]};
end
//----------------------------------------------------------------
// Control signals
//----------------------------------------------------------------
always @ (*) begin
`ifdef YOLO_TRUE_LATENCY_COUNTER
    // True full-frame latency: ap_done fires on cnn_ctrl's combinational
    // network_done (S_NEXT_LAYER && layer_id==20, wired in below as
    // net_done), i.e. the cycle AFTER the final L20 partition store has seen
    // its last AXI B response (S_STORE_OFM blocks on write_done for the
    // final partition, also under YOLO_STORE_OVERLAP).  Everything driven by
    // ap_done keeps its shape and simply moves to full network completion:
    //   - done_fire -> inference_cycles_latch (CSR +0x10) = true latency,
    //   - interrupt -> CSR reg0 bit1 'done' the firmware polls (asserts
    //     LATER; set-once level, cleared by the next reg0[0] start as
    //     before),
    //   - ap_start clear (now end-of-frame; S_IDLE re-entry and ap_start
    //     clear land on the same edge, so q_start cannot restart a frame).
    ap_done     = net_done;
`else
    ap_done     = ctrl_write_done;
`endif
    ap_ready    = 1;
end
assign network_done     = interrupt;
assign network_done_led = interrupt;

always @(posedge clk or negedge core_rstn) begin
    if (!core_rstn) begin
        inference_cycle_count   <= 32'd0;
        inference_cycles_latch  <= 32'd0;
        inference_cycle_running <= 1'b0;
    end
    else if (start_fire) begin
        inference_cycle_count   <= 32'd0;
        inference_cycles_latch  <= 32'd0;
        inference_cycle_running <= 1'b1;
    end
    else if (done_fire) begin
        inference_cycles_latch  <= inference_cycle_count + 32'd1;
        inference_cycle_running <= 1'b0;
    end
    else if (inference_cycle_running) begin
        inference_cycle_count   <= inference_cycle_count + 32'd1;
    end
end


always @ (posedge clk, negedge core_rstn) begin
    if(~core_rstn) begin
        ap_start <= 0;
    end
    else begin 
        if(!ap_start && i_ctrl_reg0[0])
            ap_start <= 1;
        else if (ap_done)
            ap_start <= 0;    
    end 
end

always @(posedge clk, negedge core_rstn) begin
    if(~core_rstn) begin
        interrupt <= 0;
    end
    else begin        
        if(i_ctrl_reg0[0])
            interrupt <= 0;         
        else if (ap_done)
            interrupt <= 1;                   
    end
end

// Parse the control registers
always @ (posedge clk, negedge core_rstn) begin
    if(~core_rstn) begin
        dram_base_addr_rd <= 0;
        dram_base_addr_wr <= 0;
        reserved_register <= 0; // unused 
    end
    else begin 
        if(!ap_start && i_ctrl_reg0[0]) begin 
            dram_base_addr_rd <= i_ctrl_reg1; // Base Address for READ  (Input image, Model parameters)
            dram_base_addr_wr <= i_ctrl_reg2; // Base Address for WRITE (Intermediate feature maps, Outputs)
            reserved_register <= i_ctrl_reg3; // reserved
        end 
        else if (ap_done) begin 
            dram_base_addr_rd <= 0;
            dram_base_addr_wr <= 0;
            reserved_register <= 0; 
        end 
    end 
end
//----------------------------------------------------------------
// DUTs
//----------------------------------------------------------------
// DMA Controller
axi_dma_ctrl #(.BIT_TRANS(BIT_TRANS))
u_dma_ctrl(
    .clk              (clk              )
   ,.rstn             (core_rstn        )
   ,.i_start          (dma_start_rd     )
   ,.i_base_address_rd(i_ctrl_reg1 + dma_addr_rd) // DMA read byte address.
   ,.i_base_address_wr(i_ctrl_reg2 + dma_addr_wr) // DMA write byte address.
   ,.i_num_trans      (dma_num_rd[BIT_TRANS-1:0]        )
   ,.i_max_req_blk_idx(dma_max_req_blk_idx_rd)
   // DMA Read
   ,.i_read_done      (read_done        )
   ,.o_ctrl_read      (ctrl_read        )
   ,.o_read_addr      (read_addr        )
   //add
   ,.i_start_wr(dma_start_wr)
   // DMA Write
   ,.i_indata_req_wr  (indata_req_wr    )
   ,.i_write_done     (write_done       )
   ,.o_ctrl_write     (ctrl_write       )
   ,.o_write_addr     (write_addr       )
   ,.o_write_data_cnt (write_data_cnt   )
   ,.o_ctrl_write_done(ctrl_write_done  )
);
// DMA write module
axi_dma_wr #(
        .BITS_TRANS(BIT_TRANS),
        .OUT_BITS_TRANS(BIT_TRANS),    
        .AXI_WIDTH_USER(1),           // Master ID
        .AXI_WIDTH_ID(4),             // ID width in bits
        .AXI_WIDTH_AD(AXI_WIDTH_AD),  // address width
        .AXI_WIDTH_DA(AXI_WIDTH_DA),  // data width
        .AXI_WIDTH_DS(AXI_WIDTH_DS)   // data strobe width
    )
u_dma_write(
    .M_AWID		(M_AWID		),  // Address ID
    .M_AWADDR	(M_AWADDR	),  // Address Write
    .M_AWLEN	(M_AWLEN	),  // Transfer length
    .M_AWSIZE	(M_AWSIZE	),  // Transfer width
    .M_AWBURST	(M_AWBURST	),  // Burst type
    .M_AWLOCK	(M_AWLOCK	),  // Atomic access information
    .M_AWCACHE	(M_AWCACHE	),  // Cachable/bufferable infor
    .M_AWPROT	(M_AWPROT	),  // Protection info
    .M_AWREGION	(M_AWREGION	),
    .M_AWQOS	(M_AWQOS	),
    .M_AWVALID	(M_AWVALID	),  // address/control valid handshake
    .M_AWREADY	(M_AWREADY	),
    .M_AWUSER   (           ),
    //Write data channel
    .M_WID		(M_WID		),  // Write ID
    .M_WDATA	(M_WDATA	),  // Write Data bus
    .M_WSTRB	(M_WSTRB	),  // Write Data byte lane strobes
    .M_WLAST	(M_WLAST	),  // Last beat of a burst transfer
    .M_WVALID	(M_WVALID	),  // Write data valid
    .M_WREADY	(M_WREADY	),  // Write data ready
    .M_WUSER    (           ),
    .M_BUSER    (           ),    
    //Write response chaDnel
    .M_BID		(M_BID		),  // buffered response ID
    .M_BRESP	(M_BRESP	),  // Buffered write response
    .M_BVALID	(M_BVALID	),  // Response info valid
    .M_BREADY	(M_BREADY	),  // Response info ready (to slave)
    //Read address channDl
    //User interface
    .start_dma	(ctrl_write     ),
    .num_trans	(dma_num_wr[BIT_TRANS-1:0]), //Number of words transferred
    .start_addr	(write_addr     ),
    .indata		(write_data     ),
    .indata_req_o(indata_req_wr ),
`ifdef YOLO_STORE_OVERLAP
    .indata_vld (store_indata_vld),
    .indata_ack (store_indata_ack),
`endif
    .done_o		(write_done     ), //Blk transfer done
    //User signals
    .clk        (clk            ),
    .rstn       (core_rstn      )
);

// DMA read module
axi_dma_rd #(
        .BITS_TRANS(BIT_TRANS),
        .OUT_BITS_TRANS(OUT_BITS_TRANS),    
        .AXI_WIDTH_USER(1),             // Master ID
        .AXI_WIDTH_ID(4),               // ID width in bits
        .AXI_WIDTH_AD(AXI_WIDTH_AD),    // address width
        .AXI_WIDTH_DA(AXI_WIDTH_DA),    // data width
        .AXI_WIDTH_DS(AXI_WIDTH_DS)     // data strobe width
    )
u_dma_read(
    //AXI Master Interface
    //Read address channel
    .M_ARVALID	(M_ARVALID	  ),  // address/control valid handshake
    .M_ARREADY	(M_ARREADY	  ),  // Read addr ready
    .M_ARADDR	(M_ARADDR	  ),  // Address Read 
    .M_ARID		(M_ARID		  ),  // Read addr ID
    .M_ARLEN	(M_ARLEN	  ),  // Transfer length
    .M_ARSIZE	(M_ARSIZE	  ),  // Transfer width
    .M_ARBURST	(M_ARBURST	  ),  // Burst type
    .M_ARLOCK	(M_ARLOCK	  ),  // Atomic access information
    .M_ARCACHE	(M_ARCACHE	  ),  // Cachable/bufferable infor
    .M_ARPROT	(M_ARPROT	  ),  // Protection info
    .M_ARQOS	(M_ARQOS	  ),  // Quality of Service
    .M_ARREGION	(M_ARREGION	  ),  // Region signaling
    .M_ARUSER	(M_ARUSER	  ),  // User defined signal
 
    //Read data channel
    .M_RVALID	(M_RVALID	  ),  // Read data valid 
    .M_RREADY	(M_RREADY	  ),  // Read data ready (to Slave)
    .M_RDATA	(M_RDATA	  ),  // Read data bus
    .M_RLAST	(M_RLAST	  ),  // Last beat of a burst transfer
    .M_RID		(M_RID		  ),  // Read ID
    .M_RUSER	(M_RUSER	  ),  // User defined signal
    .M_RRESP	(M_RRESP	  ),  // Read response
     
    //Functional Ports
    .start_dma	(ctrl_read    ),
    .num_trans	(dma_num_rd[BIT_TRANS-1:0]), //Number of 32-bit words transferred
    .start_addr	(read_addr    ),
    .data_o		(read_data    ),
    .data_vld_o	(read_data_vld),
    .data_cnt_o	(read_data_cnt),
    .done_o		(read_done    ), // DMA read complete.
    .rd_stall_i (ifm_rd_stall ), // IFM skid-FIFO backpressure (RREADY low)

    //Global signals
    .clk        (clk          ),
    .rstn       (core_rstn    )
);
//L2 or axi ctrl-> q_width, height
wire o_ctrl_data_run;
wire [511:0] total_read_data; // 32-bit * 16 = 512-bit
wire L1_vaild;
//add	

wire [11:0] o_row,o_col;
wire [8:0]  o_row_buf,o_col_buf;
wire [15:0] read_data_cnt_buf;

wire tile_commit;
wire [32-1 :0]ofm;
wire [32-1 :0]ofm_raw;
wire [64-1 :0]ofm16;
wire [128-1:0]ofm32;
wire i_mode;
wire [9:0] ch_len;
wire [4:0] layer_id;
wire tile_req_valid;
wire tile_req_ready;
wire [15:0] bias_param,scale_param;
wire mac_done;
wire o_vld;
wire tile_fire;
wire [11:0] q_width,ofm_width; // Runtime input/output width.
wire [11:0] q_height,ofm_height;
wire layer_start;
wire [11:0]    bsc_addra;
wire [31:0]   bsc_douta;

wire [7:0] fill_ch_max;
wire [7:0] fill_col_max;

wire store_mode;
wire has_maxpool;
wire [9:0] ofm_ch_idx;
wire all_oc_done;
reg L1_vaild_q;
reg L1_vaild_qq;
reg [511:0] total_read_data_q;
reg [287:0] i_weight_q;
reg signed [15:0] bias_param_q;
reg [15:0] scale_param_q;
reg [9:0] ch_len_q;
reg i_mode_q;
reg has_maxpool_q;
reg linear_head_q;
reg route8_rescale_q;
`ifdef YOLO_OC_PIPELINE
wire issue_beat_last; // from buffer_base, aligned with L1_vaild
reg  beat_last_q;     // aligned with L1_vaild_q (= compute.i_vld)
`endif
wire compute_start,compute_begin;
wire [9:0] out_ch_done;
reg  [24:0] ctrl_frame_size;
wire        ctrl_vsync_run_unused;
wire [11:0] ctrl_vsync_cnt_unused;
wire        ctrl_hsync_run_unused;
wire [11:0] ctrl_hsync_cnt_unused;
wire        ctrl_data_run_unused;
wire [24:0] ctrl_data_count_unused;
wire        ctrl_end_frame_unused;
wire        write_data_vld_unused;
wire        pe_i_start_unused;
always @(posedge clk or negedge core_rstn) begin
    if (!core_rstn) begin
        L1_vaild_q        <= 1'b0;
        L1_vaild_qq       <= 1'b0;
    end
    else begin
        L1_vaild_q  <= L1_vaild;
        L1_vaild_qq <= L1_vaild_q;
    end
end

// Wide compute-stage payload registers are guarded by L1_vaild_q. Keeping
// them off the async reset tree reduces reset fanout without changing the
// accelerator dataflow.
always @(posedge clk) begin
    if (L1_vaild) begin
        total_read_data_q <= total_read_data;
        i_weight_q        <= i_weight;
        bias_param_q      <= bias_param;
        scale_param_q     <= scale_param;
        ch_len_q          <= ch_len;
        i_mode_q          <= i_mode;
        has_maxpool_q     <= has_maxpool;
        linear_head_q     <= (layer_id == 5'd14) || (layer_id == 5'd20);
        route8_rescale_q  <= (layer_id == 5'd8);
`ifdef YOLO_OC_PIPELINE
        beat_last_q       <= issue_beat_last;
`endif
    end
end

assign compute_start = L1_vaild_q & ~L1_vaild_qq;
assign o_row_buf = o_row[8:0];
assign o_col_buf = o_col[8:0];
assign read_data_cnt_buf = read_data_cnt[15:0];

always @(*) begin
    case (layer_id)
        5'd0:  ctrl_frame_size = 25'd16384;
        5'd2:  ctrl_frame_size = 25'd4096;
        5'd4:  ctrl_frame_size = 25'd1024;
        5'd6:  ctrl_frame_size = 25'd256;
        5'd8:  ctrl_frame_size = 25'd64;
        5'd10: ctrl_frame_size = 25'd16;
        5'd12: ctrl_frame_size = 25'd16;
        5'd13: ctrl_frame_size = 25'd16;
        5'd14: ctrl_frame_size = 25'd16;
        5'd17: ctrl_frame_size = 25'd16;
        5'd20: ctrl_frame_size = 25'd64;
        default: ctrl_frame_size = 25'd1;
    endcase
end


cnn_ctrl_v2 top_ctrl(
    .clk(clk),
    .rstn(core_rstn),
// Inputs
    .q_width(q_width),
    .ofm_width(ofm_width),
    .q_height(q_height),
    .ofm_height(ofm_height),
    .q_vsync_delay(12'd0),
    .q_hsync_delay(12'd0),
    .q_frame_size(ctrl_frame_size),
    .q_start(ap_start),
    .ch_done(tile_commit),
    .L1_vaild(L1_vaild),
    .fill_done_latch(fill_done_latch),
//add
    //.tile_vld(tile_vld),
    .tile_req_valid(tile_req_valid),
    .o_mode(i_mode),
    .ch_len(ch_len),
    .all_oc_done(all_oc_done),
    .layer_id(layer_id),
    .compute_begin(compute_begin),
    .tile_req_ready(tile_req_ready),
    .tile_fire(tile_fire),
    .layer_start(layer_start),
    .fill_ch_max(fill_ch_max),
    .out_ch_done(out_ch_done),
    .bsc_addra(bsc_addra),
    .fill_col_max(fill_col_max),
    .store_mode(store_mode),
    .has_maxpool(has_maxpool),
    .active_oc_end_run(active_oc_end_run),
    //for DMA
    .read_done(read_done),
    .write_done(write_done),
    .need_dram_ifm(need_dram_ifm),
    .need_dram_wt(need_dram_wt),
    .need_dram_wr(need_dram_wr),
    .dram_ifm_addr(dram_ifm_addr),
    .dram_ifm_size(dram_ifm_size),
    .dram_wt_addr(dram_wt_addr),
    .dram_wt_size(dram_wt_size),
    .dram_ofm_addr(dram_ofm_addr),
    .dma_start_rd(dma_start_rd),
    .dma_start_wr(dma_start_wr),
    .dma_addr_rd(dma_addr_rd),
    .dma_addr_wr(dma_addr_wr),
    .dma_num_rd(dma_num_rd),
    .dma_num_wr(dma_num_wr),
    .loading_mode(loading_mode),
    .weight_load_start(weight_load_start),
    .network_done(net_done),
    //for POOLING
    .pool11_done(pool11_done),
    .pool11_run(pool11_run),
    .ofm_ch_idx(ofm_ch_idx),
//output
    
    .o_ctrl_vsync_run(ctrl_vsync_run_unused),
    .o_ctrl_vsync_cnt(ctrl_vsync_cnt_unused),
    .o_ctrl_hsync_run(ctrl_hsync_run_unused),
    .o_ctrl_hsync_cnt(ctrl_hsync_cnt_unused),
    .o_ctrl_data_run(ctrl_data_run_unused),
    .o_row(o_row),
    .o_col(o_col),
    .o_data_count(ctrl_data_count_unused),
    .o_end_frame(ctrl_end_frame_unused)
);

buffer_base buf_top(
    .clk(clk),
    .layer_start(layer_start),
    .rstn(core_rstn),
    .fill_ch_max(fill_ch_max),
    .fill_col_max(fill_col_max),
    .q_width(q_width),
    .q_height(q_height),
    .i_weight(i_weight),
    .read_data(read_data),
    .i_mode(i_mode),
    .fill_done_latch(fill_done_latch),
    .tile_req_valid(tile_req_valid),
    .i_ofm(ofm),
    .i_ofm_raw(ofm_raw),
    .i_ofm16(ofm16),
    .i_ofm32(ofm32),
    .ch_len(ch_len),
    .total_read_data(total_read_data),
    .read_data_cnt(read_data_cnt_buf), //L2, L1W address
    .read_data_vld(read_data_vld),
    .L1_vaild(L1_vaild),
    .compute_begin(compute_begin),
    .tile_fire(tile_fire),
    .ofm_width(ofm_width),
    .ofm_height(ofm_height),
    .layer_id(layer_id),
    .bias_param(bias_param),
    .scale_param(scale_param),
    .out_ch_done(out_ch_done),
    .mac_done(mac_done),
    .o_row(o_row_buf),
    .o_col(o_col_buf),
    .bsc_addra(bsc_addra),
    .out_vaild(tile_commit),
    .tile_req_ready(tile_req_ready),
    .read_done(read_done),
    .load_mode(loading_mode[0]),
    .weight_load_start(weight_load_start),
    .indata_req_wr(indata_req_wr),
`ifdef YOLO_STORE_OVERLAP
    .dma_start_wr(dma_start_wr),
    .dma_num_wr(dma_num_wr),
    .store_indata_vld(store_indata_vld),
    .store_indata_ack(store_indata_ack),
`endif
    .store_mode(store_mode),
    .has_maxpool(has_maxpool),
    .write_data(write_data),
    .write_data_vld(write_data_vld_unused),
    .pe_i_start(pe_i_start_unused),
`ifdef YOLO_OC_PIPELINE
    .issue_beat_last(issue_beat_last),
`endif
    .all_oc_done(all_oc_done),
    .ofm_ch_idx(ofm_ch_idx),
    .pool11_run(pool11_run),
    .pool11_done(pool11_done),
    .active_oc_end_run(active_oc_end_run),
    .need_dram_ifm(need_dram_ifm),
    .need_dram_wt(need_dram_wt), // YOLO_WT_STREAM: qualifies the weight-arrival issue gate
    .ifm_rd_stall(ifm_rd_stall)
);

compute compute1(
    .clk(clk),
    .rstn(core_rstn),
    .i_start(compute_start),
    .i_mode(i_mode_q),
    .i_vld(L1_vaild_q),
`ifdef YOLO_OC_PIPELINE
    .i_last(beat_last_q),
`endif
    .i_wgt(i_weight_q),
    .i_ifm(total_read_data_q),
    .bias_param(bias_param_q),
    .scale_param(scale_param_q),
    .linear_head(linear_head_q),
    .route8_rescale(route8_rescale_q),
    .i_len(ch_len_q),
    .has_maxpool(has_maxpool_q),
    .maxpool_stride(1'b0),
    .vld_o(o_vld),//?
    .mac_done(mac_done),
    .out_vaild(tile_commit),
    .ofm(ofm), //ofm is w_data for buffer( after Relu and scale)
    .ofm_raw(ofm_raw),
    .ofm16(ofm16),
    .ofm32(ofm32)
);

/*
// dpram_4096x32 
dpram_wrapper #(
    .DEPTH  (BUFF_DEPTH     ),
    .AW     (BUFF_ADDR_W    ),
    .DW     (AXI_WIDTH_DA   ))
u_data_buffer(    
    .clk	(clk		    ),
    .ena	(read_data_vld	),
	.addra	(read_data_cnt  ),
	.wea	(read_data_vld  ),
	.dia	(read_data      ),
    .enb    (1'd1           ),  // Always Read       
    .addrb	(write_data_cnt ),
    .dob	(write_data     )
);
*/

endmodule
