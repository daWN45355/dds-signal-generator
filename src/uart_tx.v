// ============================================================
// UART 发送（115200-8-N-1）
//   空闲为高，起始位低，8 位数据 LSB 先发，停止位高
// ============================================================
module uart_tx #(
    parameter integer CLK_FREQ = 50_000_000,
    parameter integer BAUD     = 115200
)(
    input  wire       clk,
    input  wire       rst_n,
    input  wire [7:0] data,
    input  wire       start,     // 单周期脉冲
    output reg        tx,
    output reg        busy
);

    localparam integer CLK_CNT = CLK_FREQ / BAUD;

    reg [9:0]  sh;
    reg [15:0] cnt;
    reg [3:0]  bitn;

    always @(posedge clk) begin
        if (!rst_n) begin
            tx   <= 1'b1;
            busy <= 1'b0;
            cnt  <= 16'd0;
            bitn <= 4'd0;
            sh   <= 10'h3FF;
        end else if (!busy) begin
            tx  <= 1'b1;
            cnt <= 16'd0;
            if (start) begin
                sh   <= {1'b1, data, 1'b0};   // [9]=停止 [8:1]=数据 [0]=起始
                tx   <= 1'b0;                 // 立即发出起始位
                bitn <= 4'd0;
                busy <= 1'b1;
            end
        end else begin
            if (cnt >= CLK_CNT - 1) begin
                cnt <= 16'd0;
                if (bitn == 4'd9) begin
                    busy <= 1'b0;
                    tx   <= 1'b1;
                end else begin
                    bitn <= bitn + 1'b1;
                    tx   <= sh[bitn + 1'b1];
                end
            end else begin
                cnt <= cnt + 1'b1;
            end
        end
    end

endmodule
