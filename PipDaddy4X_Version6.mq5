//+------------------------------------------------------------------+
//| PipDaddy4X - Patched compact MQL5 EA                             |
//| Version: 3.020                                                    |
//| Purpose: Trend + SMC order-block hybrid with ATR sizing,         |
//|          optional Multi-TP partial closes, trailing & BE.        |
//| Notes: UI removed. Single-chart/symbol operation.                |
//+------------------------------------------------------------------+
#property copyright "PipDaddy4X Patched"
#property version   "3.020"
#property strict

#include <Trade\Trade.mqh>
CTrade Trade;

//-------------------------- INPUTS ---------------------------------
input ENUM_TIMEFRAMES OperTF = PERIOD_M5;

// Strategy modes
enum STRAT_MODE { STRAT_TREND=0, STRAT_SMC=1, STRAT_AUTO=2 };
input STRAT_MODE StrategyMode = STRAT_AUTO;

// Trend inputs
input int Trend_FastMA = 10;
input int Trend_SlowMA = 30;
input int Trend_RSI_Period = 14;
input double Trend_RSI_High = 65.0;
input double Trend_RSI_Low  = 35.0;
input int ATR_Period = 14;
input double Trend_ATR_SL = 1.5;
input double Trend_ATR_TP = 3.0;

// SMC inputs
input int SMC_OB_Lookback = 50;
input double SMC_OB_MinStrength = 1.3;
input int SMC_OB_MaxAgeHours = 48;
input double SMC_LiqSweepPips = 5.0;
input bool SMC_RequireEngulfing = false;
input int SMC_EngulfingBodyPct = 60;
input double SMC_MinConfidence = 60.0;

// Risk & lots
input double Risk_Percent = 1.0;         // percent per trade
input bool UseFixedLot = false;
input double FixedLot = 0.01;

// Position management
input int Pos_MaxOpen = 3;
input bool Pos_AllowReentry = true;
input double Pos_ReentryDistance = 15.0; // pips
input int Pos_MaxReentries = 1;

// Break-even and trail (pips)
input bool Pos_UseBreakEven = true;
input double Pos_BreakEvenTrigger = 20.0;
input double Pos_BreakEvenPlus = 5.0;
input double Pos_TrailActivate = 40.0;
input double Pos_TrailDistance = 20.0;

// Multi-TP
input bool UseMultiTP = true;
input double TP1_Pips = 30.0;
input double TP1_ClosePct = 40.0;
input double TP2_Pips = 60.0;
input double TP2_ClosePct = 30.0;
input double TP3_Pips = 100.0;
input bool TP_MoveToBreakeven = true;
input double TP_BreakevenPlus = 5.0;

// Misc
input int Config_Magic = 424242;
input string Config_Comment = "PipDaddy_Patched";
input int Slippage = 20;
input double Filter_MaxSpread = 20.0; // pips
input bool Verbose = false;

//-------------------------- TYPES ----------------------------------
struct TradeSignal
{
   bool valid;
   int dir;          // 1=buy, -1=sell
   double entry;
   double sl;
   double tp;
   double confidence;
   string reason;
};

struct OrderBlock
{
   datetime time;
   double high;
   double low;
   bool isBull;
   double strength;
};

struct ReentryInfo
{
   double entryPrice;
   int direction;
   int count;
   datetime lastTime;
};

struct TPTracker
{
   ulong ticket;
   double originalLot;
   bool tp1;
   bool tp2;
   bool beMoved;
};

//----------------------- GLOBALS ----------------------------------
int hEMA_fast = INVALID_HANDLE;
int hEMA_slow = INVALID_HANDLE;
int hRSI = INVALID_HANDLE;
int hATR = INVALID_HANDLE;

datetime g_lastBar = 0;
double g_fast=0, g_slow=0, g_rsi=0, g_atr=0;
datetime g_cache_time=0;

OrderBlock g_bullOB;
OrderBlock g_bearOB;
datetime g_lastOBScan = 0;

ReentryInfo g_reentry;

TPTracker g_trackers[]; // dynamic array

