// ============================================================
// 按键连发（按住不放连续触发）
//
//   key_n 是消抖后的电平，低有效（按下 = 0）
//   行为：
//     按下瞬间      → 立刻发 1 个脉冲
//     一直按住      → 400ms 后开始连发，之后每 50ms 一个
//     松手          → 停止，等下次按下
//
//   这样短按就是走一步，长按就是连续走，不用区分"短按/长按"两套逻辑。
// ============================================================
module key_repeat #(
    parameter integer HOLD   = 20_000_000,   // 400ms @50MHz 后才开始连发
    parameter integer REPEAT = 2_500_000     // 连发间隔 50ms
)(
    input  wire clk,
    input  wire rst_n,
    input  wire key_n,      // 低有效
    output reg  pulse       // 单周期脉冲
);

    reg        key_d   = 1'b1;
    reg [25:0] cnt     = 26'd0;
    reg        holding = 1'b0;

    always @(posedge clk) begin
        if (!rst_n) begin
            key_d   <= 1'b1;
            cnt     <= 26'd0;
            holding <= 1'b0;
            pulse   <= 1'b0;
        end else begin
            key_d <= key_n;
            pulse <= 1'b0;

            if (!key_n && key_d) begin
                // 按下沿：立即触发第一次
                pulse   <= 1'b1;
                cnt     <= 26'd0;
                holding <= 1'b1;
            end else if (key_n) begin
                // 已松开
                holding <= 1'b0;
                cnt     <= 26'd0;
            end else if (holding) begin
                // 持续按住
                if (cnt >= HOLD + REPEAT) begin
                    cnt   <= HOLD;
                    pulse <= 1'b1;
                end else begin
                    cnt <= cnt + 1'b1;
                end
            end
        end
    end

endmodule
