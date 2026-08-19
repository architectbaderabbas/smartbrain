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

def rss(url, n=6):
    """Generic RSS/Atom titles (official sources)."""
    out = []
    try:
        root = ET.fromstring(fetch(url, timeout=15))
        items = list(root.iter("item")) or [e for e in root.iter() if e.tag.endswith("entry")]
        for it in items[:n]:
            t = it.findtext("title") or next((c.text for c in it if c.tag.endswith("title")), "")
            d = it.findtext("pubDate") or next((c.text for c in it if c.tag.endswith("updated") or c.tag.endswith("published")), "")
            out.append(f"- {html.unescape((t or '').strip())} ({(d or '').strip()[:25]})")
    except Exception as ex:
        out.append(f"- (feed error: {str(ex)[:60]})")
    return out

def get_official():
    return {
      "FED official":  rss("https://www.federalreserve.gov/feeds/press_all.xml"),
      "ECB official":  rss("https://www.ecb.europa.eu/rss/press.html"),
      "BoE official":  rss("https://www.bankofengland.co.uk/rss/news"),
      "BIS/central banks speeches": rss("https://www.bis.org/doclist/cbspeeches.rss"),
      "OPEC":          rss("https://www.opec.org/opec_web/en/press_room/rss.xml", 4),
      "Reuters-style wire (Google News: Reuters)": gnews('site:reuters.com markets when:6h', 8),
    }

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

STOOQ = {"EURUSD":"eurusd","GBPUSD":"gbpusd","USDJPY":"usdjpy","AUDUSD":"audusd","NZDUSD":"nzdusd","USDCAD":"usdcad",
         "USDCHF":"usdchf","XAUUSD":"xauusd","XAGUSD":"xagusd","WTI":"cl.f","BRENT":"cb.f","SPX":"^spx","NDX":"^ndx","DJI":"^dji","DAX":"^dax",
         "VIX":"^vix","DXY":"dx.f","US10Y":"10usy.b","NIKKEI":"^nkx"}
PX_CACHE = "price_context.json"
def account_prices():
    """Live prices posted by the robots (account.json 'prices') - no rate limits, refreshed every 15 min."""
    try:
        a = json.load(open(os.path.join(OUT_DIR, "account.json"), encoding="utf-8"))
        if NOW - int(a.get("ts", 0)) > 2 * 3600: return {}
        return {k: float(v) for k, v in (a.get("prices") or {}).items()}
    except Exception: return {}
LIVE_MAP = {"EURUSD":"EURUSD","GBPUSD":"GBPUSD","USDJPY":"USDJPY","AUDUSD":"AUDUSD","NZDUSD":"NZDUSD","USDCAD":"USDCAD","USDCHF":"USDCHF",
            "XAUUSD":"XAUUSD","XAGUSD":"XAGUSD","WTI":"USOIL","BRENT":"UKOIL","SPX":"US500","NDX":"US100","DJI":"US30","DAX":"GER40"}
def get_prices(max_age_h=6):
    """Daily context from stooq (cached, refreshed every max_age_h hours to respect their limits)
    + live 'last' overlaid from the robots' account report."""
    p = os.path.join(OUT_DIR, PX_CACHE)
    out = None
    try:
        c = json.load(open(p, encoding="utf-8"))
        if NOW - int(c.get("ts", 0)) <= max_age_h * 3600 and sum(1 for v in c.get("px", {}).values() if isinstance(v, dict) and v.get("last")) >= 8:
            out = c["px"]
    except Exception: pass
    if out is None:
        out = _stooq_prices()
        ok = sum(1 for v in out.values() if isinstance(v, dict) and v.get("last"))
        if ok >= 8:
            json.dump({"ts": NOW, "px": out}, open(p, "w", encoding="utf-8"))
        else:
            try: out = json.load(open(p, encoding="utf-8"))["px"]; out["_note"] = "stooq unavailable - using cached daily context"
            except Exception: pass
    live = account_prices()
    for name, sym in LIVE_MAP.items():
        if sym in live:
            d = out.get(name) if isinstance(out.get(name), dict) else {}
            d = dict(d); d["last"] = live[sym]; d["live"] = True; d.pop("error", None)
            out[name] = d
    for sym, v in live.items():
        if sym not in LIVE_MAP.values(): out.setdefault(sym, {"last": v, "live": True})
    if live: out["_live_ts"] = dt.datetime.utcfromtimestamp(NOW).strftime("%H:%M UTC") + " (robots' prices)"
    return out

