//+------------------------------------------------------------------+
//|                                           SmartMulti_v12.mq5     |
//|                                                                  |
//|  ADAPTIVE MULTI-HORIZON TRADING SYSTEM                           |
//|                                                                  |
//|  Books (each own TF / hold / study / magic / risk):              |
//|   H0 SCALP     ~10 min  M5   (backtested: DEAD - keep off)       |
//|   H1 SHORT     ~30 min  M15  (off)                               |
//|   H2 INTRADAY  ~4 h     H1   session breakout   (proven)         |
//|   H3 SWING     ~12 h    H4   trend pullback     (best new book)  |
//|   H4 POSITION  ~24 h+   D1   N-day breakout     (thin sample)    |
//|   H5 SHOCK     1-15 min ANY  event-driven momentum <-- Pedro     |
//|                                                                  |
//|  Intelligence layer (v10):                                       |
//|   [A] Volatility-scaled risk sizing                              |
//|   [B] Market-regime detector (trend / range / chaos) that        |
//|       re-weights each book's risk                                |
//|   [C] Self-adapting per-book performance memory (halves risk     |
//|       after a losing streak, pauses after a bad one)             |
//|   [D] Session windows per currency (Tokyo / London / NY)         |
//|   [E] Weekday + first/last-hour filter                           |
//|   [F] Slippage guard on execution                                |
//|   [G] Momentum confirmation (breakout candle body >= 50%)        |
//|   [H] Weekly loss cap                                            |
//|   [I] Dynamic correlation guard between open symbols             |
//|   [J] Push notifications to the phone                            |
//|   [K] Weekly written performance report (file)                   |
//|   [L] Capital-protection mode at -10% (defensive, not off)       |
//|                                                                  |
//|  SHOCK ENGINE (H5) - how it "reads" a sudden event without       |
//|  reading news: a candle whose range is >= K x normal ATR, on     |
//|  volume >= V x average, is a shock. We trade WITH the shock for  |
//|  a very short hold, with a hard time stop and a wide-spread      |
//|  guard, and we NEVER chase after the first N minutes.            |
//|  Best on gold/oil/indices; usable on FX. Backtest decides.       |
//|                                                                  |
//|  Open trades: protected EVERY tick (BE, lock, partial, trail).   |
//|  Entries: on CLOSED bars only (H5 uses its own fast TF close).   |
//|  Built for Pedro                                                 |
//+------------------------------------------------------------------+
#property copyright "Built with Claude"
#property version   "12.50"

#include <Trade/Trade.mqh>

#define NH 8

//==================== PORTFOLIO ==================================
input group "=== PORTFOLIO ==="
input long   InpMagicBase        = 910000;
input double InpMaxTotalRiskPct  = 4.0;
input int    InpMaxTotalPositions= 4;
input int    InpMaxSameCurrency  = 2;
input double InpMaxDailyLossPct  = 5.0;
input double InpMaxWeeklyLossPct = 8.0;     // [H]
input double InpMaxDrawdownPct   = 15.0;
input double InpProtectModePct   = 10.0;    // [L] defensive mode below this DD
input double InpMaxLot           = 0.50;
input int    InpMaxSpreadPoints  = 25;
input double InpCommissionPts    = 5.0;
input double InpMinTPtoCost      = 3.0;
input double InpMinLotRiskCap    = 2.0;     // skip trade if the MIN lot risks more than this x the intended risk money

input group "=== [A] VOLATILITY-SCALED RISK ==="
input bool   InpVolScale         = true;
input int    InpVolLookback      = 100;     // bars of the book TF to define "normal" ATR
input double InpVolHighMult      = 1.8;     // ATR > this x normal -> cut risk
input double InpVolLowMult       = 0.6;     // ATR < this x normal -> allow slight boost
input double InpVolMinFactor     = 0.4;     // risk never below this fraction
input double InpVolMaxFactor     = 1.3;     // risk never above this fraction

input group "=== [B] MARKET REGIME ==="
input bool   InpUseRegime        = true;
input int    InpRegimeADX        = 14;      // ADX on H1
input double InpRegimeTrendADX   = 25.0;    // ADX above = trending
input double InpRegimeChaosATRx  = 2.0;     // ATR > this x normal = chaotic
input double InpRegimeWeightHi   = 1.25;    // favoured book multiplier
input double InpRegimeWeightLo   = 0.5;     // disfavoured book multiplier

input group "=== [C] SELF-ADAPTING MEMORY ==="
input bool   InpUseMemory        = true;
input int    InpMemWindow        = 20;      // last N closed trades per book
input int    InpMemHalveAfter    = 4;       // >= N losses in last 6 -> halve risk
input int    InpMemPauseAfter    = 8;       // consecutive losses -> pause the book
input int    InpMemPauseHours    = 24;

input group "=== [D] SESSIONS PER CURRENCY (server hours) ==="
input bool   InpUseSessions      = true;
input int    InpTokyoStart       = 0;
input int    InpTokyoEnd         = 9;
input int    InpLondonStart      = 8;
input int    InpLondonEnd        = 17;
input int    InpNYStart          = 13;
input int    InpNYEnd            = 22;

input group "=== [E] CALENDAR FILTER ==="
input bool   InpSkipMondayFirst2 = true;    // skip Monday 00-02
input bool   InpSkipFridayLast4  = true;    // skip Friday after 18
input bool   InpSkipFirstHour    = true;    // skip first hour of each book's session

input group "=== [F] SLIPPAGE GUARD ==="
input int    InpMaxSlippagePts   = 15;

input group "=== [G] MOMENTUM CONFIRMATION ==="
input bool   InpUseBodyConfirm   = true;
input double InpMinBodyPct       = 0.5;     // breakout candle body >= 50% of its range

input group "=== [I] CORRELATION GUARD ==="
input bool   InpUseCorrGuard     = true;
input int    InpCorrBars         = 50;
input double InpCorrMax          = 0.80;

input group "=== [J] NOTIFICATIONS ==="
input bool   InpPushNotify       = true;    // needs MetaQuotes ID in Tools>Options>Notifications

input group "=== [K] WEEKLY REPORT ==="
input bool   InpWeeklyReport     = true;    // written to MQL5/Files/SmartMulti_report_<symbol>.txt

input group "=== NEWS FILTER ==="
input bool   InpUseNewsFilter    = true;
input bool   InpNewsBothCurr     = true;
input int    InpNewsMinBefore    = 30;
input int    InpNewsMinAfter     = 15;

input group "=== OPEN-TRADE PROTECTION (every tick) ==="
input double InpBreakEvenR       = 1.0;
input double InpBreakEvenBufATR  = 0.05;
input double InpLockAtPct        = 0.85;
input double InpLockKeepPct      = 0.70;
input double InpPartialAtPct     = 0.0;
input double InpPartialClosePct  = 0.50;
input double InpTrailATR         = 0.0;

input group "=== H0 SCALP (M5) - tested DEAD, keep off ==="
input bool   InpH0_Enabled       = false;
input double InpH0_RiskPct       = 0.5;
input int    InpH0_StudyBars     = 48;
input double InpH0_BurstATR      = 1.2;
input double InpH0_SL_ATR        = 1.0;
input double InpH0_TP_R          = 1.0;
input int    InpH0_HoldBars      = 2;
input int    InpH0_MaxPerDay     = 4;

input group "=== H1 SHORT (M15) ==="
input bool   InpH1_Enabled       = false;
input double InpH1_RiskPct       = 0.5;
input int    InpH1_StudyBars     = 32;
input double InpH1_SL_ATR        = 1.2;
input double InpH1_TP_R          = 1.2;
input int    InpH1_HoldBars      = 2;
input int    InpH1_MaxPerDay     = 4;

input group "=== H2 INTRADAY (H1 session breakout) ==="
input bool   InpH2_Enabled       = false;
input double InpH2_RiskPct       = 1.0;
input int    InpH2_RangeStartHr  = 3;
input int    InpH2_RangeEndHr    = 10;
input int    InpH2_TradeEndHr    = 16;
input int    InpH2_CloseHr       = 23;
input double InpH2_SL_ATR        = 1.5;
input double InpH2_TP_R          = 1.5;
input double InpH2_MinRangeATR   = 0.5;
input int    InpH2_MaxPerDay     = 2;

input group "=== H3 SWING (H4 pullback) ==="
input bool   InpH3_Enabled       = true;
input double InpH3_RiskPct       = 1.0;
input int    InpH3_StudyBars     = 60;
input int    InpH3_EMAPeriod     = 20;
input int    InpH3_RSIPeriod     = 14;
input double InpH3_PullbackRSI   = 45.0;
input double InpH3_SL_ATR        = 1.5;
input double InpH3_TP_R          = 2.0;
input int    InpH3_HoldBars      = 3;
input int    InpH3_MaxPerDay     = 1;

input group "=== H4 POSITION (D1 breakout) ==="
input bool   InpH4_Enabled       = false;
input double InpH4_RiskPct       = 1.0;
input int    InpH4_StudyBars     = 60;
input int    InpH4_BreakBars     = 20;
input double InpH4_SL_ATR        = 2.0;
input double InpH4_TP_R          = 2.5;
input int    InpH4_HoldBars      = 5;
input int    InpH4_MaxPerDay     = 1;

input group "=== H5 SHOCK ENGINE (event-driven, 1-15 min) ==="
input bool   InpH5_Enabled       = true;    // metals/oil/indices (brain shock can enable on FX)
input ENUM_TIMEFRAMES InpH5_TF   = PERIOD_M1; // detection timeframe
input double InpH5_RiskPct       = 0.5;
input double InpH5_ShockATRx     = 3.0;     // candle range >= this x normal ATR = shock
input double InpH5_ShockVolx     = 2.0;     // tick volume >= this x average (0 = ignore volume)
input double InpH5_MinBodyPct    = 0.6;     // shock candle must be decisive (body/range)
input int    InpH5_MaxLateBars   = 1;       // enter only within N bars after the shock
input double InpH5_SL_ATR        = 1.0;     // SL in units of the SHOCK candle range
input double InpH5_TP_R          = 1.5;
input int    InpH5_HoldBars      = 30;      // hard time stop (bars of InpH5_TF)
input int    InpH5_MaxSpreadMult = 3;       // allow spread up to N x normal during shock
input int    InpH5_MaxPerDay     = 2;
input int    InpH5_CooldownMin   = 30;      // minutes before next shock trade on same symbol
input bool   InpH5_OnlyMetalsOil = true;    // restrict to XAU/XAG/OIL/indices unless false
input double InpH5_BrainBiasBlock = 0.3;    // SHOCK never trades against a council bias stronger than this

input group "=== H6 COUNCIL (trades the brain's view, price-confirmed) ==="
input bool   InpH6_Enabled       = true;
input double InpH6_RiskPct       = 0.5;
input double InpH6_MinConf       = 0.6;     // council confidence needed
input double InpH6_MinBias       = 0.7;     // |symbol bias| needed
input int    InpH6_EMAPeriod     = 20;      // H1 EMA for price confirmation
input double InpH6_SL_ATR        = 1.5;     // SL = ATR(H1) x this
input double InpH6_TP_R          = 1.5;
input int    InpH6_HoldBars      = 12;      // max hold (H1 bars) -> then BE/close
input int    InpH6_MaxPerDay     = 1;
input int    InpH6_MaxOpen       = 2;       // max simultaneous COUNCIL trades (all symbols)
input int    InpH6_PauseAfterLoss= 2;       // consecutive losses -> pause this symbol
input int    InpH6_PauseHours    = 24;

input group "=== H7 REVERT (H1 mean reversion; ex-SmartRevert, now council-aware) ==="
input bool   InpH7_Enabled       = false;   // enable on the ex-REVERT charts (EURUSD EURGBP EURNZD NZDUSD CHFJPY)
input double InpH7_RiskPct       = 0.75;
input int    InpH7_BBPeriod      = 20;      // Bollinger period (H1)
input double InpH7_BBDev         = 2.0;     // Bollinger deviations
input int    InpH7_RSIPeriod     = 14;
input double InpH7_RSIOversold   = 30.0;    // buy zone
input double InpH7_RSIOverbought = 70.0;    // sell zone
input double InpH7_SL_ATR        = 2.0;     // SL = x ATR(H1)
input double InpH7_MinTP_ATR     = 0.5;     // skip if the middle band is closer than x ATR
input double InpH7_ADXMax        = 30.0;    // no mean reversion in a strong trend (H1 ADX)
input int    InpH7_HoldBars      = 24;      // time stop (H1 bars)
input int    InpH7_MaxPerDay     = 2;
input double InpH7_BrainBiasBlock= 0.3;     // REVERT never fades a council bias stronger than this

input group "=== CONTEXT / TREND ==="
input bool   InpUseCtxFilter     = true;
input double InpCtxMaxExtension  = 3.0;
input bool   InpCtxRequireAlign  = false;
input bool   InpUseDailyTrend    = false;
input int    InpDailyTrendBars   = 5;

input group "=== BRAIN (council of experts, read from URL) ==="
input bool   InpBrainEnabled     = true;
input string InpBrainURL         = "https://raw.githubusercontent.com/architectbaderabbas/smartbrain/main/brain.txt";
input int    InpBrainRefreshMin  = 5;       // re-read the brain every N minutes
input int    InpBrainMaxAgeMin   = 45;      // older than this -> brain ignored (fail-safe)
input bool   InpBrainEnforce     = true;    // false = advisory only (log, no blocking)
input double InpBrainBiasBlock   = 0.5;     // block trades against a bias stronger than this
input double InpBrainBiasBoost   = 0.5;     // boost risk when aligned with a bias stronger than this
input double InpBrainBoostMult   = 1.25;
input bool   InpBrainShockAssist = true;    // brain shock directive relaxes H5 detection (still price-confirmed)
input double InpBrainShockATRx   = 0.6;     // H5 ATR multiple factor when the brain flags a shock

