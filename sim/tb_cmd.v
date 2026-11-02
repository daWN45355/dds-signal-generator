// ============================================================
// cmd_parser 行为仿真
//   验证：
//     1) 复位默认值 F=1000 P=90 W=0 auto=0
//     2) "D1\r"  -> dir_set 脉冲 + dir_val=1
//     3) "F5000\r" -> freq 5000
//     4) "P\r"（只有字母没数字）-> 相位保持不变，不执行
//     5) 噪声字节 -> 不影响任何参数
//     6) "W4\r" -> auto_wave=1；再来一个波形按键事件 -> auto_wave 回 0 且 wave_fix 前进一格
//     7) 频率按键事件 -> freq +100
// ============================================================
`timescale 1ns / 1ps

module tb_cmd;

    reg        clk = 1'b0;
    reg        rst_n = 1'b0;

    reg  [7:0] rx_data  = 8'd0;
    reg        rx_valid = 1'b0;

    reg        ev_wave_next = 1'b0;
    reg        ev_freq_up   = 1'b0;
    reg        ev_freq_dn   = 1'b0;
    reg        ev_phase_up  = 1'b0;
    reg        ev_phase_dn  = 1'b0;

    wire [31:0] freq_hz;
    wire [8:0]  phase_deg;
    wire [1:0]  wave_fix;
    wire        auto_wave;
    wire [6:0]  ampl_pct;
    wire        dir_set;
    wire        dir_val;
    wire        stream_en;
    wire        upd;
    wire        query;

    cmd_parser dut (
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

    always #10 clk = ~clk;      // 50MHz

    // ---------- 脉冲抓取（dir_set / upd / query 都是单周期）----------
    reg dir_seen   = 1'b0;
    reg dir_val_q  = 1'b0;
    reg upd_seen   = 1'b0;
    reg qry_seen   = 1'b0;

    always @(posedge clk) begin
        if (dir_set) begin dir_seen <= 1'b1; dir_val_q <= dir_val; end
        if (upd)     upd_seen <= 1'b1;
        if (query)   qry_seen <= 1'b1;
    end

    integer errors = 0;

    // ---------- 发一个字节 ----------
    task send_byte(input [7:0] c);
        begin
            @(posedge clk);
            rx_data  <= c;
            rx_valid <= 1'b1;
            @(posedge clk);
            rx_valid <= 1'b0;
            repeat (4) @(posedge clk);
        end
    endtask

    // ---------- 发一条命令 ----------
    task send_str(input [7:0] a);
        begin
            send_byte(a);
        end
    endtask

    task clear_flags;
        begin
            dir_seen <= 1'b0;
            upd_seen <= 1'b0;
        end
    endtask

    task check(input [255:0] name,
               input [31:0] exp_f,
               input [8:0]  exp_p,
               input [1:0]  exp_w,
               input        exp_auto,
               input        exp_dir_seen,
               input        exp_dir_val);
        begin
            if (freq_hz !== exp_f || phase_deg !== exp_p ||
                wave_fix !== exp_w || auto_wave !== exp_auto) begin
                errors = errors + 1;
                $display("[FAIL] %0s : F=%0d P=%0d W=%0d auto=%0d (期望 F=%0d P=%0d W=%0d auto=%0d)",
                         name, freq_hz, phase_deg, wave_fix, auto_wave,
                         exp_f, exp_p, exp_w, exp_auto);
            end else if (dir_seen !== exp_dir_seen) begin
                errors = errors + 1;
                $display("[FAIL] %0s : dir_set=%0b (期望 %0b)", name, dir_seen, exp_dir_seen);
            end else if (exp_dir_seen && (dir_val_q !== exp_dir_val)) begin
                errors = errors + 1;
                $display("[FAIL] %0s : dir_val=%0b (期望 %0b)", name, dir_val_q, exp_dir_val);
            end else begin
                $display("[ OK ] %0s : F=%0d P=%0d W=%0d auto=%0d D=%0s",
                         name, freq_hz, phase_deg, wave_fix, auto_wave,
                         dir_val_q ? "-" : "+");
            end
            clear_flags;
            repeat (2) @(posedge clk);
        end
    endtask

    initial begin
        @(posedge clk); @(posedge clk);
        rst_n <= 1'b1;
        repeat (4) @(posedge clk);

        // 1) 默认值
        check("reset default", 32'd1000, 9'd90, 2'd0, 1'b0, 1'b0, 1'b0);

        // 2) D1
        send_byte("D"); send_byte("1"); send_byte(8'h0D);
        check("D1", 32'd1000, 9'd90, 2'd0, 1'b0, 1'b1, 1'b1);

        // 3) F5000
        send_byte("F"); send_byte("5"); send_byte("0"); send_byte("0"); send_byte("0"); send_byte(8'h0D);
        check("F5000", 32'd5000, 9'd90, 2'd0, 1'b0, 1'b0, 1'b0);

        // 4) "P" + 回车（只有字母没数字）-> 不执行，相位保持 90
        send_byte("P"); send_byte(8'h0D);
        check("P<CR> noise", 32'd5000, 9'd90, 2'd0, 1'b0, 1'b0, 1'b0);

        // 5) 纯噪声字节
        send_byte(8'hFF); send_byte(8'h00); send_byte(8'h5A); send_byte(8'h0D);
        check("garbage", 32'd5000, 9'd90, 2'd0, 1'b0, 1'b0, 1'b0);

        // 6) W4 开启自动轮换
        send_byte("W"); send_byte("4"); send_byte(8'h0D);
        check("W4 auto on", 32'd5000, 9'd90, 2'd0, 1'b1, 1'b0, 1'b0);

        // 7) 按键波形事件：退出自动 + wave_fix 前进
        @(posedge clk); ev_wave_next <= 1'b1;
        @(posedge clk); ev_wave_next <= 1'b0;
        repeat (2) @(posedge clk);
        check("key wave", 32'd5000, 9'd90, 2'd1, 1'b0, 1'b0, 1'b0);

        // 8) 频率按键：+100
        @(posedge clk); ev_freq_up <= 1'b1;
        @(posedge clk); ev_freq_up <= 1'b0;
        repeat (2) @(posedge clk);
        check("key freq +", 32'd5100, 9'd90, 2'd1, 1'b0, 1'b0, 1'b0);

        // 9) 频率按键往下：-100
        @(posedge clk); ev_freq_dn <= 1'b1;
        @(posedge clk); ev_freq_dn <= 1'b0;
        repeat (2) @(posedge clk);
        check("key freq -", 32'd5000, 9'd90, 2'd1, 1'b0, 1'b0, 1'b0);

        // 10) 相位按键：+15
        @(posedge clk); ev_phase_up <= 1'b1;
        @(posedge clk); ev_phase_up <= 1'b0;
        repeat (2) @(posedge clk);
        check("key phase +", 32'd5000, 9'd105, 2'd1, 1'b0, 1'b0, 1'b0);

        // 11) 串口 D0 改回加
        send_byte("D"); send_byte("0"); send_byte(8'h0D);
        check("D0", 32'd5000, 9'd105, 2'd1, 1'b0, 1'b1, 1'b0);

        // 11.5) S1 打开连续回传
        send_byte("S"); send_byte("1"); send_byte(8'h0D);
        repeat (2) @(posedge clk);
        if (stream_en !== 1'b1) begin
            errors = errors + 1;
            $display("[FAIL] S1 stream_en=%0b", stream_en);
        end else begin
            $display("[ OK ] S1 stream on");
        end

        // 12) "?" 查询
        @(posedge clk); qry_seen <= 1'b0;
        send_byte("?");
        repeat (2) @(posedge clk);
        if (!qry_seen) begin
            errors = errors + 1;
            $display("[FAIL] query ?");
        end else begin
            $display("[ OK ] query ?");
        end

        $display("--------------------------------------------------");
        if (errors == 0) $display("ALL TESTS PASSED");
        else             $display("%0d TEST(S) FAILED", errors);
        $display("--------------------------------------------------");
        $finish;
    end

    initial begin
        #200000;
        $display("[FAIL] timeout");
        $finish;
    end

endmodule
