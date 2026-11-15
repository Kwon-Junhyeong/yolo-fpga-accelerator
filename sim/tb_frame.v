`timescale 1ns/1ps

module tb_frame;
  reg clk;
  reg rstn;
  reg [31:0] i_ctrl_reg0, i_ctrl_reg1, i_ctrl_reg2, i_ctrl_reg3;

  wire M_ARVALID; reg M_ARREADY;
  wire [31:0] M_ARADDR; wire [3:0] M_ARID; wire [7:0] M_ARLEN; wire [2:0] M_ARSIZE;
  wire [1:0] M_ARBURST, M_ARLOCK; wire [3:0] M_ARCACHE; wire [2:0] M_ARPROT;
  wire [3:0] M_ARQOS, M_ARREGION, M_ARUSER;
  reg M_RVALID; wire M_RREADY; reg [31:0] M_RDATA; reg M_RLAST; reg [3:0] M_RID, M_RUSER; reg [1:0] M_RRESP;
  wire M_AWVALID; reg M_AWREADY; wire [31:0] M_AWADDR; wire [3:0] M_AWID; wire [7:0] M_AWLEN; wire [2:0] M_AWSIZE;
  wire [1:0] M_AWBURST, M_AWLOCK; wire [3:0] M_AWCACHE; wire [2:0] M_AWPROT; wire [3:0] M_AWQOS, M_AWREGION, M_AWUSER;
  wire M_WVALID; reg M_WREADY; wire [31:0] M_WDATA; wire [3:0] M_WSTRB; wire M_WLAST; wire [3:0] M_WID, M_WUSER;
  reg M_BVALID; wire M_BREADY; reg [1:0] M_BRESP; reg [3:0] M_BID; reg M_BUSER;
  wire network_done, network_done_led;
  wire [31:0] inference_cycles;
  integer fd_check;

  yolo_engine dut (
    .clk(clk), .rstn(rstn), .i_ctrl_reg0(i_ctrl_reg0), .i_ctrl_reg1(i_ctrl_reg1), .i_ctrl_reg2(i_ctrl_reg2), .i_ctrl_reg3(i_ctrl_reg3),
    .M_ARVALID(M_ARVALID), .M_ARREADY(M_ARREADY), .M_ARADDR(M_ARADDR), .M_ARID(M_ARID), .M_ARLEN(M_ARLEN), .M_ARSIZE(M_ARSIZE), .M_ARBURST(M_ARBURST), .M_ARLOCK(M_ARLOCK), .M_ARCACHE(M_ARCACHE), .M_ARPROT(M_ARPROT), .M_ARQOS(M_ARQOS), .M_ARREGION(M_ARREGION), .M_ARUSER(M_ARUSER),
    .M_RVALID(M_RVALID), .M_RREADY(M_RREADY), .M_RDATA(M_RDATA), .M_RLAST(M_RLAST), .M_RID(M_RID), .M_RUSER(M_RUSER), .M_RRESP(M_RRESP),
    .M_AWVALID(M_AWVALID), .M_AWREADY(M_AWREADY), .M_AWADDR(M_AWADDR), .M_AWID(M_AWID), .M_AWLEN(M_AWLEN), .M_AWSIZE(M_AWSIZE), .M_AWBURST(M_AWBURST), .M_AWLOCK(M_AWLOCK), .M_AWCACHE(M_AWCACHE), .M_AWPROT(M_AWPROT), .M_AWQOS(M_AWQOS), .M_AWREGION(M_AWREGION), .M_AWUSER(M_AWUSER),
    .M_WVALID(M_WVALID), .M_WREADY(M_WREADY), .M_WDATA(M_WDATA), .M_WSTRB(M_WSTRB), .M_WLAST(M_WLAST), .M_WID(M_WID), .M_WUSER(M_WUSER),
    .M_BVALID(M_BVALID), .M_BREADY(M_BREADY), .M_BRESP(M_BRESP), .M_BID(M_BID), .M_BUSER(M_BUSER),
    .inference_cycles(inference_cycles),
    .network_done(network_done), .network_done_led(network_done_led)
  );

  localparam IFM_WORDS = 65536;
  localparam [31:0] W6_BASE_WORD  = 32'd65536;
  localparam [31:0] W8_BASE_WORD  = 32'd90112;
  localparam [31:0] W10_BASE_WORD = 32'd188416;
  localparam [31:0] W12_BASE_WORD = 32'd581632;
  localparam [31:0] W13_BASE_WORD = 32'd679936;
  localparam [31:0] W14_BASE_WORD = 32'd1073152;
  localparam [31:0] W17_BASE_WORD = 32'd1148032;
  localparam [31:0] W20_BASE_WORD = 32'd1172608;
  localparam [31:0] TB_DDR_BASE_WORD = 32'h1000_0000 >> 2;
  localparam [31:0] O14_BASE_WORD = (32'h1000_0000 + 32'd4915072) >> 2;
  localparam [31:0] O20_BASE_WORD = (32'h1000_0000 + 32'd4964992) >> 2;
  localparam integer O14_WORDS = 12480;
  localparam integer O20_WORDS = 49920;
  reg [31:0] ifm_mem [0:IFM_WORDS-1];
  reg [31:0] w6_mem [0:24575], w8_mem [0:98303], w10_mem [0:393215], w12_mem [0:98303];
  reg [31:0] w13_mem [0:393215], w14_mem [0:74879], w17_mem [0:24575], w20_mem [0:56159];
  reg [31:0] l4_preload_mem [0:16383];
  reg [31:0] l11_preload_mem [0:8191];
  reg [31:0] o14_ddr_mem [0:O14_WORDS-1];
  reg [31:0] o20_ddr_mem [0:O20_WORDS-1];
  integer i;
  integer preload_i;
  integer o14_active_words;
  integer o20_active_words;
  reg       start_l6;
  reg       start_l12;
  reg       run_l11;
  reg       run_l12;
  reg       run_l13;
  reg       run_l14;
  reg       run_l17;
  reg       run_l20;
  reg [4:0] prev_layer_id;
  reg       snapshot_enable;
  reg       l10_dumped;
  reg       l11_dumped;
  reg       route8_dump_pending;
  reg       l12_dump_pending;
  wire [31:0] o20_base_word_active;
  wire [15:0] l20_snapshot_base_active;

  assign o20_base_word_active = O20_BASE_WORD;
  assign l20_snapshot_base_active = 16'h8800;

  initial begin
    clk = 0; forever #5 clk = ~clk;
  end

  initial begin
    rstn=0; i_ctrl_reg0=0; i_ctrl_reg1=0; i_ctrl_reg2=32'h1000_0000; i_ctrl_reg3=0;
    M_ARREADY=1; M_RVALID=0; M_RDATA=0; M_RLAST=0; M_RID=0; M_RUSER=0; M_RRESP=0;
    M_AWREADY=1; M_WREADY=1; M_BVALID=0; M_BRESP=0; M_BID=0; M_BUSER=0;
    for (i=0;i<IFM_WORDS;i=i+1) ifm_mem[i]=32'h01010101;
    for (i=0;i<16384;i=i+1) l4_preload_mem[i]=32'd0;
    o14_active_words = O14_WORDS;
    o20_active_words = O20_WORDS;
    for (i=0;i<O14_WORDS;i=i+1) o14_ddr_mem[i]=32'hDEADBEEF;
    for (i=0;i<O20_WORDS;i=i+1) o20_ddr_mem[i]=32'hDEADBEEF;
    start_l6 = $test$plusargs("START_L6");
    start_l12 = $test$plusargs("START_L12");
    run_l20 = $test$plusargs("RUN_L20");
    run_l17 = $test$plusargs("RUN_L17") || run_l20;
    run_l14 = $test$plusargs("RUN_L14") || run_l17;
    run_l13 = $test$plusargs("RUN_L13") || run_l14;
    run_l12 = $test$plusargs("RUN_L12") || run_l13;
    run_l11 = $test$plusargs("RUN_L11") || run_l12;
    prev_layer_id = 5'd0;
    snapshot_enable = 1'b0;
    l10_dumped = 1'b0;
    l11_dumped = 1'b0;
    route8_dump_pending = 1'b0;
    l12_dump_pending = 1'b0;

    fd_check = $fopen("generated/CONV00_input_32b.hex","r");
    if (fd_check == 0) begin
      $display("ERROR: missing generated/CONV00_input_32b.hex");
      $finish;
    end
    $fclose(fd_check);

    fd_check = $fopen("generated/CONV06_param_weight_packed24.hex","r");
    if (fd_check == 0) begin
      $display("ERROR: missing generated/CONV06_param_weight_packed24.hex");
      $finish;
    end
    $fclose(fd_check);

    fd_check = $fopen("generated/CONV08_param_weight_packed24.hex","r");
    if (fd_check == 0) begin
      $display("ERROR: missing generated/CONV08_param_weight_packed24.hex");
      $finish;
    end
    $fclose(fd_check);

    fd_check = $fopen("generated/CONV10_param_weight_packed24.hex","r");
    if (fd_check == 0) begin
      $display("ERROR: missing generated/CONV10_param_weight_packed24.hex");
      $finish;
    end
    $fclose(fd_check);

    if (run_l12) begin
      fd_check = $fopen("generated/CONV12_param_weight_packed24.hex","r");
      if (fd_check == 0) begin
        $display("ERROR: missing generated/CONV12_param_weight_packed24.hex");
        $finish;
      end
      $fclose(fd_check);
    end

    if (run_l13) begin
      fd_check = $fopen("generated/CONV13_param_weight_packed24.hex","r");
      if (fd_check == 0) begin
        $display("ERROR: missing generated/CONV13_param_weight_packed24.hex");
        $finish;
      end
      $fclose(fd_check);
    end

    if (run_l14) begin
      fd_check = $fopen("generated/CONV14_param_weight_packed24.hex","r");
      if (fd_check == 0) begin
        $display("ERROR: missing generated/CONV14_param_weight_packed24.hex");
        $finish;
      end
      $fclose(fd_check);
    end

    if (run_l17) begin
      fd_check = $fopen("generated/CONV17_param_weight_packed24.hex","r");
      if (fd_check == 0) begin
        $display("ERROR: missing generated/CONV17_param_weight_packed24.hex");
        $finish;
      end
      $fclose(fd_check);
    end

    if (run_l20) begin
      fd_check = $fopen("generated/CONV20_param_weight_packed24.hex","r");
      if (fd_check == 0) begin
        $display("ERROR: missing generated/CONV20_param_weight_packed24.hex");
        $finish;
      end
      $fclose(fd_check);
    end

    $readmemh("generated/CONV00_input_32b.hex", ifm_mem);
    $readmemh("generated/CONV06_param_weight_packed24.hex", w6_mem);
    $readmemh("generated/CONV08_param_weight_packed24.hex", w8_mem);
    $readmemh("generated/CONV10_param_weight_packed24.hex", w10_mem);
    if (run_l12)
      $readmemh("generated/CONV12_param_weight_packed24.hex", w12_mem);
    if (run_l13)
      $readmemh("generated/CONV13_param_weight_packed24.hex", w13_mem);
    if (run_l14)
      $readmemh("generated/CONV14_param_weight_packed24.hex", w14_mem);
    if (run_l17)
      $readmemh("generated/CONV17_param_weight_packed24.hex", w17_mem);
    if (run_l20)
      $readmemh("generated/CONV20_param_weight_packed24.hex", w20_mem);

    if (start_l6) begin
      fd_check = $fopen("generated/l2_preload_L4.hex","r");
      if (fd_check == 0) begin
        $display("ERROR: missing generated/l2_preload_L4.hex");
        $finish;
      end
      $fclose(fd_check);
      $readmemh("generated/l2_preload_L4.hex", l4_preload_mem);
    end

    if (start_l12) begin
      fd_check = $fopen("generated/l2_preload_L11.hex","r");
      if (fd_check == 0) begin
        $display("ERROR: missing generated/l2_preload_L11.hex");
        $finish;
      end
      $fclose(fd_check);
      $readmemh("generated/l2_preload_L11.hex", l11_preload_mem);
    end

    repeat(20) @(posedge clk); rstn=1;
    @(negedge clk);
    if (start_l12) begin
      for (preload_i=0; preload_i<8192; preload_i=preload_i+1)
        dut.buf_top.L2_buffer.ram[preload_i] = l11_preload_mem[preload_i];
      dut.top_ctrl.layer_id = 5'd12;
      dut.top_ctrl.bsc_base_acc = 12'd1008;
      dut.top_ctrl.out_ch_done = 10'd0;
      dut.top_ctrl.wt_offset = 32'd0;
      prev_layer_id = 5'd12;
      $display("[%0t] START_L12: preloaded L11 into L2 and set controller to Layer 12", $time);
    end
    else if (start_l6) begin
      for (preload_i=0; preload_i<16384; preload_i=preload_i+1)
        dut.buf_top.L2_buffer.ram[preload_i] = l4_preload_mem[preload_i];
      dut.top_ctrl.layer_id = 5'd6;
      dut.top_ctrl.bsc_base_acc = 12'd112;
      dut.top_ctrl.out_ch_done = 10'd0;
      dut.top_ctrl.wt_offset = 32'd0;
      prev_layer_id = 5'd6;
      $display("[%0t] START_L6: preloaded L4 into L2 and set controller to Layer 6", $time);
    end
    i_ctrl_reg0[3] = 1'b0;
    $display("[%0t] L14/L20 outputs: raw int32, drained per 32-channel partition", $time);
    repeat(10) @(posedge clk);
    @(negedge clk); i_ctrl_reg0[0]=1'b1;
    @(negedge clk); i_ctrl_reg0[0]=1'b0;
    snapshot_enable = 1'b1;
  end

  reg [31:0] rd_addr; reg [15:0] rd_left;

  integer dma_rd_gap;
  reg [31:0] rd_gap_cnt;
  reg [31:0] pe_latch_stall_cycles;
  initial begin
    if (!$value$plusargs("DMA_RD_GAP=%d", dma_rd_gap)) dma_rd_gap = 0;

    if ($test$plusargs("DMA_STRESS")) dma_rd_gap = 7;

    if ($test$plusargs("DMA_STRESS16")) dma_rd_gap = 15;
    rd_gap_cnt = 0;
    pe_latch_stall_cycles = 0;
  end
  always @(posedge clk) begin
    if (dut.buf_top.pe_done_latch)
      pe_latch_stall_cycles <= pe_latch_stall_cycles + 1;
  end

  reg [31:0] perf_store_state_cycles;
  reg [31:0] perf_store_dma_cycles;
  reg [31:0] perf_store_state_last;
  reg [31:0] perf_store_dma_last;
  initial begin
    perf_store_state_cycles = 0;
    perf_store_dma_cycles   = 0;
    perf_store_state_last   = 0;
    perf_store_dma_last     = 0;
  end
  always @(posedge clk) begin
    if (rstn) begin
      if (dut.top_ctrl.main_state == 3'd4)
        perf_store_state_cycles <= perf_store_state_cycles + 1;
      if (dut.u_dma_ctrl.cstate_wr != 3'd0)
        perf_store_dma_cycles <= perf_store_dma_cycles + 1;
    end
  end
  always @(posedge clk) begin
    if (M_ARVALID && M_ARREADY) begin
      M_RVALID <= 1'b0; M_RLAST <= 1'b0;
      rd_addr <= M_ARADDR[31:2];
      rd_left <= M_ARLEN + 1;
    end else if (M_RVALID && !M_RREADY) begin

    end else if ((rd_left != 0) && (rd_gap_cnt != 0)) begin

      M_RVALID <= 1'b0; M_RLAST <= 1'b0;
      rd_gap_cnt <= rd_gap_cnt - 1;
    end else if (rd_left != 0) begin
      M_RVALID <= 1'b1;
      M_RDATA  <= 32'd0;
      if (dut.loading_mode[0]) begin
        if (dut.top_ctrl.layer_id==5'd6 &&
            rd_addr >= W6_BASE_WORD &&
            rd_addr <  W6_BASE_WORD + 32'd24576)
          M_RDATA <= w6_mem[rd_addr - W6_BASE_WORD];
        else if (dut.top_ctrl.layer_id==5'd8 &&
                 rd_addr >= W8_BASE_WORD &&
                 rd_addr <  W8_BASE_WORD + 32'd98304)
          M_RDATA <= w8_mem[rd_addr - W8_BASE_WORD];
        else if (dut.top_ctrl.layer_id==5'd10 &&
                 rd_addr >= W10_BASE_WORD &&
                 rd_addr <  W10_BASE_WORD + 32'd393216)
          M_RDATA <= w10_mem[rd_addr - W10_BASE_WORD];
        else if (dut.top_ctrl.layer_id==5'd12 &&
                 rd_addr >= W12_BASE_WORD &&
                 rd_addr <  W12_BASE_WORD + 32'd98304)
          M_RDATA <= w12_mem[rd_addr - W12_BASE_WORD];
        else if (dut.top_ctrl.layer_id==5'd13 &&
                 rd_addr >= W13_BASE_WORD &&
                 rd_addr <  W13_BASE_WORD + 32'd393216)
          M_RDATA <= w13_mem[rd_addr - W13_BASE_WORD];
        else if (dut.top_ctrl.layer_id==5'd14 &&
                 rd_addr >= W14_BASE_WORD &&
                 rd_addr <  W14_BASE_WORD + 32'd74880)
          M_RDATA <= w14_mem[rd_addr - W14_BASE_WORD];
        else if (dut.top_ctrl.layer_id==5'd17 &&
                 rd_addr >= W17_BASE_WORD &&
                 rd_addr <  W17_BASE_WORD + 32'd24576)
          M_RDATA <= w17_mem[rd_addr - W17_BASE_WORD];
        else if (dut.top_ctrl.layer_id==5'd20 &&
                 rd_addr >= W20_BASE_WORD &&
                 rd_addr <  W20_BASE_WORD + 32'd56160)
          M_RDATA <= w20_mem[rd_addr - W20_BASE_WORD];
      end else begin
        if (rd_addr < IFM_WORDS)
          M_RDATA <= ifm_mem[rd_addr[15:0]];
      end
      M_RLAST <= (rd_left == 1);
      rd_addr <= rd_addr + 1; rd_left <= rd_left - 1;
      rd_gap_cnt <= dma_rd_gap;
    end else begin
      M_RVALID <= 1'b0; M_RLAST <= 1'b0;
    end
  end

  reg [31:0] wr_addr;
  reg [15:0] wr_left;

  task apply_wstrb_o14;
    input integer idx;
    input [31:0] data;
    input [3:0]  strb;
    begin
      if (strb[0]) o14_ddr_mem[idx][7:0]   = data[7:0];
      if (strb[1]) o14_ddr_mem[idx][15:8]  = data[15:8];
      if (strb[2]) o14_ddr_mem[idx][23:16] = data[23:16];
      if (strb[3]) o14_ddr_mem[idx][31:24] = data[31:24];
    end
  endtask

  task apply_wstrb_o20;
    input integer idx;
    input [31:0] data;
    input [3:0]  strb;
    begin
      if (strb[0]) o20_ddr_mem[idx][7:0]   = data[7:0];
      if (strb[1]) o20_ddr_mem[idx][15:8]  = data[15:8];
      if (strb[2]) o20_ddr_mem[idx][23:16] = data[23:16];
      if (strb[3]) o20_ddr_mem[idx][31:24] = data[31:24];
    end
  endtask

  always @(posedge clk) begin
    if (!rstn) begin
      M_BVALID <= 1'b0;
      M_BRESP  <= 2'b00;
      M_BID    <= 4'd0;
      M_BUSER  <= 1'b0;
      wr_addr  <= 32'd0;
      wr_left  <= 16'd0;
    end
    else begin
      if (M_AWVALID && M_AWREADY) begin
        wr_addr <= M_AWADDR[31:2];
        wr_left <= M_AWLEN + 1;
      end
      else if (M_WVALID && M_WREADY && wr_left != 0) begin
        if (wr_addr >= O14_BASE_WORD && wr_addr < O14_BASE_WORD + o14_active_words)
          apply_wstrb_o14(wr_addr - O14_BASE_WORD, M_WDATA, M_WSTRB);
        else if (wr_addr >= o20_base_word_active && wr_addr < o20_base_word_active + o20_active_words)
          apply_wstrb_o20(wr_addr - o20_base_word_active, M_WDATA, M_WSTRB);
        wr_addr <= wr_addr + 1;
        wr_left <= wr_left - 1;
      end

      if (M_BVALID && M_BREADY)
        M_BVALID <= 1'b0;
      else if (M_WVALID && M_WREADY && M_WLAST)
        M_BVALID <= 1'b1;
      M_BRESP <= 2'b00;
      M_BID   <= 4'd0;
      M_BUSER <= 1'b0;
    end
  end

  task dump_l2_snapshot;
    input [1023:0] path_name;
    input integer words;
    input [15:0] base_addr;
    integer fd, a; reg [31:0] v; reg [15:0] phys_addr;
    begin
      fd = $fopen(path_name, "w");
      for (a=0;a<words;a=a+1) begin
        phys_addr = base_addr + a;
        v = dut.buf_top.L2_buffer.ram[phys_addr];
        $fwrite(fd, "addr=%0d val=0x%08x b0=0x%02x b1=0x%02x b2=0x%02x b3=0x%02x\n", a, v, v[7:0], v[15:8], v[23:16], v[31:24]);
      end
      $fclose(fd);
    end
  endtask

  task dump_route8_snapshot;
    input [1023:0] path_name;
    integer fd, a; reg [31:0] v;
    begin
      fd = $fopen(path_name, "w");
      for (a=0;a<16384;a=a+1) begin
        v = dut.buf_top.L2_buffer.ram[16'h4000 + a];
        $fwrite(fd, "addr=%0d val=0x%08x b0=0x%02x b1=0x%02x b2=0x%02x b3=0x%02x\n", a, v, v[7:0], v[15:8], v[23:16], v[31:24]);
      end
      $fclose(fd);
    end
  endtask

  task dump_ddr_o14_snapshot;
    input [1023:0] path_name;
    input integer words;
    integer fd, a; reg [31:0] v;
    begin
      fd = $fopen(path_name, "w");
      for (a=0;a<words;a=a+1) begin
        v = o14_ddr_mem[a];
        $fwrite(fd, "addr=%0d val=0x%08x b0=0x%02x b1=0x%02x b2=0x%02x b3=0x%02x\n", a, v, v[7:0], v[15:8], v[23:16], v[31:24]);
      end
      $fclose(fd);
    end
  endtask

  task dump_ddr_o20_snapshot;
    input [1023:0] path_name;
    input integer words;
    integer fd, a; reg [31:0] v;
    begin
      fd = $fopen(path_name, "w");
      for (a=0;a<words;a=a+1) begin
        v = o20_ddr_mem[a];
        $fwrite(fd, "addr=%0d val=0x%08x b0=0x%02x b1=0x%02x b2=0x%02x b3=0x%02x\n", a, v, v[7:0], v[15:8], v[23:16], v[31:24]);
      end
      $fclose(fd);
    end
  endtask

  always @(posedge clk) begin
    #1;
    if (!rstn) begin
      prev_layer_id = start_l12 ? 5'd12 : (start_l6 ? 5'd6 : 5'd0);
      snapshot_enable = 1'b0;
      l10_dumped = 1'b0;
      l11_dumped = 1'b0;
      route8_dump_pending = 1'b0;
      l12_dump_pending = 1'b0;
    end else begin
      if (snapshot_enable && dut.top_ctrl.layer_id != prev_layer_id) begin
        $display("[%0t] PERF L%0d: store_state_cycles=%0d store_dma_cycles=%0d",
                 $time, prev_layer_id,
                 perf_store_state_cycles - perf_store_state_last,
                 perf_store_dma_cycles - perf_store_dma_last);
        perf_store_state_last = perf_store_state_cycles;
        perf_store_dma_last   = perf_store_dma_cycles;
        case (prev_layer_id)
          5'd0: begin
            $display("[%0t] dump L0 snapshot", $time);
            $display("[%0t] L0 pe_done_latch interlock stall cycles = %0d (dma_rd_gap=%0d)",
                     $time, pe_latch_stall_cycles, dma_rd_gap);
            dump_l2_snapshot("results/l2_snapshot_L0.txt", 65536, 16'h0000);
          end
          5'd2: begin
            $display("[%0t] dump L2 snapshot", $time);
            dump_l2_snapshot("results/l2_snapshot_L2.txt", 32768, 16'h0000);
          end
          5'd4: begin
            $display("[%0t] dump L4 snapshot", $time);
            dump_l2_snapshot("results/l2_snapshot_L4.txt", 16384, 16'h0000);
          end
          5'd6: begin
            $display("[%0t] dump L6 snapshot", $time);
            dump_l2_snapshot("results/l2_snapshot_L6.txt", 8192, 16'h8000);
          end
          5'd8: begin
            $display("[%0t] dump L8 snapshot", $time);
            dump_l2_snapshot("results/l2_snapshot_L8.txt", 4096, 16'h0000);
            route8_dump_pending = 1'b1;
          end
          5'd12: begin
            l12_dump_pending = 1'b1;
          end
          5'd13: begin
            $display("[%0t] dump L13 snapshot", $time);
            dump_l2_snapshot("results/l2_snapshot_L13.txt", 8192, 16'h8000);
            if (run_l13 && !run_l14)
              $finish;
          end
          5'd14: begin
            $display("[%0t] dump L14 snapshot", $time);
            dump_l2_snapshot("results/l2_snapshot_L14.txt", o14_active_words, 16'h0000);
            dump_ddr_o14_snapshot("results/ddr_snapshot_L14.txt", o14_active_words);
            if (run_l14 && !run_l17)
              $finish;
          end
          5'd17: begin
            $display("[%0t] dump L17 snapshot", $time);
            dump_l2_snapshot("results/l2_snapshot_L17.txt", 2048, 16'h8000);
            if (run_l17 && !run_l20)
              $finish;
          end
          5'd20: begin
            $display("[%0t] dump L20 snapshot", $time);

            $display("[%0t] CSR_LATCH: inference_cycles=%0d network_done=%b ap_start=%b",
                     $time, inference_cycles, network_done, dut.ap_start);
            dump_l2_snapshot("results/l2_snapshot_L20.txt", o20_active_words, l20_snapshot_base_active);
            dump_ddr_o20_snapshot("results/ddr_snapshot_L20.txt", o20_active_words);
            if (run_l20)
              $finish;
          end
        endcase
        prev_layer_id = dut.top_ctrl.layer_id;
      end

      if (route8_dump_pending && !dut.buf_top.route8_wr_busy) begin
        $display("[%0t] dump L8 raw route snapshot", $time);
        dump_route8_snapshot("results/l2_snapshot_L8RAW.txt");
        route8_dump_pending = 1'b0;
      end

      if (l12_dump_pending &&
          !dut.buf_top.wr_busy &&
          !dut.buf_top.ofm_write_mode) begin
        $display("[%0t] dump L12 snapshot", $time);
        dump_l2_snapshot("results/l2_snapshot_L12.txt", 4096, 16'h2000);
        l12_dump_pending = 1'b0;
        if (run_l12 && !run_l13)
          $finish;
      end

      if (!l10_dumped &&
          dut.top_ctrl.main_state == 3'd6 &&
          dut.top_ctrl.layer_id == 5'd10 &&
          !dut.buf_top.wr_busy &&
          !dut.buf_top.ofm_write_mode &&
          dut.buf_top.pool_state == 3'd1) begin
        $display("[%0t] reached S_POOL11 after L10 writes; dump L10 before pool11 modifies L2", $time);
        dump_l2_snapshot("results/l2_snapshot_L10.txt", 8192, 16'h8000);
        l10_dumped = 1'b1;
        if (!run_l11)
          $finish;
      end

      if (run_l11 && !l11_dumped && dut.buf_top.pool11_done) begin
        $display("[%0t] pool11 done; dump L11 snapshot", $time);
        dump_l2_snapshot("results/l2_snapshot_L11.txt", 8192, 16'h0000);
        l11_dumped = 1'b1;
        if (!run_l12)
          $finish;
      end
    end
  end

  initial begin
    repeat(100000000) @(posedge clk);
    $display("TIMEOUT: layer_id=%0d main_state=%0d loading_mode=%0d out_ch_done=%0d ofm_ch_idx=%0d wt_offset=%0d",
             dut.top_ctrl.layer_id, dut.top_ctrl.main_state, dut.loading_mode,
             dut.top_ctrl.out_ch_done, dut.top_ctrl.ofm_ch_idx, dut.top_ctrl.wt_offset);
    $display("TIMEOUT_BUF: buf_state=%0d wr_busy=%b ofm_write_mode=%b tile_req_ready=%b end_frame=%b compute_pending=%b more_pending=%b pool_pending=%b",
             dut.buf_top.state, dut.buf_top.wr_busy, dut.buf_top.ofm_write_mode,
             dut.tile_req_ready, dut.top_ctrl.end_frame,
             dut.top_ctrl.compute_done_pending, dut.top_ctrl.compute_more_pending,
             dut.top_ctrl.compute_pool_pending);
    $display("TIMEOUT_CTRL: cstate=%0d T_state=%0d fill_done_latch=%b fill_active=%b fill_done=%b first_fill=%b fill_col=%0d fill_ch=%0d fill_rg=%0d",
             dut.top_ctrl.cstate, dut.top_ctrl.T_state, dut.fill_done_latch,
             dut.buf_top.fill_active, dut.buf_top.fill_done, dut.buf_top.first_fill,
             dut.buf_top.fill_col, dut.buf_top.fill_ch, dut.buf_top.fill_rg);
    $display("TIMEOUT_DMA: dma_start_rd=%b ctrl_read=%b read_done=%b cstate_rd=%0d req_blk_idx_rd=%0d rd_fsm=%0d burst_cnt=%0d data_cnt=%0d num_trans_d=%0d arvalid=%b rvalid=%b rlast=%b",
             dut.dma_start_rd, dut.ctrl_read, dut.read_done,
             dut.u_dma_ctrl.cstate_rd, dut.u_dma_ctrl.req_blk_idx_rd,
             dut.u_dma_read.st_rdaxi, dut.u_dma_read.q_burst_cnt_rd,
             dut.u_dma_read.data_cnt, dut.u_dma_read.num_trans_d,
             M_ARVALID, M_RVALID, M_RLAST);
      $finish;
  end

  initial begin
    if ($test$plusargs("DEBUG_DMA")) begin
      forever begin
        repeat(10000) @(posedge clk);
        $display("DBG t=%0t layer=%0d main=%0d rd_start=%b read_done=%b ctrl_rd=%b rd_fsm=%0d burst_cnt=%0d data_cnt=%0d num=%0d arvalid=%b rvalid=%b rlast=%b",
                 $time, dut.top_ctrl.layer_id, dut.top_ctrl.main_state,
                 dut.dma_start_rd, dut.read_done, dut.ctrl_read,
                 dut.u_dma_read.st_rdaxi, dut.u_dma_read.q_burst_cnt_rd,
                 dut.u_dma_read.data_cnt, dut.u_dma_read.num_trans_d,
                 M_ARVALID, M_RVALID, M_RLAST);
      end
    end
  end

  reg [4:0] trace_layer_id;
  reg [2:0] trace_main_state;
  reg [9:0] trace_out_ch_done;
  reg       dumped_l6_part1_wbuf;
  initial begin
    trace_layer_id = 5'd31;
    trace_main_state = 3'd7;
    trace_out_ch_done = 10'd1023;
    dumped_l6_part1_wbuf = 1'b0;
  end

  always @(posedge clk) begin
    if ($test$plusargs("TRACE_STATE") && rstn) begin
      if (dut.top_ctrl.layer_id != trace_layer_id ||
          dut.top_ctrl.main_state != trace_main_state ||
          dut.top_ctrl.out_ch_done != trace_out_ch_done) begin
        $display("TRACE t=%0t layer=%0d main=%0d out_ch_done=%0d ofm_ch_idx=%0d wt_offset=%0d read_done=%b",
                 $time, dut.top_ctrl.layer_id, dut.top_ctrl.main_state,
                 dut.top_ctrl.out_ch_done, dut.top_ctrl.ofm_ch_idx,
                 dut.top_ctrl.wt_offset, dut.read_done);
        trace_layer_id = dut.top_ctrl.layer_id;
        trace_main_state = dut.top_ctrl.main_state;
        trace_out_ch_done = dut.top_ctrl.out_ch_done;
      end
    end

    if ($test$plusargs("DUMP_WBUF") && rstn &&
        !dumped_l6_part1_wbuf &&
        dut.top_ctrl.layer_id == 5'd6 &&
        dut.top_ctrl.main_state == 3'd3 &&
        dut.top_ctrl.out_ch_done == 10'd64) begin
      $writememh("results/wbuf_L6_part01_loaded.hex",
                 dut.buf_top.W_S_Buffer.u_dpram_4096x72.mem);
      dumped_l6_part1_wbuf = 1'b1;
      $display("[%0t] dumped L6 part01 weight buffer", $time);
    end

  end
endmodule
