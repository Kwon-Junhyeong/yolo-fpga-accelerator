`timescale 1ns/1ps

module tb_mul_exhaustive;
    reg clk;
    reg signed [7:0] w;
    reg [7:0] x0;
    reg [7:0] x1;
    wire signed [15:0] y0;
    wire signed [15:0] y1;

    mul dut (.clk(clk), .w(w), .x0(x0), .x1(x1), .y0(y0), .y1(y1));

    always #5 clk = ~clk;

    reg signed [15:0] exp0 [0:3];
    reg signed [15:0] exp1 [0:3];
    integer n, i, errors, checked;

    initial begin
        clk = 1'b0;
        errors = 0;
        checked = 0;
        for (i = 0; i < 4; i = i + 1) begin
            exp0[i] = 16'sd0;
            exp1[i] = 16'sd0;
        end
        for (n = 0; n < (1 << 24) + 4; n = n + 1) begin
            @(negedge clk);
            if (n < (1 << 24)) begin
                w  = n[23:16];
                x0 = n[15:8];
                x1 = n[7:0];
            end
            @(posedge clk);
            #1;
            if (n >= 4) begin
                checked = checked + 1;
                if (y0 !== exp0[3] || y1 !== exp1[3]) begin
                    errors = errors + 1;
                    if (errors <= 10)
                        $display("FAIL vector=%0d y0=%0d exp0=%0d y1=%0d exp1=%0d",
                                 n - 4, y0, exp0[3], y1, exp1[3]);
                end
            end
            for (i = 3; i > 0; i = i - 1) begin
                exp0[i] = exp0[i-1];
                exp1[i] = exp1[i-1];
            end
            exp0[0] = w * $signed({1'b0, x0});
            exp1[0] = w * $signed({1'b0, x1});
        end
        $display("[tb_mul_exhaustive] vectors=%0d errors=%0d", checked, errors);
        if (errors == 0)
            $display("[tb_mul_exhaustive] PASS");
        else
            $display("[tb_mul_exhaustive] FAIL");
        $finish;
    end
endmodule
