/**
 * Thin API client.
 *
 * Every call goes through Kong, which validates the Keycloak-issued bearer
 * token before proxying to the internal services. The browser only ever
 * learns the gateway's address.
 */

import type { OhlcResponse, TradeCreate, TradeRead } from './types';

const BASE_URL = process.env.NEXT_PUBLIC_API_BASE_URL ?? 'http://localhost:8000';

export async function getToken(): Promise<string | null> {
  // Wire this to the Keycloak JS adapter singleton in your auth provider.
  // Access tokens are held in memory (not localStorage) to limit XSS exposure.
  return typeof window !== 'undefined' ? sessionStorage.getItem('access_token') : null;
}

async function authHeaders(): Promise<Record<string, string>> {
  const token = await getToken();
  return {
    'Content-Type': 'application/json',
    ...(token ? { Authorization: `Bearer ${token}` } : {}),
  };
}

/** Generic GET. Prefer the typed helpers below where they exist. */
export async function apiFetch<T>(path: string): Promise<T> {
  const res = await fetch(`${BASE_URL}${path}`, {
    headers: await authHeaders(),
    cache: 'no-store',
  });
  if (!res.ok) {
    throw new Error(`GET ${path} failed (${res.status}): ${await res.text()}`);
  }
  return res.json() as Promise<T>;
}

/** OHLC candles for a symbol. Cached server-side for a few seconds. */
export function getOhlc(symbol: string, minutes = 60, interval = '1m'): Promise<OhlcResponse> {
  const query = new URLSearchParams({ symbol, minutes: String(minutes), interval });
  return apiFetch<OhlcResponse>(`/analytics/ohlc?${query}`);
}

/** Submit a trade. The idempotency_key makes retries safe. */
export async function postTrade(payload: TradeCreate): Promise<TradeRead> {
  const res = await fetch(`${BASE_URL}/trades`, {
    method: 'POST',
    headers: await authHeaders(),
    body: JSON.stringify(payload),
  });
  if (!res.ok) {
    throw new Error(`POST /trades failed (${res.status}): ${await res.text()}`);
  }
  return res.json() as Promise<TradeRead>;
}