def _stooq_prices():
    """Daily closes (stooq, no key) -> compact context per asset."""
    out = {}
    for name, sym in STOOQ.items():
        try:
            raw = fetch(f"https://stooq.com/q/d/l/?s={sym}&i=d", timeout=15).decode("utf-8","ignore").strip().splitlines()
            rows = [r.split(",") for r in raw[1:] if r.count(",") >= 4]
            closes = [float(r[4]) for r in rows[-260:] if r[4] not in ("", "N/D")]
            if len(closes) < 30: continue
            c = closes[-1]; hi = max(closes); lo = min(closes)
            def chg(n): return round((c/closes[-1-n]-1)*100, 2) if len(closes) > n else None
            rets = [closes[i]/closes[i-1]-1 for i in range(1, len(closes))]
            vol20 = (sum(r*r for r in rets[-20:])/20) ** 0.5 * 100 * (252 ** 0.5)
            vol1y = (sum(r*r for r in rets)/len(rets)) ** 0.5 * 100 * (252 ** 0.5)
            out[name] = {"last": c, "chg_1d%": chg(1), "chg_5d%": chg(5), "chg_20d%": chg(20),
                         "pos_in_1y_range%": round((c-lo)/(hi-lo)*100, 1) if hi > lo else None,
                         "vol20_ann%": round(vol20, 1), "vol1y_ann%": round(vol1y, 1),
                         "note": ("near 1y HIGH" if c >= hi*0.99 else "near 1y LOW" if c <= lo*1.01 else "")}
        except Exception as ex:
            out[name] = {"error": str(ex)[:80]}
    return out

SNAP_FILE = "price_snapshots.json"
def save_snapshot(prices):
    """Keep a rolling 7-day list of {ts, last prices} so we can score past calls at 4h/12h/24h."""
    p = os.path.join(OUT_DIR, SNAP_FILE)
    try: hist = json.load(open(p, encoding="utf-8"))
    except Exception: hist = []
    hist.append({"ts": NOW, "px": {k: v.get("last") for k, v in prices.items() if isinstance(v, dict) and v.get("last")}})
    hist = [h for h in hist if NOW - h["ts"] <= 7 * 86400]
    json.dump(hist, open(p, "w", encoding="utf-8"))
    return hist

ASSET_PX = {"XAU":"XAUUSD","XAG":"XAGUSD","OIL":"WTI","US500":"SPX","US100":"NDX","US30":"DJI","GER40":"DAX",
            "EUR":"EURUSD","GBP":"GBPUSD","AUD":"AUDUSD","NZD":"NZDUSD","JPY":"USDJPY","CAD":"USDCAD","CHF":"USDCHF"}
INVERTED = {"JPY","CAD","CHF"}   # USDxxx quote: currency up = pair down

def px_at(hist, ts):
    best = None
    for h in hist:
        if best is None or abs(h["ts"] - ts) < abs(best["ts"] - ts): best = h
    return best["px"] if best and abs(best["ts"] - ts) <= 3 * 3600 else None