input group "=== ACCOUNT REPORT -> BRAIN (enable on ONE chart only) ==="
input bool   InpReportEnabled    = false;   // this chart posts account.json to GitHub
input string InpReportRepo       = "architectbaderabbas/smartbrain";
input string InpReportToken      = "";      // GitHub fine-grained token (Contents: read/write) - paste on the reporter chart only
input int    InpReportEveryMin   = 15;
input string InpReportPriceSyms  = "XAUUSD,XAGUSD,USOIL,UKOIL,US500,US100,US30,GER40,EURUSD,GBPUSD,USDJPY,AUDUSD,NZDUSD,USDCAD,USDCHF,EURGBP,EURJPY,GBPJPY,AUDJPY,NZDJPY,CHFJPY,EURNZD"; // live prices sent to the brain

input group "=== LOGGING ==="
input bool   InpStatusLog        = true;
input bool   InpDailySummaryLog  = true;

//==================== INTERNALS ==================================
CTrade trade;

ENUM_TIMEFRAMES hTF[NH];
string   hName[NH];
bool     hOn[NH];
double   hRisk[NH];
double   hSL_ATR[NH];
double   hTP_R[NH];
int      hHold[NH];
int      hMaxDay[NH];
int      hStudy[NH];
long     hMagic[NH];
int      hATRh[NH];
int      hTradesToday[NH];
datetime hLastBar[NH];
datetime hPausedUntil[NH];     // [C]
double   hRegimeW[NH];         // [B]

int gEMA_H4 = INVALID_HANDLE;
int gRSI_H4 = INVALID_HANDLE;
int gADX_H1 = INVALID_HANDLE;
int gATR_H1 = INVALID_HANDLE;
int gEMA_H1 = INVALID_HANDLE;
int gBB_H7 = INVALID_HANDLE, gRSI_H7 = INVALID_HANDLE, gADX_H7 = INVALID_HANDLE;   // H7 REVERT
double gTPOverride = 0.0;      // absolute TP price for the next DoOpen (REVERT: middle band)

double   gRangeHigh = 0.0, gRangeLow = 0.0;
bool     gRangeInit = false, gBought = false, gSold = false;

datetime gLastShockTrade = 0;  // H5 cooldown

string   gvPeak = "";
datetime gCurrentDay = 0, gCurrentWeek = 0;
double   gDayStartEquity = 0.0, gWeekStartEquity = 0.0;
int      gRegime = 0;          // 0 range, 1 trend, 2 chaos
bool     gProtectMode = false;

// ---- brain state ----
bool     gBrainOK = false;          // fresh + parsed
datetime gBrainTs = 0;              // brain generation time (UTC)
datetime gBrainLastTry = 0;
int      gBrainMode = 0;            // 0 normal 1 caution 2 danger 3 halt
double   gBrainRiskMult = 1.0, gBrainConf = 0.0;
string   gBrainKeys[], gBrainVals[];
string   gBrainSummary = "";
bool     gH5SymbolOK = true;
datetime gLastReport = 0;        // symbol allowed for H5 by InpH5_OnlyMetalsOil