//----------------------- INITIALIZATION ----------------------------
int OnInit()
{
   // create indicator handles on OperTF
   hEMA_fast = iMA(_Symbol, OperTF, Trend_FastMA, 0, MODE_EMA, PRICE_CLOSE);
   hEMA_slow = iMA(_Symbol, OperTF, Trend_SlowMA, 0, MODE_EMA, PRICE_CLOSE);
   hRSI = iRSI(_Symbol, OperTF, Trend_RSI_Period, PRICE_CLOSE);
   hATR = iATR(_Symbol, OperTF, ATR_Period);
   if(hEMA_fast==INVALID_HANDLE || hEMA_slow==INVALID_HANDLE || hRSI==INVALID_HANDLE || hATR==INVALID_HANDLE)
   {
      Print("Init: indicator handle error");
      return INIT_FAILED;
   }

   g_lastBar = iTime(_Symbol, OperTF, 0);
   ResetReentry();
   ResetOrderBlocks();
   ArrayResize(g_trackers,0);

   if(Verbose) Print("Init complete");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(hEMA_fast!=INVALID_HANDLE) IndicatorRelease(hEMA_fast);
   if(hEMA_slow!=INVALID_HANDLE) IndicatorRelease(hEMA_slow);
   if(hRSI!=INVALID_HANDLE) IndicatorRelease(hRSI);
   if(hATR!=INVALID_HANDLE) IndicatorRelease(hATR);
   if(Verbose) Print("Deinit:",reason);
}

//------------------------- MAIN TICK --------------------------------
void OnTick()
{
   // only act on new bar of OperTF
   datetime t = iTime(_Symbol, OperTF, 0);
   if(t == g_lastBar) return;
   g_lastBar = t;

   UpdateIndicators();

   // basic spread check
   double point = SymbolInfoDouble(_Symbol,SYMBOL_POINT);
   long spread = SymbolInfoInteger(_Symbol,SYMBOL_SPREAD);
   double spread_pips = (spread * point) / (point * 10.0);
   if(spread_pips > Filter_MaxSpread) { if(Verbose) Print("Skip - spread too high"); return; }

   // update order blocks hourly
   if(TimeCurrent() - g_lastOBScan > 3600) { ScanOrderBlocks(); g_lastOBScan = TimeCurrent(); }

   // manage existing positions
   ManageAllPositions();

   // do pre-trade validations
   if(!PreTradeChecks()) return;

   // generate signal
   TradeSignal sig = GenerateSignal();

   if(sig.valid)
   {
      if(Verbose) PrintFormat("Signal dir=%d conf=%.1f reason=%s", sig.dir, sig.confidence, sig.reason);
      ProcessSignal(sig);
   }
}

//---------------------- INDICATOR CACHE ------------------------------
void UpdateIndicators()
{
   if(TimeCurrent() - g_cache_time < 2) return;
   double buf[];
   ArraySetAsSeries(buf,true);

   if(CopyBuffer(hEMA_fast,0,0,1,buf)>0) g_fast = buf[0];
   if(CopyBuffer(hEMA_slow,0,0,1,buf)>0) g_slow = buf[0];
   if(CopyBuffer(hRSI,0,0,1,buf)>0) g_rsi = buf[0];
   if(CopyBuffer(hATR,0,0,1,buf)>0) g_atr = buf[0];
   g_cache_time = TimeCurrent();
}

//---------------------- PRETRADE CHECKS ------------------------------
bool PreTradeChecks()
{
   // minimal account check
   if(AccountInfoDouble(ACCOUNT_BALANCE) < 50.0) return false;
   // position limit
   if(CountOpenPositions() >= Pos_MaxOpen && !Pos_AllowReentry) return false;
   return true;
}

//---------------------- SIGNAL LOGIC --------------------------------
TradeSignal GenerateSignal()
{
   TradeSignal s; s.valid=false; s.confidence=0; s.reason="";
   // choose strategy
   STRAT_MODE mode = GetActiveStrategy();
   if(mode == STRAT_TREND) return TrendSignal();
   else return SMCSignal();
}

