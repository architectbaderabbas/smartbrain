#!/usr/bin/env python3
"""
SmartBrain WATCHMAN - the cheap 5-minute guard.

Every 5 minutes:
  1. Reads the latest full-council decision (brain.json / brain.txt).
  2. Pulls only the fast feeds (breaking, geopolitics, oil, gold, central banks) + calendar.
  3. Asks a small, cheap model ONE question: "Is there a NEW major event since the last council
     that changes risk, or a sudden shock?"  (Haiku by default)
  4. If YES  -> runs the FULL council now (brain.py) so brain.txt is rewritten by the 9 experts.
     If NO   -> heartbeat: rewrites brain.txt with a fresh ts (so the robots know the brain is alive
                and nothing changed) while shifting the relative windows (news_block, shock) so they
                stay correct.
  5. If the last full council is older than FULL_EVERY_MIN, runs the full council anyway.

Env: ANTHROPIC_API_KEY, WATCH_MODEL (default claude-haiku-4-5), FULL_EVERY_MIN (default 60)
"""
import os, re, json, time, sys, subprocess, datetime as dt
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import brain  # reuse fetch / gnews / get_calendar / write helpers

OUT_DIR   = brain.OUT_DIR
API_KEY   = os.environ.get("ANTHROPIC_API_KEY", "").strip()
MODEL     = os.environ.get("WATCH_MODEL", "claude-haiku-4-5")
FULL_EVERY= int(os.environ.get("FULL_EVERY_MIN", "60"))
NOW       = int(time.time())

def load_last():
    try:
        with open(os.path.join(OUT_DIR, "brain.json"), encoding="utf-8") as f: return json.load(f)
    except Exception: return None

def run_full_council(reason):
    print("WATCHMAN -> full council:", reason)
    r = subprocess.run([sys.executable, os.path.join(OUT_DIR, "brain.py")], capture_output=True, text=True)
    print(r.stdout[-500:], r.stderr[-500:])
    log_watch(f"FULL COUNCIL triggered: {reason}")

def log_watch(line):
    p = os.path.join(OUT_DIR, "watch_log.md")
    with open(p, "a", encoding="utf-8") as f:
        f.write(f"- {dt.datetime.utcfromtimestamp(NOW).strftime('%Y-%m-%d %H:%M UTC')} · {line}\n")
    if os.path.getsize(p) > 200_000:
        data = open(p, encoding="utf-8").read()[-150_000:]
        open(p, "w", encoding="utf-8").write(data)

def shift_windows(d, elapsed_min):
    """news_block=CUR:start:end;...  shock=SYM:dir:valid:reason  are minutes relative to ts -> shift."""
    nb = d.get("news_block", "none")
    if nb and nb != "none":
        keep = []
        for part in nb.split(";"):
            f = part.split(":")
            if len(f) < 3: continue
            try:
                s, e = int(f[1]) - elapsed_min, int(f[2]) - elapsed_min
            except ValueError: continue
            if e >= -5: keep.append(f"{f[0]}:{s}:{e}")
        d["news_block"] = ";".join(keep) if keep else "none"
    sh = d.get("shock", "none")
    if sh and sh != "none":
        keep = []
        for part in sh.split(";"):
            f = part.split(":")
            if len(f) < 3: continue
            try: v = int(f[2]) - elapsed_min
            except ValueError: continue
            if v > 0: keep.append(":".join([f[0], f[1], str(v)] + f[3:]))
        d["shock"] = ";".join(keep) if keep else "none"
    return d

def heartbeat(last, note, calendar=None):
    d = dict(last["directives"])
    elapsed = int((NOW - int(last.get("ts", NOW))) / 60)
    d = shift_windows(d, elapsed)
    try:
        if calendar is None: calendar = brain.get_calendar()
        d["news_events"] = brain.news_events_line(calendar)
    except Exception: pass
    # write brain.txt with the NEW ts but the SAME decision; keep brain.json's council time in 'council_ts'
    txt = [f"ts={NOW}", f"generated={dt.datetime.utcfromtimestamp(NOW).strftime('%Y-%m-%d %H:%M UTC')} (watchman heartbeat; council {elapsed} min ago)", "version=1"]
    for k in brain.ORDER: txt.append(f"{k}={d.get(k,'')}")
    txt.append(f"watchman={note}")
    with open(os.path.join(OUT_DIR, "brain.txt"), "w", encoding="utf-8") as f: f.write("\n".join(txt) + "\n")
    with open(os.path.join(OUT_DIR, "brain.json"), "w", encoding="utf-8") as f:
        json.dump({"ts": NOW, "council_ts": last.get("council_ts", last.get("ts")), "directives": d,
                   "error": last.get("error"), "watchman": note, "alerts": last.get("alerts", [])[-10:]}, f, ensure_ascii=False, indent=1)
    log_watch("heartbeat · " + note)

