"""
backend.py - connects the website to the real Verilog scoring engine.

How it works
------------
1. Icarus Verilog (iverilog) compiles live_tb.v + cricket_scoreboard.v.
2. backend.py starts ONE long-running "vvp" simulation process.
3. Every button click becomes one text line written to vvp's standard input.
4. The Verilog testbench plays that delivery through the cricket_scoreboard
   module and prints a STATE line, which backend.py reads and sends to the
   browser as JSON.

The simulation keeps running between clicks, so the score is never reset
by a new event. Undo restarts the simulation and replays the earlier
deliveries through the same Verilog module.

Only the Python standard library is used. Run:  python backend.py
Then open  http://localhost:8000
"""

import json
import os
import queue
import shutil
import subprocess
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("PORT", 8000))
HERE = os.path.dirname(os.path.abspath(__file__))
VERILOG_FILES = ["live_tb.v", "cricket_scoreboard.v"]
SIM_FILE = "live_sim.vvp"

STATIC_FILES = {
    "/": ("index.html", "text/html; charset=utf-8"),
    "/index.html": ("index.html", "text/html; charset=utf-8"),
    "/style.css": ("style.css", "text/css; charset=utf-8"),
    "/script.js": ("script.js", "application/javascript; charset=utf-8"),
}

MAX_WICKETS = 10
BOWLER_COUNT = 5


# ---------------------------------------------------------------------
#  Verilog engine: one persistent Icarus Verilog (vvp) process
# ---------------------------------------------------------------------
class VerilogEngine:
    def __init__(self):
        self.iverilog = shutil.which("iverilog")
        self.vvp = shutil.which("vvp")
        if not self.iverilog or not self.vvp:
            raise RuntimeError(
                "iverilog / vvp not found in PATH. "
                "Start this script from the MSYS2 UCRT64 shell.")
        self.proc = None
        self.lines = queue.Queue()
        self.compile()

    def compile(self):
        cmd = [self.iverilog, "-g2005", "-o", SIM_FILE] + VERILOG_FILES
        result = subprocess.run(cmd, cwd=HERE, capture_output=True, text=True)
        if result.returncode != 0:
            raise RuntimeError("Verilog compile failed:\n" + result.stdout + result.stderr)

    def start(self):
        self.stop()
        self.lines = queue.Queue()
        self.proc = subprocess.Popen(
            [self.vvp, SIM_FILE], cwd=HERE,
            stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT, text=True, bufsize=1)
        threading.Thread(target=self._reader, args=(self.proc, self.lines),
                         daemon=True).start()

    @staticmethod
    def _reader(proc, out_queue):
        for line in proc.stdout:
            out_queue.put(line.rstrip("\r\n"))
        out_queue.put(None)          # process ended

    def stop(self):
        if self.proc is not None:
            try:
                self.proc.stdin.write("9 0 0 0 0 0 0\n")
                self.proc.stdin.flush()
                self.proc.wait(timeout=2)
            except Exception:
                self.proc.kill()
            self.proc = None

    def send(self, values):
        """Send one command line to the simulation and return the parsed STATE."""
        if self.proc is None or self.proc.poll() is not None:
            raise RuntimeError("Verilog simulation is not running.")
        self.proc.stdin.write(" ".join(str(int(v)) for v in values) + "\n")
        self.proc.stdin.flush()

        log = []
        while True:
            try:
                line = self.lines.get(timeout=5)
            except queue.Empty:
                raise RuntimeError("Verilog simulation did not answer.\n" + "\n".join(log))
            if line is None:
                raise RuntimeError("Verilog simulation stopped.\n" + "\n".join(log))
            if line.startswith("STATE "):
                return self.parse_state(line)
            log.append(line)

    @staticmethod
    def parse_state(line):
        state = {}
        for item in line.split()[1:]:
            key, value = item.split("=")
            if "," in value:
                state[key] = [int(v) for v in value.split(",")]
            else:
                state[key] = int(value)
        return state


