// ============================================================
// UART 接收（115200-8-N-1）
//   50MHz / 115200 = 434.03  → 每位 434 个时钟
//   起始位中点确认（抗毛刺），数据位中点采样，LSB 先到
// ============================================================
module uart_rx #(
    parameter integer CLK_FREQ = 50_000_000,
    parameter integer BAUD     = 115200
)(
    input  wire       clk,
    input  wire       rst_n,
    input  wire       rx,
    output reg  [7:0] data,
    output reg        valid      // 收到一个字节，单周期脉冲
);

    localparam integer CLK_CNT = CLK_FREQ / BAUD;   // 434
    localparam integer HALF    = CLK_CNT / 2;       // 217

    localparam [1:0] S_IDLE  = 2'd0,
                     S_START = 2'd1,
                     S_DATA  = 2'd2,
                     S_STOP  = 2'd3;

    reg [1:0]  st;
    reg [1:0]  sync;        // 两级同步，跨时钟域防亚稳态
    reg [15:0] cnt;
    reg [3:0]  bitn;
    reg [9:0]  sh;

    wire rx_s      = sync[1];                        // 较旧的采样（延迟 2 拍）
    // 下降沿 = 上一拍为高、这一拍为低。sync[0] 比 sync[1] 新。
    wire fall_edge = (sync[1] == 1'b1) && (sync[0] == 1'b0);

    always @(posedge clk) begin
        sync <= {sync[0], rx};
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            st    <= S_IDLE;
            cnt   <= 16'd0;
            bitn  <= 4'd0;
            sh    <= 10'h3FF;
            data  <= 8'd0;
            valid <= 1'b0;
        end else begin
            valid <= 1'b0;
            case (st)
                S_IDLE: begin
                    if (fall_edge) begin
                        cnt <= 16'd0;
                        st  <= S_START;
                    end
                end

                // ---- 等到起始位中点，再确认一次确实是低 ----
                S_START: begin
                    if (cnt >= HALF - 1) begin
                        cnt <= 16'd0;
                        if (!rx_s) begin
                            bitn <= 4'd0;
                            st   <= S_DATA;
                        end else begin
                            st <= S_IDLE;       // 毛刺，丢弃
                        end
                    end else begin
                        cnt <= cnt + 1'b1;
                    end
                end

                // ---- 8 个数据位，每位中点采样 ----
                S_DATA: begin
                    if (cnt >= CLK_CNT - 1) begin
                        cnt <= 16'd0;
                        sh  <= {rx_s, sh[9:1]};
                        if (bitn == 4'd7) st   <= S_STOP;
                        else              bitn <= bitn + 1'b1;
                    end else begin
                        cnt <= cnt + 1'b1;
                    end
                end

                // ---- 停止位 ----
                S_STOP: begin
                    if (cnt >= CLK_CNT - 1) begin
                        cnt   <= 16'd0;
                        data  <= sh[9:2];       // 8 位数据在这里
                        valid <= 1'b1;
                        st    <= S_IDLE;
                    end else begin
                        cnt <= cnt + 1'b1;
                    end
                end

                default: st <= S_IDLE;
            endcase
        end
    end

endmodule