WATCH_SYSTEM = """You are the WATCHMAN of a trading brain. A full council of experts meets periodically and issues directives.
Between meetings you check the fast news feeds every 5 minutes and answer ONE question:
Is there a NEW, MAJOR, MARKET-MOVING event or a SUDDEN SHOCK that happened AFTER the last council decision
and is NOT already reflected in it? Examples: military strike/escalation or ceasefire, surprise central-bank action or
intervention, flash crash / circuit breakers, major terror attack, big natural disaster hitting a market, OPEC surprise,
shock data release with a violent move, presidential/emergency announcement affecting markets.
Routine headlines, opinion pieces, repeats of what the council already knows => NO.
Answer ONLY in this exact format (no prose):
alert=<yes|no>
severity=<0-3>   (0 nothing, 1 notable, 2 serious, 3 extreme)
what=<one short line describing the new event, or none>
shock=<SYMBOL:dir(1|-1):valid_minutes:short_reason or none>   (only for a genuine sudden shock happening now)
"""

def ask_watch(last, headlines, calendar):
    if not API_KEY: return None, "no key"
    council_time = dt.datetime.utcfromtimestamp(int(last.get("council_ts", last.get("ts", NOW)))).strftime("%Y-%m-%d %H:%M UTC")
    d = last["directives"]
    handled = "\n".join(f"- {dt.datetime.utcfromtimestamp(a['ts']).strftime('%H:%M')} UTC: {a['what']}" for a in last.get("alerts", [])[-8:]) or "none"
    user = (f"UTC now: {dt.datetime.utcfromtimestamp(NOW).strftime('%Y-%m-%d %H:%M')}\n"
            f"Last full council: {council_time}\nIts summary: {d.get('summary')}\nIts risk_mode: {d.get('risk_mode')} shock: {d.get('shock')}\n"
            f"\n## Alerts ALREADY handled today (the council already met on these; the same story again => alert=no)\n{handled}\n\n"
            "## Fast feeds now\n")
    for k, v in headlines.items(): user += f"### {k}\n" + "\n".join(v) + "\n"
    soon = [e for e in calendar if isinstance(e.get("in_min"), int) and -30 <= e["in_min"] <= 30 and e.get("impact") == "high"]
    user += "\n## High-impact events within +/-30 min\n" + json.dumps(soon, ensure_ascii=False)
    body = json.dumps({"model": MODEL, "max_tokens": 200, "temperature": 0,
                       "system": WATCH_SYSTEM, "messages": [{"role": "user", "content": user}]}).encode()
    req = urllib.request.Request("https://api.anthropic.com/v1/messages", data=body, method="POST",
                                 headers={"content-type": "application/json", "x-api-key": API_KEY, "anthropic-version": "2023-06-01"})
    with urllib.request.urlopen(req, timeout=60) as r:
        res = json.loads(r.read())
    return "".join(p.get("text", "") for p in res.get("content", [])), None


def handle_trade(last):
    """A closed trade just arrived (EVENT=trade). Run the post-mortem desk, write the lesson,
    apply only CONSERVATIVE actions (restrict books / lower risk), then heartbeat."""
    trades = brain.read_trades(30)
    if not trades: return False
    t = trades[-1]
    print("WATCHMAN trade:", t.get("symbol"), t.get("book"), t.get("pl"))
    try:
        prices = brain.get_prices(); brain.NOW = NOW; brain.save_snapshot(prices)
    except Exception as ex:
        prices = None; print("snapshot error", ex)
    text = None
    try:
        text = brain.post_mortem(t, last, prices)
    except Exception as ex:
        print("post-mortem error", ex); log_watch(f"post-mortem error: {ex}")
    d = shift_windows(dict(last["directives"]), int((NOW - int(last.get("ts", NOW))) / 60))
    note = f"trade {t.get('symbol')} {t.get('book')} {t.get('pl')}$ -> post-mortem written"
    # 1) protocol: 3 losses in a row in one book today => book off for the rest of the day
    book = t.get("book", "?"); streak = 0
    day0 = NOW - (NOW % 86400)
    for x in reversed([x for x in trades if x.get("book") == book and int(x.get("t_out", 0)) >= day0]):
        if float(x.get("pl", 0) or 0) < 0: streak += 1
        else: break
    if streak >= 3 and book != "?":
        ab = d.get("allow_books", "ALL").upper()
        books = ["INTRADAY","SWING","POSITION","SHOCK","COUNCIL","REVERT"] if ab in ("ALL", "") else ab.split(",")
        books = [b for b in books if b and b != book]
        d["allow_books"] = ",".join(books) if books else "SWING"
        note += f"; {book} 3 losses in a row -> removed from allow_books"
    # 2) the post-mortem desk may ask for a conservative action
    if text:
        m = re.search(r"ACTION\s*=\s*(.+)", text)
        if m and m.group(1).strip().lower() != "none":
            for part in m.group(1).split(";"):
                kv = part.strip().split("=", 1)
                if len(kv) != 2: continue
                k, v = kv[0].strip().lower(), kv[1].strip().upper()
                if k == "allow_books" and v and v != "ALL":
                    cur = d.get("allow_books", "ALL").upper()
                    if cur in ("ALL", ""): d["allow_books"] = v
                    else: d["allow_books"] = ",".join([b for b in cur.split(",") if b in v.split(",")]) or v
                    note += f"; allow_books={d['allow_books']} (post-mortem)"
                elif k == "risk_mult":
                    try:
                        nv = float(v); cv = float(d.get("risk_mult", 1.0))
                        if nv < 0.4: nv = 0.4   # post-mortem may not starve the robots
                        if nv < cv: d["risk_mult"] = str(round(max(0.25, nv), 2)); note += f"; risk_mult={d['risk_mult']} (post-mortem)"
                    except Exception: pass
    last["directives"] = d
    heartbeat(last, note)
    return True

