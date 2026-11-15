`timescale 1ns/1ns

module L2_buffer (
	clk,
	rstn,
	ena,
	addra,
	wea,
	enb,
	addrb,
	dia,
	doa,
	dob
);

parameter DW = 72;
parameter AW = 12;
parameter AW_B = 10;
parameter DEPTH = 256;
parameter N_DELAY = 1;
parameter R_DW = 288;

input							clk;
input                           rstn;

input [AW-1			:	0]		addra;
input [3:0]					    wea;
input							ena;
input [DW-1			:	0]		dia;
input [AW_B-1			:	0]  addrb;
input							enb;
output [31:0] doa;

output [R_DW-1		:	0]		dob;

reg	[R_DW-1			:	0]		rdata;

`ifdef FPGA

	generate

        if((DEPTH == 65536) && (DW == 32)) begin: gen_dpram_65536x32
            dpram_65536x32 u_dpram_65536x32 (

				.clka    (clk),
				.ena     (ena),
				.wea     (wea),
				.addra   (addra),
				.dina    (dia),
				.doa     (doa),

				.clkb    (clk),
				.enb     (enb),
				.addrb   (addrb),
				.doutb   (dob)
			);
		end

	endgenerate
`else

	reg [DW-1			:	0]		ram[0:DEPTH-1];
	reg [31:0] rdata_a;

	wire [AW-1:0] base;
	assign doa = rdata_a;

	always @(posedge clk) begin
        if(ena) begin
            if(wea[0]) ram[addra][7:0]   <= dia[7:0];
            if(wea[1]) ram[addra][15:8]  <= dia[15:8];
            if(wea[2]) ram[addra][23:16] <= dia[23:16];
            if(wea[3]) ram[addra][31:24] <= dia[31:24];
        end
    end
    always @(posedge clk) begin
        if(ena)
            rdata_a <= ram[addra];
    end

generate
    if(N_DELAY == 1) begin: delay_1
        reg [R_DW-1:0] rdata;
        always @(posedge clk) begin: read
            if(enb)
                rdata <= ram[addrb];
        end
        assign dob = rdata;
    end
    else begin: delay_n
        reg [N_DELAY*R_DW-1:0] rdata_r;
        always @(posedge clk) begin: read
            if(enb)
                rdata_r[0+:R_DW] <= ram[addrb];
        end
        always @(posedge clk) begin: delay
            integer i;
            for(i = 0; i < N_DELAY-1; i = i+1)
                if(enb)
                    rdata_r[(i+1)*R_DW+:R_DW] <= rdata_r[i*R_DW+:R_DW];
        end
        assign dob = rdata_r[(N_DELAY-1)*R_DW+:R_DW];
    end
endgenerate
`endif

endmodule