//---------------------- TREND SIGNAL --------------------------------
TradeSignal TrendSignal()
{
   TradeSignal s; 
   s.valid = false; 
   s.confidence = 0;
   s.reason = "";

   // try to read recent MA & RSI values (series arrays: [0]=current, [1]=prev, [2]=prev2)
   double maF[], maS[], rsiA[];
   ArraySetAsSeries(maF, true);
   ArraySetAsSeries(maS, true);
   ArraySetAsSeries(rsiA, true);

   // If CopyBuffer fails, fall back to cached values (g_fast, g_slow, g_rsi)
   bool ok = true;
   if(CopyBuffer(hEMA_fast, 0, 0, 3, maF) < 3) ok = false;
   if(CopyBuffer(hEMA_slow, 0, 0, 3, maS) < 3) ok = false;
   if(CopyBuffer(hRSI, 0, 0, 2, rsiA) < 2) ok = false;

   double fast0, fast1, fast2, slow0, slow1, slow2, rsi0, rsi1;
   if(ok)
   {
      fast0 = maF[0]; fast1 = maF[1]; fast2 = maF[2];
      slow0 = maS[0]; slow1 = maS[1]; slow2 = maS[2];
      rsi0  = rsiA[0]; rsi1 = rsiA[1];
   }
   else
   {
      // fallback to cached single values (no cross info available reliably)
      fast0 = g_fast; slow0 = g_slow; rsi0 = g_rsi;
      // approximate previous values by shifting (best-effort)
      fast1 = fast0; fast2 = fast0;
      slow1 = slow0; slow2 = slow0;
      rsi1  = rsi0;
   }

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   // detect recent MA cross using previous values
   bool crossUp = (fast1 > slow1 && fast2 <= slow2);
   bool crossDown = (fast1 < slow1 && fast2 >= slow2);

   // price relative to fast MA for filter
   double price = bid;
   bool priceAboveMA = price > fast0;
   bool priceBelowMA = price < fast0;

   // conditions
   bool rsiRisingFromLow = (rsi1 < Trend_RSI_Low && rsi0 > rsi1);
   bool rsiFallingFromHigh = (rsi1 > Trend_RSI_High && rsi0 < rsi1);

   // BUY: MA cross up OR uptrend with RSI pullback and price above fast MA
   if( (crossUp || (fast0 > slow0 && rsiRisingFromLow)) && priceAboveMA )
   {
      s.valid = true;
      s.dir = 1;
      s.entry = ask;
      s.sl = s.entry - (g_atr * Trend_ATR_SL);
      s.tp = s.entry + (g_atr * Trend_ATR_TP);
      s.confidence = 70 + (crossUp ? 15 : 0) + (rsiRisingFromLow ? 10 : 0);
      s.reason = crossUp ? "MA cross up" : "Trend+RSI pullback";
      if(!ValidateRR(s)) s.valid = false;
      return s;
   }

   // SELL: MA cross down OR downtrend with RSI pullback and price below fast MA
   if( (crossDown || (fast0 < slow0 && rsiFallingFromHigh)) && priceBelowMA )
   {
      s.valid = true;
      s.dir = -1;
      s.entry = bid;
      s.sl = s.entry + (g_atr * Trend_ATR_SL);
      s.tp = s.entry - (g_atr * Trend_ATR_TP);
      s.confidence = 70 + (crossDown ? 15 : 0) + (rsiFallingFromHigh ? 10 : 0);
      s.reason = crossDown ? "MA cross down" : "Trend+RSI pullback";
      if(!ValidateRR(s)) s.valid = false;
      return s;
   }

   return s;
}