def main():
    last = load_last()
    if os.environ.get("FORCE_FULL") == "1":
        run_full_council("manual run"); return
    if not last or "directives" not in last:
        run_full_council("no previous council"); return
    if os.environ.get("EVENT") == "trade":
        if handle_trade(last): return
    council_ts = int(last.get("council_ts", last.get("ts", 0)))
    age_min = int((NOW - council_ts) / 60)
    if age_min >= FULL_EVERY:
        run_full_council(f"scheduled full council (last {age_min} min ago)"); return
    if last["directives"].get("risk_mode") in ("halt", "danger") and age_min >= 30:
        run_full_council(f"re-assess emergency mode ({last['directives'].get('risk_mode')}, council {age_min} min ago)"); return

    # price snapshot every 5 min (no LLM cost) so the scorecard can judge past calls
    try:
        prices = brain.get_prices(); brain.NOW = NOW; brain.save_snapshot(prices)
    except Exception as ex:
        print("snapshot error", ex)
    headlines = {
        "BREAKING":    brain.gnews('breaking OR "just in" OR urgent market OR "flash crash" when:1h', 8),
        "GEOPOLITICS": brain.gnews('strike OR attack OR missile OR ceasefire OR escalation OR war when:2h', 8),
        "OIL/GOLD":    brain.gnews('oil price OR gold price OR OPEC when:2h', 6),
        "CENTRAL BANKS": brain.gnews('"Federal Reserve" OR ECB OR "Bank of Japan" OR intervention OR "emergency rate" when:2h', 6),
    }
    calendar = brain.get_calendar()
    try:
        ans, err = ask_watch(last, headlines, calendar)
    except Exception as ex:
        ans, err = None, str(ex)
    if not ans:
        heartbeat(last, f"watch error: {err}", calendar); return
    kv = {}
    for line in ans.splitlines():
        m = re.match(r"\s*([a-z_]+)\s*=\s*(.*)$", line.strip())
        if m: kv[m.group(1)] = m.group(2).strip()
    alert = kv.get("alert", "no").lower() == "yes"
    sev = int(kv.get("severity", "0") or 0) if kv.get("severity", "0").isdigit() else 0
    what = kv.get("what", "none")
    shock = kv.get("shock", "none")
    print("WATCHMAN:", alert, sev, what, shock)
    if alert and sev >= 2:
        # dedupe: same story as a recent alert (word overlap) within 3h => already handled
        w_new = set(re.findall(r"[a-z]{4,}", what.lower()))
        for a in last.get("alerts", [])[-10:]:
            if NOW - int(a.get("ts", 0)) > 3 * 3600: continue
            w_old = set(re.findall(r"[a-z]{4,}", str(a.get("what", "")).lower()))
            if w_new and len(w_new & w_old) / max(1, len(w_new)) >= 0.5:
                print("WATCHMAN: same story already handled ->", a.get("what"))
                heartbeat(last, f"quiet (repeat of handled alert: {what[:60]})", calendar); return
        last.setdefault("alerts", []).append({"ts": NOW, "what": what, "sev": sev})
    if alert and sev >= 2:
        # EMERGENCY PROTOCOL: act first (robots read within 5 min), then convene the council
        d = shift_windows(dict(last["directives"]), int((NOW - int(last.get("ts", NOW))) / 60))
        if shock and shock != "none": d["shock"] = shock.replace(" ", "_")
        if sev >= 3:
            d["risk_mode"] = "halt"; d["allow_books"] = "SHOCK"; d["risk_mult"] = "0.5"
            d["summary"] = f"EMERGENCY (sev3): {what} - HALT new entries 30 min, SHOCK book only"
            d["summary_ar"] = "طوارئ: " + what + " — توقّف الدخول 30 دقيقة، كتاب الصدمة فقط"
        else:
            if d.get("risk_mode") in ("normal", "caution"): d["risk_mode"] = "danger"
            try: d["risk_mult"] = str(min(float(d.get("risk_mult", 1.0)), 0.6))
            except Exception: d["risk_mult"] = "0.6"
            d["summary"] = f"ALERT (sev2): {what} - danger mode until the council decides"
            d["summary_ar"] = "إنذار: " + what + " — وضع خطر حتى يقرّر المجلس"
        last["directives"] = d
        heartbeat(last, f"ALERT sev{sev}: {what} -> protocol applied, council convening", calendar)
        run_full_council(f"ALERT sev{sev}: {what}")
    else:
        heartbeat(last, f"quiet (sev{sev}) {what if what!='none' else ''}".strip(), calendar)

if __name__ == "__main__":
    main()