//+------------------------------------------------------------------+
int OnInit()
  {
   trade.SetDeviationInPoints(InpMaxSlippagePts);   // [F]
   trade.SetTypeFillingBySymbol(_Symbol);

   hTF[0]=PERIOD_M5;  hName[0]="SCALP";    hOn[0]=InpH0_Enabled; hRisk[0]=InpH0_RiskPct;
   hTF[1]=PERIOD_M15; hName[1]="SHORT";    hOn[1]=InpH1_Enabled; hRisk[1]=InpH1_RiskPct;
   hTF[2]=PERIOD_H1;  hName[2]="INTRADAY"; hOn[2]=InpH2_Enabled; hRisk[2]=InpH2_RiskPct;
   hTF[3]=PERIOD_H4;  hName[3]="SWING";    hOn[3]=InpH3_Enabled; hRisk[3]=InpH3_RiskPct;
   hTF[4]=PERIOD_D1;  hName[4]="POSITION"; hOn[4]=InpH4_Enabled; hRisk[4]=InpH4_RiskPct;
   hTF[5]=InpH5_TF;   hName[5]="SHOCK";    hOn[5]=InpH5_Enabled; hRisk[5]=InpH5_RiskPct;
   hTF[6]=PERIOD_H1;  hName[6]="COUNCIL";  hOn[6]=InpH6_Enabled; hRisk[6]=InpH6_RiskPct;
   hTF[7]=PERIOD_H1;  hName[7]="REVERT";   hOn[7]=InpH7_Enabled; hRisk[7]=InpH7_RiskPct;

   hSL_ATR[0]=InpH0_SL_ATR; hSL_ATR[1]=InpH1_SL_ATR; hSL_ATR[2]=InpH2_SL_ATR;
   hSL_ATR[3]=InpH3_SL_ATR; hSL_ATR[4]=InpH4_SL_ATR; hSL_ATR[5]=InpH5_SL_ATR; hSL_ATR[6]=InpH6_SL_ATR; hSL_ATR[7]=InpH7_SL_ATR;
   hTP_R[0]=InpH0_TP_R; hTP_R[1]=InpH1_TP_R; hTP_R[2]=InpH2_TP_R;
   hTP_R[3]=InpH3_TP_R; hTP_R[4]=InpH4_TP_R; hTP_R[5]=InpH5_TP_R; hTP_R[6]=InpH6_TP_R; hTP_R[7]=1.0;
   hHold[0]=InpH0_HoldBars; hHold[1]=InpH1_HoldBars; hHold[2]=0;
   hHold[3]=InpH3_HoldBars; hHold[4]=InpH4_HoldBars; hHold[5]=InpH5_HoldBars; hHold[6]=InpH6_HoldBars; hHold[7]=InpH7_HoldBars;
   hMaxDay[0]=InpH0_MaxPerDay; hMaxDay[1]=InpH1_MaxPerDay; hMaxDay[2]=InpH2_MaxPerDay;
   hMaxDay[3]=InpH3_MaxPerDay; hMaxDay[4]=InpH4_MaxPerDay; hMaxDay[5]=InpH5_MaxPerDay; hMaxDay[6]=InpH6_MaxPerDay; hMaxDay[7]=InpH7_MaxPerDay;
   hStudy[0]=InpH0_StudyBars; hStudy[1]=InpH1_StudyBars; hStudy[2]=24;
   hStudy[3]=InpH3_StudyBars; hStudy[4]=InpH4_StudyBars; hStudy[5]=60; hStudy[6]=24; hStudy[7]=24;

   // H5 symbol restriction
   gH5SymbolOK = !(InpH5_OnlyMetalsOil && !IsMetalOilIndex(_Symbol));
   if(hOn[5] && !gH5SymbolOK)
      Print("SHOCK book on ", _Symbol, ": price-only detection off (OnlyMetalsOil=true); brain shock directives still honoured");

   for(int i = 0; i < NH; i++)
     {
      hMagic[i]       = InpMagicBase + i;
      hTradesToday[i] = 0;
      hLastBar[i]     = 0;
      hPausedUntil[i] = 0;
      hRegimeW[i]     = 1.0;
      hATRh[i] = iATR(_Symbol, hTF[i], 14);
      if(hATRh[i] == INVALID_HANDLE) { Print("ATR handle failed ", hName[i]); return(INIT_FAILED); }
     }

   gEMA_H4 = iMA(_Symbol, PERIOD_H4, InpH3_EMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   gRSI_H4 = iRSI(_Symbol, PERIOD_H4, InpH3_RSIPeriod, PRICE_CLOSE);
   gADX_H1 = iADX(_Symbol, PERIOD_H1, InpRegimeADX);
   gATR_H1 = iATR(_Symbol, PERIOD_H1, 14);
   gEMA_H1 = iMA(_Symbol, PERIOD_H1, InpH6_EMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   if(gEMA_H4 == INVALID_HANDLE || gRSI_H4 == INVALID_HANDLE || gEMA_H1 == INVALID_HANDLE ||
      gADX_H1 == INVALID_HANDLE || gATR_H1 == INVALID_HANDLE)
     { Print("Indicator handles failed"); return(INIT_FAILED); }
   if(hOn[7])
     {
      gBB_H7  = iBands(_Symbol, PERIOD_H1, InpH7_BBPeriod, 0, InpH7_BBDev, PRICE_CLOSE);
      gRSI_H7 = iRSI(_Symbol, PERIOD_H1, InpH7_RSIPeriod, PRICE_CLOSE);
      gADX_H7 = iADX(_Symbol, PERIOD_H1, 14);
      if(gBB_H7 == INVALID_HANDLE || gRSI_H7 == INVALID_HANDLE || gADX_H7 == INVALID_HANDLE)
        { Print("REVERT indicator handles failed"); return(INIT_FAILED); }
     }

   gvPeak = "SM10_Peak_" + (string)InpMagicBase;
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(!GlobalVariableCheck(gvPeak) || GlobalVariableGet(gvPeak) < eq)
      GlobalVariableSet(gvPeak, eq);

   ResetDay();
   ResetWeek();
   EventSetTimer(30);
   BrainRefresh(true);

   string on = "";
   for(int i = 0; i < NH; i++) if(hOn[i]) on += hName[i] + " ";
   Print("SmartMulti v12 on ", _Symbol, " | books: ", (on == "" ? "NONE" : on),
         "| regime=", InpUseRegime, " volScale=", InpVolScale, " memory=", InpUseMemory);
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
   for(int i = 0; i < NH; i++) if(hATRh[i] != INVALID_HANDLE) IndicatorRelease(hATRh[i]);
   if(gEMA_H4 != INVALID_HANDLE) IndicatorRelease(gEMA_H4);
   if(gRSI_H4 != INVALID_HANDLE) IndicatorRelease(gRSI_H4);
   if(gADX_H1 != INVALID_HANDLE) IndicatorRelease(gADX_H1);
   if(gATR_H1 != INVALID_HANDLE) IndicatorRelease(gATR_H1);
   if(gEMA_H1 != INVALID_HANDLE) IndicatorRelease(gEMA_H1);
   if(gBB_H7  != INVALID_HANDLE) IndicatorRelease(gBB_H7);
   if(gRSI_H7 != INVALID_HANDLE) IndicatorRelease(gRSI_H7);
   if(gADX_H7 != INVALID_HANDLE) IndicatorRelease(gADX_H7);
  }

//+------------------------------------------------------------------+
void OnTimer() { BrainRefresh(false); ReportAccount(false); }

//+------------------------------------------------------------------+
void OnTick()
  {
   ProfitGuard();
   BrainRefresh(false);
   CheckNewDay();
   CheckNewWeek();
   UpdateEquityPeak();
   UpdateProtectMode();          // [L]

   ManageOpenTrades();           // every tick

   if(!PortfolioAllowsNewTrade()) return;

   // SHOCK v2: early entries (every tick, not only on closed bars)
   if(hOn[5]) { ShockNewsBreakout(); ShockLiveEntry(); }

   // Regime is recomputed once per H1 bar (cheap)
   static datetime lastH1 = 0;
   datetime h1 = iTime(_Symbol, PERIOD_H1, 0);
   if(h1 != lastH1) { lastH1 = h1; UpdateRegime(); if(InpStatusLog) StatusLog(); }

   for(int i = 0; i < NH; i++)
     {
      if(!hOn[i]) continue;
      if(hPausedUntil[i] > TimeCurrent()) continue;      // [C]

      datetime bt = iTime(_Symbol, hTF[i], 0);
      if(bt == hLastBar[i]) continue;
      hLastBar[i] = bt;

      if(i == 2) UpdateSessionRange();
      if(hTradesToday[i] >= hMaxDay[i]) continue;
      if(gProtectMode && i != 3 && i != 2) continue;
      if(gBrainOK && InpBrainEnforce && !BrainAllowsBook(i)) continue;
      if(i == 5 && !gH5SymbolOK && !BrainShockActive()) continue;      // [L] defensive: only proven books

      TryHorizon(i);
     }
  }

//+------------------------------------------------------------------+
//| Day / week bookkeeping                                            |
//+------------------------------------------------------------------+
void CheckNewDay()
  {
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   dt.hour = 0; dt.min = 0; dt.sec = 0;
   datetime today = StructToTime(dt);
   if(today != gCurrentDay)
     {
      if(InpDailySummaryLog && gCurrentDay > 0) DailySummary();
      ResetDay();
     }
  }
void ResetDay()
  {
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   dt.hour = 0; dt.min = 0; dt.sec = 0;
   gCurrentDay     = StructToTime(dt);
   gDayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   for(int i = 0; i < NH; i++) hTradesToday[i] = 0;
   gRangeHigh = 0.0; gRangeLow = 0.0; gRangeInit = false; gBought = false; gSold = false;
  }
void CheckNewWeek()
  {
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   // week key = date of the Monday
   datetime dayStart = TimeCurrent() - (TimeCurrent() % 86400);
   int dow = dt.day_of_week; if(dow == 0) dow = 7;
   datetime monday = dayStart - (datetime)((dow - 1) * 86400);
   if(monday != gCurrentWeek)
     {
      if(InpWeeklyReport && gCurrentWeek > 0) WeeklyReport();
      ResetWeek();
     }
  }
void ResetWeek()
  {
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   datetime dayStart = TimeCurrent() - (TimeCurrent() % 86400);
   int dow = dt.day_of_week; if(dow == 0) dow = 7;
   gCurrentWeek     = dayStart - (datetime)((dow - 1) * 86400);
   gWeekStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
  }
void UpdateEquityPeak()
  {
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(!GlobalVariableCheck(gvPeak) || eq > GlobalVariableGet(gvPeak)) GlobalVariableSet(gvPeak, eq);
  }

//+------------------------------------------------------------------+
//| [L] Capital-protection mode                                      |
//+------------------------------------------------------------------+
void UpdateProtectMode()
  {
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   double peak = GlobalVariableCheck(gvPeak) ? GlobalVariableGet(gvPeak) : eq;
   bool now = (peak > 0 && eq <= peak * (1.0 - InpProtectModePct / 100.0));
   if(now != gProtectMode)
     {
      gProtectMode = now;
      string msg = now ? "PROTECT MODE ON: drawdown > " + DoubleToString(InpProtectModePct, 1) + "% - risk halved, weak books paused"
                       : "PROTECT MODE OFF: equity recovered";
      Print(msg);
      Notify(msg);
     }
  }

//+------------------------------------------------------------------+
//| [B] Regime detector -> per-book weights                          |
//+------------------------------------------------------------------+
void UpdateRegime()
  {
   if(!InpUseRegime) { for(int i = 0; i < NH; i++) hRegimeW[i] = 1.0; return; }

   double adx[], atr[];
   ArraySetAsSeries(adx, true); ArraySetAsSeries(atr, true);
   if(CopyBuffer(gADX_H1, 0, 0, 2, adx) < 2) return;
   if(CopyBuffer(gATR_H1, 0, 0, InpVolLookback + 2, atr) < InpVolLookback + 2) return;

   double norm = 0.0;
   for(int i = 1; i <= InpVolLookback; i++) norm += atr[i];
   norm /= InpVolLookback;
   double atrNow = atr[1];

   int newRegime;
   if(norm > 0 && atrNow >= InpRegimeChaosATRx * norm) newRegime = 2;   // chaos
   else if(adx[1] >= InpRegimeTrendADX)                newRegime = 1;   // trend
   else                                                newRegime = 0;   // range

   if(newRegime != gRegime)
     {
      gRegime = newRegime;
      Print("REGIME -> ", RegimeName(gRegime), " (ADX=", DoubleToString(adx[1], 1),
            " ATR/normal=", DoubleToString(norm > 0 ? atrNow / norm : 0, 2), ")");
     }

   // weights: who gets favoured in which regime
   //  range : nothing special (mean-reversion lives in the other EA)
   //  trend : breakout books (H2, H4) and swing (H3) up; scalps down
   //  chaos : everything down except SHOCK (H5) up
   for(int i = 0; i < NH; i++) hRegimeW[i] = 1.0;
   if(gRegime == 0)
     { hRegimeW[7] = InpRegimeWeightHi; }
   else if(gRegime == 1)
     { hRegimeW[2] = InpRegimeWeightHi; hRegimeW[3] = InpRegimeWeightHi; hRegimeW[4] = InpRegimeWeightHi;
       hRegimeW[0] = InpRegimeWeightLo; hRegimeW[1] = InpRegimeWeightLo; hRegimeW[7] = InpRegimeWeightLo; }
   else if(gRegime == 2)
     { for(int i = 0; i < NH; i++) hRegimeW[i] = InpRegimeWeightLo; hRegimeW[5] = InpRegimeWeightHi; }
  }
string RegimeName(int r) { return(r == 0 ? "RANGE" : (r == 1 ? "TREND" : "CHAOS")); }

//+------------------------------------------------------------------+
//| [A] Volatility factor for a book                                  |
//+------------------------------------------------------------------+
double VolFactor(const int h)
  {
   if(!InpVolScale) return(1.0);
   double a[];
   ArraySetAsSeries(a, true);
   int need = InpVolLookback + 2;
   if(CopyBuffer(hATRh[h], 0, 0, need, a) < need) return(1.0);
   double norm = 0.0;
   for(int i = 1; i <= InpVolLookback; i++) norm += a[i];
   norm /= InpVolLookback;
   if(norm <= 0) return(1.0);
   double ratio = a[1] / norm;
   double f = 1.0;
   if(ratio >= InpVolHighMult)     f = 1.0 / ratio;          // e.g. 2x ATR -> 0.5 risk
   else if(ratio <= InpVolLowMult) f = 1.0 + (InpVolLowMult - ratio);
   if(f < InpVolMinFactor) f = InpVolMinFactor;
   if(f > InpVolMaxFactor) f = InpVolMaxFactor;
   return(f);
  }

//+------------------------------------------------------------------+
//| [C] Performance memory: streaks over last N closed trades        |
//+------------------------------------------------------------------+
double MemoryFactor(const int h)
  {
   if(!InpUseMemory) return(1.0);
   if(!HistorySelect(TimeCurrent() - 90 * 86400, TimeCurrent())) return(1.0);

   double pl[];
   ArrayResize(pl, 0);
   int deals = HistoryDealsTotal();
   for(int d = deals - 1; d >= 0 && ArraySize(pl) < InpMemWindow; d--)
     {
      ulong t = HistoryDealGetTicket(d);
      if(t == 0) continue;
      if(HistoryDealGetString(t, DEAL_SYMBOL) != _Symbol) continue;
      if(HistoryDealGetInteger(t, DEAL_MAGIC) != hMagic[h]) continue;
      if(HistoryDealGetInteger(t, DEAL_ENTRY) != DEAL_ENTRY_OUT) continue;
      double p = HistoryDealGetDouble(t, DEAL_PROFIT) + HistoryDealGetDouble(t, DEAL_SWAP)
               + HistoryDealGetDouble(t, DEAL_COMMISSION);
      int n = ArraySize(pl); ArrayResize(pl, n + 1); pl[n] = p;   // newest first
     }
   int n = ArraySize(pl);
   if(n < 3) return(1.0);

   // consecutive losses from the newest
   int streak = 0;
   for(int i = 0; i < n; i++) { if(pl[i] < 0) streak++; else break; }
   if(streak >= InpMemPauseAfter && hPausedUntil[h] < TimeCurrent())
     {
      hPausedUntil[h] = TimeCurrent() + (datetime)(InpMemPauseHours * 3600);
      string m = hName[h] + " on " + _Symbol + ": " + (string)streak + " losses in a row - PAUSED " + (string)InpMemPauseHours + "h";
      Print(m); Notify(m);
      return(0.0);
     }
   // losses in last 6
   int lastN = MathMin(6, n), losses = 0;
   for(int i = 0; i < lastN; i++) if(pl[i] < 0) losses++;
   if(losses >= InpMemHalveAfter) return(0.5);
   return(1.0);
  }

//+------------------------------------------------------------------+
//| [D] Session window per currency                                  |
//+------------------------------------------------------------------+
bool InSessionForSymbol()
  {
   if(!InpUseSessions) return(true);
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   int hr = dt.hour;
   string b = SymbolInfoString(_Symbol, SYMBOL_CURRENCY_BASE);
   string q = SymbolInfoString(_Symbol, SYMBOL_CURRENCY_PROFIT);
   bool tokyo  = (hr >= InpTokyoStart  && hr < InpTokyoEnd);
   bool london = (hr >= InpLondonStart && hr < InpLondonEnd);
   bool ny     = (hr >= InpNYStart     && hr < InpNYEnd);

   bool ok = false;
   string cs[2]; cs[0] = b; cs[1] = q;
   for(int i = 0; i < 2; i++)
     {
      string c = cs[i];
      if(c == "JPY" || c == "AUD" || c == "NZD") ok = ok || tokyo || london;
      else if(c == "EUR" || c == "GBP" || c == "CHF") ok = ok || london || ny;
      else if(c == "USD" || c == "CAD")               ok = ok || london || ny;
      else                                            ok = true;   // metals/oil/indices: any
     }
   return(ok);
  }

//+------------------------------------------------------------------+
//| [E] Calendar filter                                              |
//+------------------------------------------------------------------+
bool CalendarAllows()
  {
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   if(InpSkipMondayFirst2 && dt.day_of_week == 1 && dt.hour < 2) return(false);
   if(InpSkipFridayLast4  && dt.day_of_week == 5 && dt.hour >= 18) return(false);
   if(dt.day_of_week == 0 || dt.day_of_week == 6) return(false);
   return(true);
  }

//+------------------------------------------------------------------+
bool IsMetalOilIndex(const string s)
  {
   string u = s; StringToUpper(u);
   return(StringFind(u, "XAU") >= 0 || StringFind(u, "XAG") >= 0 || StringFind(u, "GOLD") >= 0 ||
          StringFind(u, "OIL") >= 0 || StringFind(u, "BRENT") >= 0 || StringFind(u, "WTI") >= 0 ||
          StringFind(u, "US30") >= 0 || StringFind(u, "US100") >= 0 || StringFind(u, "US500") >= 0 ||
          StringFind(u, "DJ30") >= 0 || StringFind(u, "GER40") >= 0 || StringFind(u, "NAS") >= 0);
  }

//+------------------------------------------------------------------+
//| Portfolio gates                                                  |
//+------------------------------------------------------------------+
bool PortfolioAllowsNewTrade()
  {
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   double peak = GlobalVariableCheck(gvPeak) ? GlobalVariableGet(gvPeak) : eq;
   if(peak > 0 && eq <= peak * (1.0 - InpMaxDrawdownPct / 100.0)) return(false);
   if(gDayStartEquity > 0 && eq <= gDayStartEquity * (1.0 - InpMaxDailyLossPct / 100.0)) return(false);
   if(gWeekStartEquity > 0 && eq <= gWeekStartEquity * (1.0 - InpMaxWeeklyLossPct / 100.0)) return(false); // [H]
   if(CountMyPositions() >= InpMaxTotalPositions) return(false);
   if(OpenRiskPct() >= InpMaxTotalRiskPct) return(false);
   if(!CalendarAllows()) return(false);
   if(NewsNear()) return(false);
   if(gBrainOK && InpBrainEnforce && gBrainMode == 3) return(false);   // brain: HALT
   return(true);
  }

int CountMyPositions()
  {
   int c = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i); if(t == 0) continue;
      long m = PositionGetInteger(POSITION_MAGIC);
      if(m >= InpMagicBase && m < InpMagicBase + NH) c++;
     }
   return(c);
  }

double OpenRiskPct()
  {
   double eq = AccountInfoDouble(ACCOUNT_EQUITY); if(eq <= 0) return(100.0);
   double risk = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i); if(t == 0) continue;
      long m = PositionGetInteger(POSITION_MAGIC);
      if(m < InpMagicBase || m >= InpMagicBase + NH) continue;
      string s = PositionGetString(POSITION_SYMBOL);
      double tv = SymbolInfoDouble(s, SYMBOL_TRADE_TICK_VALUE);
      double ts = SymbolInfoDouble(s, SYMBOL_TRADE_TICK_SIZE);
      if(tv <= 0 || ts <= 0) continue;
      double sl = PositionGetDouble(POSITION_SL); if(sl <= 0) continue;
      double op = PositionGetDouble(POSITION_PRICE_OPEN);
      double vol = PositionGetDouble(POSITION_VOLUME);
      risk += MathAbs(op - sl) / ts * tv * vol;
     }
   return(risk / eq * 100.0);
  }

//+------------------------------------------------------------------+
bool NewsNear()
  {
   if(!InpUseNewsFilter) return(false);
   if(MQLInfoInteger(MQL_TESTER) || MQLInfoInteger(MQL_OPTIMIZATION)) return(false);
   datetime from = TimeCurrent() - (datetime)(InpNewsMinAfter * 60);
   datetime to   = TimeCurrent() + (datetime)(InpNewsMinBefore * 60);
   string cur[2]; int n = 0;
   if(InpNewsBothCurr)
     {
      string b = SymbolInfoString(_Symbol, SYMBOL_CURRENCY_BASE);
      string q = SymbolInfoString(_Symbol, SYMBOL_CURRENCY_PROFIT);
      if(b != "") { cur[n] = b; n++; }
      if(q != "" && q != b) { cur[n] = q; n++; }
     }
   if(n == 0) { cur[0] = "USD"; cur[1] = "EUR"; n = 2; }
   for(int c = 0; c < n; c++)
     {
      MqlCalendarValue v[];
      if(!CalendarValueHistory(v, from, to, NULL, cur[c])) continue;
      for(int i = 0; i < ArraySize(v); i++)
        {
         MqlCalendarEvent ev;
         if(!CalendarEventById(v[i].event_id, ev)) continue;
         if(ev.importance == CALENDAR_IMPORTANCE_HIGH) return(true);
        }
     }
   return(false);
  }

//+------------------------------------------------------------------+
//| Currency guard + [I] correlation guard                            |
//+------------------------------------------------------------------+
int CurrencyExposure(const string c, const int dir)
  {
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i); if(t == 0) continue;
      string s = PositionGetString(POSITION_SYMBOL);
      int sgn = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 1 : -1;
      string b = SymbolInfoString(s, SYMBOL_CURRENCY_BASE);
      string q = SymbolInfoString(s, SYMBOL_CURRENCY_PROFIT);
      if(b == c && sgn == dir) n++; else if(q == c && -sgn == dir) n++;
     }
   return(n);
  }
