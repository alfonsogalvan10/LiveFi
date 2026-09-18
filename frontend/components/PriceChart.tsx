'use client';

import { useEffect, useRef } from 'react';
import { createChart, type IChartApi, type UTCTimestamp } from 'lightweight-charts';

import type { Candle } from '@/lib/types';

export function PriceChart({ candles }: { candles: Candle[] }) {
  const containerRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (!containerRef.current || candles.length === 0) return;

    const chart: IChartApi = createChart(containerRef.current, {
      layout: { background: { color: 'transparent' }, textColor: '#94a3b8' },
      grid: { vertLines: { color: '#1e293b' }, horzLines: { color: '#1e293b' } },
      rightPriceScale: { borderColor: '#334155' },
      timeScale: { borderColor: '#334155', timeVisible: true },
      height: 420,
    });

    const series = chart.addCandlestickSeries({
      upColor: '#16a34a',
      downColor: '#dc2626',
      borderVisible: false,
      wickUpColor: '#16a34a',
      wickDownColor: '#dc2626',
    });

    series.setData(
      candles.map((c) => ({
        time: (new Date(c.window_start).getTime() / 1000) as UTCTimestamp,
        open: c.open,
        high: c.high,
        low: c.low,
        close: c.close,
      })),
    );
    chart.timeScale().fitContent();

    const onResize = () =>
      chart.applyOptions({ width: containerRef.current?.clientWidth ?? 800 });
    onResize();
    window.addEventListener('resize', onResize);

    return () => {
      window.removeEventListener('resize', onResize);
      chart.remove();
    };
  }, [candles]);

  return <div ref={containerRef} className="rounded-xl border border-slate-800 bg-slate-900/50" />;
}
