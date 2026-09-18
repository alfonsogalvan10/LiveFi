/**
 * Thin API client. All calls go through Kong, which validates the
 * Keycloak-issued bearer token before proxying to internal services.
 */

const BASE_URL = process.env.NEXT_PUBLIC_API_BASE_URL ?? 'http://localhost:8000';

export async function getToken(): Promise<string | null> {
  // Wire this to the Keycloak JS adapter singleton in your auth provider.
  return typeof window !== 'undefined' ? sessionStorage.getItem('access_token') : null;
}

export async function apiFetch<T = unknown>(path: string): Promise<T> {
  const token = await getToken();
  const res = await fetch(`${BASE_URL}${path}`, {
    headers: {
      'Content-Type': 'application/json',
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
    },
    cache: 'no-store',
  });

  if (!res.ok) {
    throw new Error(`API error ${res.status}: ${await res.text()}`);
  }
  return res.json() as Promise<T>;
}

export async function postTrade(payload: {
  idempotency_key: string;
  symbol: string;
  side: 'BUY' | 'SELL';
  quantity: number;
  price: number;
}) {
  const token = await getToken();
  const res = await fetch(`${BASE_URL}/trades`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
    },
    body: JSON.stringify(payload),
  });
  if (!res.ok) throw new Error(`Trade rejected: ${await res.text()}`);
  return res.json();
}