// SMC / Order block based (simple)
TradeSignal SMCSignal()
{
   TradeSignal s; s.valid=false; s.confidence=0;
   double price = SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double pip = SymbolInfoDouble(_Symbol,SYMBOL_POINT) * 10.0;

   // bullish OB
   if(g_bullOB.strength >= SMC_OB_MinStrength && price >= g_bullOB.low && price <= g_bullOB.high)
   {
      int age = (int)((TimeCurrent() - g_bullOB.time)/3600);
      if(age <= SMC_OB_MaxAgeHours)
      {
         bool conf = !SMC_RequireEngulfing || IsEngulfing(true);
         if(conf)
         {
            s.valid=true; s.dir=1;
            s.entry = SymbolInfoDouble(_Symbol,SYMBOL_ASK);
            double slp = 15.0;
            s.sl = g_bullOB.low - slp * pip;
            double riskpips = MathAbs(s.entry - s.sl)/pip;
            s.tp = s.entry + riskpips * 2.0 * pip;
            s.confidence = 60 + g_bullOB.strength*5;
            s.reason = "SMC bull OB";
            if(!ValidateRR(s)) s.valid=false;
         }
      }
   }
   // bearish OB
   else if(g_bearOB.strength >= SMC_OB_MinStrength && price >= g_bearOB.low && price <= g_bearOB.high)
   {
      int age = (int)((TimeCurrent() - g_bearOB.time)/3600);
      if(age <= SMC_OB_MaxAgeHours)
      {
         bool conf = !SMC_RequireEngulfing || IsEngulfing(false);
         if(conf)
         {
            s.valid=true; s.dir=-1;
            s.entry = SymbolInfoDouble(_Symbol,SYMBOL_BID);
            double slp = 15.0;
            s.sl = g_bearOB.high + slp * pip;
            double riskpips = MathAbs(s.entry - s.sl)/pip;
            s.tp = s.entry - riskpips * 2.0 * pip;
            s.confidence = 60 + g_bearOB.strength*5;
            s.reason = "SMC bear OB";
            if(!ValidateRR(s)) s.valid=false;
         }
      }
   }
   return s;
}

//------------------- ORDER BLOCK SCAN -------------------------------
void ScanOrderBlocks()
{
   // simple scan, store the strongest single OB each side
   ResetOrderBlocks();
   for(int i=2; i<SMC_OB_Lookback; i++)
   {
      double close1 = iClose(_Symbol, OperTF, i);
      double open1  = iOpen(_Symbol, OperTF, i);
      double high0  = iHigh(_Symbol, OperTF, i-1);
      double low1   = iLow(_Symbol, OperTF, i);
      double high1  = iHigh(_Symbol, OperTF, i);

      if(close1 < open1 && high0 > high1) // bullish OB candidate
      {
         double obSize = high1 - low1;
         double upMove = high0 - low1;
         if(obSize > 0)
         {
            double strength = upMove/obSize;
            if(strength > g_bullOB.strength)
            {
               g_bullOB.high = high1; g_bullOB.low = low1;
               g_bullOB.time = iTime(_Symbol, OperTF, i);
               g_bullOB.strength = MathMin(strength,10.0);
               g_bullOB.isBull = true;
            }
         }
      }

      // bearish
      double close2 = iClose(_Symbol, OperTF, i);
      double open2  = iOpen(_Symbol, OperTF, i);
      double low0   = iLow(_Symbol, OperTF, i-1);
      double high2  = iHigh(_Symbol, OperTF, i);
      double low2   = iLow(_Symbol, OperTF, i);

      if(close2 > open2 && low0 < low2)
      {
         double obSize = high2 - low2;
         double downMove = high2 - low0;
         if(obSize > 0)
         {
            double strength = downMove/obSize;
            if(strength > g_bearOB.strength)
            {
               g_bearOB.high = high2; g_bearOB.low = low2;
               g_bearOB.time = iTime(_Symbol, OperTF, i);
               g_bearOB.strength = MathMin(strength,10.0);
               g_bearOB.isBull = false;
            }
         }
      }
   }
}

//------------------- ENTRY / EXECUTION ------------------------------
void ProcessSignal(TradeSignal &sig)
{
   int openCount = CountOpenPositions();
   if(openCount == 0)
   {
      ExecuteOrder(sig);
      return;
   }

   // allow reentry logic
   if(Pos_AllowReentry && g_reentry.count < Pos_MaxReentries)
   {
      if(ShouldReenter(sig))
      {
         ExecuteOrder(sig);
         g_reentry.count++;
         if(Verbose) Print("Reentry executed, count=", g_reentry.count);
      }
   }
}

