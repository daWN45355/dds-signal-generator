// ============================================================
// 四按键控制
//
//   面板布局（模块内部按"低有效"写：1 = 松开，0 = 按下）：
//     板载按键本来就是低有效（上拉到 3V3，按下短到 GND），
//     所以顶层直接把它们接进来，不做任何取反。
//     K1 波形键   —— 按一下走一格：正弦→方波→三角→锯齿→正弦…
//                    **不连发**：只有 4 种波形，连发反而会因为松手时机
//                    随机停在某一种，感觉像"乱跳"。一下就是一格，可预期。
//     K2 频率键   —— 按住加减频率，100Hz 一步，长按连发
//     K3 相位键   —— 按住加减相位，15° 一步，长按连发
//     K4 方向键   —— 短按翻转"加/减"，决定 K2/K3 往哪个方向走
//
//   K2/K3 的加减方向由 K4 的 dir_flag 统一决定：
//     dir_flag = 0 → 两个键都是"加"
//     dir_flag = 1 → 两个键都是"减"
//
//   【方向键为什么要锁定 250ms】
//   如果 K4 接触不良、或者按 K2 时手蹭到了 K4，dir_flag 会连续翻转：
//   前一个脉冲是"加"、下一个脉冲变"减"，加一下减一下净变化为零，
//   用户看到的就是"频率能调，但一松手又回去了"。
//   翻转后锁 250ms，抖动和误触就没法连续翻转了。
//
//   【方向也能从串口改】
//   cmd_parser 收到 D0/D1 时给出 dir_set 脉冲，把 dir_flag 直接写成 0/1。
//   这样即使 K4 坏了，也能用电脑改方向；同时也是排查 K4 的好工具：
//     电脑发 D1 后按 K2，频率应该往下走 —— 说明 K2 和方向逻辑都正常，
//     问题只在 K4 本身。
//
//   本模块只产生"事件脉冲"，具体怎么改参数由 cmd_parser 决定。
// ============================================================
module key_ctrl #(
    parameter integer DIR_LOCK = 12_500_000    // 250ms @50MHz
)(
    input  wire clk,
    input  wire rst_n,

    input  wire key_wave,       // K1
    input  wire key_freq,       // K2
    input  wire key_phase,      // K3
    input  wire key_dir,        // K4

    input  wire dir_set,        // 串口改方向（单周期脉冲）
    input  wire dir_val,        // 配合 dir_set：0 = 加，1 = 减

    output wire ev_wave_next,   // 波形循环一格
    output wire ev_freq_up,
    output wire ev_freq_dn,
    output wire ev_phase_up,
    output wire ev_phase_dn,

    output reg  dir_flag        // 0 = 加，1 = 减
);

    // ---------- 消抖 ----------
    wire d_wave, d_freq, d_phase, d_dir;

    key_debounce u_k1 (.clk(clk), .rst_n(rst_n), .key_in(key_wave ), .key_out(d_wave ));
    key_debounce u_k2 (.clk(clk), .rst_n(rst_n), .key_in(key_freq ), .key_out(d_freq ));
    key_debounce u_k3 (.clk(clk), .rst_n(rst_n), .key_in(key_phase), .key_out(d_phase));
    key_debounce u_k4 (.clk(clk), .rst_n(rst_n), .key_in(key_dir  ), .key_out(d_dir  ));

    // ---------- 波形键：只要按下沿，不连发 ----------
    reg d_wave_r;
    reg p_wave_r;

    always @(posedge clk) begin
        if (!rst_n) begin
            d_wave_r <= 1'b1;
            p_wave_r <= 1'b0;
        end else begin
            d_wave_r <= d_wave;
            p_wave_r <= (!d_wave && d_wave_r);   // 低有效：1->0 = 按下
        end
    end

    // ---------- 频率/相位键：连发 ----------
    wire p_freq, p_phase;

    key_repeat u_r2 (.clk(clk), .rst_n(rst_n), .key_n(d_freq ), .pulse(p_freq ));
    key_repeat u_r3 (.clk(clk), .rst_n(rst_n), .key_n(d_phase), .pulse(p_phase));

    // ---------- 方向键：按下沿翻转 + 250ms 锁定 ----------
    reg        d_dir_r;
    reg [24:0] lock_cnt;

    always @(posedge clk) begin
        if (!rst_n) begin
            d_dir_r  <= 1'b1;
            dir_flag <= 1'b0;          // 上电默认"加"
            lock_cnt <= 25'd0;
        end else begin
            d_dir_r <= d_dir;

            if (dir_set) begin
                // 串口强制设定方向，同时重新上锁
                dir_flag <= dir_val;
                lock_cnt <= DIR_LOCK[24:0];
            end else if (lock_cnt != 25'd0) begin
                lock_cnt <= lock_cnt - 1'b1;      // 锁定中，忽略方向键
            end else if (!d_dir && d_dir_r) begin
                // 稳定按下沿（低有效：1->0 就是按下）
                dir_flag <= ~dir_flag;
                lock_cnt <= DIR_LOCK[24:0];
            end
        end
    end

    // ---------- 事件输出 ----------
    assign ev_wave_next = p_wave_r;
    assign ev_freq_up   = p_freq  & ~dir_flag;
    assign ev_freq_dn   = p_freq  &  dir_flag;
    assign ev_phase_up  = p_phase & ~dir_flag;
    assign ev_phase_dn  = p_phase &  dir_flag;

endmodule