def build_scorecard(hist):
    """Score each past directive: did the asset move in the direction of the bias after 4h/12h/24h?"""
    p = os.path.join(OUT_DIR, "brain_log.md")
    try: log = open(p, encoding="utf-8").read()
    except Exception: return {}
    decisions = []
    for sec in log.split("\n# "):
        if "## DIRECTIVES" not in sec: continue
        head = sec.strip().splitlines()[0][:16]
        try: ts = int(dt.datetime.strptime(head, "%Y-%m-%d %H:%M").replace(tzinfo=dt.timezone.utc).timestamp())
        except Exception: continue
        d = {}
        for line in sec.split("## DIRECTIVES",1)[1].splitlines():
            m = re.match(r"\s*([A-Za-z0-9_]+)\s*=\s*(.*)$", line)
            if m: d[m.group(1)] = m.group(2).strip()
        decisions.append((ts, d))
    per_asset = {}; overall = {"4h":[0,0],"12h":[0,0],"24h":[0,0]}; by_mind = {}
    for ts, d in decisions:
        p0 = px_at(hist, ts)
        if not p0: continue
        for hz, secs in (("4h",4*3600),("12h",12*3600),("24h",24*3600)):
            if NOW - ts < secs: continue
            p1 = px_at(hist, ts + secs)
            if not p1: continue
            for cur, sym in ASSET_PX.items():
                b = float(d.get("bias_"+cur, 0) or 0)
                if abs(b) < 0.3 or sym not in p0 or sym not in p1 or not p0[sym]: continue
                move = (p1[sym]/p0[sym]-1) * (-1 if cur in INVERTED else 1)
                hit = 1 if (move > 0) == (b > 0) else 0
                a = per_asset.setdefault(cur, {"4h":[0,0],"12h":[0,0],"24h":[0,0]})
                a[hz][0] += hit; a[hz][1] += 1
                overall[hz][0] += hit; overall[hz][1] += 1
                mm = by_mind.setdefault(d.get("mind","?"), [0,0]); mm[0] += hit; mm[1] += 1
    def pct(x): return round(100*x[0]/x[1]) if x[1] else None
    return {"decisions_scored": sum(1 for _ in decisions),
            "overall_hit_rate%": {k: pct(v) for k, v in overall.items()},
            "per_asset_hit_rate%": {a: {k: pct(v) for k, v in hz.items()} for a, hz in per_asset.items()},
            "by_mind_state%": {m: pct(v) for m, v in by_mind.items()},
            "note": "hit = price moved in the direction of a bias with |bias|>=0.3 after the horizon; None = not enough data yet"}

def read_account():
    p = os.path.join(OUT_DIR, "account.json")
    try:
        a = json.load(open(p, encoding="utf-8"))
        if NOW - int(a.get("ts", 0)) > 3 * 3600: a["stale"] = True
        return a
    except Exception: return None

def read_playbook():
    p = os.path.join(OUT_DIR, "historian.md")
    try:
        with open(p, encoding="utf-8") as f: return f.read()[:12000]
    except Exception: return "(no playbook file)"


# ---------- TRADE JOURNAL / LESSONS (learning loop on real trades) ----------
def read_trades(n=25):
    p = os.path.join(OUT_DIR, "trades.json")
    try: return json.load(open(p, encoding="utf-8"))[-n:]
    except Exception: return []

def trade_stats(trades):
    """Per-book stats over the journal: trades, wins, net, avg minutes, against-bias count."""
    st = {}
    for t in trades:
        b = t.get("book", "?"); s = st.setdefault(b, {"trades": 0, "wins": 0, "net": 0.0, "against_bias": 0, "sl_hits": 0, "time_exits": 0})
        s["trades"] += 1; pl = float(t.get("pl", 0) or 0); s["net"] = round(s["net"] + pl, 2)
        if pl >= 0: s["wins"] += 1
        d = 1 if t.get("dir") == "BUY" else -1
        if float(t.get("brain_bias", 0) or 0) * d <= -0.3: s["against_bias"] += 1
        if t.get("reason") == "SL": s["sl_hits"] += 1
        if t.get("reason") == "EA" and pl < 0: s["time_exits"] += 1
    return st

def read_lessons():
    p = os.path.join(OUT_DIR, "lessons.md")
    try: return open(p, encoding="utf-8").read()[-6000:]
    except Exception: return "(no lessons yet)"

def add_lesson(text):
    p = os.path.join(OUT_DIR, "lessons.md")
    old = ""
    try: old = open(p, encoding="utf-8").read()
    except Exception: pass
    entry = f"### {dt.datetime.utcfromtimestamp(NOW).strftime('%Y-%m-%d %H:%M UTC')}\n{text.strip()}\n\n"
    blocks = [b for b in (old.split("### ") if old else []) if b.strip() and not b.lstrip().startswith("#")]
    blocks = blocks[-19:]  # keep the last 20 lessons
    new = "# SmartBrain lessons (post-mortems on real trades, newest last)\n\n" + "".join("### " + b for b in blocks) + entry
    open(p, "w", encoding="utf-8").write(new)