bool CurrencyGuardBlocks(const ENUM_ORDER_TYPE type)
  {
   if(InpMaxSameCurrency <= 0) return(false);
   int sgn = (type == ORDER_TYPE_BUY) ? 1 : -1;
   string b = SymbolInfoString(_Symbol, SYMBOL_CURRENCY_BASE);
   string q = SymbolInfoString(_Symbol, SYMBOL_CURRENCY_PROFIT);
   if(b != "" && CurrencyExposure(b, sgn) >= InpMaxSameCurrency) return(true);
   if(q != "" && CurrencyExposure(q, -sgn) >= InpMaxSameCurrency) return(true);
   return(false);
  }

// Pearson correlation of H1 closes between two symbols over N bars
double Corr(const string a, const string b, const int n)
  {
   double ca[], cb[];
   if(CopyClose(a, PERIOD_H1, 1, n, ca) < n) return(0.0);
   if(CopyClose(b, PERIOD_H1, 1, n, cb) < n) return(0.0);
   double ma = 0, mb = 0;
   for(int i = 0; i < n; i++) { ma += ca[i]; mb += cb[i]; }
   ma /= n; mb /= n;
   double sab = 0, saa = 0, sbb = 0;
   for(int i = 0; i < n; i++)
     { double da = ca[i] - ma, db = cb[i] - mb; sab += da * db; saa += da * da; sbb += db * db; }
   if(saa <= 0 || sbb <= 0) return(0.0);
   return(sab / MathSqrt(saa * sbb));
  }
bool CorrelationGuardBlocks(const ENUM_ORDER_TYPE type)
  {
   if(!InpUseCorrGuard) return(false);
   int dir = (type == ORDER_TYPE_BUY) ? 1 : -1;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i); if(t == 0) continue;
      string s = PositionGetString(POSITION_SYMBOL);
      if(s == _Symbol) continue;
      int sgn = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 1 : -1;
      double c = Corr(_Symbol, s, InpCorrBars);
      // same direction & strongly positive corr, or opposite direction & strongly negative
      if((c >= InpCorrMax && sgn == dir) || (c <= -InpCorrMax && sgn == -dir))
        {
         Print("Correlation guard: ", _Symbol, " vs ", s, " corr=", DoubleToString(c, 2), " - skipped");
         return(true);
        }
     }
   return(false);
  }

//+------------------------------------------------------------------+
//| Context / trend                                                  |
//+------------------------------------------------------------------+
bool StudyWindow(const int h, const double atrVal, double &driftATR, double &rangeATR)
  {
   driftATR = 0.0; rangeATR = 0.0;
   int n = hStudy[h];
   if(atrVal <= 0 || n < 3) return(false);
   if(Bars(_Symbol, hTF[h]) < n + 2) return(false);
   double hh = -DBL_MAX, ll = DBL_MAX;
   for(int i = 1; i <= n; i++)
     {
      double hv = iHigh(_Symbol, hTF[h], i), lv = iLow(_Symbol, hTF[h], i);
      if(hv <= 0 || lv <= 0) return(false);
      if(hv > hh) hh = hv; if(lv < ll) ll = lv;
     }
   double newest = iClose(_Symbol, hTF[h], 1), oldest = iClose(_Symbol, hTF[h], n);
   if(newest <= 0 || oldest <= 0) return(false);
   driftATR = (newest - oldest) / atrVal; rangeATR = (hh - ll) / atrVal;
   return(true);
  }
bool ContextAllows(const int h, const ENUM_ORDER_TYPE type, const double atrVal)
  {
   if(!InpUseCtxFilter || h == 5 || h == 6 || h == 7) return(true);   // shock/council/revert exempt by design
   double drift, rng;
   if(!StudyWindow(h, atrVal, drift, rng)) return(true);
   int dir = (type == ORDER_TYPE_BUY) ? 1 : -1;
   if(InpCtxMaxExtension > 0.0 && (drift * dir) > InpCtxMaxExtension) return(false);
   if(InpCtxRequireAlign && (drift * dir) < 0.0) return(false);
   return(true);
  }
bool DailyTrendAllows(const ENUM_ORDER_TYPE type, const int h = -1)
  {
   if(!InpUseDailyTrend || h == 7) return(true);   // REVERT fades moves by design
   double nw = iClose(_Symbol, PERIOD_D1, 1), pa = iClose(_Symbol, PERIOD_D1, InpDailyTrendBars + 1);
   if(nw <= 0 || pa <= 0) return(true);
   bool up = (nw > pa);
   if((type == ORDER_TYPE_BUY && !up) || (type == ORDER_TYPE_SELL && up)) return(false);
   return(true);
  }

// [G] candle body must be decisive
bool BodyConfirms(const ENUM_TIMEFRAMES tf, const double minPct)
  {
   double o = iOpen(_Symbol, tf, 1), c = iClose(_Symbol, tf, 1);
   double hh = iHigh(_Symbol, tf, 1), ll = iLow(_Symbol, tf, 1);
   double rng = hh - ll; if(rng <= 0) return(false);
   return(MathAbs(c - o) / rng >= minPct);
  }

double ATRof(const int h)
  {
   double a[]; ArraySetAsSeries(a, true);
   if(CopyBuffer(hATRh[h], 0, 0, 2, a) < 2) return(0.0);
   return(a[1]);
  }

//+------------------------------------------------------------------+
//| Dispatcher                                                       |
//+------------------------------------------------------------------+
void TryHorizon(const int h)
  {
   double atrVal = ATRof(h); if(atrVal <= 0) return;
   if(h != 5 && !InSessionForSymbol()) return;              // [D] (shock ignores sessions)
   switch(h)
     {
      case 0: EntryScalp(h, atrVal);    break;
      case 1: EntryShort(h, atrVal);    break;
      case 2: EntryIntraday(h, atrVal); break;
      case 3: EntrySwing(h, atrVal);    break;
      case 4: EntryPosition(h, atrVal); break;
      case 5: EntryShock(h, atrVal);    break;
      case 6: EntryCouncil(h, atrVal);  break;
      case 7: EntryRevert(h, atrVal);   break;
     }
  }

void EntryScalp(const int h, const double atrVal)
  {
   double c1 = iClose(_Symbol, hTF[h], 1), c4 = iClose(_Symbol, hTF[h], 4);
   if(c1 <= 0 || c4 <= 0) return;
   double thrust = (c1 - c4) / atrVal;
   if(thrust >=  InpH0_BurstATR) DoOpen(h, ORDER_TYPE_BUY,  atrVal, 0);
   if(thrust <= -InpH0_BurstATR) DoOpen(h, ORDER_TYPE_SELL, atrVal, 0);
  }

void EntryShort(const int h, const double atrVal)
  {
   int n = hStudy[h]; if(Bars(_Symbol, hTF[h]) < n + 3) return;
   int hi = iHighest(_Symbol, hTF[h], MODE_HIGH, n, 2), lo = iLowest(_Symbol, hTF[h], MODE_LOW, n, 2);
   if(hi < 0 || lo < 0) return;
   double H = iHigh(_Symbol, hTF[h], hi), L = iLow(_Symbol, hTF[h], lo), c1 = iClose(_Symbol, hTF[h], 1);
   if(H <= 0 || L <= 0 || c1 <= 0) return;
   if(InpUseBodyConfirm && !BodyConfirms(hTF[h], InpMinBodyPct)) return;
   if(c1 > H) DoOpen(h, ORDER_TYPE_BUY,  atrVal, 0);
   if(c1 < L) DoOpen(h, ORDER_TYPE_SELL, atrVal, 0);
  }

void UpdateSessionRange()
  {
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   if(dt.hour < InpH2_RangeStartHr || dt.hour >= InpH2_RangeEndHr) return;
   double hv = iHigh(_Symbol, PERIOD_H1, 1), lv = iLow(_Symbol, PERIOD_H1, 1);
   if(hv <= 0 || lv <= 0) return;
   if(!gRangeInit) { gRangeHigh = hv; gRangeLow = lv; gRangeInit = true; }
   else { if(hv > gRangeHigh) gRangeHigh = hv; if(lv < gRangeLow) gRangeLow = lv; }
  }
void EntryIntraday(const int h, const double atrVal)
  {
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   if(dt.hour < InpH2_RangeEndHr || dt.hour >= InpH2_TradeEndHr) return;
   if(InpSkipFirstHour && dt.hour == InpH2_RangeEndHr) return;         // [E]
   if(!gRangeInit || gRangeHigh <= gRangeLow) return;
   if(InpH2_MinRangeATR > 0.0 && (gRangeHigh - gRangeLow) < InpH2_MinRangeATR * atrVal) return;
   double c1 = iClose(_Symbol, PERIOD_H1, 1); if(c1 <= 0) return;
   if(InpUseBodyConfirm && !BodyConfirms(PERIOD_H1, InpMinBodyPct)) return;   // [G]
   if(!gBought && c1 > gRangeHigh) { if(DoOpen(h, ORDER_TYPE_BUY,  atrVal, 0)) gBought = true; }
   else if(!gSold && c1 < gRangeLow) { if(DoOpen(h, ORDER_TYPE_SELL, atrVal, 0)) gSold = true; }
  }

void EntrySwing(const int h, const double atrVal)
  {
   double ema[], rsi[]; ArraySetAsSeries(ema, true); ArraySetAsSeries(rsi, true);
   if(CopyBuffer(gEMA_H4, 0, 0, 3, ema) < 3) return;
   if(CopyBuffer(gRSI_H4, 0, 0, 3, rsi) < 3) return;
   double c1 = iClose(_Symbol, PERIOD_H4, 1); if(c1 <= 0) return;
   bool up = (c1 > ema[1]), dn = (c1 < ema[1]);
   bool buy  = up && (rsi[2] < InpH3_PullbackRSI) && (rsi[1] > rsi[2]);
   bool sell = dn && (rsi[2] > 100.0 - InpH3_PullbackRSI) && (rsi[1] < rsi[2]);
   if(buy)  DoOpen(h, ORDER_TYPE_BUY,  atrVal, 0);
   if(sell) DoOpen(h, ORDER_TYPE_SELL, atrVal, 0);
  }

void EntryPosition(const int h, const double atrVal)
  {
   int n = InpH4_BreakBars; if(Bars(_Symbol, PERIOD_D1) < n + 3) return;
   int hi = iHighest(_Symbol, PERIOD_D1, MODE_HIGH, n, 2), lo = iLowest(_Symbol, PERIOD_D1, MODE_LOW, n, 2);
   if(hi < 0 || lo < 0) return;
   double H = iHigh(_Symbol, PERIOD_D1, hi), L = iLow(_Symbol, PERIOD_D1, lo), c1 = iClose(_Symbol, PERIOD_D1, 1);
   if(H <= 0 || L <= 0 || c1 <= 0) return;
   if(c1 > H) DoOpen(h, ORDER_TYPE_BUY,  atrVal, 0);
   if(c1 < L) DoOpen(h, ORDER_TYPE_SELL, atrVal, 0);
  }

//+------------------------------------------------------------------+
//| H7 REVERT - mean reversion (ex SmartRevert v4, same signal):     |
//|  BUY : H1 close below lower Bollinger + RSI oversold             |
//|  SELL: H1 close above upper Bollinger + RSI overbought           |
//|  TP = middle band, SL = x ATR, no trade when ADX(H1) is strong   |
//|  Now inside SmartMulti: council bias/news/mode, Profit Guard,    |
//|  portfolio caps, memory and regime weights all apply.            |
//+------------------------------------------------------------------+
void EntryRevert(const int h, const double atrVal)
  {
   double up[], lo[], mid[], rsi[], adx[];
   ArraySetAsSeries(up, true); ArraySetAsSeries(lo, true); ArraySetAsSeries(mid, true);
   ArraySetAsSeries(rsi, true); ArraySetAsSeries(adx, true);
   if(CopyBuffer(gBB_H7, BASE_LINE,  0, 2, mid) < 2) return;
   if(CopyBuffer(gBB_H7, UPPER_BAND, 0, 2, up)  < 2) return;
   if(CopyBuffer(gBB_H7, LOWER_BAND, 0, 2, lo)  < 2) return;
   if(CopyBuffer(gRSI_H7, 0, 0, 2, rsi) < 2) return;
   if(CopyBuffer(gADX_H7, 0, 0, 2, adx) < 2) return;
   double c1 = iClose(_Symbol, PERIOD_H1, 1); if(c1 <= 0) return;
   if(adx[1] >= InpH7_ADXMax) return;                                   // strong trend: do not fade
   if(gRegime == 1) return;                                             // SmartMulti regime says TREND: do not fade
   bool buy  = (c1 < lo[1]) && (rsi[1] < InpH7_RSIOversold);
   bool sell = (c1 > up[1]) && (rsi[1] > InpH7_RSIOverbought);
   if(!buy && !sell) return;
   int dir = buy ? 1 : -1;
   // council: never fade a real bias (tighter than the global block)
   if(gBrainOK && SymbolBias() * dir <= -InpH7_BrainBiasBlock)
     { Print("REVERT ", _Symbol, ": skipped - against council bias ", DoubleToString(SymbolBias(), 2)); return; }
   double price = buy ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double minDist = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double tpDist = (mid[1] - price) * dir;
   if(tpDist < MathMax(InpH7_MinTP_ATR * atrVal, minDist)) { Print("REVERT ", _Symbol, ": middle band too close - skipped"); return; }
   gTPOverride = mid[1];
   DoOpen(h, buy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, atrVal, 0);
   gTPOverride = 0.0;
  }

