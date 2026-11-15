`timescale 1ns / 1ps

module dpram_512x32_ (
    input         clka,
    input         rstn,
    input         ena,
    input  [8:0]  addra,
    input  [31:0] dina,
    input         wea,
    input         clkb,
    input         enb,
    input  [8:0]  addrb,
    output [31:0] doutb
);

    reg [31:0] ram [0:511];
    reg [31:0] rdata_b;

    integer init_i;
    initial begin
        for (init_i = 0; init_i < 512; init_i = init_i + 1)
            ram[init_i] = 32'd0;
        rdata_b = 32'd0;
    end

    always @(posedge clka) begin
        if (ena && wea)
            ram[addra] <= dina;
    end

    always @(posedge clkb) begin
        if (!rstn)
            rdata_b <= 32'd0;
        else if (enb)
            rdata_b <= ram[addrb];
    end

    assign doutb = rdata_b;
endmodule