PM_SYSTEM = """You are the POST-MORTEM desk of a trading brain (a council of experts advising MetaTrader robots).
A real trade just closed. Analyse it honestly in <= 8 short lines.
STRUCTURE (do not forget): SmartMulti books (INTRADAY, SWING, POSITION, SHOCK, COUNCIL, REVERT) obey the council's allow_books/
risk_mult/biases (REVERT = H1 mean reversion, merged into SmartMulti on 2026-08-19 evening; trades before that came from the old
independent SmartRevert robot). BREAKOUT and 'other:<magic>' are older independent robots that never read the council - by design,
not a violation. All positions are protected by the account-wide Profit Guard (BE at 0.5R, give-back close, lock half MFE).
So: never call a trade 'rogue'/'mutiny'; for the independent robots give a verdict on THEIR edge and, if needed, a
recommendation for the human operator (reduce risk / switch off). Your ACTION may only touch allow_books (SmartMulti books)
and risk_mult (never below 0.4); write 'none' otherwise.
1) What the robot did (book, symbol, direction, hold time, exit reason).
2) Was it aligned with or against the council's bias at the time? Was the council's bias itself right (use PRICE CONTEXT)?
3) Root cause of the loss/win: entry logic (e.g. shock in a choppy no-event market), stop placement, time stop, news, council error, or plain variance.
4) One concrete LESSON the council should apply from now on (rule-like, e.g. "in caution mode with no fresh event, do not let SHOCK trade indices").
5) Any directive change recommended NOW (allow_books / risk_mult / bias) or "no change".
End with a line: LESSON=<one sentence>  and a line: ACTION=<allow_books=...;risk_mult=...  or none>
Be specific, no fluff. If it was a win, say what worked and whether it was luck."""

def post_mortem(trade, prev, prices=None):
    """Called by the watchman when a closed trade arrives. Writes a lesson; may adjust directives (conservative only)."""
    if not API_KEY: return None
    recent = read_trades(15)
    user = (f"UTC now: {dt.datetime.utcfromtimestamp(NOW).strftime('%Y-%m-%d %H:%M')}\n\n## CLOSED TRADE\n" + json.dumps(trade, ensure_ascii=False) +
            "\n\n## RECENT TRADES (journal, oldest -> newest)\n" + json.dumps(recent, ensure_ascii=False)[:5000] +
            "\n\n## PER-BOOK STATS\n" + json.dumps(trade_stats(recent), ensure_ascii=False) +
            "\n\n## COUNCIL DIRECTIVES IN FORCE\n" + json.dumps((prev or {}).get("directives", {}), ensure_ascii=False)[:3000] +
            "\n\n## PRICE CONTEXT\n" + json.dumps(prices or {}, ensure_ascii=False)[:4000] +
            "\n\n## PREVIOUS LESSONS\n" + read_lessons() + "\n\nWrite the post-mortem.")
    body = json.dumps({"model": MODEL, "max_tokens": 700, "temperature": 0.2,
                       "system": PM_SYSTEM, "messages": [{"role": "user", "content": user}]}).encode()
    req = urllib.request.Request("https://api.anthropic.com/v1/messages", data=body, method="POST",
                                 headers={"content-type": "application/json", "x-api-key": API_KEY, "anthropic-version": "2023-06-01"})
    with urllib.request.urlopen(req, timeout=90) as r:
        res = json.loads(r.read())
    text = "".join(p.get("text", "") for p in res.get("content", []))
    head = f"**{trade.get('symbol')} {trade.get('book')} {trade.get('dir')} {trade.get('lots')} lots · {trade.get('mins')} min · exit {trade.get('reason')} · P/L {trade.get('pl')}$ · council bias {trade.get('brain_bias')} ({trade.get('brain_mode')})**\n"
    add_lesson(head + text)
    return text

def decision_memory(prices):
    """Last few decisions (from brain_log.md) so Awareness can compare words vs what happened."""
    p = os.path.join(OUT_DIR, "brain_log.md")
    try:
        log = open(p, encoding="utf-8").read()
    except Exception:
        return "none"
    secs = [x for x in log.split("\n# ") if "## DIRECTIVES" in x][-8:]
    mem = []
    for sec in secs:
        head = sec.strip().splitlines()[0][:20]
        d = {}
        for line in sec.split("## DIRECTIVES",1)[1].splitlines():
            m = re.match(r"\s*([A-Za-z0-9_]+)\s*=\s*(.*)$", line)
            if m: d[m.group(1)] = m.group(2).strip()
        keep = {k: d.get(k) for k in ("risk_mode","risk_mult","conf","mind","bias_USD","bias_JPY","bias_XAU","bias_OIL","bias_US500","summary") if k in d}
        mem.append({"at": head, **keep})
    return json.dumps(mem, ensure_ascii=False)