//+------------------------------------------------------------------+
//| H5 SHOCK ENGINE                                                  |
//| Detects the footprint of a sudden event on the fast TF:          |
//|  - a candle whose range >= K x normal ATR                        |
//|  - decisive body (not a spike-and-return wick)                   |
//|  - optional volume surge                                         |
//| Trades in the direction of the shock, only within N bars after,  |
//| with SL sized off the shock candle itself and a hard time stop.  |
//+------------------------------------------------------------------+
void EntryShock(const int h, const double atrVal)
  {
   ENUM_TIMEFRAMES tf = hTF[h];
   if(gLastShockTrade > 0 && TimeCurrent() - gLastShockTrade < (datetime)(InpH5_CooldownMin * 60)) return;

   // brain assist: if the council flagged a shock on this symbol, relax detection and lock direction
   int brainDir = 0;
   double atrX = InpH5_ShockATRx;
   if(InpBrainShockAssist && BrainShockDir(brainDir))
      atrX = InpH5_ShockATRx * InpBrainShockATRx;
   if(!gH5SymbolOK && brainDir == 0) return;

   // scan the last few closed bars for a shock candle
   int found = -1;
   for(int i = 1; i <= InpH5_MaxLateBars; i++)
     {
      double hh = iHigh(_Symbol, tf, i), ll = iLow(_Symbol, tf, i);
      double o  = iOpen(_Symbol, tf, i), c  = iClose(_Symbol, tf, i);
      if(hh <= 0 || ll <= 0) return;
      double rng = hh - ll; if(rng <= 0) continue;
      if(rng < atrX * atrVal) continue;                 // not big enough
      if(MathAbs(c - o) / rng < InpH5_MinBodyPct) continue;        // spike-and-return, skip
      if(InpH5_ShockVolx > 0.0)
        {
         long v = iVolume(_Symbol, tf, i);
         long sum = 0; int cnt = 0;
         for(int k = i + 1; k <= i + 30; k++) { sum += iVolume(_Symbol, tf, k); cnt++; }
         double avg = (cnt > 0) ? (double)sum / cnt : 0.0;
         if(avg > 0 && v < InpH5_ShockVolx * avg) continue;      // no volume surge
        }
      found = i; break;
     }
   if(found < 0) return;

   double o = iOpen(_Symbol, tf, found), c = iClose(_Symbol, tf, found);
   double shockRange = iHigh(_Symbol, tf, found) - iLow(_Symbol, tf, found);
   ENUM_ORDER_TYPE dir = (c > o) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;

   // must not have already reversed most of the shock
   double now = iClose(_Symbol, tf, 1);
   double progress = (dir == ORDER_TYPE_BUY) ? (now - o) : (o - now);
   if(progress < 0.5 * shockRange) return;                        // gave back too much

   // spread during shocks is wide; allow up to N x normal but not insane
   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(spread > InpMaxSpreadPoints * InpH5_MaxSpreadMult) return;

   Print("SHOCK detected on ", _Symbol, " ", EnumToString(tf), ": range=", DoubleToString(shockRange / atrVal, 1),
         "x ATR, dir=", (dir == ORDER_TYPE_BUY ? "UP" : "DOWN"), (brainDir != 0 ? " [council-confirmed]" : ""));
   if(DoOpen(h, dir, shockRange, spread))    // SL sized off the shock candle
      gLastShockTrade = TimeCurrent();
  }

//+------------------------------------------------------------------+
//| Shared order placement                                           |
//+------------------------------------------------------------------+
//| H6 COUNCIL - trades the brain's directional view, price-confirmed |
//|  - brain fresh, conf >= MinConf, |symbol bias| >= MinBias         |
//|  - last H1 candle closed in the bias direction and on the right   |
//|    side of EMA(H1)                                                |
//|  - max N open council trades overall, pause after K losses        |
//+------------------------------------------------------------------+
void EntryCouncil(const int h, const double atrVal)
  {
   if(!gBrainOK) return;
   if(gBrainConf < InpH6_MinConf) return;
   double sb = SymbolBias();
   if(MathAbs(sb) < InpH6_MinBias) return;
   int dir = (sb > 0) ? 1 : -1;

   // portfolio cap for council trades (all symbols)
   int open = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i); if(t == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) == hMagic[6]) open++;
     }
   if(open >= InpH6_MaxOpen) return;

   // consecutive-loss pause for this symbol
   if(CouncilLossStreak() >= InpH6_PauseAfterLoss && hPausedUntil[6] < TimeCurrent())
     {
      hPausedUntil[6] = TimeCurrent() + (datetime)(InpH6_PauseHours * 3600);
      Print("COUNCIL ", _Symbol, ": ", InpH6_PauseAfterLoss, " losses in a row - paused ", InpH6_PauseHours, "h");
      return;
     }
   if(hPausedUntil[6] > TimeCurrent()) return;

   // price confirmation on H1
   double ema[]; ArraySetAsSeries(ema, true);
   if(CopyBuffer(gEMA_H1, 0, 0, 3, ema) < 3) return;
   double o1 = iOpen(_Symbol, PERIOD_H1, 1), c1 = iClose(_Symbol, PERIOD_H1, 1);
   if(o1 <= 0 || c1 <= 0) return;
   bool candleOK = (dir > 0) ? (c1 > o1) : (c1 < o1);
   bool sideOK   = (dir > 0) ? (c1 > ema[1]) : (c1 < ema[1]);
   if(!candleOK || !sideOK) return;
   if(InpUseBodyConfirm && !BodyConfirms(PERIOD_H1, InpMinBodyPct * 0.6)) return;   // mild decisiveness

   Print("COUNCIL signal on ", _Symbol, ": bias=", DoubleToString(sb, 2), " conf=", DoubleToString(gBrainConf, 2),
         " dir=", (dir > 0 ? "BUY" : "SELL"), " | ", gBrainSummary);
   DoOpen(h, (dir > 0) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, atrVal, 0);
  }
int CouncilLossStreak()
  {
   if(!HistorySelect(TimeCurrent() - 30 * 86400, TimeCurrent())) return(0);
   int streak = 0;
   for(int d = HistoryDealsTotal() - 1; d >= 0; d--)
     {
      ulong t = HistoryDealGetTicket(d); if(t == 0) continue;
      if(HistoryDealGetString(t, DEAL_SYMBOL) != _Symbol) continue;
      if(HistoryDealGetInteger(t, DEAL_MAGIC) != hMagic[6]) continue;
      if(HistoryDealGetInteger(t, DEAL_ENTRY) != DEAL_ENTRY_OUT) continue;
      double p = HistoryDealGetDouble(t, DEAL_PROFIT) + HistoryDealGetDouble(t, DEAL_SWAP) + HistoryDealGetDouble(t, DEAL_COMMISSION);
      if(p < 0) streak++; else break;
     }
   return(streak);
  }

//+------------------------------------------------------------------+
bool DoOpen(const int h, const ENUM_ORDER_TYPE type, const double atrOrRange, const long spreadOverride)
  {
   if(CurrencyGuardBlocks(type))         return(false);
   if(CorrelationGuardBlocks(type))      return(false);   // [I]
   if(!DailyTrendAllows(type, h))        return(false);
   if(!ContextAllows(h, type, atrOrRange)) return(false);
   double brainMult = 1.0;
   if(gBrainOK)
     {
      int dsg = (type == ORDER_TYPE_BUY) ? 1 : -1;
      string why = "";
      if(!BrainAllowsTrade(h, dsg, brainMult, why))
        {
         Print("BRAIN blocks ", hName[h], " ", (dsg > 0 ? "BUY" : "SELL"), " on ", _Symbol, ": ", why);
         if(InpBrainEnforce) return(false);
         brainMult = 1.0;
        }
     }

   double point  = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double ask    = SymbolInfoDouble(_Symbol, SYMBOL_ASK), bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(ask <= 0 || bid <= 0) return(false);
   long   stopsLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minDist = stopsLevel * point;

   double slDist = hSL_ATR[h] * atrOrRange; if(slDist < minDist) slDist = minDist;
   double tpDist = hTP_R[h] * slDist;       if(tpDist < minDist) tpDist = minDist;
   if(gTPOverride > 0.0)                     // REVERT: target = Bollinger middle band (absolute price)
     {
      double d = (gTPOverride - (type == ORDER_TYPE_BUY ? ask : bid)) * (type == ORDER_TYPE_BUY ? 1 : -1);
      if(d >= minDist) tpDist = d;
     }

   long spread = (spreadOverride > 0) ? spreadOverride : SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(h != 5 && spread > InpMaxSpreadPoints) return(false);
   if(InpMinTPtoCost > 0.0)
     {
      double tpPts = tpDist / point, costPts = (double)spread + InpCommissionPts;
      if(costPts > 0.0 && tpPts < costPts * InpMinTPtoCost)
        { Print(hName[h], ": target ", DoubleToString(tpPts, 0), "pts vs cost ", DoubleToString(costPts, 0), "pts - skipped"); return(false); }
     }

   // ---- adaptive risk: base x volatility x regime x memory x protect ----
   double risk = hRisk[h];
   risk *= VolFactor(h);                     // [A]
   risk *= hRegimeW[h];                      // [B]
   double mem = MemoryFactor(h);             // [C]
   if(mem <= 0.0) return(false);
   risk *= mem;
   if(gProtectMode) risk *= 0.5;             // [L]
   risk *= brainMult;                        // brain: mode x bias alignment

   double price, sl, tp;
   if(type == ORDER_TYPE_BUY) { price = ask; sl = NormalizeDouble(price - slDist, digits); tp = NormalizeDouble(price + tpDist, digits); }
   else                       { price = bid; sl = NormalizeDouble(price + slDist, digits); tp = NormalizeDouble(price - tpDist, digits); }

   double lot = CalcLot(slDist, risk); if(lot <= 0) return(false);

   trade.SetExpertMagicNumber(hMagic[h]);
   bool ok = trade.PositionOpen(_Symbol, type, lot, price, sl, tp, hName[h]);
   if(ok)
     {
      hTradesToday[h]++;
      // [F] slippage check on the actual fill
      double fill = trade.ResultPrice();
      double slip = (fill > 0) ? MathAbs(fill - price) / point : 0.0;
      string msg = hName[h] + " " + _Symbol + " " + (type == ORDER_TYPE_BUY ? "BUY" : "SELL") +
                   " lot=" + DoubleToString(lot, 2) + " risk=" + DoubleToString(risk, 2) + "%" +
                   " SL=" + DoubleToString(sl, digits) + " TP=" + DoubleToString(tp, digits) +
                   " regime=" + RegimeName(gRegime) + (gBrainOK ? " brain=" + BrainModeName() : " brain=off") + " slip=" + DoubleToString(slip, 0) + "pts";
      Print(msg); Notify(msg);                // [J]
      if(slip > InpMaxSlippagePts) Print("WARNING: slippage ", DoubleToString(slip, 0), "pts exceeded limit");
     }
   else Print(hName[h], " order failed: ", trade.ResultRetcodeDescription());
   return(ok);
  }

//+------------------------------------------------------------------+
double CalcLot(const double slDistance, const double riskPct)
  {
   double balance = AccountInfoDouble(ACCOUNT_BALANCE), riskMoney = balance * riskPct / 100.0;
   double tv = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE), ts = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tv <= 0 || ts <= 0) return(0);
   double lossPerLot = slDistance / ts * tv; if(lossPerLot <= 0) return(0);
   double lot = riskMoney / lossPerLot;
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN), maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP); if(step <= 0) step = 0.01;
   lot = MathFloor(lot / step) * step;
   if(lot < minLot)
     {
      // min lot would risk far more than intended (e.g. silver/indices with a wide ATR stop) -> skip the trade
      if(minLot * lossPerLot > riskMoney * InpMinLotRiskCap) { Print("SKIP ", _Symbol, ": min lot risks ", DoubleToString(minLot * lossPerLot, 2), "$ > ", DoubleToString(riskMoney * InpMinLotRiskCap, 2), "$ cap"); return(0); }
      lot = minLot;
     }
   if(lot > maxLot) lot = maxLot; if(lot > InpMaxLot) lot = InpMaxLot;
   int d = (step >= 1.0) ? 0 : (int)MathCeil(-MathLog10(step));
   return(NormalizeDouble(lot, d));
  }

