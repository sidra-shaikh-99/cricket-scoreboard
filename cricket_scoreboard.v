// =====================================================================
//  cricket_scoreboard.v
//  Digital cricket scoring engine (Verilog HDL).
//
//  One delivery is sent to the module by pulsing event_valid for one
//  clock cycle while the delivery inputs are held steady:
//
//     run_in     runs for this delivery (0..6)
//     wicket_in  a wicket fell on this delivery
//     wide_in    delivery was a wide      (not a legal ball)
//     noball_in  delivery was a no ball   (not a legal ball)
//     bye_in     runs are byes            (legal ball)
//     legbye_in  runs are leg byes        (legal ball)
//     (none of the extra flags)  -> normal delivery, runs off the bat
//
//  Meaning of run_in:
//     normal / wicket : runs scored by the batter
//     wide            : EXTRA runs on top of the 1 run penalty
//     no ball         : runs off the bat on top of the 1 run penalty
//     bye / leg bye   : number of bye / leg bye runs
//
//  max_overs : length of the innings in overs (1..50)
//  target    : runs needed to win in a chase, 0 = no target (1st innings)
// =====================================================================
module cricket_scoreboard (
    input             clk,
    input             rst,            // synchronous, active high
    input             event_valid,    // 1 clock pulse = 1 delivery
    input      [2:0]  run_in,
    input             wicket_in,
    input             wide_in,
    input             noball_in,
    input             bye_in,
    input             legbye_in,
    input      [5:0]  max_overs,
    input      [9:0]  target,

    // ---- team totals ----
    output reg [9:0]  total_runs,
    output reg [3:0]  wickets,
    output reg [8:0]  legal_balls,    // legal deliveries bowled
    output reg [6:0]  fours,
    output reg [6:0]  sixes,
    output reg [7:0]  extras,
    output reg [7:0]  wides,          // runs given as wides
    output reg [7:0]  noballs,        // number of no balls
    output reg [7:0]  byes,
    output reg [7:0]  legbyes,
    output     [5:0]  overs,          // completed overs
    output     [2:0]  balls_in_over,  // legal balls in the current over
    output     [15:0] run_rate_x100,  // run rate * 100
    output reg        innings_over,
    output reg        last_legal,     // was the last delivery a legal one?

    // ---- batters (11 per side, each value is 8 bits wide) ----
    output reg [3:0]  striker,
    output reg [3:0]  non_striker,
    output reg [3:0]  next_batter,
    output reg [87:0] bat_runs,
    output reg [87:0] bat_balls,
    output reg [87:0] bat_fours,
    output reg [87:0] bat_sixes,
    output reg [10:0] bat_out,

    // ---- bowlers (5 bowlers, bowl in rotation, 8 bits each) ----
    output reg [39:0] bowl_balls,
    output reg [39:0] bowl_runs,
    output reg [39:0] bowl_wkts
);

    // ------------------------------------------------------------
    //  Values derived from the counters
    // ------------------------------------------------------------
    wire [8:0] max_balls = max_overs * 6;

    assign overs         = legal_balls / 6;
    assign balls_in_over = legal_balls % 6;
    assign run_rate_x100 = (legal_balls == 0) ? 16'd0
                         : (total_runs * 20'd600) / legal_balls;

    // Bowler for the current over (bowlers rotate every over)
    wire [2:0] cur_bowler = overs % 5;

    // ------------------------------------------------------------
    //  Temporary variables used while decoding one delivery
    // ------------------------------------------------------------
    reg        ev_wide, ev_nb, ev_bye, ev_lb;
    reg        legal, is_wicket, faced, over_end, swap;
    reg [3:0]  total_add;     // runs added to the team total
    reg [3:0]  bat_add;       // runs credited to the batter
    reg [3:0]  bowl_add;      // runs charged to the bowler
    reg [3:0]  extra_add;     // runs added to extras
    reg [9:0]  new_runs;
    reg [3:0]  new_wkts;
    reg [8:0]  new_balls;
    reg [3:0]  ns, nn, tmp;

    always @(posedge clk) begin
        if (rst) begin
            total_runs   <= 0;   wickets     <= 0;   legal_balls <= 0;
            fours        <= 0;   sixes       <= 0;   extras      <= 0;
            wides        <= 0;   noballs     <= 0;   byes        <= 0;
            legbyes      <= 0;   innings_over <= 0;  last_legal  <= 0;
            striker      <= 0;   non_striker <= 1;   next_batter <= 2;
            bat_runs     <= 0;   bat_balls   <= 0;   bat_fours   <= 0;
            bat_sixes    <= 0;   bat_out     <= 0;
            bowl_balls   <= 0;   bowl_runs   <= 0;   bowl_wkts   <= 0;
        end
        else if (event_valid && !innings_over) begin

            // ---- 1. decide what kind of delivery this is ----
            ev_wide   = wide_in;
            ev_nb     = noball_in & ~wide_in;
            ev_bye    = bye_in    & ~wide_in & ~noball_in;
            ev_lb     = legbye_in & ~wide_in & ~noball_in & ~bye_in;
            is_wicket = wicket_in & ~wide_in & ~noball_in;
            legal     = ~(ev_wide | ev_nb);
            faced     = ~ev_wide;            // batter faces every ball except a wide

            // ---- 2. work out the runs ----
            total_add = 0;  bat_add = 0;  bowl_add = 0;  extra_add = 0;
            if (ev_wide) begin
                total_add = 4'd1 + run_in;   bowl_add = total_add;
                extra_add = total_add;
            end
            else if (ev_nb) begin
                total_add = 4'd1 + run_in;   bat_add  = run_in;
                bowl_add  = total_add;       extra_add = 4'd1;
            end
            else if (ev_bye || ev_lb) begin
                total_add = run_in;          extra_add = run_in;
            end
            else begin
                total_add = run_in;          bat_add = run_in;
                bowl_add  = run_in;
            end

            new_runs  = total_runs  + total_add;
            new_wkts  = wickets     + is_wicket;
            new_balls = legal_balls + legal;

            // ---- 3. who is on strike next? ----
            over_end = legal && ((new_balls % 6) == 0);
            ns = striker;
            nn = non_striker;
            if (is_wicket && new_wkts < 10) ns = next_batter;   // new batter walks in
            swap = run_in[0] ^ over_end;                        // odd runs or end of over
            if (swap) begin
                tmp = ns;  ns = nn;  nn = tmp;
            end
            striker     <= ns;
            non_striker <= nn;
            if (is_wicket && new_wkts < 10) next_batter <= next_batter + 1;

            // ---- 4. team counters ----
            total_runs  <= new_runs;
            wickets     <= new_wkts;
            legal_balls <= new_balls;
            last_legal  <= legal;
            extras      <= extras + extra_add;
            if (ev_wide) wides   <= wides + total_add;
            if (ev_nb)   noballs <= noballs + 1;
            if (ev_bye)  byes    <= byes + run_in;
            if (ev_lb)   legbyes <= legbyes + run_in;
            if (bat_add == 4) fours <= fours + 1;
            if (bat_add == 6) sixes <= sixes + 1;

            // ---- 5. batter statistics (striker before the ball) ----
            if (faced)
                bat_balls[striker*8 +: 8] <= bat_balls[striker*8 +: 8] + 1;
            if (bat_add != 0)
                bat_runs[striker*8 +: 8]  <= bat_runs[striker*8 +: 8] + bat_add;
            if (bat_add == 4)
                bat_fours[striker*8 +: 8] <= bat_fours[striker*8 +: 8] + 1;
            if (bat_add == 6)
                bat_sixes[striker*8 +: 8] <= bat_sixes[striker*8 +: 8] + 1;
            if (is_wicket)
                bat_out[striker] <= 1'b1;

            // ---- 6. bowler statistics ----
            if (legal)
                bowl_balls[cur_bowler*8 +: 8] <= bowl_balls[cur_bowler*8 +: 8] + 1;
            if (bowl_add != 0)
                bowl_runs[cur_bowler*8 +: 8]  <= bowl_runs[cur_bowler*8 +: 8] + bowl_add;
            if (is_wicket)
                bowl_wkts[cur_bowler*8 +: 8]  <= bowl_wkts[cur_bowler*8 +: 8] + 1;

            // ---- 7. is the innings finished? ----
            if (new_balls >= max_balls ||          // all overs bowled
                new_wkts  >= 10        ||          // all out
                (target != 0 && new_runs >= target))   // target chased
                innings_over <= 1'b1;
        end
    end

endmodule
