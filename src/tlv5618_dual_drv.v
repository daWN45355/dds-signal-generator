// ============================================================
// TLV5618A 双通道驱动 v3
//
// 时序依据（手册 SLAS230，VDD=5V）：
//   tw(H)/tw(L) SCLK 脉宽       >= 25 ns   → 本设计各 40 ns
//   tsu(CS-CK)  CS 拉低到首个沿  >= 5 ns    → 本设计 60 ns
//   tsu(C16-CS) 第16下降沿到CS上升 >= 10 ns → 本设计 60 ns
//   输出更新：第 16 个下降沿之后的“下一个上升沿”才更新 DAC
//            → 本设计在末位后补一个第 17 个上升沿，再拉高 CS
//   SCLK 频率 <= 20 MHz          → 本设计 12.5 MHz（周期 80 ns）
//
// 帧格式：D15=R1  D14=SPD  D13=PWR  D12=R0  D11..0=数据
//   R1R0=00 → 写 DAC B 并写 BUFFER
//   R1R0=01 → 只写 BUFFER（B 不动）
//   R1R0=10 → 写 DAC A，并用 BUFFER 内容同步更新 B
//
// 同步模式（mode=2）：先发 01 把 B 值放进 BUFFER，再发 10 ——
//   A 更新与 B 从 BUFFER 重载发生在同一时刻，两路严格同步。
// ============================================================
module tlv5618_dual_drv (
    input  wire        clk,        // 50MHz
    input  wire        rst_n,
    input  wire        start,      // 单周期脉冲
    input  wire [11:0] code_a,
    input  wire [11:0] code_b,
    input  wire [1:0]  mode,       // 0=A only  1=B only  2=同步A+B
    output reg         sclk,
    output reg         din,
    output reg         cs,
    output reg         busy
);

    localparam [3:0] S_IDLE   = 4'd0,
                     S_CS     = 4'd1,   // CS 拉低 2 个时钟
                     S_CS2    = 4'd2,
                     S_BIT    = 4'd3,   // 每位 4 个时钟
                     S_LAST0  = 4'd4,   // 末位后保持低 2 个时钟（满足 tw(L)）
                     S_LAST1  = 4'd5,   // 第 17 个上升沿（触发 DAC 更新）
                     S_LAST2  = 4'd6,
                     S_DONE   = 4'd7,   // CS 拉高
                     S_GAP1   = 4'd8,   // 帧间 CS 高电平保持
                     S_GAP2   = 4'd9;

    reg [3:0]  state;
    reg [1:0]  sub;         // 位内步进 0..3
    reg [15:0] shreg;
    reg [15:0] f0, f1;
    reg [1:0]  nframe;
    reg [1:0]  idx;
    reg [4:0]  bitcnt;

    wire [15:0] frame_buf = {1'b0, 1'b1, 1'b0, 1'b1, code_b}; // R1R0=01 只写BUFFER
    wire [15:0] frame_a   = {1'b1, 1'b1, 1'b0, 1'b0, code_a}; // R1R0=10 写A+更新B
    wire [15:0] frame_b   = {1'b0, 1'b1, 1'b0, 1'b0, code_b}; // R1R0=00 写B

    always @(posedge clk) begin
        if (!rst_n) begin
            state  <= S_IDLE;
            sclk   <= 1'b0;
            din    <= 1'b0;
            cs     <= 1'b1;
            shreg  <= 16'd0;
            bitcnt <= 5'd0;
            sub    <= 2'd0;
            busy   <= 1'b0;
            idx    <= 2'd0;
            nframe <= 2'd1;
            f0     <= 16'd0;
            f1     <= 16'd0;
        end else begin
            case (state)
                S_IDLE: begin
                    sclk <= 1'b0;
                    cs   <= 1'b1;
                    busy <= 1'b0;
                    if (start) begin
                        case (mode)
                            2'd0: begin f0 <= frame_a;   nframe <= 2'd1; end
                            2'd1: begin f0 <= frame_b;   nframe <= 2'd1; end
                            default: begin f0 <= frame_buf; f1 <= frame_a; nframe <= 2'd2; end
                        endcase
                        idx   <= 2'd0;
                        cs    <= 1'b0;
                        busy  <= 1'b1;
                        state <= S_CS;
                    end
                end

                // ---- CS 建立：2 个时钟 = 40ns（含首位间隔共 60ns）----
                S_CS: begin
                    shreg  <= (idx == 2'd0) ? f0 : f1;
                    bitcnt <= 5'd0;
                    sub    <= 2'd0;
                    state  <= S_CS2;
                end
                S_CS2: state <= S_BIT;

                // ---- 每位 4 个时钟：低(数据就位) → 高 → 高 → 低(采样) ----
                S_BIT: begin
                    case (sub)
                        2'd0: begin
                            din <= shreg[15];      // 数据就位（SCLK 低）
                            sub <= 2'd1;
                        end
                        2'd1: begin
                            sclk <= 1'b1;          // 上升沿
                            sub  <= 2'd2;
                        end
                        2'd2: begin
                            sclk <= 1'b1;          // 高电平共 2 个时钟 = 40ns
                            sub  <= 2'd3;
                        end
                        default: begin
                            sclk <= 1'b0;          // 下降沿（DAC 在此采样）
                            if (bitcnt == 5'd15) begin
                                state <= S_LAST0;
                            end else begin
                                shreg  <= {shreg[14:0], 1'b0};
                                bitcnt <= bitcnt + 1'b1;
                                sub    <= 2'd0;
                            end
                        end
                    endcase
                end

                // ---- 末位后低电平保持 2 个时钟 = 40ns ----
                S_LAST0: begin
                    sclk  <= 1'b0;
                    state <= S_LAST1;
                end

                // ---- 第 17 个上升沿：手册要求，输出在此更新 ----
                S_LAST1: begin
                    sclk  <= 1'b1;
                    state <= S_LAST2;
                end
                S_LAST2: begin
                    sclk  <= 1'b1;
                    state <= S_DONE;
                end

                // ---- CS 上升（距第 16 下降沿 60ns，要求 >=10ns）----
                S_DONE: begin
                    cs <= 1'b1;
                    if ((idx + 2'd1) < nframe) begin
                        state <= S_GAP1;
                    end else begin
                        busy  <= 1'b0;
                        state <= S_IDLE;
                    end
                end

                S_GAP1: begin
                    sclk  <= 1'b0;
                    state <= S_GAP2;
                end

                S_GAP2: begin
                    cs    <= 1'b0;
                    idx   <= idx + 2'd1;
                    state <= S_CS;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
