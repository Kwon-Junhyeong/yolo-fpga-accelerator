`timescale 1ns/1ps

module tb_mul_packed;
    reg clk;
    reg signed [7:0] w;
    reg [7:0] x0;
    reg [7:0] x1;
    wire signed [15:0] y0;
    wire signed [15:0] y1;

    reg signed [15:0] exp0_pipe [0:3];
    reg signed [15:0] exp1_pipe [0:3];
    integer i;
    integer cycle;
    integer errors;
    integer seed;
    reg signed [15:0] exp0_now;
    reg signed [15:0] exp1_now;

    mul dut (
        .clk(clk),
        .w(w),
        .x0(x0),
        .x1(x1),
        .y0(y0),
        .y1(y1)
    );

    always #5 clk = ~clk;

    function signed [15:0] mul_ref;
        input signed [7:0] fw;
        input [7:0] fx;
        begin
            mul_ref = fw * $signed({1'b0, fx});
        end
    endfunction

    task set_case;
        input signed [7:0] tw;
        input [7:0] tx0;
        input [7:0] tx1;
        begin
            w = tw;
            x0 = tx0;
            x1 = tx1;
        end
    endtask

    initial begin
        clk = 1'b0;
        w = 8'sd0;
        x0 = 8'd0;
        x1 = 8'd0;
        errors = 0;
        seed = 32'h1357_2468;
        for (i = 0; i < 4; i = i + 1) begin
            exp0_pipe[i] = 16'sd0;
            exp1_pipe[i] = 16'sd0;
        end

        for (cycle = 0; cycle < 260; cycle = cycle + 1) begin
            @(negedge clk);
            case (cycle)
                0: set_case(8'sd0,    8'd0,   8'd0);
                1: set_case(8'sd1,    8'd255, 8'd254);
                2: set_case(-8'sd1,   8'd255, 8'd1);
                3: set_case(8'sd127,  8'd255, 8'd128);
                4: set_case(-8'sd128, 8'd255, 8'd127);
                5: set_case(-8'sd7,   8'd13,  8'd29);
                default: begin
                    w  = $random(seed);
                    x0 = $random(seed);
                    x1 = $random(seed);
                end
            endcase

            exp0_now = mul_ref(w, x0);
            exp1_now = mul_ref(w, x1);

            @(posedge clk);
            #1;
            if (cycle >= 4) begin
                if (y0 !== exp0_pipe[3]) begin
                    $display("FAIL cycle=%0d y0 got=%0d exp=%0d", cycle, y0, exp0_pipe[3]);
                    errors = errors + 1;
                end
                if (y1 !== exp1_pipe[3]) begin
                    $display("FAIL cycle=%0d y1 got=%0d exp=%0d", cycle, y1, exp1_pipe[3]);
                    errors = errors + 1;
                end
            end
            for (i = 3; i > 0; i = i - 1) begin
                exp0_pipe[i] = exp0_pipe[i-1];
                exp1_pipe[i] = exp1_pipe[i-1];
            end
            exp0_pipe[0] = exp0_now;
            exp1_pipe[0] = exp1_now;
        end

        if (errors == 0)
            $display("[tb_mul_packed] PASS");
        else
            $display("[tb_mul_packed] FAIL errors=%0d", errors);
        $finish;
    end
endmodule