//+------------------------------------------------------------------+
//| Every-tick protection                                            |
//+------------------------------------------------------------------+
void ManageOpenTrades()
  {
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double minDist = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * point;
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i); if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      long m = PositionGetInteger(POSITION_MAGIC);
      if(m < InpMagicBase || m >= InpMagicBase + NH) continue;
      int h = (int)(m - InpMagicBase);

      int dir = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 1 : -1;
      double entry = PositionGetDouble(POSITION_PRICE_OPEN), curSL = PositionGetDouble(POSITION_SL), curTP = PositionGetDouble(POSITION_TP);
      double last = (dir > 0) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      if(last <= 0) continue;
      double gain = (last - entry) * dir;
      double atrVal = ATRof(h);
      double risk = (curSL > 0) ? MathAbs(entry - curSL) : ((atrVal > 0) ? hSL_ATR[h] * atrVal : 0.0);
      // for shock trades the SL was set off the shock candle; use current SL distance as 1R
      double tpD = (curTP > 0) ? MathAbs(curTP - entry) : 0.0;
      double donePct = (tpD > 0) ? gain / tpD : 0.0;

      // H2 session flat-out
      if(h == 2 && dt.hour >= InpH2_CloseHr)
        {
         if(gain > 0.0 && atrVal > 0)
           {
            double be = NormalizeDouble(entry + dir * InpBreakEvenBufATR * atrVal, digits);
            bool better = (dir > 0) ? (be > curSL) : (be < curSL || curSL == 0);
            if(better && MathAbs(last - be) > minDist) { trade.PositionModify(ticket, be, curTP); continue; }
           }
         trade.PositionClose(ticket); continue;
        }

      // holding-time exit
      if(hHold[h] > 0)
        {
         datetime opened = (datetime)PositionGetInteger(POSITION_TIME);
         if(TimeCurrent() - opened >= (datetime)(PeriodSeconds(hTF[h]) * hHold[h]))
           {
            if(h == 5) { trade.PositionClose(ticket); continue; }   // shock: hard time stop, no exceptions
            if(gain > 0.0 && atrVal > 0)
              {
               double be = NormalizeDouble(entry + dir * InpBreakEvenBufATR * atrVal, digits);
               bool better = (dir > 0) ? (be > curSL) : (be < curSL || curSL == 0);
               if(better && MathAbs(last - be) > minDist) { trade.PositionModify(ticket, be, curTP); continue; }
              }
            else { trade.PositionClose(ticket); continue; }
           }
        }

      // COUNCIL: if the council flipped against the trade, exit at market
      if(h == 6 && gBrainOK)
        {
         double sbNow = SymbolBias();
         if(sbNow * dir <= -InpBrainBiasBlock || gBrainMode == 3)
           { Print("COUNCIL exit ", _Symbol, ": council view flipped/halt"); trade.PositionClose(ticket); continue; }
        }

      if(risk <= 0) continue;

      if(InpBreakEvenR > 0.0 && gain >= InpBreakEvenR * risk)
        {
         double be = NormalizeDouble(entry + dir * InpBreakEvenBufATR * (atrVal > 0 ? atrVal : risk * 0.1), digits);
         bool better = (dir > 0) ? (be > curSL) : (be < curSL || curSL == 0);
         if(better && MathAbs(last - be) > minDist) if(trade.PositionModify(ticket, be, curTP)) curSL = be;
        }
      if(InpPartialAtPct > 0.0 && donePct >= InpPartialAtPct)
        {
         double vol = PositionGetDouble(POSITION_VOLUME), step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP), vmin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
         if(step <= 0) step = 0.01;
         double cut = MathFloor((vol * InpPartialClosePct) / step) * step;
         if(cut >= vmin && (vol - cut) >= vmin) trade.PositionClosePartial(ticket, cut);
        }
      if(InpLockAtPct > 0.0 && donePct >= InpLockAtPct)
        {
         double lockp = NormalizeDouble(entry + dir * gain * InpLockKeepPct, digits);
         bool better = (dir > 0) ? (lockp > curSL) : (lockp < curSL || curSL == 0);
         if(better && MathAbs(last - lockp) > minDist) if(trade.PositionModify(ticket, lockp, curTP)) curSL = lockp;
        }
      if(InpTrailATR > 0.0 && atrVal > 0 && gain >= InpBreakEvenR * risk)
        {
         double tr = NormalizeDouble(last - dir * InpTrailATR * atrVal, digits);
         bool better = (dir > 0) ? (tr > curSL) : (tr < curSL || curSL == 0);
         if(better && MathAbs(last - tr) > minDist) trade.PositionModify(ticket, tr, curTP);
        }
     }
  }

//+------------------------------------------------------------------+
//| [J] notifications, [K] reports, logs                             |
//+------------------------------------------------------------------+
void Notify(const string msg)
  {
   if(!InpPushNotify) return;
   if(MQLInfoInteger(MQL_TESTER) || MQLInfoInteger(MQL_OPTIMIZATION)) return;
   SendNotification("SmartMulti " + msg);
  }

void BookStats(const datetime from, double &net[], int &cnt[], int &win[])
  {
   for(int i = 0; i < NH; i++) { net[i] = 0; cnt[i] = 0; win[i] = 0; }
   if(!HistorySelect(from, TimeCurrent())) return;
   int deals = HistoryDealsTotal();
   for(int d = 0; d < deals; d++)
     {
      ulong t = HistoryDealGetTicket(d); if(t == 0) continue;
      if(HistoryDealGetString(t, DEAL_SYMBOL) != _Symbol) continue;
      if(HistoryDealGetInteger(t, DEAL_ENTRY) != DEAL_ENTRY_OUT) continue;
      long m = HistoryDealGetInteger(t, DEAL_MAGIC);
      if(m < InpMagicBase || m >= InpMagicBase + NH) continue;
      int h = (int)(m - InpMagicBase);
      double p = HistoryDealGetDouble(t, DEAL_PROFIT) + HistoryDealGetDouble(t, DEAL_SWAP) + HistoryDealGetDouble(t, DEAL_COMMISSION);
      net[h] += p; cnt[h]++; if(p >= 0) win[h]++;
     }
  }

void DailySummary()
  {
   double net[NH]; int cnt[NH], win[NH];
   BookStats(gCurrentDay, net, cnt, win);
   for(int i = 0; i < NH; i++)
      if(cnt[i] > 0)
         Print("DAILY [", _Symbol, " ", hName[i], "]: trades=", cnt[i], " wins=", win[i], " net=", DoubleToString(net[i], 2));
  }

void WeeklyReport()
  {
   double net[NH]; int cnt[NH], win[NH];
   BookStats(gCurrentWeek, net, cnt, win);
   string fn = "SmartMulti_report_" + _Symbol + ".txt";
   int fh = FileOpen(fn, FILE_WRITE | FILE_READ | FILE_TXT | FILE_ANSI);
   if(fh == INVALID_HANDLE) return;
   FileSeek(fh, 0, SEEK_END);
   FileWrite(fh, "=== WEEK of ", TimeToString(gCurrentWeek, TIME_DATE), " | ", _Symbol, " ===");
   double total = 0;
   for(int i = 0; i < NH; i++)
     {
      if(cnt[i] == 0) continue;
      total += net[i];
      FileWrite(fh, hName[i], ": trades=", cnt[i], " wins=", win[i],
                " winrate=", DoubleToString(100.0 * win[i] / cnt[i], 0), "% net=", DoubleToString(net[i], 2));
     }
   FileWrite(fh, "TOTAL net=", DoubleToString(total, 2), " | equity=", DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2),
             " | regime now=", RegimeName(gRegime), " | protect=", (gProtectMode ? "ON" : "off"));
   FileWrite(fh, "");
   FileClose(fh);
   Notify("Weekly report written: " + fn + " total=" + DoubleToString(total, 2));
  }

void StatusLog()
  {
   string s = "Status " + _Symbol + ": regime=" + RegimeName(gRegime) +
              " openRisk=" + DoubleToString(OpenRiskPct(), 2) + "% pos=" + (string)CountMyPositions() +
              "/" + (string)InpMaxTotalPositions + " spread=" + (string)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) +
              (gProtectMode ? " PROTECT" : "") +
              (gBrainOK ? " brain=" + BrainModeName() + " x" + DoubleToString(gBrainRiskMult, 2) + " bias(" + _Symbol + ")=" + DoubleToString(SymbolBias(), 2) : " brain=OFF");
   for(int i = 0; i < NH; i++)
      if(hOn[i]) s += " | " + hName[i] + "=" + (string)hTradesToday[i] + "/" + (string)hMaxDay[i] +
                      (hPausedUntil[i] > TimeCurrent() ? "(paused)" : "");
   Print(s);
  }
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| BRAIN - council of experts (brain.txt from URL)                   |
//| key=value lines. Fail-safe: stale/missing -> gBrainOK=false.      |
//+------------------------------------------------------------------+
void BrainRefresh(const bool force)
  {
   if(!InpBrainEnabled || InpBrainURL == "" || StringFind(InpBrainURL, "USERNAME") >= 0) { gBrainOK = false; return; }
   if(MQLInfoInteger(MQL_TESTER) || MQLInfoInteger(MQL_OPTIMIZATION)) { gBrainOK = false; return; }
   datetime nowLocal = TimeLocal();
   if(!force && gBrainLastTry > 0 && nowLocal - gBrainLastTry < (datetime)(InpBrainRefreshMin * 60)) { BrainCheckAge(); return; }
   gBrainLastTry = nowLocal;

   char data[], result[]; string rh;
   ResetLastError();
   int code = WebRequest("GET", InpBrainURL, "", 5000, data, result, rh);
   if(code != 200)
     {
      Print("BRAIN: fetch failed code=", code, " err=", GetLastError(), " (add the URL in Tools>Options>Expert Advisors>WebRequest)");
      BrainCheckAge();
      return;
     }
   string body = CharArrayToString(result, 0, -1, CP_UTF8);
   string lines[]; int n = StringSplit(body, '\n', lines);
   ArrayResize(gBrainKeys, 0); ArrayResize(gBrainVals, 0);
   for(int i = 0; i < n; i++)
     {
      string ln = lines[i]; StringTrimLeft(ln); StringTrimRight(ln);
      int p = StringFind(ln, "=");
      if(p <= 0) continue;
      string k = StringSubstr(ln, 0, p), v = StringSubstr(ln, p + 1);
      StringTrimLeft(k); StringTrimRight(k); StringTrimLeft(v); StringTrimRight(v);
      int m = ArraySize(gBrainKeys); ArrayResize(gBrainKeys, m + 1); ArrayResize(gBrainVals, m + 1);
      gBrainKeys[m] = k; gBrainVals[m] = v;
     }
   string oldSummary = gBrainSummary; int oldMode = gBrainMode;
   gBrainTs       = (datetime)StringToInteger(BrainGet("ts", "0"));
   string mode    = BrainGet("risk_mode", "normal");
   gBrainMode     = (mode == "halt") ? 3 : (mode == "danger") ? 2 : (mode == "caution") ? 1 : 0;
   gBrainRiskMult = StringToDouble(BrainGet("risk_mult", "1.0"));
   if(gBrainRiskMult < 0.25) gBrainRiskMult = 0.25; if(gBrainRiskMult > 1.25) gBrainRiskMult = 1.25;
   gBrainConf     = StringToDouble(BrainGet("conf", "0"));
   gBrainSummary  = BrainGet("summary", "");
   BrainCheckAge();
   if(gBrainOK && (gBrainSummary != oldSummary || gBrainMode != oldMode))
     {
      string msg = "BRAIN " + BrainModeName() + " x" + DoubleToString(gBrainRiskMult, 2) + " conf=" + DoubleToString(gBrainConf, 2) + " | " + gBrainSummary;
      Print(msg);
      if(gBrainMode >= 2 || oldMode >= 2) Notify(msg);
     }
  }
void BrainCheckAge()
  {
   if(gBrainTs <= 0) { gBrainOK = false; return; }
   long age = (long)(TimeGMT() - gBrainTs);
   bool ok = (age <= (long)InpBrainMaxAgeMin * 60);
   if(gBrainOK && !ok) Print("BRAIN: stale (", age / 60, " min) - ignored, robots on own logic");
   gBrainOK = ok;
  }
string BrainGet(const string key, const string def)
  {
   for(int i = 0; i < ArraySize(gBrainKeys); i++) if(gBrainKeys[i] == key) return(gBrainVals[i]);
   return(def);
  }
string BrainModeName() { return(gBrainMode == 3 ? "HALT" : gBrainMode == 2 ? "DANGER" : gBrainMode == 1 ? "CAUTION" : "NORMAL"); }
double BrainBias(const string cur) { return(StringToDouble(BrainGet("bias_" + cur, "0"))); }

// bias of THIS symbol in [-1,1]: metals/oil/indices direct; FX = (base - quote)/2
double SymbolBias() { return(SymbolBiasOf(_Symbol)); }
double SymbolBiasOf(const string sym)
  {
   string u = sym; StringToUpper(u);
   if(StringFind(u, "XAU") >= 0 || StringFind(u, "GOLD") >= 0) return(BrainBias("XAU"));
   if(StringFind(u, "XAG") >= 0) return(BrainBias("XAG"));
   if(StringFind(u, "OIL") >= 0 || StringFind(u, "BRENT") >= 0 || StringFind(u, "WTI") >= 0) return(BrainBias("OIL"));
   if(StringFind(u, "US500") >= 0 || StringFind(u, "SPX") >= 0) return(BrainBias("US500"));
   if(StringFind(u, "US100") >= 0 || StringFind(u, "NAS") >= 0) return(BrainBias("US100"));
   if(StringFind(u, "US30") >= 0 || StringFind(u, "DJ30") >= 0) return(BrainBias("US30"));
   if(StringFind(u, "GER40") >= 0 || StringFind(u, "DAX") >= 0) return(BrainBias("GER40"));
   string b = SymbolInfoString(sym, SYMBOL_CURRENCY_BASE), q = SymbolInfoString(sym, SYMBOL_CURRENCY_PROFIT);
   if(b == "" || q == "") return(0.0);
   return((BrainBias(b) - BrainBias(q)) / 2.0);
  }
bool BrainAllowsBook(const int h)
  {
   string ab = BrainGet("allow_books", "ALL"); StringToUpper(ab);
   if(ab == "ALL" || ab == "") return(true);
   return(StringFind("," + ab + ",", "," + hName[h] + ",") >= 0);
  }
bool BrainListHas(const string csv, const string item)
  {
   if(csv == "" || csv == "none") return(false);
   string u = csv; StringToUpper(u); string it = item; StringToUpper(it);
   return(StringFind("," + u + ",", "," + it + ",") >= 0);
  }