def news_events_line(calendar, horizon_min=240):
    """news_events=CUR:epoch:Title;...  (high-impact releases within the next horizon; for the robots' news-breakout)"""
    out = []
    for e in calendar or []:
        if e.get("impact") != "high" or not isinstance(e.get("in_min"), int): continue
        if -10 <= e["in_min"] <= horizon_min:
            t = re.sub(r"[^A-Za-z0-9 ._-]", "", str(e.get("title") or ""))[:40].replace(" ", "_")
            out.append(f"{e.get('cur')}:{e.get('ts')}:{t}")
    return ";".join(out[:12]) if out else "none"

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
IMPORTANT STRUCTURE: the SmartMulti books (INTRADAY, SWING, POSITION, SHOCK, COUNCIL, REVERT) read and obey your directives
(allow_books, risk_mult, biases, blocks). REVERT = H1 mean reversion (Bollinger+RSI fade, TP middle band): it is blocked automatically
against any symbol bias stronger than 0.3 and in TREND regime, so when you expect a strong trend set the bias and REVERT stands aside;
in calm ranging markets it is the book to allow. BREAKOUT (session breakout H1) and any book named
'other:<magic>' are OLDER INDEPENDENT robots that do NOT read the council by design - they are not 'rogue'; they are only
protected by the account-wide Profit Guard (break-even at 0.5R, give-back close, lock half of MFE). When they lose, judge
them on their own merits and, if they are net losers, RECOMMEND to the human operator (Pedro) to reduce their risk or switch
them off - never call them insubordinate. trades.json field 'book' tells you which robot traded.

The council (debate honestly, disagree when needed, then converge):
 1. Chief Macro Economist - growth/inflation/rates cycle per economy.
 2. Central-Bank Watcher - Fed/ECB/BoE/BoJ/RBA/RBNZ/BoC/SNB next moves, speeches, surprises.
 3. Geopolitical & Crisis Analyst - wars, attacks, sanctions, disasters, political shocks; who benefits (USD/JPY/CHF/gold/oil).
 4. FX Strategist - relative strength of each currency for the next 4-24 hours.
 5. Gold & Oil Trader - XAU/XAG/OIL flow, OPEC, safe-haven demand.
 6. Equity / Risk-Sentiment Desk - risk-on/risk-off, indices, VIX-type stress.
 7. Risk Manager - protects capital: news windows, thin liquidity, whipsaw danger, when to halt.
 8. Market Historian - carries the memory of the markets: how FX, gold, oil and indices actually behaved in past
    analogous episodes (wars, oil shocks, CB surprises, crises, interventions, elections, disasters). Uses the
    HISTORICAL PLAYBOOK and the PRICE CONTEXT below (real recent prices: where each asset sits vs its 1y range,
    recent momentum, realized volatility). Says: "the last N times this happened, X did Y for Z days", warns when
    a move is already extended vs history, and flags when the current setup rhymes with a known pattern.
 9. Chairman - listens to all, weighs evidence quality (fresh > stale, facts > opinion), issues FINAL directives.

THE PSYCHE (self-monitoring layer). After the 9 experts speak and BEFORE the Chairman decides, five inner voices review
the draft decision. They are not extra analysts; they audit the council's own state of mind:
 - Awareness (self-consciousness): compares this draft with the PREVIOUS DIRECTIVES and the DECISION MEMORY (what we said
   over the last hours vs what prices then did). Flags flip-flopping (changing view without new facts) or stubbornness
   (holding a view that prices already refuted). If flip-flopping: freeze changes (keep previous biases) unless new hard facts.
 - Greed detector: fires when confidence is high, most biases point the same way, prefer_symbols is long, or "easy money"
   language appears. When it fires the risk_mult must be REDUCED, never raised, and it says so.
 - Fear detector: fires when the council over-reacts to a single headline or to a recent loss (danger/halt without concrete
   ongoing threat, or all biases collapsing to 0 after being confident with no new facts). It restores balance: prefer
   caution over halt, and explains.
 - Prudence: every strong call (|bias| >= 0.7 or shock or block) needs at least two independent sources AND a historical
   analog from the Market Historian; otherwise it downgrades it (0.5..0.6) and says why.
 - Intuition: the only voice allowed to see beyond the evidence. It writes one short hunch. It can NEVER change numbers by
   itself; the Chairman may adopt it explicitly, must say "adopting intuition because ...", and cap the change at +/-0.2 bias.
