'use client';

import useSWR from 'swr';
import { PriceChart } from '@/components/PriceChart';
import { useLiveStream } from '@/lib/useLiveStream';
import { apiFetch } from '@/lib/api';

const SYMBOL = 'AAPL';

export default function DashboardPage() {
  const { data, error, isLoading } = useSWR(
    `/analytics/ohlc?symbol=${SYMBOL}&minutes=120`,
    apiFetch,
    { refreshInterval: 5000 },
  );

  const { connected, lastMessage } = useLiveStream(['analytics.ohlc']);

  return (
    <section className="space-y-6">
      <div className="flex items-center gap-3">
        <h2 className="text-xl font-medium">{SYMBOL}</h2>
        <span
          className={`rounded-full px-2 py-0.5 text-xs ${
            connected ? 'bg-up/20 text-up' : 'bg-slate-800 text-slate-400'
          }`}
        >
          {connected ? 'live' : 'offline'}
        </span>
      </div>

      {isLoading && <p className="text-slate-400">Loading candles…</p>}
      {error && <p className="text-down">Failed to load analytics.</p>}

      {data?.candles?.length > 0 && <PriceChart candles={data.candles} />}

      <pre className="rounded-lg border border-slate-800 bg-slate-900 p-4 text-xs text-slate-400">
        {lastMessage ? JSON.stringify(lastMessage, null, 2) : 'Waiting for live updates…'}
      </pre>
    </section>
  );
}
