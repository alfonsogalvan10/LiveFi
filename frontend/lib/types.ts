/**
 * Shared response contracts.
 *
 * These mirror the Pydantic schemas in the backend services. When you change
 * a schema in the services' app/schemas directories, change it here too —
 * nothing enforces this automatically, so it is a manual contract.
 *
 * NOTE: avoid writing a literal glob like `services/<svc>/app/schemas` with
 * a wildcard in a block comment. The two-character sequence star-slash closes
 * the comment early and the remainder of the line is parsed as code.
 */

/** A single OHLC candle, as produced by the Flink windowed aggregation. */
export interface Candle {
  window_start: string;
  open: number;
  high: number;
  low: number;
  close: number;
  volume: number;
}

/** GET /analytics/ohlc */
export interface OhlcResponse {
  cached: boolean;
  symbol: string;
  candles: Candle[];
}

/** A buy/sell volume bucket. */
export interface VolumeBucket {
  window_start: string;
  buy_volume: number;
  sell_volume: number;
  net_volume: number;
}

/** GET /analytics/volume */
export interface VolumeResponse {
  cached: boolean;
  symbol: string;
  buckets: VolumeBucket[];
}

/** Latest portfolio risk snapshot. */
export interface RiskMetrics {
  computed_at: string;
  var_95: number | null;
  exposure: number | null;
  sharpe: number | null;
}

/** GET /analytics/risk */
export interface RiskResponse {
  cached: boolean;
  portfolio_id: string;
  metrics: RiskMetrics | null;
}

/** POST /trades request body. */
export interface TradeCreate {
  idempotency_key: string;
  symbol: string;
  side: 'BUY' | 'SELL';
  quantity: number;
  price: number;
}

/** A persisted trade, as returned by POST /trades. */
export interface TradeRead extends TradeCreate {
  id: number;
  executed_at: string;
  source: string;
  created_at: string;
}

/** Envelope for messages pushed over the WebSocket. */
export interface StreamMessage<T = unknown> {
  channel: string;
  data: T;
}
