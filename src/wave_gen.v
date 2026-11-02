// ============================================================
// 波形合成：正弦 / 方波 / 三角 / 锯齿
//   输入 32 位相位，取高 10 位查 1024 点正弦表
//   中心值 2048，幅度 0..4095（12 位满量程）
//
// 注意：不能把三角波命名为 tri —— tri 是 Verilog 保留字
//       （三态线网类型），会直接报语法错误。这里用 tri_w。
// ============================================================
module wave_gen (
    input  wire        clk,
    input  wire [31:0] phase,
    input  wire [1:0]  wave_sel,   // 0=正弦 1=方波 2=三角 3=锯齿
    output reg  [11:0] code
);

    // ---- 正弦查表 ----
    wire [9:0]  addr = phase[31:22];
    wire [11:0] sin_q;

    sine_rom u_rom (
        .clk  (clk),
        .addr (addr),
        .q    (sin_q)
    );

    // ---- 三角波：前半周期上升，后半周期下降 ----
    wire [11:0] tri_w = phase[31] ? ~phase[30:19] : phase[30:19];

    // ---- 方波：相位最高位 ----
    wire [11:0] sqr_w = phase[31] ? 12'hFFF : 12'h000;

    // ---- 锯齿波：相位高 12 位直取 ----
    wire [11:0] saw_w = phase[31:20];

    always @(posedge clk) begin
        case (wave_sel)
            2'd0:    code <= sin_q;   // 正弦（ROM 有一拍延迟，不影响波形）
            2'd1:    code <= sqr_w;   // 方波
            2'd2:    code <= tri_w;   // 三角
            default: code <= saw_w;   // 锯齿
        endcase
    end

endmodule