bool ShouldReenter(TradeSignal &sig)
{
   if(g_reentry.entryPrice == 0) return false;
   if(sig.dir != g_reentry.direction) return false;
   double pip = SymbolInfoDouble(_Symbol,SYMBOL_POINT)*10.0;
   double dist = MathAbs(sig.entry - g_reentry.entryPrice);
   if(dist > Pos_ReentryDistance * pip * 2.0) return false;
   if(TimeCurrent() - g_reentry.lastTime < 300) return false;
   return true;
}

void ExecuteOrder(TradeSignal &sig)
{
   double lot = CalcLot(sig.entry, sig.sl);
   if(lot <= 0) { if(Verbose) Print("Lot calculation returned 0"); return; }
   double step = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   if(step <= 0) step = 0.01;
   double minlot = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double maxlot = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   lot = MathFloor(lot/step) * step;
   lot = MathMax(minlot, MathMin(maxlot, lot));

   MqlTradeRequest req; MqlTradeResult res; ZeroMemory(req); ZeroMemory(res);
   req.action = TRADE_ACTION_DEAL;
   req.symbol = _Symbol;
   req.volume = lot;
   req.magic = Config_Magic;
   req.comment = Config_Comment;
   req.deviation = Slippage;
   req.type_filling = GetFillingMode();

   if(sig.dir == 1) { req.type = ORDER_TYPE_BUY; req.price = SymbolInfoDouble(_Symbol,SYMBOL_ASK); }
   else { req.type = ORDER_TYPE_SELL; req.price = SymbolInfoDouble(_Symbol,SYMBOL_BID); }

   req.sl = NormalizeDouble(sig.sl, _Digits);
   req.tp = NormalizeDouble(sig.tp, _Digits);

   if(!OrderSend(req,res))
   {
      if(Verbose) Print("OrderSend failed err=", GetLastError());
      return;
   }
   if(res.retcode != TRADE_RETCODE_DONE)
   {
      if(Verbose) Print("OrderSend failed rc=", res.retcode, " desc=", GetErrorDescription(res.retcode));
      return;
   }

   // track reentry base
   if(g_reentry.entryPrice == 0)
   {
      g_reentry.entryPrice = sig.entry;
      g_reentry.direction = sig.dir;
      g_reentry.count = 0;
   }
   g_reentry.lastTime = TimeCurrent();

   // add TP tracker if Multi-TP
   if(UseMultiTP)
      AddTracker(res.order, lot);

   if(Verbose) PrintFormat("Order opened ticket=%I64u lot=%.2f dir=%d", res.order, lot, sig.dir);
}

//-------------------- LOT SIZING -----------------------------------
double CalcLot(double entry, double sl)
{
   if(UseFixedLot) return FixedLot;
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double risk_amt = balance * (Risk_Percent/100.0);
   double slDist = MathAbs(entry - sl);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize<=0 || tickValue<=0 || slDist<=0) return 0;
   double lots = risk_amt / ((slDist / tickSize) * tickValue);
   return lots;
}

//------------------ TRACKER MANAGEMENT ------------------------------
void AddTracker(ulong ticket, double lot)
{
   int n = ArraySize(g_trackers);
   ArrayResize(g_trackers, n+1);
   g_trackers[n].ticket = ticket;
   g_trackers[n].originalLot = lot;
   g_trackers[n].tp1 = false;
   g_trackers[n].tp2 = false;
   g_trackers[n].beMoved = false;
}

int FindTracker(ulong ticket)
{
   for(int i=0;i<ArraySize(g_trackers);i++) if(g_trackers[i].ticket==ticket) return i;
   return -1;
}

void RemoveTrackerByIndex(int idx)
{
   int n = ArraySize(g_trackers);
   if(idx<0 || idx>=n) return;
   for(int i=idx;i<n-1;i++) g_trackers[i] = g_trackers[i+1];
   ArrayResize(g_trackers, n-1);
}