// news_block=USD:20:45;EUR:110:135  (minutes relative to brain ts)
bool BrainNewsBlocks()
  {
   string nb = BrainGet("news_block", "none"); if(nb == "none" || nb == "") return(false);
   string b = SymbolInfoString(_Symbol, SYMBOL_CURRENCY_BASE), q = SymbolInfoString(_Symbol, SYMBOL_CURRENCY_PROFIT);
   string parts[]; int n = StringSplit(nb, ';', parts);
   datetime now = TimeGMT();
   for(int i = 0; i < n; i++)
     {
      string f[]; if(StringSplit(parts[i], ':', f) < 3) continue;
      string cur = f[0]; StringToUpper(cur);
      if(cur != b && cur != q && !(cur == "USD" && IsMetalOilIndex(_Symbol))) continue;
      datetime st = gBrainTs + (datetime)(StringToInteger(f[1]) * 60), en = gBrainTs + (datetime)(StringToInteger(f[2]) * 60);
      if(now >= st && now <= en) return(true);
     }
   return(false);
  }
// shock=XAUUSD:1:60:reason;USOIL:-1:45:reason
bool BrainShockDir(int &dir)
  {
   dir = 0;
   if(!gBrainOK) return(false);
   string sh = BrainGet("shock", "none"); if(sh == "none" || sh == "") return(false);
   string parts[]; int n = StringSplit(sh, ';', parts);
   string me = _Symbol; StringToUpper(me);
   for(int i = 0; i < n; i++)
     {
      string f[]; if(StringSplit(parts[i], ':', f) < 3) continue;
      string sym = f[0]; StringToUpper(sym);
      if(StringFind(me, sym) < 0 && StringFind(sym, me) < 0) continue;
      datetime until = gBrainTs + (datetime)(StringToInteger(f[2]) * 60);
      if(TimeGMT() > until) continue;
      dir = (StringToInteger(f[1]) >= 0) ? 1 : -1;
      return(true);
     }
   return(false);
  }
bool BrainShockActive() { int d; return(BrainShockDir(d)); }

// final decision for a trade: returns false with reason, or true with a risk multiplier
bool BrainAllowsTrade(const int h, const int dir, double &mult, string &why)
  {
   mult = 1.0;
   if(!gBrainOK) return(true);
   if(gBrainMode == 3) { why = "HALT"; return(false); }
   if(BrainListHas(BrainGet("block_symbols", "none"), _Symbol)) { why = "symbol blocked by council"; return(false); }
   if(!gNewsEntry && BrainNewsBlocks()) { why = "news window (council)"; return(false); }
   if(gBrainMode == 2 && h != 5 && h != 3 && h != 6) { why = "DANGER: only SWING/SHOCK/COUNCIL allowed"; return(false); }
   double sb = SymbolBias() * dir;          // >0 aligned, <0 against
   if(sb <= -InpBrainBiasBlock) { why = "against council bias " + DoubleToString(SymbolBias(), 2); return(false); }
   if(h == 5 && sb <= -InpH5_BrainBiasBlock) { why = "SHOCK against council bias " + DoubleToString(SymbolBias(), 2); return(false); }
   mult = gBrainRiskMult;
   if(gBrainMode == 1) mult *= 0.75;
   if(gBrainMode == 2) mult *= 0.5;
   if(sb >= InpBrainBiasBoost) mult *= InpBrainBoostMult;
   if(BrainListHas(BrainGet("prefer_symbols", "none"), _Symbol)) mult *= 1.1;
   if(mult > 1.5) mult = 1.5;
   return(true);
  }
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| ACCOUNT REPORT -> GitHub (account.json) so the brain "hears" the  |
//| account: balance, equity, day P/L, open positions, today's books |
//+------------------------------------------------------------------+
string JsonEsc(string s) { StringReplace(s, "\\", "\\\\"); StringReplace(s, "\"", "\\\""); return(s); }
string BookNameOf(const long magic)
  {
   if(magic >= InpMagicBase && magic < InpMagicBase + NH) return(hName[(int)(magic - InpMagicBase)]);
   if(magic == 202609) return("REVERT");
   if(magic == 202660) return("BREAKOUT");
   return("other:" + (string)magic);
  }
string BuildAccountJson()
  {
   double bal = AccountInfoDouble(ACCOUNT_BALANCE), eq = AccountInfoDouble(ACCOUNT_EQUITY);
   string j = "{\"ts\":" + (string)(long)TimeGMT() + ",\"account\":" + (string)AccountInfoInteger(ACCOUNT_LOGIN) +
              ",\"balance\":" + DoubleToString(bal, 2) + ",\"equity\":" + DoubleToString(eq, 2) +
              ",\"day_pl\":" + DoubleToString(gDayStartEquity > 0 ? eq - gDayStartEquity : 0.0, 2) +
              ",\"week_pl\":" + DoubleToString(gWeekStartEquity > 0 ? eq - gWeekStartEquity : 0.0, 2) +
              ",\"brain_mode\":\"" + (gBrainOK ? BrainModeName() : "OFF") + "\",\"positions\":[";
   int n = 0;
   for(int i = 0; i < PositionsTotal(); i++)
     {
      ulong t = PositionGetTicket(i); if(t == 0) continue;
      if(n > 0) j += ",";
      j += "{\"symbol\":\"" + PositionGetString(POSITION_SYMBOL) + "\",\"type\":\"" +
           (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY ? "BUY" : "SELL") + "\",\"lots\":" +
           DoubleToString(PositionGetDouble(POSITION_VOLUME), 2) + ",\"pl\":" +
           DoubleToString(PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP), 2) +
           ",\"book\":\"" + BookNameOf(PositionGetInteger(POSITION_MAGIC)) + "\",\"opened\":" +
           (string)(long)PositionGetInteger(POSITION_TIME) + "}";
      n++;
     }
   j += "],\"books\":[";
   // today's closed trades per book (all symbols, all magics)
   string names[8] = {"SCALP","SHORT","INTRADAY","SWING","POSITION","SHOCK","COUNCIL","REVERT"};
   double net[9]; int cnt[9], win[9]; int streak[9];
   for(int b = 0; b < 9; b++) { net[b] = 0; cnt[b] = 0; win[b] = 0; streak[b] = 0; }
   if(HistorySelect(gCurrentDay, TimeCurrent()))
     {
      int deals = HistoryDealsTotal();
      for(int d = 0; d < deals; d++)
        {
         ulong t = HistoryDealGetTicket(d); if(t == 0) continue;
         if(HistoryDealGetInteger(t, DEAL_ENTRY) != DEAL_ENTRY_OUT) continue;
         string bn = BookNameOf(HistoryDealGetInteger(t, DEAL_MAGIC));
         int idx = 8;
         for(int b = 0; b < 8; b++) if(names[b] == bn) idx = b;
         if(bn == "BREAKOUT") idx = 2;
         double p = HistoryDealGetDouble(t, DEAL_PROFIT) + HistoryDealGetDouble(t, DEAL_SWAP) + HistoryDealGetDouble(t, DEAL_COMMISSION);
         net[idx] += p; cnt[idx]++; if(p >= 0) { win[idx]++; streak[idx] = 0; } else streak[idx]++;
        }
     }
   bool first = true;
   for(int b = 0; b < 9; b++)
     {
      if(cnt[b] == 0) continue;
      string nm = (b < 8) ? names[b] : "OTHER";
      if(!first) j += ","; first = false;
      j += "{\"name\":\"" + nm + "\",\"trades\":" + (string)cnt[b] + ",\"wins\":" + (string)win[b] +
           ",\"net\":" + DoubleToString(net[b], 2) + ",\"loss_streak\":" + (string)streak[b] + "}";
     }
   j += "],\"prices\":{";
   string syms[]; int ns = StringSplit(InpReportPriceSyms, ',', syms); bool firstp = true;
   for(int s = 0; s < ns; s++)
     {
      string sy = syms[s]; StringTrimLeft(sy); StringTrimRight(sy); if(sy == "") continue;
      double bid = SymbolInfoDouble(sy, SYMBOL_BID); if(bid <= 0) continue;
      if(!firstp) j += ","; firstp = false;
      j += "\"" + sy + "\":" + DoubleToString(bid, (int)SymbolInfoInteger(sy, SYMBOL_DIGITS));
     }
   j += "}}";
   return(j);
  }
// GitHub repository_dispatch (POST) -> a workflow writes account.json into the repo
void ReportAccount(const bool force)
  {
   if(!InpReportEnabled || InpReportToken == "" || InpReportRepo == "") return;
   if(MQLInfoInteger(MQL_TESTER)) return;
   if(!force && gLastReport > 0 && TimeLocal() - gLastReport < (datetime)(InpReportEveryMin * 60)) return;
   gLastReport = TimeLocal();

   string url = "https://api.github.com/repos/" + InpReportRepo + "/dispatches";
   string hdr = "Authorization: Bearer " + InpReportToken + "\r\nAccept: application/vnd.github+json\r\nUser-Agent: SmartMulti\r\nContent-Type: application/json\r\n";
   string payload = "{\"event_type\":\"account\",\"client_payload\":" + BuildAccountJson() + "}";
   char pdata[]; StringToCharArray(payload, pdata, 0, StringLen(payload), CP_UTF8);
   char pres[]; string prh;
   ResetLastError();
   int c2 = WebRequest("POST", url, hdr, 8000, pdata, pres, prh);
   if(c2 == 204 || c2 == 200) Print("REPORT: account report dispatched (", StringLen(payload), " bytes)");
   else Print("REPORT: dispatch failed code=", c2, " err=", GetLastError(), " (whitelist https://api.github.com in Tools>Options>Expert Advisors; token needs Contents: read/write)");
  }
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| TRADE JOURNAL -> GitHub ("trade" dispatch) : every closed deal on |
//| the account (all symbols, all robots) with entry/exit/reason and  |
//| the council's view at close time, so the brain can do post-mortems|
//+------------------------------------------------------------------+
string DealReasonName(const long r)
  {
   if(r == DEAL_REASON_SL) return("SL");
   if(r == DEAL_REASON_TP) return("TP");
   if(r == DEAL_REASON_SO) return("STOPOUT");
   if(r == DEAL_REASON_EXPERT) return("EA");
   if(r == DEAL_REASON_CLIENT || r == DEAL_REASON_MOBILE || r == DEAL_REASON_WEB) return("MANUAL");
   return("OTHER");
  }
void ReportTrade(const ulong dealTicket)
  {
   if(!InpReportEnabled || InpReportToken == "" || InpReportRepo == "") return;
   if(MQLInfoInteger(MQL_TESTER)) return;
   if(!HistoryDealSelect(dealTicket)) return;
   if(HistoryDealGetInteger(dealTicket, DEAL_ENTRY) != DEAL_ENTRY_OUT) return;
   long   posId  = HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID);
   string sym    = HistoryDealGetString(dealTicket, DEAL_SYMBOL);
   long   magic  = HistoryDealGetInteger(dealTicket, DEAL_MAGIC);
   double vol    = HistoryDealGetDouble(dealTicket, DEAL_VOLUME);
   double px_out = HistoryDealGetDouble(dealTicket, DEAL_PRICE);
   double pl     = HistoryDealGetDouble(dealTicket, DEAL_PROFIT) + HistoryDealGetDouble(dealTicket, DEAL_SWAP) + HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);
   long   reason = HistoryDealGetInteger(dealTicket, DEAL_REASON);
   datetime t_out = (datetime)HistoryDealGetInteger(dealTicket, DEAL_TIME);
   // entry deal of the same position
   double px_in = 0, sl = 0, tp = 0; datetime t_in = 0; string dir = "?";
   if(HistorySelectByPosition(posId))
     {
      for(int i = 0; i < HistoryDealsTotal(); i++)
        {
         ulong d = HistoryDealGetTicket(i);
         if(HistoryDealGetInteger(d, DEAL_ENTRY) == DEAL_ENTRY_IN)
           {
            px_in = HistoryDealGetDouble(d, DEAL_PRICE); t_in = (datetime)HistoryDealGetInteger(d, DEAL_TIME);
            dir = (HistoryDealGetInteger(d, DEAL_TYPE) == DEAL_TYPE_BUY) ? "BUY" : "SELL";
            sl = HistoryDealGetDouble(d, DEAL_SL); tp = HistoryDealGetDouble(d, DEAL_TP);
            break;
           }
        }
     }
   int dg = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   int mins = (t_in > 0) ? (int)((t_out - t_in) / 60) : 0;
   string j = "{\"ts\":" + (string)(long)TimeGMT() + ",\"pos\":" + (string)posId + ",\"symbol\":\"" + sym + "\",\"book\":\"" + BookNameOf(magic) +
              "\",\"dir\":\"" + dir + "\",\"lots\":" + DoubleToString(vol, 2) + ",\"in\":" + DoubleToString(px_in, dg) + ",\"out\":" + DoubleToString(px_out, dg) +
              ",\"sl\":" + DoubleToString(sl, dg) + ",\"tp\":" + DoubleToString(tp, dg) + ",\"t_in\":" + (string)(long)t_in + ",\"t_out\":" + (string)(long)t_out +
              ",\"mins\":" + (string)mins + ",\"reason\":\"" + DealReasonName(reason) + "\",\"pl\":" + DoubleToString(pl, 2) +
              ",\"brain_mode\":\"" + (gBrainOK ? BrainModeName() : "OFF") + "\",\"brain_bias\":" + DoubleToString(gBrainOK ? SymbolBiasOf(sym) : 0.0, 2) +
              ",\"balance\":" + DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2) + "}";
   string url = "https://api.github.com/repos/" + InpReportRepo + "/dispatches";
   string hdr = "Authorization: Bearer " + InpReportToken + "\r\nAccept: application/vnd.github+json\r\nUser-Agent: SmartMulti\r\nContent-Type: application/json\r\n";
   string payload = "{\"event_type\":\"trade\",\"client_payload\":{\"t\":" + j + "}}";   // GitHub allows max 10 top-level keys -> nest
   char pdata[]; StringToCharArray(payload, pdata, 0, StringLen(payload), CP_UTF8);
   char pres[]; string prh;
   ResetLastError();
   int c3 = WebRequest("POST", url, hdr, 8000, pdata, pres, prh);
   if(c3 == 204 || c3 == 200) Print("JOURNAL: ", sym, " ", BookNameOf(magic), " ", dir, " pl=", DoubleToString(pl, 2), " reason=", DealReasonName(reason), " sent to brain");
   else Print("JOURNAL: dispatch failed code=", c3, " err=", GetLastError());
  }
