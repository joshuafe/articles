#!/usr/bin/env python3
"""
Scheduler prototype for DESIGN-PM.md §6.1 — stdlib only, written to be ported to Swift.

  python3 engine.py seed.json            -> prints the Now strip, every target's path, decisions
  python3 engine.py seed.json --ics out.ics   -> also writes the calendar feed (deadlines + milestones + blocks)

Two walks per target:
  backwards from the deadline  -> each step's WALL (latest finish for the end date to hold)
  forwards from today, EDF     -> each step's PLANNED start/end in real capacity, then its TARGET DATE
                                  (planned end + buffer, never past the wall).
"""
import json, sys, math
from datetime import date, timedelta, datetime

DAY = timedelta(days=1)

def d(s): return date.fromisoformat(s)

class Engine:
    def __init__(self, seed):
        self.today = d(seed["today"])
        cap = seed["capacity"]
        self.wk, self.we = cap["weekday_minutes"], cap["weekend_minutes"]
        self.fixed = {d(f["date"]): f["minutes"] for f in cap.get("fixed", [])}
        self.pattern = cap.get("pattern")
        self.projects = {p["id"]: p for p in seed["projects"]}
        self.targets = seed["targets"]
        self.decisions = list(seed.get("decisions", []))
        self.horizon = self.today + timedelta(days=120)

    # ---- capacity -------------------------------------------------------------------------
    def capacity(self, day):
        # a per-weekday pattern ("mon".."sun" -> minutes) wins over the two flat numbers
        pat = getattr(self, "pattern", None)
        if pat:
            base = pat.get(["mon","tue","wed","thu","fri","sat","sun"][day.weekday()], self.we if day.weekday() >= 5 else self.wk)
        else:
            base = self.we if day.weekday() >= 5 else self.wk
        return max(0, base - self.fixed.get(day, 0))

    # ---- backward walk: walls ----------------------------------------------------------------
    def walls(self, t):
        """latest finish per step, walking back from the target's deadline."""
        steps = [s for s in t["steps"] if not s.get("done")]
        due = d(t["due"]) if t.get("due") else None
        lf = due
        for s in reversed(steps):
            own = d(s["due"]) if s.get("due") else None
            wall = min(x for x in [lf, own] if x) if (lf or own) else None
            s["_wall"] = wall
            if wall is None:
                continue
            # latest start: consume the step's effort backwards over capacity, ending at the wall
            remaining, day = s["effort"], wall
            while remaining > 0 and day > self.today - timedelta(days=365):
                remaining -= self.capacity(day)
                if remaining > 0: day -= DAY
            s["_latest_start"] = day
            lf = day - timedelta(days=s.get("lead_days", 0))  # predecessor must finish before the lead begins
        return steps

    # ---- forward walk: EDF day simulation -------------------------------------------------------
    def plan(self):
        for t in self.targets:
            t["_steps"] = self.walls(t)
            for i, s in enumerate(t["_steps"]):
                s["_target"] = t; s["_index"] = i; s["_left"] = s["effort"]
                s["_planned_start"] = s["_planned_end"] = None
                s["_ready_from"] = self.today
        # Urgency classes, then earliest wall:
        #   0 a hard step that must begin by today (its latest start has arrived)
        #   1 an overdue goal step (its wall has passed) — it may use slack before non-urgent hard work
        #   2 any other hard step    3 any other goal step    4 backlog
        def rank(s, day):
            kind = s["_target"].get("kind")
            ls = s.get("_latest_start"); wall = s["_wall"]
            if kind == "hard" and ls and ls <= day: cls = 0
            elif kind == "goal" and wall and wall < day: cls = 1
            elif kind == "hard": cls = 2
            elif kind == "goal": cls = 3
            else: cls = 4
            return (cls, wall or self.horizon, s["_target"]["due"] or "9999", s["_index"])
        day = self.today
        self.allocations = {}  # day -> [(step, minutes)]
        while day <= self.horizon:
            free = self.capacity(day)
            while free > 0:
                ready = [s for t in self.targets for s in t["_steps"]
                         if s["_left"] > 0 and s["_ready_from"] <= day
                         and (s["_index"] == 0 or t["_steps"][s["_index"]-1]["_left"] == 0)]
                if not ready: break
                s = min(ready, key=lambda x: rank(x, day))
                take = min(free, s["_left"])
                s["_left"] -= take; free -= take
                s["_planned_start"] = s["_planned_start"] or day
                self.allocations.setdefault(day, []).append((s, take))
                if s["_left"] == 0:
                    s["_planned_end"] = day
                    nxt = s["_index"] + 1
                    if nxt < len(s["_target"]["_steps"]):
                        s["_target"]["_steps"][nxt]["_ready_from"] = day + timedelta(days=s.get("lead_days", 0)) + (DAY if s.get("lead_days") else timedelta(0))
            day += DAY
        # target dates, lateness, states
        for t in self.targets:
            late = []
            for s in t["_steps"]:
                pe = s["_planned_end"]
                buffer = max(1, math.ceil(s["effort"] / 240))  # a day per ~4 h of work, at least one
                if pe and s["_wall"]:
                    s["_target_date"] = min(s["_wall"], pe + timedelta(days=buffer))
                    s["_late"] = pe > s["_wall"]
                else:
                    s["_target_date"] = pe; s["_late"] = pe is None
                if s["_late"]: late.append(s)
            last = t["_steps"][-1] if t["_steps"] else None
            if last and last["_planned_end"] and last["_wall"]:
                t["_slack_days"] = (last["_wall"] - last["_planned_end"]).days
            else:
                t["_slack_days"] = None
            if t.get("kind") == "hard":
                t["_state"] = "willMiss" if late else ("atRisk" if (t["_slack_days"] is not None and t["_slack_days"] < 2) else "onTrack")
            elif t.get("kind") == "goal":
                t["_state"] = "slipping" if late else "onTrack"
            else:
                t["_state"] = "backlog"
            t["_late_steps"] = late
            if t["_state"] == "willMiss":
                self.decisions.append({
                    "id": f"E-{t['id']}", "target": t["id"], "engine": True,
                    "question": f"'{t['title']}' cannot be finished by {t['due']} at current capacity. What gives?",
                    "why_now": f"{late[0]['text']} lands on {late[0]['_planned_end']} but had to finish by {late[0]['_wall']}.",
                    "background": "Hard deadline; the engine never moves it. Everything due earlier was placed first (earliest deadline first).",
                    "touches": "This target and whatever you choose to move.",
                    "options": [{"label": "Add hours this week", "does": "Raise capacity on named days; the plan re-runs."},
                                {"label": "Move a goal out", "does": "Pushes a goal target's steps after this one."},
                                {"label": "Shrink the scope", "does": "Cut or shorten steps; the planner proposes which."}],
                    "if_unanswered": "It stays red; the step named above runs late."})

    # ---- reporting ---------------------------------------------------------------------------
    def now_strip(self):
        hard = sorted([t for t in self.targets if t.get("kind") == "hard"], key=lambda t: t["due"])
        due = [(t["due"], t["title"], t["_state"], t["_slack_days"]) for t in hard]
        at_risk = [t for t in self.targets if t["_state"] in ("willMiss", "atRisk", "slipping")]
        today = self.allocations.get(self.today, [])
        return due, at_risk, today

    def report(self):
        out = []
        P = out.append
        P(f"# Schedule as of {self.today:%a %b %d %Y}\n")
        if getattr(self, "pattern", None):
            P("Capacity (min/day): " + ", ".join(f"{k} {v}" for k, v in self.pattern.items()) + "; minus fixed events; EDF across all targets.\n")
        else:
            P(f"Capacity: {self.wk} min weekdays, {self.we} min weekend days, minus fixed events; EDF across all targets.\n")
        due, at_risk, today = self.now_strip()
        P("## Now strip\n")
        P("**Due (hard, by date)**\n")
        for dd, title, st, slack in due:
            mark = {"willMiss": "RED", "atRisk": "amber", "onTrack": "ok"}[st]
            P(f"- {dd} · {title} · {mark} · slack {slack if slack is not None else '?'} d")
        P("\n**At risk / slipping**\n")
        for t in at_risk:
            why = (f"{t['_late_steps'][0]['text']} planned to end {t['_late_steps'][0]['_planned_end']}, wall {t['_late_steps'][0]['_wall']}"
                   if t["_late_steps"] else f"slack {t['_slack_days']} d")
            P(f"- {t['title']} · {t['_state']} · {why}")
        if not at_risk: P("- nothing")
        P("\n**Today**\n")
        for s, m in today:
            P(f"- {m} min · {s['text']} ({s['_target']['title']})")
        if not today: P("- nothing scheduled")
        P("\n## Next 10 days\n")
        for i in range(10):
            day = self.today + timedelta(days=i)
            items = self.allocations.get(day, [])
            P(f"- **{day:%a %b %d}** ({self.capacity(day)} min): " + ("; ".join(f"{m}′ {s['text']} [{s['_target']['id']}]" for s, m in items) or "free"))
        P("\n## Targets and paths\n")
        for t in sorted(self.targets, key=lambda t: t.get("due") or "9999"):
            P(f"### {t['id']} · {t['title']} · {t.get('kind')} {t.get('due')} · {t['_state']} (slack {t['_slack_days']} d)")
            if t.get("why"): P(f"_{t['why']}_")
            P("")
            P("| step | effort | lead | wall | planned | target date | note |")
            P("|---|---|---|---|---|---|---|")
            for s in t["_steps"]:
                flags = " ".join(x for x in ["MILESTONE" if s.get("milestone") else "", "YOU" if s.get("needs_you") else "", "LATE" if s["_late"] else ""] if x)
                P(f"| {s['text']} | {s['effort']}′ | {s.get('lead_days', 0)} d | {s['_wall']} | {s['_planned_start']} → {s['_planned_end']} | **{s['_target_date']}** | {flags} |")
            P("")
        P("## Decisions for you\n")
        for dc in self.decisions:
            P(f"**{dc['id']} · {dc['question']}**  ")
            P(f"Why now: {dc['why_now']}  ")
            P(f"Background: {dc['background']}  ")
            P(f"Touches: {dc['touches']}  ")
            for o in dc["options"]: P(f"- [{o['label']}] → {o['does']}")
            P(f"If you don't answer: {dc['if_unanswered']}\n")
        return "\n".join(out)

    # ---- calendar feed -----------------------------------------------------------------------
    def ics(self, blocks=True):
        L = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//FrictionlessNotes//PM prototype//EN",
             "CALSCALE:GREGORIAN", "METHOD:PUBLISH", "X-WR-CALNAME:Deadlines (FrictionlessNotes)",
             "BEGIN:VTIMEZONE", "TZID:America/New_York",
             "BEGIN:STANDARD", "DTSTART:20071104T020000", "RRULE:FREQ=YEARLY;BYMONTH=11;BYDAY=1SU", "TZOFFSETFROM:-0400", "TZOFFSETTO:-0500", "TZNAME:EST", "END:STANDARD",
             "BEGIN:DAYLIGHT", "DTSTART:20070311T020000", "RRULE:FREQ=YEARLY;BYMONTH=3;BYDAY=2SU", "TZOFFSETFROM:-0500", "TZOFFSETTO:-0400", "TZNAME:EDT", "END:DAYLIGHT",
             "END:VTIMEZONE"]
        stamp = datetime.utcnow().strftime("%Y%m%dT%H%M%SZ")
        def esc(s): return s.replace("\\", "\\\\").replace(",", "\\,").replace(";", "\;").replace("\n", "\\n")
        def allday(uid, day, title, desc, transparent=False, seq=0):
            L.extend(["BEGIN:VEVENT", f"UID:{uid}@frictionlessnotes", f"DTSTAMP:{stamp}", f"SEQUENCE:{seq}",
                      f"DTSTART;VALUE=DATE:{day:%Y%m%d}", f"DTEND;VALUE=DATE:{(day+DAY):%Y%m%d}",
                      f"SUMMARY:{esc(title)}", f"DESCRIPTION:{esc(desc)}",
                      "TRANSP:TRANSPARENT" if transparent else "TRANSP:OPAQUE", "END:VEVENT"])
        for t in self.targets:
            if not t.get("due"): continue
            kind = t.get("kind")
            allday(t["id"], d(t["due"]), f"{t['title']} · {kind}",
                   f"{t['_state']}; slack {t['_slack_days']} d. {t.get('why','')}", transparent=(kind == "goal"))
            n = len(t["_steps"])
            for s in t["_steps"]:
                if s.get("milestone") and s["_target_date"]:
                    allday(s["id"], s["_target_date"], f"{s['text']} · {s['_index']+1} of {n} · {self.projects[t['project']]['name']}",
                           f"No later than {s['_wall']}. Estimate {s['effort']} min" + (f" + {s['lead_days']} d waiting" if s.get("lead_days") else "") + (". LATE" if s["_late"] else ""),
                           transparent=True)
        if blocks:
            for day, items in sorted(self.allocations.items()):
                start = datetime(day.year, day.month, day.day, 9 if day.weekday() < 5 else 10, 0)
                for s, m in items:
                    end = start + timedelta(minutes=m)
                    L.extend(["BEGIN:VEVENT", f"UID:{s['id']}-{day:%Y%m%d}@frictionlessnotes", f"DTSTAMP:{stamp}",
                              f"DTSTART;TZID=America/New_York:{start:%Y%m%dT%H%M%S}", f"DTEND;TZID=America/New_York:{end:%Y%m%dT%H%M%S}",
                              f"SUMMARY:{esc('Work: ' + s['text'])}", f"DESCRIPTION:{esc(s['_target']['title'])}", "TRANSP:TRANSPARENT", "END:VEVENT"])
                    start = end + timedelta(minutes=15)
        L.append("END:VCALENDAR")
        return "\r\n".join(L) + "\r\n"

if __name__ == "__main__":
    seed = json.load(open(sys.argv[1]))
    e = Engine(seed); e.plan()
    print(e.report())
    if "--ics" in sys.argv:
        path = sys.argv[sys.argv.index("--ics") + 1]
        open(path, "w").write(e.ics())
        print(f"\n(feed written to {path})")