# ---------------------------------------------------------------------
#  Match: innings list + undo history. All scoring comes from Verilog.
# ---------------------------------------------------------------------
class Match:
    def __init__(self):
        self.engine = VerilogEngine()
        self.team_names = ["Team A", "Team B"]
        self.max_overs = 20
        self.innings = []
        self.new_match(self.team_names, self.max_overs)

    # ----- helpers -----
    def current(self):
        return self.innings[-1]

    def start_innings_in_verilog(self, innings):
        """(Re)start the simulation and replay this innings' deliveries."""
        self.engine.start()
        state = self.engine.send([1, self.max_overs, innings["target"], 0, 0, 0, 0])
        for ev in innings["events"]:
            state = self.engine.send([2] + ev["payload"])
        innings["state"] = state

    def match_complete(self):
        return len(self.innings) == 2 and self.current()["state"]["over"] == 1

    # ----- actions -----
    def new_match(self, team_names, overs):
        self.team_names = team_names
        self.max_overs = overs
        self.innings = [{"target": 0, "events": [], "state": None}]
        self.start_innings_in_verilog(self.current())

    def play(self, kind, value):
        if self.match_complete():
            raise ValueError("The match is finished. Click Reset Match to play again.")
        inn = self.current()
        state = inn["state"]
        if state["over"] == 1:
            raise ValueError("This innings is over. Click Next Innings.")

        #            runs  wkt wide nb  bye lb
        if kind == "runs":
            payload, label = [value, 0, 0, 0, 0, 0], str(value)
        elif kind == "wicket":
            payload, label = [0, 1, 0, 0, 0, 0], "W"
        elif kind == "wide":
            payload, label = [0, 0, 1, 0, 0, 0], "Wd"
        elif kind == "noball":
            payload, label = [0, 0, 0, 1, 0, 0], "Nb"
        elif kind == "bye":
            payload, label = [value, 0, 0, 0, 1, 0], "B%d" % value
        elif kind == "legbye":
            payload, label = [value, 0, 0, 0, 0, 1], "Lb%d" % value
        else:
            raise ValueError("Unknown event")

        new_state = self.engine.send([2] + payload)      # <-- real Verilog does the scoring
        inn["events"].append({"payload": payload, "label": label,
                              "over_index": state["overs"]})
        inn["state"] = new_state

    def undo(self):
        inn = self.current()
        if not inn["events"]:
            if len(self.innings) == 1:
                raise ValueError("Nothing to undo.")
            self.innings.pop()                  # go back to the first innings
            inn = self.current()
        if inn["events"]:
            inn["events"].pop()
        self.start_innings_in_verilog(inn)      # replay through Verilog

    def next_innings(self):
        if len(self.innings) >= 2:
            raise ValueError("The second innings is already in progress.")
        first = self.current()
        target = first["state"]["runs"] + 1
        self.innings.append({"target": target, "events": [], "state": None})
        self.start_innings_in_verilog(self.current())

    # ----- JSON for the browser -----
    def snapshot(self):
        inn = self.current()
        s = inn["state"]
        innings_no = len(self.innings)
        bat_idx = innings_no - 1
        batting = self.team_names[bat_idx]
        bowling = self.team_names[1 - bat_idx]
        complete = self.match_complete()

        # batters
        batters = []
        for i in range(11):
            at_crease = i in (s["striker"], s["nonstriker"])
            if not (i < s["nextbat"] or at_crease):
                continue
            if s["bat_out"][i]:
                status = "out"
            elif at_crease and s["over"] == 0:
                status = "batting"
            else:
                status = "not out"
            runs, balls = s["bat_runs"][i], s["bat_balls"][i]
            batters.append({
                "name": "Batter %d" % (i + 1),
                "status": status,
                "on_strike": i == s["striker"] and s["over"] == 0,
                "runs": runs, "balls": balls,
                "fours": s["bat_fours"][i], "sixes": s["bat_sixes"][i],
                "sr": round(runs * 100.0 / balls, 1) if balls else 0.0,
            })

        # bowlers
        current_bowler = s["overs"] % BOWLER_COUNT
        bowlers = []
        for i in range(BOWLER_COUNT):
            balls, runs = s["bowl_balls"][i], s["bowl_runs"][i]
            bowling_now = i == current_bowler and s["over"] == 0
            if balls == 0 and runs == 0 and not bowling_now:
                continue
            bowlers.append({
                "name": "Bowler %d" % (i + 1),
                "bowling": bowling_now,
                "overs": "%d.%d" % (balls // 6, balls % 6),
                "runs": runs, "wickets": s["bowl_wkts"][i],
                "econ": round(runs * 6.0 / balls, 2) if balls else 0.0,
            })

        # this over (labels of the deliveries in the current over)
        over_no = s["overs"]
        title = "This over"
        if s["bio"] == 0 and over_no > 0:
            over_no -= 1
            title = "Last over"
        this_over = [e["label"] for e in inn["events"] if e["over_index"] == over_no]

        # chase information
        target = inn["target"]
        need = None
        if target:
            max_balls = self.max_overs * 6
            need = {"runs": max(target - s["runs"], 0),
                    "balls": max(max_balls - s["balls"], 0)}

        # summary of the first innings
        summaries = []
        for n, item in enumerate(self.innings):
            st = item["state"]
            summaries.append({
                "team": self.team_names[n],
                "runs": st["runs"], "wickets": st["wkts"],
                "overs": "%d.%d" % (st["overs"], st["bio"]),
            })

        return {
            "teams": self.team_names,
            "max_overs": self.max_overs,
            "innings_no": innings_no,
            "batting": batting,
            "bowling": bowling,
            "state": s,
            "run_rate": round(s["rr"] / 100.0, 2),
            "overs_text": "%d.%d" % (s["overs"], s["bio"]),
            "batters": batters,
            "bowlers": bowlers,
            "this_over": this_over,
            "this_over_title": title,
            "target": target,
            "need": need,
            "innings_over": s["over"] == 1,
            "match_complete": complete,
            "summaries": summaries,
            "status": self.status_text(s, target, complete, batting, bowling),
            "can_undo": bool(inn["events"]) or len(self.innings) > 1,
            "can_next_innings": innings_no == 1,
        }

    def status_text(self, s, target, complete, batting, bowling):
        if complete:
            first_runs = self.innings[0]["state"]["runs"]
            if s["runs"] >= target:
                return "%s won by %d wickets" % (batting, MAX_WICKETS - s["wkts"])
            if s["runs"] == target - 1:
                return "Match tied"
            return "%s won by %d runs" % (bowling, first_runs - s["runs"])
        if s["over"] == 1:
            return "Innings complete - %s %d/%d. Start the next innings." % (
                batting, s["runs"], s["wkts"])
        if target:
            runs_needed = target - s["runs"]
            balls_left = self.max_overs * 6 - s["balls"]
            return "%s need %d runs from %d balls" % (batting, runs_needed, balls_left)
        return "%s batting - first innings in progress" % batting


# ---------------------------------------------------------------------
#  HTTP server
# ---------------------------------------------------------------------
MATCH = None
LOCK = threading.Lock()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass                                    # keep the console quiet

    def send_json(self, data, code=200):
        body = json.dumps(data).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = self.path.split("?")[0]
        if path == "/api/state":
            with LOCK:
                self.send_json(MATCH.snapshot())
            return
        if path in STATIC_FILES:
            name, mime = STATIC_FILES[path]
            try:
                with open(os.path.join(HERE, name), "rb") as f:
                    body = f.read()
            except OSError:
                self.send_error(404)
                return
            self.send_response(200)
            self.send_header("Content-Type", mime)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)
            return
        self.send_error(404)

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        try:
            data = json.loads(self.rfile.read(length) or b"{}")
        except ValueError:
            self.send_json({"error": "Bad request"}, 400)
            return

        with LOCK:
            try:
                if self.path == "/api/event":
                    kind = data.get("type")
                    value = int(data.get("value", 0))
                    if kind == "runs" and value not in (0, 1, 2, 3, 4, 6):
                        raise ValueError("Invalid run value")
                    if kind in ("bye", "legbye") and value not in (1, 2, 3, 4):
                        raise ValueError("Invalid bye value")
                    MATCH.play(kind, value)
                elif self.path == "/api/undo":
                    MATCH.undo()
                elif self.path == "/api/next_innings":
                    MATCH.next_innings()
                elif self.path == "/api/reset":
                    a = str(data.get("team_a", "")).strip()[:24] or "Team A"
                    b = str(data.get("team_b", "")).strip()[:24] or "Team B"
                    overs = max(1, min(50, int(data.get("overs", 20))))
                    MATCH.new_match([a, b], overs)
                else:
                    self.send_error(404)
                    return
                self.send_json(MATCH.snapshot())
            except ValueError as err:
                result = MATCH.snapshot()
                result["error"] = str(err)
                self.send_json(result, 400)
            except RuntimeError as err:
                self.send_json({"error": str(err)}, 500)


def main():
    global MATCH
    try:
        MATCH = Match()
    except RuntimeError as err:
        print(err)
        sys.exit(1)

    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    print("Verilog engine ready (Icarus Verilog).")
    print("Open http://localhost:%d in your browser. Press Ctrl+C to stop." % PORT)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        MATCH.engine.stop()


if __name__ == "__main__":
    main()
