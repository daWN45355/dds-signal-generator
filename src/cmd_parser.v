// ============================================================
`timescale 1ns / 1ps      // 只为仿真（xsim 要求全设计都有 timescale），
                          // 对综合没有任何影响
// 串口指令解析
//
// 指令格式：<字母><十进制数><回车>
//   F1000    频率 100..20000 Hz
//   P90      相位差 0..359 度
//   W2       波形 0=正弦 1=方波 2=三角 3=锯齿  4=自动轮换
//   A50      幅度 1..100 %
//   D0/D1    按键方向 0=加 1=减（K4 坏了也能用电脑改）
//   S0/S1    连续回传 0=关 1=开（每秒自动回传一行，调按键时很有用）
//   ?        查询当前参数
//
// 另外还接受来自按键的事件脉冲（ev_*），和串口命令共用同一组寄存器。
// 串口和按键可以任意混用，谁先到算谁的。
//
// 容错：
//   1) 非法字符直接丢弃，不会卡死状态机
//   2) **必须至少收到一位数字才执行命令**。
//      串口线没接（RX 悬空）时 D18 会捡噪声，随机会凑出 'P'/'\r' 这种
//      只有字母没有数字的"命令"，以前会把相位拍成 0、把波形拍回正弦，
//      表现就是"没动它，参数自己变了"。加了数字校验后噪声无法生效。
// ============================================================
module cmd_parser (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [7:0]  rx_data,
    input  wire        rx_valid,

    // 按键事件（单周期脉冲）
    input  wire        ev_wave_next,
    input  wire        ev_freq_up,
    input  wire        ev_freq_dn,
    input  wire        ev_phase_up,
    input  wire        ev_phase_dn,

    output reg  [31:0] freq_hz,     // 1 .. 20000
    output reg  [8:0]  phase_deg,   // 0 .. 359
    output reg  [1:0]  wave_fix,    // 固定波形 0..3
    output reg         auto_wave,   // 1 = 自动轮换
    output reg  [6:0]  ampl_pct,    // 1 .. 100

    output reg         dir_set,     // 串口改方向（单周期脉冲）
    output reg         dir_val,     // 配合 dir_set：0 = 加，1 = 减
    output reg         stream_en,   // 1 = 每秒自动回传一行状态

    output reg         upd,         // 参数更新脉冲（触发回传状态）
    output reg         query        // 收到 '?' 的脉冲
);

    localparam [1:0] S_IDLE = 2'd0,
                     S_NUM  = 2'd1;

    reg [1:0]  st;
    reg [7:0]  cmd_ch;
    reg [19:0] num;
    reg        has_num;         // 本条命令是否收到过数字

    always @(posedge clk) begin
        if (!rst_n) begin
            st        <= S_IDLE;
            cmd_ch    <= 8'd0;
            num       <= 20'd0;
            has_num   <= 1'b0;
            freq_hz   <= 32'd1000;    // 上电默认 1kHz
            phase_deg <= 9'd90;       // 默认 90°
            wave_fix  <= 2'd0;        // 默认正弦
            auto_wave <= 1'b0;        // 上电固定正弦，不再自动轮换
                                      // （有按键了，自动轮换会让用户以为芯片在乱跳；
                                      //   串口发 W4 仍然可以开启）
            ampl_pct  <= 7'd100;
            dir_set   <= 1'b0;
            dir_val   <= 1'b0;
            stream_en <= 1'b0;        // 默认不刷屏
            upd       <= 1'b0;
            query     <= 1'b0;
        end else begin
            upd     <= 1'b0;
            query   <= 1'b0;
            dir_set <= 1'b0;

            if (rx_valid) begin
                case (st)
                    // ---------------- 等命令字母 ----------------
                    S_IDLE: begin
                        case (rx_data)
                            8'h3F: begin                      // '?'
                                query <= 1'b1;
                            end
                            8'h46, 8'h50, 8'h57, 8'h41, 8'h44, 8'h53:
                            begin                             // 'F' 'P' 'W' 'A' 'D' 'S'
                                cmd_ch  <= rx_data;
                                num     <= 20'd0;
                                has_num <= 1'b0;
                                st      <= S_NUM;
                            end
                            default: ;                        // 其它字符忽略
                        endcase
                    end

                    // ---------------- 收数字 ----------------
                    S_NUM: begin
                        if (rx_data >= 8'h30 && rx_data <= 8'h39) begin
                            has_num <= 1'b1;
                            if (num < 20'd200_000)            // 防溢出
                                num <= num * 20'd10 + (rx_data - 8'h30);
                        end else if (rx_data == 8'h0D || rx_data == 8'h0A) begin
                            st <= S_IDLE;
                            // 没有任何数字就当作噪声，不执行
                            if (has_num) begin
                                case (cmd_ch)
                                    8'h46: begin              // 'F'
                                        if (num >= 20'd1 && num <= 20'd20000) begin
                                            freq_hz <= num;
                                            upd     <= 1'b1;
                                        end
                                    end
                                    8'h50: begin              // 'P'
                                        if (num <= 20'd359) begin
                                            phase_deg <= num[8:0];
                                            upd       <= 1'b1;
                                        end
                                    end
                                    8'h57: begin              // 'W'
                                        if (num <= 20'd3) begin
                                            wave_fix  <= num[1:0];
                                            auto_wave <= 1'b0;
                                            upd       <= 1'b1;
                                        end else if (num == 20'd4) begin
                                            auto_wave <= 1'b1;
                                            upd       <= 1'b1;
                                        end
                                    end
                                    8'h41: begin              // 'A'
                                        if (num >= 20'd1 && num <= 20'd100) begin
                                            ampl_pct <= num[6:0];
                                            upd      <= 1'b1;
                                        end
                                    end
                                    8'h44: begin              // 'D'
                                        if (num <= 20'd1) begin
                                            dir_val <= num[0];
                                            dir_set <= 1'b1;
                                            upd     <= 1'b1;
                                        end
                                    end
                                    8'h53: begin              // 'S' 连续回传
                                        if (num <= 20'd1) begin
                                            stream_en <= num[0];
                                            upd       <= 1'b1;
                                        end
                                    end
                                    default: ;
                                endcase
                            end
                        end else begin
                            st <= S_IDLE;                     // 非法字符，放弃本条
                        end
                    end

                    default: st <= S_IDLE;
                endcase
            end

            // ================ 按键事件 ================
            // 波形键：只在 4 种固定波形里循环 正弦→方波→三角→锯齿→正弦 …
            // 按键一律退出自动轮换模式，避免"按一下却在自动跳"的困惑
            if (ev_wave_next) begin
                auto_wave <= 1'b0;
                if (wave_fix == 2'd3) wave_fix <= 2'd0;
                else                  wave_fix <= wave_fix + 1'b1;
                upd <= 1'b1;
            end

            // 频率键：100Hz 一步，范围 100 .. 20000
            if (ev_freq_up) begin
                if (freq_hz >= 32'd19_900) freq_hz <= 32'd20_000;
                else                       freq_hz <= freq_hz + 32'd100;
                upd <= 1'b1;
            end

            if (ev_freq_dn) begin
                if (freq_hz <= 32'd200)    freq_hz <= 32'd100;
                else                       freq_hz <= freq_hz - 32'd100;
                upd <= 1'b1;
            end

            // 相位键：15° 一步，环形 0 .. 359
            if (ev_phase_up) begin
                if (phase_deg + 9'd15 > 9'd359)
                    phase_deg <= phase_deg + 9'd15 - 9'd360;
                else
                    phase_deg <= phase_deg + 9'd15;
                upd <= 1'b1;
            end

            if (ev_phase_dn) begin
                if (phase_deg < 9'd15)
                    phase_deg <= phase_deg + 9'd360 - 9'd15;
                else
                    phase_deg <= phase_deg - 9'd15;
                upd <= 1'b1;
            end
        end
    end

endmodule
