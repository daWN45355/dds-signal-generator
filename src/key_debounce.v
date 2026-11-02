// ============================================================
// 按键消抖
//   两级同步 + 稳定计数：电平连续保持 CNT 个时钟才认可
//   CNT = 1_000_000 @50MHz = 20ms
// ============================================================
module key_debounce #(
    parameter integer CNT = 1_000_000
)(
    input  wire clk,
    input  wire rst_n,
    input  wire key_in,
    output reg  key_out
);

    // ---------- 异步输入两级同步 ----------
    reg [1:0] sync = 2'b11;
    always @(posedge clk) sync <= {sync[0], key_in};
    wire key_s = sync[1];

    // ---------- 稳定计数 ----------
    reg [20:0] cnt = 21'd0;

    always @(posedge clk) begin
        if (!rst_n) begin
            cnt     <= 21'd0;
            key_out <= 1'b1;          // 默认按上拉处理，未按下为高
        end else if (key_s == key_out) begin
            cnt <= 21'd0;             // 电平一致，计数清零
        end else if (cnt == CNT - 1) begin
            key_out <= key_s;         // 连续 20ms 变化，才认账
            cnt     <= 21'd0;
        end else begin
            cnt <= cnt + 1'b1;
        end
    end

endmodule
