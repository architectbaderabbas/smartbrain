# SmartBrain lessons (post-mortems on real trades, newest last)

### # SmartBrain lessons (post-mortems on real trades, newest last)

### # SmartBrain lessons (post-mortems on real trades, newest last)

### # SmartBrain lessons (post-mortems on real trades, newest last)

### # SmartBrain lessons (post-mortems on real trades, newest last)

### 2026-08-19 00:11 UTC
**USOIL SHOCK SELL 0.01 lots · 10 min · exit EA · P/L -0.22$ · council bias -0.3 (CAUTION)**
## POST-MORTEM ANALYSIS

**TRADE SUMMARY:**
SHOCK book sold USOIL at 85.096, held 10 minutes, exited at 85.118 via time-stop (EA reason), -$0.22 loss. Direction aligned with council's OIL bias (-0.3), but trade failed to move.

**ALIGNMENT & BIAS ACCURACY:**
Trade was aligned with bearish OIL bias. However, **cannot verify if bias was correct** - all price context data corrupted/unavailable. Operating blind without market confirmation is dangerous.

**ROOT CAUSE:**
Classic SHOCK failure in CAUTION mode: entered a directional trade in what was likely a **choppy, low-volatility Asian session** (00:11 UTC = dead zone). No price movement in 10 minutes = no volatility = wrong environment for SHOCK. The book needs momentum/events to work; it got neither.

**CONCRETE LESSON:**
In CAUTION mode during Asian hours (22:00-02:00 UTC) with no active shock/news, SHOCK book should be **suspended entirely** - it's a momentum hunter being deployed in a desert.

**DIRECTIVE CHANGE:**
Temporarily restrict SHOCK until volatility returns or we exit Asian session. Price context system must be fixed urgently - trading without market data is reckless.

**LESSON:** SHOCK book must not trade during low-volatility Asian hours in CAUTION mode; it requires events or clear momentum to function.

**ACTION:** allow_books=INTRADAY,SWING,POSITION,REVERT; (restore SHOCK after 02:00 UTC or if shock/news emerges)

### 2026-08-19 02:46 UTC
**AUDUSD other SELL 0.01 lots · 586 min · exit EA · P/L 0.91$ · council bias 0.05 (CAUTION)**
## POST-MORTEM ANALYSIS

**TRADE SUMMARY:**
"other" book sold AUDUSD at 0.70922, held 586 minutes (~9.8 hours), exited at 0.70831 via EA (likely time-stop), +$0.91 profit. Direction was SELL AUD, but council bias was **+0.2 AUD** (bullish) – trade was **against council bias**.

**ALIGNMENT & BIAS ACCURACY:**
Trade contradicted council's AUD +0.2 bias. **Cannot verify if bias was correct** – all price context still corrupted. However, the SELL made money (91 pips), suggesting either: (a) council's bullish AUD bias was wrong, or (b) short-term mean-reversion in an extended move (summary noted "AUD trimmed to +0.2 (extended)").

**ROOT CAUSE:**
Win appears to be **variance/luck in a counter-bias trade**. The "other" book (likely a catch-all or legacy EA) ignored council directives and sold into what council thought was extended AUD strength. It worked, but for wrong reasons – no price data means no confirmation this was skill vs. random walk. 9.8-hour hold suggests slow grind, not conviction.

**CONCRETE LESSON:**
"other" book operating independently of council bias is **governance failure**. Either integrate it into allowed_books discipline or kill it. Wins against bias are dangerous – they reward ignoring the council and create false confidence. Also: **fix price context immediately** – two trades, zero market visibility.

**DIRECTIVE CHANGE:**
Identify what "other" book is. If it's rogue/unmanaged, add to block list. If it's legitimate, it must respect council bias or be restricted to REVERT-only mode. No change to current allow_books until price data restored.

**LESSON:** Unmanaged "other" book trading against council bias is a governance hole; wins against bias are luck, not edge, and must be closed.

**ACTION:** Investigate "other" book identity; if non-compliant, add to block or force bias-alignment; priority-1: restore price context feed.