void RemoveTrackerByTicket(ulong ticket)
{
   int idx = FindTracker(ticket);
   if(idx>=0) RemoveTrackerByIndex(idx);
}

//------------------ POSITION MANAGEMENT -----------------------------
void ManageAllPositions()
{
   int tot = PositionsTotal();
   bool any = false;

   // iterate backwards to allow safe modification during loop
   for(int idx = tot - 1; idx >= 0; idx--)
   {
      if(!PositionSelectByIndex(idx)) 
         continue;

      string sym = PositionGetString(POSITION_SYMBOL);
      if(sym != _Symbol) 
         continue;

      // only manage positions opened by this EA (magic)
      if((int)PositionGetInteger(POSITION_MAGIC) != Config_Magic) 
         continue;

      any = true;
      ulong ticket = PositionGetInteger(POSITION_TICKET);
      ManagePosition(ticket);
   }

   // if we have no open positions from this EA, reset reentry tracking
   if(!any) ResetReentry();
}

void ManagePosition(ulong ticket)
{
   if(!PositionSelectByTicket(ticket)) return;
   double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
   ENUM_POSITION_TYPE ptype = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   double curPrice = (ptype==POSITION_TYPE_BUY)? SymbolInfoDouble(_Symbol,SYMBOL_BID) : SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   double pip = SymbolInfoDouble(_Symbol,SYMBOL_POINT)*10.0;
   double profitPips = (ptype==POSITION_TYPE_BUY) ? (curPrice - openPrice)/pip : (openPrice - curPrice)/pip;
   double curSL = PositionGetDouble(POSITION_SL);
   double curTP = PositionGetDouble(POSITION_TP);

   // Multi-TP handling (priority)
   if(UseMultiTP)
   {
      int idx = FindTracker(ticket);
      if(idx>=0) HandleMultiTP(ticket, idx, profitPips, ptype, openPrice, curPrice, curSL, curTP);
      return;
   }

   // Break-even
   if(Pos_UseBreakEven && profitPips >= Pos_BreakEvenTrigger)
   {
      double be = openPrice + (Pos_BreakEvenPlus * pip * ((ptype==POSITION_TYPE_BUY)?1:-1));
      if((ptype==POSITION_TYPE_BUY && curSL < be) || (ptype==POSITION_TYPE_SELL && (curSL > be || curSL==0)))
         ModifyPositionSLTP(ticket, be, curTP);
   }

   // trailing
   if(profitPips >= Pos_TrailActivate)
   {
      double newSL = (ptype==POSITION_TYPE_BUY)? curPrice - Pos_TrailDistance*pip : curPrice + Pos_TrailDistance*pip;
      if((ptype==POSITION_TYPE_BUY && newSL>curSL && newSL>openPrice) || (ptype==POSITION_TYPE_SELL && (newSL<curSL || curSL==0) && newSL<openPrice))
         ModifyPositionSLTP(ticket, newSL, curTP);
   }
}

