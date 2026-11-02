// ============================================================
// 阶段 7 顶层：双通道 DDS + 四按键面板 + 串口在线调参
//
//   按键：直接用扩展板自带的 S1~S4（丝印 KEY_1~KEY_4），
//         **低有效**（引脚经 220R 上拉到 VCC_3V3，按下短到 GND）
//         实测：空闲 K=1111，按 K1/K2/K3/K4 依次变 1110/1101/1011/0111
//         G19 = KEY_1  波形键：正弦→方波→三角→锯齿→正弦 …（只在这 4 种里循环）
//         J19 = KEY_2  频率键：按住加减，100Hz 一步，长按连发
//         K19 = KEY_3  相位键：按住加减，15° 一步，长按连发
//         L16 = KEY_4  方向键：短按翻转"加/减"（翻转后锁 250ms，防误触）
//
//   串口 115200-8-N-1，指令以回车结尾：
//     F1000    频率 100..20000 Hz
//     P90      相位差 0..359 度
//     W2       波形 0正弦 1方波 2三角 3锯齿 4自动轮换
//     A50      幅度 1..100 %
//     D1       按键方向 0=加 1=减
//     S1       连续回传 每秒自动来一行（调按键时用）
//     ?        查询，回一行 F=01000 P=090 W=0 A=100 D=+ K=0000
//
//   K= 报四个按键的按下状态，顺序 {L16,K19,J19,G19}：
//     空闲 0000，按 K1/K2/K3/K4 依次变 1000/0100/0010/0001。
//     空闲不是 0000 就说明某一路短路或极性问题。
//
//   按键和串口共用同一组参数寄存器，可以混着用。
//   每次参数变化都会自动回传一行状态，所以按键操作也能在电脑上看到。
//
//   注意：P4 排针是摄像头接口（OV5640），上面的脚基本都是 OV_* 信号。
//         本项目用的 F19/F20/D19/D18/D20/C20 分别对应 OV_HREF/OV_XCLK/
//         OV_D7/OV_D5/OV_D4/OV_D2 —— 不接摄像头时正好可以挪用。
// ============================================================
module dds_key_top (
    input  wire clk,        // N18  50MHz
    input  wire key_wave,   // G19  板载 KEY_1，低有效（未按=1）
    input  wire key_freq,   // J19  板载 KEY_2，低有效
    input  wire key_phase,  // K19  板载 KEY_3，低有效
    input  wire key_dir,    // L16  板载 KEY_4，低有效
    input  wire uart_rx,    // D18  接 CH340 TXD
    output wire uart_tx,    // D20  接 CH340 RXD
    output wire dac_din,    // F19
    output wire dac_sclk,   // F20
    output wire dac_cs,     // D19
    output wire heart       // C20  1Hz 心跳
);

    localparam [31:0] WAVE_PERIOD = 32'd100_000_000;  // 自动轮换 2s 一种

    // ================= 上电复位 =================
    // 显式给初值：Xilinx 触发器上电本来就会清零，但在 xsim 里
    // 未初始化 reg 是 X，会让复位判断失效、整条链路染成 X。
    // 写上初值后仿真与硬件行为一致。
    //
    // 本板没有复位按键（V13 实测悬空），所以只用上电复位，
    // 不再把 V13 接进来 —— 悬空输入会导致随机复位。
    reg [15:0] por_cnt = 16'd0;
    reg        rst_n   = 1'b0;

    always @(posedge clk) begin
        if (por_cnt != 16'hFFFF) begin
            por_cnt <= por_cnt + 1'b1;
            rst_n   <= 1'b0;
        end else begin
            rst_n   <= 1'b1;
        end
    end

    // ================= 串口接收 =================
    wire [7:0] rx_data;
    wire       rx_valid;

    uart_rx #(
        .CLK_FREQ (50_000_000),
        .BAUD     (115200)
    ) u_rx (
        .clk   (clk),
        .rst_n (rst_n),
        .rx    (uart_rx),
        .data  (rx_data),
        .valid (rx_valid)
    );

    // ================= 按键 =================
    wire ev_wave_next;
    wire ev_freq_up;
    wire ev_freq_dn;
    wire ev_phase_up;
    wire ev_phase_dn;
    wire dir_flag;
    wire dir_set;
    wire dir_val;

    key_ctrl u_key (
        .clk          (clk),
        .rst_n        (rst_n),
        // 板载按键是【低有效】：引脚经 220R 上拉到 VCC_3V3，
        // 未按下读 1，按下被按键短到 GND 读 0。
        // 实测数据（状态行 K= 字段，原始电平，顺序 L16 K19 J19 G19）：
        //   空闲 1111   按 KEY_1 1110   按 KEY_2 1101
        //   按 KEY_3 1011   按 KEY_4 0111
        // key_ctrl 内部本来就按低有效写的，所以这里【直接接，不取反】。
        // 之前错按"高有效"取了反，结果空闲时被当成"一直按住"：
        // 频率一路减到 100Hz、相位不停转、方向被翻成减 —— 全对上了。
        .key_wave     (key_wave),
        .key_freq     (key_freq),
        .key_phase    (key_phase),
        .key_dir      (key_dir),
        // 串口 D0/D1 也能改方向，K4 坏了照样能调
        .dir_set      (dir_set),
        .dir_val      (dir_val),
        .ev_wave_next (ev_wave_next),
        .ev_freq_up   (ev_freq_up),
        .ev_freq_dn   (ev_freq_dn),
        .ev_phase_up  (ev_phase_up),
        .ev_phase_dn  (ev_phase_dn),
        .dir_flag     (dir_flag)
    );

    // ================= 指令解析 =================
    wire [31:0] freq_hz;
    wire [8:0]  phase_deg;
    wire [1:0]  wave_fix;
    wire        auto_wave;
    wire [6:0]  ampl_pct;
    wire        upd;
    wire        query;
    wire        stream_en;

    cmd_parser u_parser (
        .clk          (clk),
        .rst_n        (rst_n),
        .rx_data      (rx_data),
        .rx_valid     (rx_valid),
        .ev_wave_next (ev_wave_next),
        .ev_freq_up   (ev_freq_up),
        .ev_freq_dn   (ev_freq_dn),
        .ev_phase_up  (ev_phase_up),
        .ev_phase_dn  (ev_phase_dn),
        .freq_hz      (freq_hz),
        .phase_deg    (phase_deg),
        .wave_fix     (wave_fix),
        .auto_wave    (auto_wave),
        .ampl_pct     (ampl_pct),
        .dir_set      (dir_set),
        .dir_val      (dir_val),
        .stream_en    (stream_en),
        .upd          (upd),
        .query        (query)
    );

    // ================= 参数换算 =================
    //
    // 频率控制字 = f × 2^32 / 50e6 = f × 85.89934592
    //   原来写成 (f * 85899) / 1000，除法器组合延迟太大（WNS 曾 -1.877ns）。
    //   改用定点乘：85.89934592 × 2^24 = 1441151881，误差 6e-10，
    //   只需一个乘法器加一次右移。
    //
    // 相位偏移 = 角度 × 2^32 / 360 ≈ 角度 × 11930464
    //
    // 两者都打一拍再驱动相位累加器，切断长组合路径。
    wire [14:0] f15     = freq_hz[14:0];
    wire [45:0] fw_prod = f15 * 46'd1441151881;
    wire [32:0] pw_prod = phase_deg * 33'd11930464;

    reg [31:0] freq_word;
    reg [31:0] phase_word;

    always @(posedge clk) begin
        if (!rst_n) begin
            freq_word  <= 32'd85899;          // 默认 1kHz
            phase_word <= 32'h4000_0000;      // 默认 90°
        end else begin
            freq_word  <= fw_prod[45:24];     // ÷ 2^24
            phase_word <= pw_prod[31:0];
        end
    end

    // 幅度增益：百分比 × 655 ≈ (百分比/100) × 65536
    wire [16:0] ampl_gain = ampl_pct * 17'd655;

    // ================= 相位累加器 =================
    reg  [31:0] phase_a;
    wire [31:0] phase_b = phase_a + phase_word;

    always @(posedge clk) begin
        if (!rst_n) phase_a <= 32'd0;
        else        phase_a <= phase_a + freq_word;
    end

    // ================= 波形选择 =================
    reg [31:0] wave_cnt;
    reg [1:0]  auto_cnt;

    always @(posedge clk) begin
        if (!rst_n) begin
            wave_cnt <= 32'd0;
            auto_cnt <= 2'd0;
        end else if (wave_cnt >= WAVE_PERIOD - 1'b1) begin
            wave_cnt <= 32'd0;
            auto_cnt <= auto_cnt + 1'b1;
        end else begin
            wave_cnt <= wave_cnt + 1'b1;
        end
    end

    wire [1:0] wave_now = auto_wave ? auto_cnt : wave_fix;

    // ================= 波形合成 =================
    wire [11:0] code_a;
    wire [11:0] code_b;

    wave_gen u_wave_a (
        .clk      (clk),
        .phase    (phase_a),
        .wave_sel (wave_now),
        .code     (code_a)
    );

    wave_gen u_wave_b (
        .clk      (clk),
        .phase    (phase_b),
        .wave_sel (wave_now),
        .code     (code_b)
    );

    // ================= 幅度缩放（围绕 2048 中心）=================
    wire signed [12:0] sa = $signed({1'b0, code_a}) - 13'sd2048;
    wire signed [12:0] sb = $signed({1'b0, code_b}) - 13'sd2048;

    wire signed [17:0] gain_s = $signed({1'b0, ampl_gain});
    wire signed [30:0] pa = sa * gain_s;
    wire signed [30:0] pb = sb * gain_s;

    wire signed [12:0] oa = pa >>> 16;
    wire signed [12:0] ob = pb >>> 16;

    wire [11:0] code_a_s = oa + 13'sd2048;
    wire [11:0] code_b_s = ob + 13'sd2048;

    // ================= 更新节拍 =================
    // 以前是固定每 256 个时钟（5.12us）更新一次，现在改成
    // "SPI 一空就立刻送下一组" —— 采样率从 195kHz 提到约 340kHz，
    // 锯齿波/方波的台阶更细，示波器上更干净。
    // （一帧 16 位 × 4 时钟 × 2 帧 + 收尾 ≈ 146 个时钟 ≈ 2.9us）
    wire        busy;
    reg         start;
    reg  [11:0] lat_a, lat_b;

    always @(posedge clk) begin
        if (!rst_n) begin
            start <= 1'b0;
            lat_a <= 12'd2048;
            lat_b <= 12'd2048;
        end else begin
            start <= 1'b0;
            if (!busy) begin
                lat_a <= code_a_s;
                lat_b <= code_b_s;
                start <= 1'b1;
            end
        end
    end

    tlv5618_dual_drv u_drv (
        .clk     (clk),
        .rst_n   (rst_n),
        .start   (start),
        .code_a  (lat_a),
        .code_b  (lat_b),
        .mode    (2'd2),
        .sclk    (dac_sclk),
        .din     (dac_din),
        .cs      (dac_cs),
        .busy    (busy)
    );

    // ================= 1Hz 节拍 / 心跳 =================
    reg [24:0] hcnt;
    reg        hreg;
    reg        sec_tick;

    always @(posedge clk) begin
        if (!rst_n) begin
            hcnt     <= 25'd0;
            hreg     <= 1'b0;
            sec_tick <= 1'b0;
        end else if (hcnt >= 25'd24_999_999) begin
            hcnt     <= 25'd0;
            hreg     <= ~hreg;
            sec_tick <= 1'b1;          // 每秒一个脉冲，给"连续回传"用
        end else begin
            hcnt     <= hcnt + 1'b1;
            sec_tick <= 1'b0;
        end
    end

    assign heart = hreg;

    // ================= 状态回传 =================
    // K= 报的是四个按键的**按下状态**（位序 {L16,K19,J19,G19}），
    // 也就是原始电平取反后的结果：1 = 按住，0 = 松开。
    // 空闲应为 0000；按 K1/K2/K3/K4 依次变 1000/0100/0010/0001。
    wire [3:0] key_press = ~{key_dir, key_phase, key_freq, key_wave};

    wire [7:0] st_data;
    wire       st_start;
    wire       tx_busy;

    status_tx u_status (
        .clk       (clk),
        .rst_n     (rst_n),
        // S1 打开连续回传后，每秒自动来一行，调按键时不用一直按 ?
        .req       (upd | query | (stream_en & sec_tick)),
        .freq_hz   (freq_hz),
        .phase_deg (phase_deg),
        // 回传的是"模式"不是"当前波形"：自动轮换时报 4，
        // 否则按 auto_cnt 报会一直显示 0~3，看不出已经切到自动模式
        .wave      (auto_wave ? 3'd4 : {1'b0, wave_fix}),
        .ampl_pct  (ampl_pct),
        .dir_flag  (dir_flag),
        .key_press (key_press),
        .tx_busy   (tx_busy),
        .tx_data   (st_data),
        .tx_start  (st_start)
    );

    uart_tx #(
        .CLK_FREQ (50_000_000),
        .BAUD     (115200)
    ) u_tx (
        .clk   (clk),
        .rst_n (rst_n),
        .data  (st_data),
        .start (st_start),
        .tx    (uart_tx),
        .busy  (tx_busy)
    );

endmodule
