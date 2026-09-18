import type { Metadata } from 'next';
import './globals.css';

export const metadata: Metadata = {
  title: 'LiveFi — Real-Time Financial Dashboard',
  description: 'Streaming trades, OHLC candles, and portfolio risk.',
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en" className="dark">
      <body className="min-h-screen bg-slate-950 text-slate-100 antialiased">
        <header className="border-b border-slate-800 px-6 py-3">
          <h1 className="text-lg font-semibold tracking-tight">LiveFi</h1>
        </header>
        <main className="p-6">{children}</main>
      </body>
    </html>
  );
}