// Multi-TP handler
void HandleMultiTP(ulong ticket, int idx, double profitPips, ENUM_POSITION_TYPE pType, double openPrice, double curPrice, double curSL, double curTP)
{
   if(!PositionSelectByTicket(ticket)) { RemoveTrackerByIndex(idx); return; }
   double pip = SymbolInfoDouble(_Symbol,SYMBOL_POINT)*10.0;
   double vol = PositionGetDouble(POSITION_VOLUME);

   // TP1
   if(!g_trackers[idx].tp1 && profitPips >= TP1_Pips)
   {
      double closeVol = NormalizeVolume(g_trackers[idx].originalLot * (TP1_ClosePct/100.0));
      closeVol = MathMin(vol, closeVol);
      if(ClosePartial(ticket, closeVol))
      {
         g_trackers[idx].tp1 = true;
         if(TP_MoveToBreakeven && !g_trackers[idx].beMoved)
         {
            double be = (pType==POSITION_TYPE_BUY)? openPrice + TP_BreakevenPlus*pip : openPrice - TP_BreakevenPlus*pip;
            ModifyPositionSLTP(ticket, be, curTP);
            g_trackers[idx].beMoved = true;
         }
      }
   }

   // TP2
   if(g_trackers[idx].tp1 && !g_trackers[idx].tp2 && profitPips >= TP2_Pips)
   {
      double closeVol = NormalizeVolume(g_trackers[idx].originalLot * (TP2_ClosePct/100.0));
      closeVol = MathMin(vol, closeVol);
      if(ClosePartial(ticket, closeVol))
      {
         g_trackers[idx].tp2 = true;
         // tighten trail
         double trailDist = 30.0 * pip;
         double newSL = (pType==POSITION_TYPE_BUY)? curPrice - trailDist : curPrice + trailDist;
         if((pType==POSITION_TYPE_BUY && newSL>curSL) || (pType==POSITION_TYPE_SELL && (newSL<curSL || curSL==0)))
            ModifyPositionSLTP(ticket, newSL, curTP);
      }
   }

   // TP3
   if(g_trackers[idx].tp2 && profitPips >= TP3_Pips)
   {
      double rem = PositionGetDouble(POSITION_VOLUME);
      if(ClosePartial(ticket, rem))
      {
         RemoveTrackerByIndex(idx);
      }
   }

   // aggressive trail after TP2
   if(g_trackers[idx].tp2 && profitPips > TP2_Pips + 20.0)
   {
      double trailDist = 25.0 * pip;
      double newSL = (pType==POSITION_TYPE_BUY)? curPrice - trailDist : curPrice + trailDist;
      if((pType==POSITION_TYPE_BUY && newSL>curSL) || (pType==POSITION_TYPE_SELL && (newSL<curSL || curSL==0)))
         ModifyPositionSLTP(ticket, newSL, curTP);
   }
}

// Close partial helper
bool ClosePartial(ulong ticket, double volume)
{
   if(volume <= 0) return false;
   if(!PositionSelectByTicket(ticket)) return false;
   ENUM_POSITION_TYPE pt = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

   MqlTradeRequest req; MqlTradeResult res; ZeroMemory(req); ZeroMemory(res);
   req.action = TRADE_ACTION_DEAL;
   req.position = ticket;
   req.symbol = _Symbol;
   req.volume = volume;
   req.type = (pt==POSITION_TYPE_BUY)? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
   req.price = (pt==POSITION_TYPE_BUY)? SymbolInfoDouble(_Symbol,SYMBOL_BID) : SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   req.deviation = Slippage;
   req.magic = Config_Magic;
   req.type_filling = GetFillingMode();

   if(!OrderSend(req,res)) { if(Verbose) Print("ClosePartial OrderSend err=", GetLastError()); return false; }
   if(res.retcode != TRADE_RETCODE_DONE) { if(Verbose) Print("ClosePartial rc=", res.retcode); return false; }
   return true;
}

// Modify SL/TP
void ModifyPositionSLTP(ulong ticket, double newSL, double newTP)
{
   MqlTradeRequest req; MqlTradeResult res; ZeroMemory(req); ZeroMemory(res);
   req.action = TRADE_ACTION_SLTP;
   req.position = ticket;
   req.symbol = _Symbol;
   req.sl = NormalizeDouble(newSL, _Digits);
   req.tp = NormalizeDouble(newTP, _Digits);
   if(!OrderSend(req,res)) if(Verbose) Print("Modify err=",GetLastError());
}

//------------------ SMALL HELPERS ----------------------------------
bool IsEngulfing(bool bullish)
{
   double o0 = iOpen(_Symbol, OperTF, 1), c0 = iClose(_Symbol, OperTF, 1);
   double o1 = iOpen(_Symbol, OperTF, 2), c1 = iClose(_Symbol, OperTF, 2);
   double h = iHigh(_Symbol, OperTF, 1), l = iLow(_Symbol, OperTF, 1);
   double body0 = MathAbs(c0 - o0), body1 = MathAbs(c1 - o1);
   double rng = h - l; if(rng==0) return false;
   double bodyPct = (body0 / rng) * 100.0;
   if(bullish) return (c0>o0 && c1<o1 && c0>o1 && o0<c1 && body0>body1 && bodyPct > SMC_EngulfingBodyPct);
   else        return (c0<o0 && c1>o1 && c0<o1 && o0>c1 && body0>body1 && bodyPct > SMC_EngulfingBodyPct);
}

