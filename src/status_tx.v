// ============================================================
// 状态回传：把当前参数拼成一行 ASCII 发回电脑
//
//   F=01000 P=090 W=0 A=100 D=+ K=0000\r\n   (共 36 字节)
//
//   D=+ / D=-   按键加减方向
//   K=xxxx      四个按键的**按下状态**，顺序固定为
//                 K1=G19  K2=J19  K3=K19  K4=L16
//               1 = 正在按住，0 = 松开。没取反没消抖（顶层取反后的原始电平），
//               所以能直接看出两件事：
//                 ① 空闲时应该是 0000；不是 0000 说明某一路短路/极性问题
//                 ② 按住哪个键，哪一位变 1 —— 一眼看出引脚对应关系
//               实测：按 K1 → 1000，按 K2 → 0100，按 K3 → 0010，按 K4 → 0001
//               正式演示时可以发 S0 关掉自动回传，就不刷屏了。
//
//   115200 波特率下约 3.1ms 发完
// ============================================================
module status_tx (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        req,          // 单周期脉冲，触发一次回传
    input  wire [31:0] freq_hz,
    input  wire [8:0]  phase_deg,
    input  wire [2:0]  wave,         // 0..3 固定波形，4 = 自动轮换
    input  wire [6:0]  ampl_pct,
    input  wire        dir_flag,     // 0 = 加，1 = 减
    input  wire [3:0]  key_press,    // {L16, K19, J19, G19} 1 = 按下
    input  wire        tx_busy,
    output reg  [7:0]  tx_data,
    output reg         tx_start
);

    reg [7:0] msg_buf [0:35];
    reg [5:0] blen;
    reg [5:0] bidx;
    reg       sending;

    reg [16:0] fv;
    reg [8:0]  pv;
    reg [6:0]  av;

    always @(posedge clk) begin
        if (!rst_n) begin
            blen     <= 6'd0;
            bidx     <= 6'd0;
            sending  <= 1'b0;
            tx_start <= 1'b0;
            tx_data  <= 8'd0;
        end else begin
            tx_start <= 1'b0;

            // ---------- 组帧 ----------
            if (req && !sending) begin
                fv = freq_hz;
                pv = phase_deg;
                av = ampl_pct;

                msg_buf[0]  <= 8'h46;                       // 'F'
                msg_buf[1]  <= 8'h3D;                       // '='
                msg_buf[2]  <= 8'h30 + ((fv / 17'd10000) % 10);
                msg_buf[3]  <= 8'h30 + ((fv / 17'd1000)  % 10);
                msg_buf[4]  <= 8'h30 + ((fv / 17'd100)   % 10);
                msg_buf[5]  <= 8'h30 + ((fv / 17'd10)    % 10);
                msg_buf[6]  <= 8'h30 +  (fv % 10);
                msg_buf[7]  <= 8'h20;                       // ' '
                msg_buf[8]  <= 8'h50;                       // 'P'
                msg_buf[9]  <= 8'h3D;
                msg_buf[10] <= 8'h30 + ((pv / 9'd100) % 10);
                msg_buf[11] <= 8'h30 + ((pv / 9'd10)  % 10);
                msg_buf[12] <= 8'h30 +  (pv % 10);
                msg_buf[13] <= 8'h20;
                msg_buf[14] <= 8'h57;                       // 'W'
                msg_buf[15] <= 8'h3D;
                msg_buf[16] <= 8'h30 + {5'd0, wave};
                msg_buf[17] <= 8'h20;
                msg_buf[18] <= 8'h41;                       // 'A'
                msg_buf[19] <= 8'h3D;
                msg_buf[20] <= 8'h30 + ((av / 7'd100) % 10);
                msg_buf[21] <= 8'h30 + ((av / 7'd10)  % 10);
                msg_buf[22] <= 8'h30 +  (av % 10);
                msg_buf[23] <= 8'h20;
                msg_buf[24] <= 8'h44;                       // 'D'
                msg_buf[25] <= 8'h3D;
                msg_buf[26] <= dir_flag ? 8'h2D : 8'h2B;    // '-' : '+'
                msg_buf[27] <= 8'h20;
                msg_buf[28] <= 8'h4B;                       // 'K'
                msg_buf[29] <= 8'h3D;
                msg_buf[30] <= 8'h30 + {7'd0, key_press[3]};
                msg_buf[31] <= 8'h30 + {7'd0, key_press[2]};
                msg_buf[32] <= 8'h30 + {7'd0, key_press[1]};
                msg_buf[33] <= 8'h30 + {7'd0, key_press[0]};
                msg_buf[34] <= 8'h0D;                       // '\r'
                msg_buf[35] <= 8'h0A;                       // '\n'

                blen    <= 6'd36;
                bidx    <= 6'd0;
                sending <= 1'b1;
            end

            // ---------- 逐字节发 ----------
            if (sending && !tx_busy && !tx_start) begin
                tx_data  <= msg_buf[bidx];
                tx_start <= 1'b1;
                if (bidx + 6'd1 >= blen) begin
                    sending <= 1'b0;
                end else begin
                    bidx <= bidx + 6'd1;
                end
            end
        end
    end

endmodule
