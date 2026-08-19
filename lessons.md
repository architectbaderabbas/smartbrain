# SmartBrain lessons (post-mortems on real trades, newest last)

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

