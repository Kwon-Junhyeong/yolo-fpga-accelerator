`timescale 1ns / 1ps

module dpram_4096x72_ (

    input          clka,
    input          ena,
    input  [0:0]   wea,
    input  [11:0]  addra,
    input  [71:0]  dina,

    input          clkb,
    input          enb,
    input  [9:0]   addrb,
    output reg [287:0] doutb
);

    reg [71:0] mem [0:4095];

    initial begin
        $readmemh("rom/weight_4096x72.hex", mem);
    end

    always @(posedge clka) begin
        if (ena && wea)
            mem[addra] <= dina;
    end

    wire [11:0] base_addr_b = addrb << 2;

    always @(posedge clkb) begin
        if (enb) begin
            doutb <= {mem[base_addr_b + 3],
                      mem[base_addr_b + 2],
                      mem[base_addr_b + 1],
                      mem[base_addr_b    ]};
        end
    end

endmodule
