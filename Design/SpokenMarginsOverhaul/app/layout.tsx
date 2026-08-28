import type { Metadata } from 'next';
import './globals.css';

export const metadata: Metadata = {
  title: 'Spoken Margins — Experience Overhaul',
  description: 'An interactive product and UX study for Spoken Margins.',
};

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return <html lang="en"><body>{children}</body></html>;
}
