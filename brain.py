#!/usr/bin/env python3
"""
SmartBrain - the "council of experts" for Pedro's trading robots.

Every run:
  1. Collects: economic calendar (this week, high/medium impact), fresh headlines
     (macro, central banks, geopolitics/war, gold, oil, indices, each major currency),
     and the previous brain output (for continuity).
  2. Convenes a council of expert personas (macro economist, central-bank watcher,
     geopolitical analyst, FX strategist, gold/oil trader, index/risk-sentiment desk,
     risk manager, chairman) inside one Claude call. They debate, then the chairman
     issues the FINAL DIRECTIVES as strict key=value lines.
  3. Validates and writes:
        brain.txt    - machine file read by SmartMulti_v11 (key=value)
        brain.json   - same content, structured
        brain_log.md - human readable reasoning + directives (append)
Fail-safe: if anything fails, brain.txt is written with neutral directives and a
short "error", so the robots simply fall back to their own logic.

Env: ANTHROPIC_API_KEY (required for the council; without it -> calendar-only rules)
     BRAIN_MODEL (default claude-sonnet-4-5)
"""
import os, re, json, time, html, sys, datetime as dt
import urllib.request, urllib.parse, xml.etree.ElementTree as ET

OUT_DIR   = os.path.dirname(os.path.abspath(__file__))
API_KEY   = os.environ.get("ANTHROPIC_API_KEY", "").strip()
MODEL     = os.environ.get("BRAIN_MODEL", "claude-sonnet-4-5")
NOW       = int(time.time())
UA        = {"User-Agent": "Mozilla/5.0 (SmartBrain/1.0)"}

CURRENCIES = ["USD","EUR","GBP","JPY","AUD","NZD","CAD","CHF"]
ASSETS     = ["XAU","XAG","OIL","US500","US100","US30","GER40"]

def fetch(url, timeout=20):
    req = urllib.request.Request(url, headers=UA)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read()

# ---------- 1. DATA ----------
def get_calendar():
    """ForexFactory public weekly calendar (high/medium impact)."""
    events = []
    try:
        data = json.loads(fetch("https://nfs.faireconomy.media/ff_calendar_thisweek.json"))
        for e in data:
            imp = (e.get("impact") or "").lower()
            if imp not in ("high", "medium"): continue
            try:
                ts = int(dt.datetime.fromisoformat(e["date"].replace("Z","+00:00")).timestamp())
            except Exception:
                continue
            if ts < NOW - 6*3600 or ts > NOW + 48*3600: continue
            events.append({"ts": ts, "in_min": int((ts-NOW)/60), "cur": e.get("country"),
                           "title": e.get("title"), "impact": imp,
                           "forecast": e.get("forecast"), "previous": e.get("previous"), "actual": e.get("actual")})
    except Exception as ex:
        events.append({"error": f"calendar fetch failed: {ex}"})
    return events

def gnews(query, n=8):
    url = "https://news.google.com/rss/search?q=" + urllib.parse.quote(query) + "&hl=en-US&gl=US&ceid=US:en"
    out = []
    try:
        root = ET.fromstring(fetch(url))
        for item in root.iter("item"):
            title = html.unescape(item.findtext("title") or "")
            pub   = item.findtext("pubDate") or ""
            src   = item.findtext("source") or ""
            out.append(f"- [{src}] {title} ({pub})")
            if len(out) >= n: break
    except Exception as ex:
        out.append(f"- (feed error: {ex})")
    return out

def get_headlines():
    q = {
      "MACRO":       'forex market OR "central bank" OR inflation OR "rate decision" when:1d',
      "FED/USD":     '"Federal Reserve" OR Powell OR "US dollar" OR Treasury yields when:1d',
      "ECB/EUR":     'ECB OR euro OR Lagarde OR eurozone economy when:1d',
      "BOE/GBP":     '"Bank of England" OR sterling OR "UK economy" when:1d',
      "BOJ/JPY":     '"Bank of Japan" OR yen OR "Japan intervention" when:1d',
      "AUD/NZD/CAD": 'RBA OR RBNZ OR "Bank of Canada" OR "Australian dollar" OR "New Zealand dollar" OR "Canadian dollar" when:1d',
      "CHF":         '"Swiss National Bank" OR "Swiss franc" when:2d',
      "GEOPOLITICS": 'war OR missile OR attack OR ceasefire OR sanctions OR escalation when:1d',
      "GOLD":        'gold price when:1d',
      "OIL":         'oil price OR OPEC OR crude when:1d',
      "STOCKS/RISK": 'stock market OR "S&P 500" OR Nasdaq OR "risk-off" OR selloff when:1d',
      "BREAKING":    'breaking market OR "flash crash" OR "emergency" OR earthquake OR hurricane when:12h',
    }
    return {k: gnews(v) for k, v in q.items()}

def read_previous():
    p = os.path.join(OUT_DIR, "brain.json")
    try:
        with open(p, encoding="utf-8") as f: return json.load(f)
    except Exception: return None

