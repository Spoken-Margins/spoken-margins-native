// The app's frame: Four tabs (Library, Following, Margins, Settings; Design/proposals/four-tabs.md), the
// mini player above the tab bar, and Now Playing over everything.
import { useCallback, useEffect, useState, type DragEvent, type ReactNode } from 'react';
import { DataProvider } from './data.tsx';
import { FollowingIcon, LibraryIcon, MarginsIcon, SettingsIcon } from './icons.tsx';
import { openFiles, useOpenMarginFile } from './import.tsx';
import { PlayerProvider } from './player.tsx';
import { Following } from './screens/Following.tsx';
import { Library } from './screens/Library.tsx';
import { Margins } from './screens/Margins.tsx';
import { MiniPlayer, NowPlaying } from './screens/NowPlaying.tsx';
import { Settings } from './screens/Settings.tsx';
import { useNativeOpenedFiles } from './native-files.ts';
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
  const [dropping, setDropping] = useState(false);

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
  const openMarginFile = useOpenMarginFile(openPlayer);
  useSharedFiles(openMarginFile);
  useNativeOpenedFiles(openMarginFile);

  // A `.spokenmargins` file dropped anywhere on the app opens like a picked one.
  const carriesFiles = (event: DragEvent) => Array.from(event.dataTransfer.types).includes('Files');
  const onDragOver = (event: DragEvent) => {
    if (!carriesFiles(event)) return;
    event.preventDefault();
    event.dataTransfer.dropEffect = 'copy';
    setDropping(true);
  };
  const onDrop = (event: DragEvent) => {
    if (!carriesFiles(event)) return;
    event.preventDefault();
    setDropping(false);
    void openFiles(Array.from(event.dataTransfer.files), openMarginFile);
  };

  return (
    <div
      className="app"
      onDragOver={onDragOver}
      onDragLeave={(event) => {
        // Once shown, the overlay covers the app, so a drag leaving it has left the window.
        if ((event.target as HTMLElement).classList.contains('drop-overlay')) setDropping(false);
      }}
      onDrop={onDrop}
    >
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
        {tab === 'margins' && <Margins onPlay={openPlayer} onOpenFile={openMarginFile} />}
        {tab === 'settings' && <Settings />}
      </main>
      {!nowPlaying && <MiniPlayer onOpen={openPlayer} />}
      {nowPlaying && <NowPlaying onClose={() => setNowPlaying(false)} />}
      {dropping && (
        <div className="drop-overlay" aria-hidden="true">
          <p>Drop a .spokenmargins file to open its Margins</p>
        </div>
      )}
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