bool ValidateRR(TradeSignal &s)
{
   double risk = MathAbs(s.entry - s.sl);
   double reward = MathAbs(s.tp - s.entry);
   if(risk <= 0) return false;
   return (reward / risk >= 1.0); // minimal 1:1
}

//------------------ COUNT OPEN POSITIONS -----------------------------
int CountOpenPositions()
{
   int cnt = 0;
   int total = PositionsTotal();
   for(int i = 0; i < total; i++)
   {
      if(!PositionSelectByIndex(i)) 
         continue;
      // count only same symbol and same EA magic number
      if(PositionGetString(POSITION_SYMBOL) == _Symbol && (int)PositionGetInteger(POSITION_MAGIC) == Config_Magic)
         cnt++;
   }
   return cnt;
}

ENUM_ORDER_TYPE_FILLING GetFillingMode()
{
   uint f = (uint)SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   if((f & SYMBOL_FILLING_FOK) == SYMBOL_FILLING_FOK) return ORDER_FILLING_FOK;
   if((f & SYMBOL_FILLING_IOC) == SYMBOL_FILLING_IOC) return ORDER_FILLING_IOC;
   return ORDER_FILLING_RETURN;
}

string GetErrorDescription(uint rc)
{
   switch(rc)
   {
      case TRADE_RETCODE_INVALID: return "Invalid request";
      case TRADE_RETCODE_INVALID_VOLUME: return "Invalid volume";
      case TRADE_RETCODE_INVALID_PRICE: return "Invalid price";
      case TRADE_RETCODE_INVALID_STOPS: return "Invalid stops";
      case TRADE_RETCODE_TRADE_DISABLED: return "Trading disabled";
      case TRADE_RETCODE_MARKET_CLOSED: return "Market closed";
      case TRADE_RETCODE_NO_MONEY: return "Not enough money";
      case TRADE_RETCODE_INVALID_FILL: return "Invalid fill mode";
      case TRADE_RETCODE_CONNECTION: return "No connection";
      default: return "RC:"+IntegerToString((int)rc);
   }
}

//----------------- REENTRY & RESET ----------------------------------
void ResetReentry()
{
   g_reentry.entryPrice = 0;
   g_reentry.direction = 0;
   g_reentry.count = 0;
   g_reentry.lastTime = 0;
}

void ResetOrderBlocks()
{
   g_bullOB.time = 0; g_bullOB.high=0; g_bullOB.low=0; g_bullOB.strength=0; g_bullOB.isBull=true;
   g_bearOB.time = 0; g_bearOB.high=0; g_bearOB.low=0; g_bearOB.strength=0; g_bearOB.isBull=false;
}

//----------------- VOLUME HELPERS -----------------------------------
double NormalizeVolume(double v)
{
   double step = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   double min  = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   if(step <= 0) step = 0.01;
   double res = MathFloor(v/step)*step;
   res = MathMax(res, min);
   return res;
}

//----------------- STRATEGY SELECTION -------------------------------
STRAT_MODE GetActiveStrategy()
{
   if(StrategyMode != STRAT_AUTO) return StrategyMode;
   if(StringFind(_Symbol,"XAU")>=0 || StringFind(_Symbol,"GOLD")>=0) return STRAT_SMC;
   return STRAT_TREND;
}

//----------------- END ------------------------------------------------
/*
  Notes:
  - Removed duplicate stray code that caused "if/else/return" at global scope.
  - All struct-arrays are dynamic. No static-sized struct arrays remain.
  - If any compile errors remain, paste the exact compiler output (lines + messages) and I will patch further.
*/