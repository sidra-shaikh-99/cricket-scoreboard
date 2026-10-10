// =====================================================================
//  live_tb.v
//  "Live" testbench used by backend.py.
//
//  backend.py starts this simulation ONCE (vvp keeps running), then sends
//  one text line per command through standard input:
//
//     1 max_overs target 0 0 0 0      -> reset the scoreboard
//     2 runs wicket wide noball bye legbye -> play one delivery
//     9 0 0 0 0 0 0                   -> stop the simulation
//
//  After every command this testbench prints one line starting with
//  "STATE" that contains the values of the cricket_scoreboard module.
//  Because the simulation stays alive, the score is kept between clicks.
//  Waveforms are written to live_session.vcd (open it with GTKWave).
// =====================================================================
`timescale 1ns/1ps

module live_tb;

    reg        clk = 0;
    reg        rst = 1;
    reg        event_valid = 0;
    reg  [2:0] run_in = 0;
    reg        wicket_in = 0, wide_in = 0, noball_in = 0, bye_in = 0, legbye_in = 0;
    reg  [5:0] max_overs = 20;
    reg  [9:0] target = 0;

    wire [9:0]  total_runs;
    wire [3:0]  wickets;
    wire [8:0]  legal_balls;
    wire [6:0]  fours, sixes;
    wire [7:0]  extras, wides, noballs, byes, legbyes;
    wire [5:0]  overs;
    wire [2:0]  balls_in_over;
    wire [15:0] run_rate_x100;
    wire        innings_over, last_legal;
    wire [3:0]  striker, non_striker, next_batter;
    wire [87:0] bat_runs, bat_balls, bat_fours, bat_sixes;
    wire [10:0] bat_out;
    wire [39:0] bowl_balls, bowl_runs, bowl_wkts;

    cricket_scoreboard dut (
        .clk(clk), .rst(rst), .event_valid(event_valid),
        .run_in(run_in), .wicket_in(wicket_in), .wide_in(wide_in),
        .noball_in(noball_in), .bye_in(bye_in), .legbye_in(legbye_in),
        .max_overs(max_overs), .target(target),
        .total_runs(total_runs), .wickets(wickets), .legal_balls(legal_balls),
        .fours(fours), .sixes(sixes), .extras(extras), .wides(wides),
        .noballs(noballs), .byes(byes), .legbyes(legbyes),
        .overs(overs), .balls_in_over(balls_in_over),
        .run_rate_x100(run_rate_x100),
        .innings_over(innings_over), .last_legal(last_legal),
        .striker(striker), .non_striker(non_striker), .next_batter(next_batter),
        .bat_runs(bat_runs), .bat_balls(bat_balls),
        .bat_fours(bat_fours), .bat_sixes(bat_sixes), .bat_out(bat_out),
        .bowl_balls(bowl_balls), .bowl_runs(bowl_runs), .bowl_wkts(bowl_wkts)
    );

    always #5 clk = ~clk;     // 10 ns clock

    // Prints an array of 'count' values (each 'width' bits wide) as  a,b,c,...
    // Done with explicit tasks so the output is easy to parse in Python.
    integer k;

    task print_state;
        begin
            $write("STATE runs=%0d wkts=%0d balls=%0d overs=%0d bio=%0d fours=%0d sixes=%0d",
                   total_runs, wickets, legal_balls, overs, balls_in_over, fours, sixes);
            $write(" extras=%0d wides=%0d noballs=%0d byes=%0d legbyes=%0d",
                   extras, wides, noballs, byes, legbyes);
            $write(" rr=%0d over=%0d legal=%0d striker=%0d nonstriker=%0d nextbat=%0d",
                   run_rate_x100, innings_over, last_legal, striker, non_striker, next_batter);

            $write(" bat_runs=");
            for (k = 0; k < 11; k = k + 1) begin
                $write("%0d", bat_runs[k*8 +: 8]);   if (k < 10) $write(",");
            end
            $write(" bat_balls=");
            for (k = 0; k < 11; k = k + 1) begin
                $write("%0d", bat_balls[k*8 +: 8]);  if (k < 10) $write(",");
            end
            $write(" bat_fours=");
            for (k = 0; k < 11; k = k + 1) begin
                $write("%0d", bat_fours[k*8 +: 8]);  if (k < 10) $write(",");
            end
            $write(" bat_sixes=");
            for (k = 0; k < 11; k = k + 1) begin
                $write("%0d", bat_sixes[k*8 +: 8]);  if (k < 10) $write(",");
            end
            $write(" bat_out=");
            for (k = 0; k < 11; k = k + 1) begin
                $write("%0d", bat_out[k]);           if (k < 10) $write(",");
            end
            $write(" bowl_balls=");
            for (k = 0; k < 5; k = k + 1) begin
                $write("%0d", bowl_balls[k*8 +: 8]); if (k < 4) $write(",");
            end
            $write(" bowl_runs=");
            for (k = 0; k < 5; k = k + 1) begin
                $write("%0d", bowl_runs[k*8 +: 8]);  if (k < 4) $write(",");
            end
            $write(" bowl_wkts=");
            for (k = 0; k < 5; k = k + 1) begin
                $write("%0d", bowl_wkts[k*8 +: 8]);  if (k < 4) $write(",");
            end
            $write("\n");
            $fflush();
        end
    endtask

    integer n, cmd, a1, a2, a3, a4, a5, a6;
    reg     running;

    initial begin
        $dumpfile("live_session.vcd");
        $dumpvars(0, live_tb);

        running = 1;
        while (running) begin
            // 32'h8000_0000 is standard input in Icarus Verilog
            n = $fscanf(32'h8000_0000, "%d %d %d %d %d %d %d",
                        cmd, a1, a2, a3, a4, a5, a6);

            if (n != 7 || cmd == 9) begin
                running = 0;
            end
            else if (cmd == 1) begin
                // ---- reset: a1 = max overs, a2 = target ----
                @(negedge clk);
                max_overs = a1;
                target    = a2;
                rst       = 1;
                @(negedge clk);
                @(negedge clk);
                rst       = 0;
                print_state;
            end
            else if (cmd == 2) begin
                // ---- one delivery: a1=runs a2=wicket a3=wide a4=noball a5=bye a6=legbye ----
                @(negedge clk);
                run_in    = a1;
                wicket_in = a2;
                wide_in   = a3;
                noball_in = a4;
                bye_in    = a5;
                legbye_in = a6;
                event_valid = 1;
                @(negedge clk);
                event_valid = 0;
                run_in = 0;  wicket_in = 0;  wide_in = 0;
                noball_in = 0;  bye_in = 0;  legbye_in = 0;
                print_state;
            end
            $dumpflush;
        end

        $display("BYE");
        $finish;
    end

endmodule