### 2026-08-19 09:05 UTC
**AUDJPY BREAKOUT SELL 0.04 lots · 65 min · exit SL · P/L -4.6$ · council bias -0.1 (CAUTION)**
## POST-MORTEM ANALYSIS

**TRADE SUMMARY:**
BREAKOUT book sold AUDJPY at 112.538, held 65 minutes, hit stop-loss at 112.721, -$4.60 loss (0.04 lots, largest position yet). Direction was SELL AUD/BUY JPY, aligned with council's mild bearish bias (brain_bias -0.1, AUD 0.0, JPY +0.2). Trade taken in CAUTION mode with BREAKOUT explicitly **not in allowed_books list**.

**ALIGNMENT & BIAS ACCURACY:**
Trade direction matched council's slight JPY-bullish tilt, but **BREAKOUT book was BANNED** (allow_books="INTRADAY,SWING,POSITION,REVERT,COUNCIL"). This is a **critical governance violation** – the robot ignored council directives entirely. Cannot assess if bias was correct (price context still dead), but the 18.3-pip adverse move suggests either false breakout or wrong-side entry.

**ROOT CAUSE:**
**Rogue book execution** – BREAKOUT traded despite explicit exclusion, taking 4x normal risk (0.04 lots vs. 0.01 in recent trades) and getting stopped out. This is the second governance failure in 3 trades ("other" book, now BREAKOUT). Root cause is **enforcement failure**: allow_books directive is being ignored by MT4 EAs. The loss itself is secondary to the systemic breakdown – unauthorized books are trading freely.

**CONCRETE LESSON:**
**Immediate EA audit required** – if allow_books cannot be enforced programmatically, all non-compliant EAs must be manually disabled in MT4 terminal. BREAKOUT in particular is dangerous in CAUTION mode (chases momentum in low-conviction environment). The 0.04 lot size suggests it's also ignoring risk_mult=0.6. This is a control system failure, not a market loss.

**DIRECTIVE CHANGE:**
Emergency: **manually disable BREAKOUT EA in MT4 until enforcement mechanism confirmed**. Verify "other" book is also disabled. No directive changes will matter if robots ignore them. Restore price context as priority-1 (third trade blind). Once control restored, BREAKOUT stays banned until regime shifts to "trending" with conf >0.7.

**LESSON:** allow_books directive is not being enforced; BREAKOUT book violated ban and ignored risk controls, causing largest loss in journal.

**ACTION:** allow_books=INTRADAY,SWING,POSITION,REVERT,COUNCIL; **MANUAL: disable BREAKOUT + other EAs in MT4 terminal; audit EA compliance before next trade**

### 2026-08-19 09:13 UTC
**NZDJPY BREAKOUT SELL 0.04 lots · 72 min · exit SL · P/L -4.47$ · council bias -0.05 (CAUTION)**
## POST-MORTEM ANALYSIS

**TRADE SUMMARY:**
BREAKOUT book sold NZDJPY at 93.433, held 72 minutes, hit stop-loss at 93.611, -$4.47 loss (0.04 lots). Direction was SELL NZD/BUY JPY, aligned with council's mild bearish bias (brain_bias -0.05, NZD +0.1, JPY +0.2). **BREAKOUT was explicitly BANNED** from allowed_books list.

**ALIGNMENT & BIAS ACCURACY:**
Trade direction matched council's JPY preference, but this is **irrelevant** – BREAKOUT is operating as a **rogue agent**. This is the **second consecutive banned-book violation** (AUDJPY 7 minutes earlier, now NZDJPY). Cannot verify bias accuracy (price context completely dead for 9+ hours), but 17.8-pip adverse move in 72 minutes suggests false breakout or chop.

