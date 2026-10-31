import { createRoot } from 'react-dom/client';
import { App } from './App.tsx';
import { takeLaunchLink } from './launch-link.ts';
import './styles.css';

const launchLink = takeLaunchLink();
const root = document.getElementById('root');
if (root) createRoot(root).render(<App launchLink={launchLink} />);

// The service worker exists only in a build (`npm run build`); the dev server never registers one, so
// development always sees fresh files.
if (import.meta.env.PROD && 'serviceWorker' in navigator) {
  window.addEventListener('load', () => {
    navigator.serviceWorker.register('./sw.js').catch((error: unknown) => console.warn('Service worker not registered', error));
  });
}