# ---------- 2. COUNCIL ----------
SYSTEM = """You are SmartBrain: a council of senior market experts that advises a fully automatic
MetaTrader 5 trading system running 24/7 for a small retail account (~$500-5000, max risk 1% per trade).
The robots trade: FX majors/crosses (mean reversion H1, session breakout H1, H4 trend pullback,
D1 breakout) and a SHOCK engine on gold/oil/indices that catches sudden event-driven moves (1-15 min).
The robots CANNOT read news. YOU are their eyes and judgment. They read your directives every 5 minutes.

The council (debate honestly, disagree when needed, then converge):
 1. Chief Macro Economist - growth/inflation/rates cycle per economy.
 2. Central-Bank Watcher - Fed/ECB/BoE/BoJ/RBA/RBNZ/BoC/SNB next moves, speeches, surprises.
 3. Geopolitical & Crisis Analyst - wars, attacks, sanctions, disasters, political shocks; who benefits (USD/JPY/CHF/gold/oil).
 4. FX Strategist - relative strength of each currency for the next 4-24 hours.
 5. Gold & Oil Trader - XAU/XAG/OIL flow, OPEC, safe-haven demand.
 6. Equity / Risk-Sentiment Desk - risk-on/risk-off, indices, VIX-type stress.
 7. Risk Manager - protects capital: news windows, thin liquidity, whipsaw danger, when to halt.
 8. Chairman - listens to all, weighs evidence quality (fresh > stale, facts > opinion), issues FINAL directives.

Rules for the directives:
 - Be conservative. Uncertain => 0 bias, risk_mode=normal. Only strong, fresh, multi-source evidence => |bias| >= 0.5.
 - Scheduled high-impact events within the next 60 min for a currency => set news_block for that currency window.
 - A GENUINE sudden shock (war escalation, surprise CB action, disaster) confirmed by fresh (< 90 min) headlines
   => shock directive on the asset (XAUUSD/XAGUSD/USOIL/UKOIL/US500/US100/US30/GER40 or an FX pair) with direction and
   validity <= 120 min. Never invent shocks from routine volatility.
 - risk_mode: normal | caution (moderate uncertainty, big data day) | danger (active crisis, extreme volatility) | halt (do not open anything).
 - risk_mult: 0.25..1.25 global multiplier for the robots' risk (1.0 = unchanged).
 - allow_books: subset of INTRADAY,SWING,POSITION,SHOCK,COUNCIL,REVERT that should be allowed now (default ALL).
 - IMPORTANT: a COUNCIL book opens a real trade (0.5% risk, price-confirmed) whenever conf >= 0.6 AND |bias| >= 0.7 on a symbol.
   So only give |bias| >= 0.7 with conf >= 0.6 when the council is truly convinced by fresh, concrete evidence and the move is
   likely to persist for the next 4-12 hours. Prefer fewer, stronger calls over many weak ones.
Output format: first a section "## Council debate" (short, max ~25 lines, each expert one or two lines, then Chairman).
Then a section "## DIRECTIVES" containing ONLY key=value lines, no prose, exactly these keys:
risk_mode=<normal|caution|danger|halt>
risk_mult=<0.25..1.25>
regime=<risk_on|risk_off|mixed>
bias_USD=<-1..1>  bias_EUR=  bias_GBP=  bias_JPY=  bias_AUD=  bias_NZD=  bias_CAD=  bias_CHF=  (each on its own line)
bias_XAU=  bias_XAG=  bias_OIL=  bias_US500=  bias_US100=  bias_US30=  bias_GER40=
conf=<0..1 overall confidence in the biases>
allow_books=<comma list or ALL>
news_block=<CUR:minutes_from_now_start:minutes_from_now_end;...> or none   (e.g. USD:20:45;EUR:110:135)
block_symbols=<comma list of symbols to avoid now> or none
shock=<SYMBOL:dir(1|-1):valid_minutes:short reason> or none   (multiple separated by ;)
prefer_symbols=<comma list of symbols where the council sees the cleanest opportunity> or none
summary=<one line in simple English, max 200 chars>
summary_ar=<same line in simple Lebanese Arabic, max 200 chars>
"""

def council(calendar, headlines, prev):
    if not API_KEY:
        return None, "no ANTHROPIC_API_KEY - rule-based fallback"
    prev_txt = json.dumps(prev.get("directives"), ensure_ascii=False) if prev else "none"
    user = ("UTC now: " + dt.datetime.utcfromtimestamp(NOW).strftime("%Y-%m-%d %H:%M") + "\n\n"
            "## Economic calendar (next 48h, high/medium; in_min = minutes from now, negative = already released)\n"
            + json.dumps(calendar, ensure_ascii=False)[:6000] + "\n\n## Fresh headlines by desk\n")
    for k, v in headlines.items():
        user += f"### {k}\n" + "\n".join(v) + "\n"
    user += "\n## Previous directives (15 min ago)\n" + prev_txt + "\n\nConvene the council now and output the two sections."
    body = json.dumps({"model": MODEL, "max_tokens": 2500, "temperature": 0.2,
                       "system": SYSTEM, "messages": [{"role": "user", "content": user}]}).encode()
    req = urllib.request.Request("https://api.anthropic.com/v1/messages", data=body, method="POST",
                                 headers={"content-type": "application/json", "x-api-key": API_KEY,
                                          "anthropic-version": "2023-06-01"})
    with urllib.request.urlopen(req, timeout=120) as r:
        res = json.loads(r.read())
    text = "".join(p.get("text", "") for p in res.get("content", []))
    return text, None