void OnTradeTransaction(const MqlTradeTransaction &trans, const MqlTradeRequest &request, const MqlTradeResult &result)
  {
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
   if(!InpReportEnabled) return;
   ReportTrade(trans.deal);
  }
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| PROFIT GUARD (account-wide, runs on the reporter chart only)      |
//| Pedro's rule: "if the market turns, keep the small profit, never  |
//| let a winner become a loser". Applies to ALL positions of the     |
//| account (all robots, all symbols):                                |
//|  1. gain >= GuardBE_R x risk       -> SL to entry + spread buffer |
//|  2. best gain (MFE) >= GuardArm_R and price gave back more than   |
//|     (1-GuardKeepPct) of it          -> close at market            |
//|  3. MFE >= GuardLockR              -> SL locks half of the MFE    |
//+------------------------------------------------------------------+
input group "=== PROFIT GUARD (all robots; active on the reporter chart) ==="
input bool   InpGuardEnabled     = true;
input double InpGuardBE_R        = 0.5;     // break-even once profit >= this x risk
input double InpGuardArm_R       = 0.7;     // arm the give-back rule once MFE >= this x risk
input double InpGuardKeepPct     = 0.40;    // close if profit falls to <= this share of MFE
input double InpGuardLockR       = 1.0;     // from this MFE (in R) lock half of MFE with the SL
ulong  gGuardTk[]; double gGuardMFE[]; double gGuardRisk[];
int GuardSlot(const ulong tk, const double risk0)
  {
   int n = ArraySize(gGuardTk);
   for(int i = 0; i < n; i++) if(gGuardTk[i] == tk) return(i);
   ArrayResize(gGuardTk, n + 1); ArrayResize(gGuardMFE, n + 1); ArrayResize(gGuardRisk, n + 1);
   gGuardTk[n] = tk; gGuardMFE[n] = 0.0; gGuardRisk[n] = risk0;
   return(n);
  }
void GuardCleanup()
  {
   int n = ArraySize(gGuardTk);
   for(int i = n - 1; i >= 0; i--)
      if(!PositionSelectByTicket(gGuardTk[i]))
        {
         for(int j = i; j < n - 1; j++) { gGuardTk[j] = gGuardTk[j+1]; gGuardMFE[j] = gGuardMFE[j+1]; gGuardRisk[j] = gGuardRisk[j+1]; }
         n--; ArrayResize(gGuardTk, n); ArrayResize(gGuardMFE, n); ArrayResize(gGuardRisk, n);
        }
  }
void ProfitGuard()
  {
   if(!InpGuardEnabled || !InpReportEnabled) return;      // one instance per account (the reporter chart)
   if(MQLInfoInteger(MQL_TESTER)) return;
   GuardCleanup();
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong tk = PositionGetTicket(i); if(tk == 0) continue;
      string sym = PositionGetString(POSITION_SYMBOL);
      int    dir = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 1 : -1;
      double entry = PositionGetDouble(POSITION_PRICE_OPEN), sl = PositionGetDouble(POSITION_SL), tp = PositionGetDouble(POSITION_TP);
      double last  = (dir > 0) ? SymbolInfoDouble(sym, SYMBOL_BID) : SymbolInfoDouble(sym, SYMBOL_ASK);
      if(last <= 0) continue;
      // initial risk (R): SL distance when first seen; if SL already beyond entry use TP/1.5; else skip
      double risk0 = 0;
      if(sl > 0 && sl * dir < entry * dir) risk0 = MathAbs(entry - sl);
      else if(tp > 0) risk0 = MathAbs(tp - entry) / 1.5;
      if(risk0 <= 0) continue;
      int    k    = GuardSlot(tk, risk0);
      double risk = gGuardRisk[k]; if(risk <= 0) { gGuardRisk[k] = risk0; risk = risk0; }
      double gain  = (last - entry) * dir, gainR = gain / risk;
      if(gainR > gGuardMFE[k]) gGuardMFE[k] = gainR;
      double mfe   = gGuardMFE[k];
      int    dg    = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
      double pt    = SymbolInfoDouble(sym, SYMBOL_POINT);
      double minD  = SymbolInfoInteger(sym, SYMBOL_TRADE_STOPS_LEVEL) * pt;
      double spr   = SymbolInfoDouble(sym, SYMBOL_ASK) - SymbolInfoDouble(sym, SYMBOL_BID);
      // 2. give-back rule: a winner turning -> take what is left
      if(mfe >= InpGuardArm_R && gainR <= mfe * InpGuardKeepPct)
        {
         if(trade.PositionClose(tk)) Print("GUARD: ", sym, " closed - MFE ", DoubleToString(mfe, 2), "R fell to ", DoubleToString(gainR, 2), "R (kept the small profit)");
         continue;
        }
      double want = 0;
      if(gainR >= InpGuardBE_R) want = entry + dir * (spr + 2 * pt);                        // 1. break-even
      if(mfe >= InpGuardLockR) { double lk = entry + dir * (mfe * risk * 0.5); if(want == 0 || lk * dir > want * dir) want = lk; }   // 3. lock half of MFE
      if(want != 0)
        {
         want = NormalizeDouble(want, dg);
         bool better = (sl == 0) ? true : ((want - sl) * dir >= 0.05 * risk);   // only meaningful improvements (>= 0.05R)
         if(better && MathAbs(last - want) > minD + spr)
            if(trade.PositionModify(tk, want, tp)) Print("GUARD: ", sym, " SL -> ", DoubleToString(want, dg), " (gain ", DoubleToString(gainR, 2), "R, MFE ", DoubleToString(mfe, 2), "R)");
        }
     }
  }
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| SHOCK v2 - catch the move EARLY                                   |
//|  A) live-bar entry: the forming M1 bar already >= K x ATR with a  |
//|     decisive body and price still pushing -> enter NOW (not after |
//|     the close).                                                   |
//|  B) scheduled-news breakout: the brain publishes news_events=     |
//|     CUR:epoch:title;... ; N min before the release we freeze the  |
//|     pre-news range, and the first break of it in the first minutes|
//|     after the release is traded immediately in that direction.    |
//+------------------------------------------------------------------+
input group "=== SHOCK v2 (early entries) ==="
input bool   InpH5_LiveEntry     = true;    // enter on the forming M1 bar
input double InpH5_LiveATRx      = 2.0;     // forming bar range >= this x ATR
input double InpH5_LiveBodyPct   = 0.6;     // body/range of the forming bar
input bool   InpH5_NewsBreakout  = true;    // scheduled-news breakout
input int    InpH5_NewsArmMin    = 2;       // arm this many minutes before the release
input int    InpH5_NewsRangeBars = 5;       // M1 bars that define the pre-news range
input int    InpH5_NewsWindowMin = 5;       // breakout must happen within N min after the release
input double InpH5_NewsBufATR    = 0.10;    // breakout buffer (x ATR)
datetime gLiveBarDone = 0;
datetime gNewsArmedTs = 0, gNewsDoneTs = 0; double gNewsHi = 0, gNewsLo = 0; string gNewsTitle = "";
bool     gNewsEntry = false;     // true while placing a news-breakout order (bypasses the news window block)

bool ShockGate()
  {
   int h = 5;
   if(!hOn[h]) return(false);
   if(hPausedUntil[h] > TimeCurrent()) return(false);
   if(hTradesToday[h] >= hMaxDay[h]) return(false);
   if(gProtectMode) return(false);
   if(gBrainOK && InpBrainEnforce && !BrainAllowsBook(h)) return(false);
   if(gLastShockTrade > 0 && TimeCurrent() - gLastShockTrade < (datetime)(InpH5_CooldownMin * 60)) return(false);
   return(true);
  }

// A) live-bar shock entry
void ShockLiveEntry()
  {
   if(!InpH5_LiveEntry || !ShockGate()) return;
   int brainDir = 0; bool assist = (InpBrainShockAssist && BrainShockDir(brainDir));
   if(!gH5SymbolOK && !assist) return;
   ENUM_TIMEFRAMES tf = hTF[5];
   datetime t0 = iTime(_Symbol, tf, 0); if(t0 == 0 || t0 == gLiveBarDone) return;
   double atr = ATRof(5); if(atr <= 0) return;
   double hh = iHigh(_Symbol, tf, 0), ll = iLow(_Symbol, tf, 0), o = iOpen(_Symbol, tf, 0);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID), ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(hh <= 0 || ll <= 0 || o <= 0 || bid <= 0) return;
   double rng = hh - ll; if(rng < (assist ? InpBrainShockATRx : 1.0) * InpH5_LiveATRx * atr) return;
   double c = bid;
   if(MathAbs(c - o) / rng < InpH5_LiveBodyPct) return;                 // not decisive
   ENUM_ORDER_TYPE dir = (c > o) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   if(brainDir != 0 && ((dir == ORDER_TYPE_BUY) != (brainDir > 0))) return;   // council locked the other way
   double fromExtreme = (dir == ORDER_TYPE_BUY) ? (hh - c) : (c - ll);
   if(fromExtreme > 0.25 * rng) return;                                   // already pulling back
   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(spread > InpMaxSpreadPoints * InpH5_MaxSpreadMult) return;
   gLiveBarDone = t0;                                                     // one attempt per bar
   Print("SHOCK-LIVE on ", _Symbol, ": forming bar ", DoubleToString(rng / atr, 1), "x ATR, dir=", (dir == ORDER_TYPE_BUY ? "UP" : "DOWN"));
   if(DoOpen(5, dir, rng, spread)) gLastShockTrade = TimeCurrent();
  }

// B) scheduled-news breakout
bool NewsEventRelevant(const string cur)
  {
   string u = _Symbol; StringToUpper(u); string cu = cur; StringToUpper(cu);
   if(cu == "") return(false);
   if(StringFind(u, cu) >= 0) return(true);                                // currency in the pair
   if(cu == "USD" && IsMetalOilIndex(_Symbol)) return(true);               // US data moves gold/oil/indices
   return(false);
  }
void ShockNewsBreakout()
  {
   if(!InpH5_NewsBreakout || !gBrainOK || !ShockGate()) return;
   string ev = BrainGet("news_events", "none"); if(ev == "" || ev == "none") return;
   datetime now = TimeGMT();
   string parts[]; int n = StringSplit(ev, ';', parts);
   datetime best = 0; string bestTitle = "";
   for(int i = 0; i < n; i++)
     {
      string f[]; if(StringSplit(parts[i], ':', f) < 2) continue;
      datetime ts = (datetime)StringToInteger(f[1]);
      if(ts <= 0 || !NewsEventRelevant(f[0])) continue;
      if(now < ts - InpH5_NewsArmMin * 60 || now > ts + InpH5_NewsWindowMin * 60) continue;
      if(best == 0 || ts < best) { best = ts; bestTitle = (ArraySize(f) > 2 ? f[2] : f[0]); }
     }
   if(best == 0) return;
   ENUM_TIMEFRAMES tf = hTF[5];
   // arm: freeze the pre-news range
   if(gNewsArmedTs != best && now < best)
     {
      double hi = 0, lo = 0;
      for(int i = 1; i <= InpH5_NewsRangeBars; i++)
        {
         double h_ = iHigh(_Symbol, tf, i), l_ = iLow(_Symbol, tf, i); if(h_ <= 0 || l_ <= 0) return;
         if(hi == 0 || h_ > hi) hi = h_; if(lo == 0 || l_ < lo) lo = l_;
        }
      gNewsArmedTs = best; gNewsHi = hi; gNewsLo = lo; gNewsTitle = bestTitle;
      Print("NEWS armed on ", _Symbol, " for ", bestTitle, " at ", TimeToString(best), " UTC: range ", DoubleToString(lo, _Digits), "-", DoubleToString(hi, _Digits));
      return;
     }
   if(gNewsArmedTs != best || gNewsDoneTs == best || now < best) return;
   double atr = ATRof(5); if(atr <= 0) return;
   double buf = InpH5_NewsBufATR * atr;
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID), ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   ENUM_ORDER_TYPE dir; double rng = (gNewsHi - gNewsLo) + buf;
   if(ask > gNewsHi + buf) dir = ORDER_TYPE_BUY;
   else if(bid < gNewsLo - buf) dir = ORDER_TYPE_SELL;
   else return;
   if(rng < 0.5 * atr) rng = 0.5 * atr;                                     // never an absurdly tight stop
   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(spread > InpMaxSpreadPoints * InpH5_MaxSpreadMult) { return; }       // wait for the spread to calm (still inside the window)
   gNewsDoneTs = best;                                                       // one shot per event
   Print("NEWS breakout on ", _Symbol, " (", gNewsTitle, "): ", (dir == ORDER_TYPE_BUY ? "UP" : "DOWN"), " range=", DoubleToString(rng / atr, 2), "x ATR");
   gNewsEntry = true;
   if(DoOpen(5, dir, rng, spread)) gLastShockTrade = TimeCurrent();
   gNewsEntry = false;
  }
//+------------------------------------------------------------------+
