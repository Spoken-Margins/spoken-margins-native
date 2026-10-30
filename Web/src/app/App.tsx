// The app's frame: Four tabs (Library, Following, Margins, Settings; Design/proposals/four-tabs.md), the
// mini player above the tab bar, and Now Playing over everything.
import { useCallback, useEffect, useState, type ReactNode } from 'react';
import { DataProvider } from './data.tsx';
import { FollowingIcon, LibraryIcon, MarginsIcon, SettingsIcon } from './icons.tsx';
import { PlayerProvider, usePlayer } from './player.tsx';
import { Following } from './screens/Following.tsx';
import { Library } from './screens/Library.tsx';
import { Margins } from './screens/Margins.tsx';
import { MiniPlayer, NowPlaying } from './screens/NowPlaying.tsx';
import { Settings } from './screens/Settings.tsx';
import { useSharedFiles } from './shared-files.ts';
import { UiProvider } from './ui.tsx';

type Tab = 'library' | 'following' | 'margins' | 'settings';
const TABS: Array<{ id: Tab; label: string; icon: () => ReactNode }> = [
  { id: 'library', label: 'Library', icon: LibraryIcon },
  { id: 'following', label: 'Following', icon: FollowingIcon },
  { id: 'margins', label: 'Margins', icon: MarginsIcon },
  { id: 'settings', label: 'Settings', icon: SettingsIcon },
];

function tabFromHash(): Tab {
  const id = window.location.hash.replace('#', '');
  return TABS.some((t) => t.id === id) ? (id as Tab) : 'library';
}

function Shell() {
  const [tab, setTabState] = useState<Tab>(tabFromHash);
  const [nowPlaying, setNowPlaying] = useState(false);
  const [followOpen, setFollowOpen] = useState(false);
  useSharedFiles();

  const setTab = useCallback((next: Tab) => {
    setTabState(next);
    if (window.location.hash !== `#${next}`) window.history.replaceState(null, '', `#${next}`);
  }, []);

  useEffect(() => {
    const onHash = () => setTabState(tabFromHash());
    window.addEventListener('hashchange', onHash);
    return () => window.removeEventListener('hashchange', onHash);
  }, []);

  const openPlayer = useCallback(() => setNowPlaying(true), []);

  // The tab's title names where the listener is, so a screen reader or the tab switcher can tell (WCAG 2.4.2).
  const player = usePlayer();
  const playingTitle = nowPlaying ? player.episode?.title : undefined;
  useEffect(() => {
    const label = TABS.find((t) => t.id === tab)?.label ?? 'Library';
    document.title = playingTitle ? `${playingTitle}, Now Playing · Spoken Margins` : `${label} · Spoken Margins`;
  }, [tab, playingTitle]);

  return (
    <div className="app">
      <nav className="tabbar" aria-label="Sections" inert={nowPlaying}>
        <span className="brand" aria-hidden="true">
          <img src="./icons/icon.svg" alt="" width="28" height="28" />
          Spoken Margins
        </span>
        {TABS.map(({ id, label, icon: TabIcon }) => (
          <button key={id} type="button" className="tab" aria-current={tab === id ? 'page' : undefined} onClick={() => setTab(id)}>
            <TabIcon />
            <span>{label}</span>
          </button>
        ))}
      </nav>
      <main className="content" inert={nowPlaying}>
        {tab === 'library' && (
          <Library
            onPlay={openPlayer}
            onFindShows={() => {
              setTab('following');
              setFollowOpen(true);
            }}
          />
        )}
        {tab === 'following' && <Following onPlay={openPlayer} followOpen={followOpen} setFollowOpen={setFollowOpen} />}
        {tab === 'margins' && <Margins onPlay={openPlayer} />}
        {tab === 'settings' && <Settings />}
      </main>
      {!nowPlaying && <MiniPlayer onOpen={openPlayer} />}
      {nowPlaying && <NowPlaying onClose={() => setNowPlaying(false)} />}
    </div>
  );
}

export function App() {
  return (
    <UiProvider>
      <DataProvider>
        <PlayerProvider>
          <Shell />
        </PlayerProvider>
      </DataProvider>
    </UiProvider>
  );
}