# ---------- 3. PARSE / VALIDATE ----------
def clamp(x, lo, hi, default):
    try:
        v = float(x); return max(lo, min(hi, v))
    except Exception: return default

def parse_directives(text):
    d = {}
    sec = text.split("## DIRECTIVES", 1)
    block = sec[1] if len(sec) == 2 else text
    for line in block.splitlines():
        m = re.match(r"\s*([A-Za-z0-9_]+)\s*=\s*(.*)$", line)
        if m: d[m.group(1).strip()] = m.group(2).strip()
    out = {}
    out["risk_mode"] = d.get("risk_mode","normal").lower()
    if out["risk_mode"] not in ("normal","caution","danger","halt"): out["risk_mode"] = "normal"
    out["risk_mult"] = round(clamp(d.get("risk_mult",1.0), 0.25, 1.25, 1.0), 2)
    out["regime"]    = d.get("regime","mixed").lower()
    out["conf"]      = round(clamp(d.get("conf",0.3), 0, 1, 0.3), 2)
    for c in CURRENCIES + ASSETS:
        out[f"bias_{c}"] = round(clamp(d.get(f"bias_{c}",0), -1, 1, 0.0), 2)
    out["allow_books"]    = d.get("allow_books","ALL").upper().replace(" ","") or "ALL"
    for k in ("news_block","block_symbols","shock","prefer_symbols"):
        v = d.get(k,"none").strip()
        out[k] = "none" if v.lower() in ("", "none", "n/a") else (v.replace(" ", "_") if k == "shock" else v.replace(" ", ""))
    out["summary"]    = d.get("summary","")[:200].replace("\n"," ")
    out["summary_ar"] = d.get("summary_ar","")[:200].replace("\n"," ")
    return out

def rule_based(calendar):
    """Fallback without the council: only the calendar-window logic."""
    out = {f"bias_{c}": 0.0 for c in CURRENCIES + ASSETS}
    out.update({"risk_mode":"normal","risk_mult":1.0,"regime":"mixed","conf":0.0,"allow_books":"ALL",
                "block_symbols":"none","shock":"none","prefer_symbols":"none",
                "summary":"council offline - calendar-only mode","summary_ar":"المجلس غير متصل - وضع التقويم فقط"})
    nb = []
    for e in calendar:
        if e.get("impact") == "high" and -20 <= e.get("in_min", 999) <= 90:
            nb.append(f"{e['cur']}:{max(-20, e['in_min']-30)}:{e['in_min']+20}")
    out["news_block"] = ";".join(nb) if nb else "none"
    return out

# ---------- 4. WRITE ----------
ORDER = ["risk_mode","risk_mult","regime","conf","allow_books","news_block","block_symbols","shock","prefer_symbols"] \
        + [f"bias_{c}" for c in CURRENCIES + ASSETS] + ["summary","summary_ar"]

def write_outputs(directives, debate, err):
    txt = [f"ts={NOW}", f"generated={dt.datetime.utcfromtimestamp(NOW).strftime('%Y-%m-%d %H:%M UTC')}", "version=1"]
    for k in ORDER:
        txt.append(f"{k}={directives.get(k,'')}")
    with open(os.path.join(OUT_DIR,"brain.txt"),"w",encoding="utf-8") as f: f.write("\n".join(txt)+"\n")
    with open(os.path.join(OUT_DIR,"brain.json"),"w",encoding="utf-8") as f:
        json.dump({"ts":NOW,"directives":directives,"error":err}, f, ensure_ascii=False, indent=1)
    p = os.path.join(OUT_DIR,"brain_log.md")
    with open(p,"a",encoding="utf-8") as f:
        f.write(f"\n\n# {dt.datetime.utcfromtimestamp(NOW).strftime('%Y-%m-%d %H:%M UTC')}\n")
        if err: f.write(f"_error: {err}_\n")
        if debate: f.write(debate.strip()+"\n")
        else: f.write("```\n"+"\n".join(txt)+"\n```\n")
    if os.path.getsize(p) > 300_000:          # keep the log bounded
        data = open(p,encoding="utf-8").read()[-250_000:]
        open(p,"w",encoding="utf-8").write(data)

def main():
    calendar  = get_calendar()
    headlines = get_headlines()
    prev      = read_previous()
    debate, err = None, None
    try:
        debate, err = council(calendar, headlines, prev)
    except Exception as ex:
        err = f"council failed: {ex}"
    directives = parse_directives(debate) if debate else rule_based(calendar)
    write_outputs(directives, debate, err)
    print("OK", directives.get("risk_mode"), directives.get("risk_mult"), directives.get("summary"))
    if err: print("WARN", err, file=sys.stderr)

if __name__ == "__main__":
    main()