The psyche then states the council's mental state: calm | greedy | fearful | scattered | focused, and the Chairman decides.

EMERGENCY PROTOCOL (fixed rules, not up for debate):
 - Severity-3 event (major war escalation / attack on a nuclear or oil chokepoint / flash crash / exchange halt / surprise
   CB emergency action): risk_mode=halt for at least the first 30 minutes (allow_books=SHOCK only), then the council may
   move to danger (risk_mult<=0.5) once direction is clearer. Never go straight from halt to normal.
 - Severity-2 event: risk_mode=danger, risk_mult<=0.6, block_symbols for the directly hit assets until price stabilizes.
 - If the ACCOUNT STATE shows daily loss <= -3% or 3 losing trades in a row in one book: that book must be removed from
   allow_books for the rest of the day; if daily loss <= -4%: risk_mode=halt.
 - Stale or missing data (feeds failed): stay conservative (caution), never invent.

LEARNING LOOP: the TRADE JOURNAL shows the robots' real closed trades and the LESSONS are post-mortems written after each one.
The Awareness voice must read them. Repeated losses of one book in the current regime => remove it from allow_books or lower
risk_mult; a book trading against our bias and losing => keep biases honest; a lesson that applies now MUST be applied.

SCORECARD USE: the Awareness voice must read the SCORECARD. Assets/voices with poor recent accuracy get lower |bias| and
the Chairman lowers conf accordingly. Good accuracy does NOT allow exceeding the normal caps.

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
Output format: first a section "## Council debate" (short, max ~28 lines, each expert one or two lines, then Chairman). Name each speaker exactly, e.g. "Market Historian:".
Then a section "## Psyche" (5 short lines: Awareness / Greed / Fear / Prudence / Intuition, each with fired=yes|no and one sentence).
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
mind=<calm|greedy|fearful|scattered|focused>
psyche_flags=<comma list of voices that fired: awareness,greed,fear,prudence,intuition or none>
intuition=<one short sentence hunch (English), or none>
"""

def council(calendar, headlines, prev, prices=None, playbook="", official=None, scorecard=None, account=None, trades=None, lessons=""):
    if not API_KEY:
        return None, "no ANTHROPIC_API_KEY - rule-based fallback"
    prev_txt = json.dumps(prev.get("directives"), ensure_ascii=False) if prev else "none"
    user = ("UTC now: " + dt.datetime.utcfromtimestamp(NOW).strftime("%Y-%m-%d %H:%M") + "\n\n"
            "## Economic calendar (next 48h, high/medium; in_min = minutes from now, negative = already released)\n"
            + json.dumps(calendar, ensure_ascii=False)[:6000] + "\n\n## Fresh headlines by desk\n")
    for k, v in headlines.items():
        user += f"### {k}\n" + "\n".join(v) + "\n"
    user += "\n## OFFICIAL SOURCES (central banks / OPEC / wires)\n"
    for k, v in (official or {}).items():
        user += f"### {k}\n" + "\n".join(v) + "\n"
    user += "\n## PRICE CONTEXT for the Market Historian (real daily data)\n" + json.dumps(prices or {}, ensure_ascii=False)
    user += "\n\n## HISTORICAL PLAYBOOK (for the Market Historian)\n" + (playbook or "")
    user += "\n\n## SCORECARD (how accurate our past calls were; use it to weight voices and calibrate confidence)\n" + json.dumps(scorecard or {}, ensure_ascii=False)[:4000]
    user += "\n\n## ACCOUNT STATE (live report from the robots, if available)\n" + json.dumps(account or {}, ensure_ascii=False)[:3000]
    user += "\n\n## TRADE JOURNAL (last real closed trades, oldest -> newest) + PER-BOOK STATS\n" + json.dumps(trades or [], ensure_ascii=False)[:5000] + "\n" + json.dumps(trade_stats(trades or []), ensure_ascii=False)
    user += "\n\n## LESSONS (post-mortems on our real trades; apply the ones relevant now)\n" + (lessons or "")
    user += "\n\n## DECISION MEMORY (our last decisions, oldest -> newest; compare with PRICE CONTEXT chg_1d/5d)\n" + decision_memory(prices)
    user += "\n\n## Previous directives (15 min ago)\n" + prev_txt + "\n\nConvene the council now and output the three sections."
    body = json.dumps({"model": MODEL, "max_tokens": 3500, "temperature": 0.2,
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
    out["mind"]       = d.get("mind","calm").lower()
    if out["mind"] not in ("calm","greedy","fearful","scattered","focused"): out["mind"] = "calm"
    out["psyche_flags"] = d.get("psyche_flags","none").lower().replace(" ","") or "none"
    out["intuition"]  = d.get("intuition","none")[:200].replace("\n"," ")
    out["summary"]    = d.get("summary","")[:200].replace("\n"," ")
    out["summary_ar"] = d.get("summary_ar","")[:200].replace("\n"," ")
    return out

def rule_based(calendar):
    """Fallback without the council: only the calendar-window logic."""
    out = {f"bias_{c}": 0.0 for c in CURRENCIES + ASSETS}
    out.update({"risk_mode":"normal","risk_mult":1.0,"regime":"mixed","conf":0.0,"allow_books":"ALL",
                "block_symbols":"none","shock":"none","prefer_symbols":"none",
                "summary":"council offline - calendar-only mode","summary_ar":"المجلس غير متصل - وضع التقويم فقط",
                "mind":"calm","psyche_flags":"none","intuition":"none"})
    nb = []
    for e in calendar:
        if e.get("impact") == "high" and -20 <= e.get("in_min", 999) <= 90:
            nb.append(f"{e['cur']}:{max(-20, e['in_min']-30)}:{e['in_min']+20}")
    out["news_block"] = ";".join(nb) if nb else "none"
    return out

# ---------- 4. WRITE ----------
ORDER = ["risk_mode","risk_mult","regime","conf","allow_books","news_block","block_symbols","shock","prefer_symbols"] \
        + [f"bias_{c}" for c in CURRENCIES + ASSETS] + ["summary","summary_ar","mind","psyche_flags","intuition","news_events"]

def write_outputs(directives, debate, err):
    txt = [f"ts={NOW}", f"generated={dt.datetime.utcfromtimestamp(NOW).strftime('%Y-%m-%d %H:%M UTC')}", "version=1"]
    for k in ORDER:
        txt.append(f"{k}={directives.get(k,'')}")
    with open(os.path.join(OUT_DIR,"brain.txt"),"w",encoding="utf-8") as f: f.write("\n".join(txt)+"\n")
    prev_alerts = []
    try: prev_alerts = json.load(open(os.path.join(OUT_DIR,"brain.json"), encoding="utf-8")).get("alerts", [])[-10:]
    except Exception: pass
    with open(os.path.join(OUT_DIR,"brain.json"),"w",encoding="utf-8") as f:
        json.dump({"ts":NOW,"council_ts":NOW,"directives":directives,"error":err,"alerts":prev_alerts}, f, ensure_ascii=False, indent=1)
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
    prices    = get_prices()
    playbook  = read_playbook()
    official  = get_official()
    hist      = save_snapshot(prices)
    scorecard = build_scorecard(hist)
    json.dump(scorecard, open(os.path.join(OUT_DIR, "scorecard.json"), "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    account   = read_account()
    trades    = read_trades(20)
    lessons   = read_lessons()
    debate, err = None, None
    try:
        debate, err = council(calendar, headlines, prev, prices, playbook, official, scorecard, account, trades, lessons)
    except Exception as ex:
        err = f"council failed: {ex}"
    directives = parse_directives(debate) if debate else rule_based(calendar)
    directives["news_events"] = news_events_line(calendar)
    write_outputs(directives, debate, err)
    print("OK", directives.get("risk_mode"), directives.get("risk_mult"), directives.get("summary"))
    if err: print("WARN", err, file=sys.stderr)

if __name__ == "__main__":
    main()
