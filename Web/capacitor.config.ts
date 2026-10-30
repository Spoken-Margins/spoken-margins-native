// The Android wrapper (#2981): Capacitor serves the Vite build (`dist/`) inside an Android WebView.
//
// Feeds and pages are read with native HTTP through `src/sources/native-http.ts`, which calls CapacitorHttp
// explicitly. Patching the WebView's global `fetch` (`CapacitorHttp.enabled`) stays off, so nothing else in the app
// quietly changes transport, and native cookies stay off, so no read carries credentials.
import type { CapacitorConfig } from '@capacitor/cli';

const config: CapacitorConfig = {
  appId: 'com.spokenmargins.android',
  appName: 'Spoken Margins',
  webDir: 'dist',
  android: {
    allowMixedContent: false,
  },
  plugins: {
    CapacitorHttp: { enabled: false },
    CapacitorCookies: { enabled: false },
  },
};

export default config;