**ROOT CAUSE:**
**Systemic enforcement collapse** – BREAKOUT book is ignoring allow_books directive, trading 0.04 lots (4x base size, violating risk_mult=0.6), and has now hit stop-loss on **both** unauthorized trades within 8 minutes of each other. This is not a trading loss; this is a **robot mutiny**. The previous post-mortem called for manual EA shutdown – it clearly wasn't executed, and BREAKOUT immediately took a second unauthorized position. Combined loss: -$9.07 in <2 hours from a banned book.

**CONCRETE LESSON:**
**Words without action are worthless**. The council diagnosed the problem 8 minutes ago (AUDJPY post-mortem) but failed to execute the manual shutdown, allowing BREAKOUT to immediately violate again. Lesson: **emergency directives require immediate physical intervention** – disable the EA in MT4 terminal NOW, not after writing analysis. BREAKOUT in CAUTION mode is a liability, not an asset.

**DIRECTIVE CHANGE:**
**STOP WRITING AND ACT**: Physically disable BREAKOUT EA in MT4 terminal this second. Verify "other" book disabled. Do not process another trade until compliance confirmed. Price context must be fixed before next session – three consecutive trades with zero market visibility is gambling, not trading.

**LESSON:** Emergency directives must be executed immediately, not deferred; BREAKOUT's second violation proves analysis without action enables repeated failures.

**ACTION:** allow_books=INTRADAY,SWING,POSITION,REVERT,COUNCIL; **IMMEDIATE MANUAL ACTION REQUIRED: disable BREAKOUT EA in MT4 NOW; verify enforcement before resuming trading**

### 2026-08-19 12:36 UTC
**EURGBP other SELL 0.08 lots · 96 min · exit EA · P/L 2.5$ · council bias -0.1 (CAUTION)**
## POST-MORTEM ANALYSIS

**TRADE SUMMARY:**
"other" book sold EURGBP at 0.85617, held 96 minutes, closed by EA at 0.85594 for +$2.50 profit (0.08 lots, largest position in journal). Direction was SELL EUR/BUY GBP, aligned with council bias (brain_bias -0.1, EUR -0.2, GBP 0.0). Trade taken in CAUTION mode with "other" book **not in allowed_books list**.

**ALIGNMENT & BIAS ACCURACY:**
Trade direction matched council's EUR-bearish stance and won 2.3 pips. But this is the **third consecutive governance violation** – "other" book remains active despite two prior post-mortems flagging it as rogue. Cannot verify if bias was actually correct (price context still completely dead after 10+ hours). The 0.08 lot size is **13x the banned SHOCK book's size** and violates risk_mult=0.6 in CAUTION mode.

**ROOT CAUSE:**
**Complete enforcement failure and analysis paralysis**. Council has now written three post-mortems identifying rogue books, calling for manual shutdowns, demanding immediate action – yet "other" book just traded 0.08 lots (highest risk in journal) while explicitly banned. The win is **irrelevant** – unauthorized execution with 13x normal risk is Russian roulette. Root cause: **no one is actually disabling the EAs**. Writing lessons without execution is theatre.

**CONCRETE LESSON:**
**This council is impotent if directives aren't enforced**. Three post-mortems, zero compliance. "other" book's $2.50 win with 0.08 lots in a blind market (no price data) is **more dangerous than BREAKOUT's losses** – it rewards maximum risk-taking by a banned book and creates illusion of control. Lesson: **halt all trading until physical EA audit completed**. No more trades until someone confirms in MT4 terminal which EAs are running and manually disables non-compliant ones.

**DIRECTIVE CHANGE:**
**TRADING SUSPENSION**: Do not process another trade until: 1) Physical verification that BREAKOUT and "other" EAs are disabled in MT4, 2) Price context feed restored and verified working, 3) Written confirmation of which EAs are actually running. Current state is unacceptable – banned books trading maximum size with zero market visibility while council writes impotent analyses.

**LESSON:** Three post-mortems with zero enforcement proves the council has no operational control; profitable rogue trades are more dangerous than losses because they mask systemic failure.

**ACTION:** allow_books=SWING,POSITION,REVERT,COUNCIL; risk_mult=0.0; **SUSPEND ALL TRADING until MT4 EA audit completed and price context restored**

