// The app's frame: Four tabs (Library, Following, Margins, Settings; Design/proposals/four-tabs.md), the
// mini player above the tab bar, and Now Playing over everything.
import { useCallback, useEffect, useState, type DragEvent, type ReactNode } from 'react';
import { DataProvider } from './data.tsx';
import { FollowingIcon, LibraryIcon, MarginsIcon, SettingsIcon } from './icons.tsx';
import { openFileBytes, openFiles, useOpenMarginFile, useOpenShareLink, type OpenMarginFile } from './import.tsx';
import type { Landing } from './logic/import.ts';
import type { ParsedLink } from './logic/share-link.ts';
import { PlayerProvider, usePlayer } from './player.tsx';
import { FeedRefreshProvider } from './refresh.tsx';
import { Arrival } from './screens/Arrival.tsx';
import { ArrivalListen } from './screens/ArrivalListen.tsx';
import { showIphoneStep } from './logic/arrival-card.ts';
import type { PacketRead } from './ports.ts';
import { capacitorBridge } from '../sources/native-http.ts';
import { useData } from './data.tsx';
import { Following } from './screens/Following.tsx';
import { Library } from './screens/Library.tsx';
import { Margins } from './screens/Margins.tsx';
import { MiniPlayer, NowPlaying } from './screens/NowPlaying.tsx';
import { Settings } from './screens/Settings.tsx';
import { useNativeOpenedFiles } from './native-files.ts';
import { useLaunchedFiles, useSharedFiles } from './shared-files.ts';
import { SearchProvider, useClearSearches } from './search.tsx';
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

function Shell({ launchLink }: { launchLink: ParsedLink }) {
  const [tab, setTabState] = useState<Tab>(tabFromHash);
  const [nowPlaying, setNowPlaying] = useState(false);
  const [followOpen, setFollowOpen] = useState(false);
  // The name a Following search found nothing for, which the Follow sheet opens looking for.
  const [followQuery, setFollowQuery] = useState<string>();
  const [dropping, setDropping] = useState(false);
  // Where the last opened file left the listener, so Now Playing can offer to start there (#3039).
  const [landing, setLanding] = useState<Landing>();

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
  const clearSearches = useClearSearches();
  const landed = useCallback((at: Landing) => {
    // Something new came in: an old search must not hide it once Now Playing closes.
    clearSearches();
    setLanding(at);
    setNowPlaying(true);
  }, [clearSearches]);
  // A file of Margins on a text the web app can't play opens the card that plays them here (#5265).
  const [listening, setListening] = useState<PacketRead>();
  const openMarginFile = useOpenMarginFile(landed, setListening);
  const data = useData();
  // Every way a file arrives goes through the same unpacking, so a backup `.zip` shared to the installed app, or
  // opened with the Android app, opens its packets as a picked one does.
  const openArrivedFile = useCallback<OpenMarginFile>((bytes, fileName) => openFileBytes(bytes, fileName, openMarginFile), [openMarginFile]);
  useSharedFiles(openArrivedFile);
  useNativeOpenedFiles(openArrivedFile);
  useLaunchedFiles(openMarginFile);
  const openShareLink = useOpenShareLink(landed);
  // A page opened at a share link starts on the arrival page, not in the app (#2168).
  const [arriving, setArriving] = useState(launchLink.kind !== 'none');
  const arrived = useCallback((playing: boolean) => {
    setArriving(false);
    if (playing) setNowPlaying(true);
    else setTabState('library');
  }, []);

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

  // The tab's title names where the listener is, so a screen reader or the tab switcher can tell (WCAG 2.4.2).
  const player = usePlayer();
  // Now Playing shows only when there is an episode for it to show. A tap on a post whose voice isn't found, a paid post,
  // a refused relay or a dead page opens nothing, and then the page behind must stay usable: Now Playing makes the tabs
  // and the content inert, so one that drew nothing would freeze the whole page (#4433). Asked for while the voice is
  // being looked up, it shows when the episode arrives; asked for and nothing came, the request is dropped.
  const nowPlayingShown = nowPlaying && player.episode !== undefined;
  useEffect(() => {
    if (nowPlaying && player.episode === undefined && !player.loading) setNowPlaying(false);
  }, [nowPlaying, player.episode, player.loading]);
  const playingTitle = nowPlayingShown ? player.episode?.title : undefined;
  useEffect(() => {
    if (arriving) return;
    const label = TABS.find((t) => t.id === tab)?.label ?? 'Library';
    document.title = playingTitle ? `${playingTitle}, Now Playing · Spoken Margins` : `${label} · Spoken Margins`;
  }, [tab, playingTitle, arriving]);

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
      <nav className="tabbar" aria-label="Sections" inert={nowPlayingShown || arriving || listening !== undefined}>
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
      <main className="content" inert={nowPlayingShown || arriving || listening !== undefined}>
        {tab === 'library' && (
          <Library
            onPlay={openPlayer}
            onOpenFile={openMarginFile}
            onFindShows={() => {
              setTab('following');
              setFollowOpen(true);
            }}
            onGoFollowing={() => setTab('following')}
          />
        )}
        {tab === 'following' && (
          <Following
            onPlay={openPlayer}
            followOpen={followOpen}
            setFollowOpen={(open) => {
              setFollowOpen(open);
              // Every way the sheet closes passes here, so a later "Follow a show" opens with an empty field.
              if (!open) setFollowQuery(undefined);
            }}
            followQuery={followQuery}
            onLookFor={(query) => {
              setFollowQuery(query);
              setFollowOpen(true);
            }}
          />
        )}
        {tab === 'margins' && <Margins onPlay={openPlayer} onOpenFile={openMarginFile} onOpenLink={openShareLink} />}
        {tab === 'settings' && <Settings />}
      </main>
      {!nowPlayingShown && !arriving && !listening && <MiniPlayer onOpen={openPlayer} />}
      {arriving && <Arrival link={launchLink} onDone={arrived} />}
      {listening && !arriving && (
        <ArrivalListen
          key={listening.contentDigest}
          read={listening}
          origin="file"
          iphoneStep={showIphoneStep(capacitorBridge() !== undefined, navigator.userAgent)}
          libraryFirst
          heardBefore={new Set()}
          setHeard={data.setHeard}
          onLibrary={() => {
            setListening(undefined);
            setTab('library');
          }}
        />
      )}
      {nowPlayingShown && (
        <NowPlaying
          landing={landing}
          onClose={() => {
            setNowPlaying(false);
            setLanding(undefined);
          }}
        />
      )}
      {dropping && (
        <div className="drop-overlay" aria-hidden="true">
          <p>Drop a .spokenmargins file to open its Margins</p>
        </div>
      )}
    </div>
  );
}

export function App({ launchLink = { kind: 'none' } }: { launchLink?: ParsedLink }) {
  return (
    <UiProvider>
      <DataProvider>
        <FeedRefreshProvider>
          <SearchProvider>
            <PlayerProvider>
              <Shell launchLink={launchLink} />
            </PlayerProvider>
          </SearchProvider>
        </FeedRefreshProvider>
      </DataProvider>
    </UiProvider>
  );
}
