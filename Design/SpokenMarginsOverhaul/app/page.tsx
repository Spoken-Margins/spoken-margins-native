'use client';

import { useState } from 'react';

type ScreenName =
  | 'library'
  | 'onboarding'
  | 'item'
  | 'player'
  | 'recording'
  | 'timeline'
  | 'add'
  | 'sources'
  | 'margins'
  | 'share'
  | 'storage';

const scenes: Array<{ id: ScreenName; label: string; group: string }> = [
  { id: 'library', label: 'Library', group: 'FIND' },
  { id: 'onboarding', label: 'First run', group: 'FIND' },
  { id: 'add', label: 'Add source', group: 'FIND' },
  { id: 'item', label: 'Item detail', group: 'FIND' },
  { id: 'player', label: 'Now playing', group: 'LISTEN' },
  { id: 'recording', label: 'Recording', group: 'LISTEN' },
  { id: 'timeline', label: 'Timeline', group: 'LISTEN' },
  { id: 'sources', label: 'Source inbox', group: 'RETURN' },
  { id: 'margins', label: 'Your margins', group: 'RETURN' },
  { id: 'share', label: 'Share preview', group: 'RETURN' },
  { id: 'storage', label: 'Offline storage', group: 'TRUST' },
];

const screenNotes: Record<ScreenName, { title: string; principle: string; protects: string }> = {
  library: {
    title: 'A library, not a queue of controls',
    principle: 'Resume is the highest-value action; destructive actions move out of the scan path.',
    protects: 'Recognition, large-library scanability, and continuity across formats.',
  },
  onboarding: {
    title: 'Teach by listening',
    principle: 'Two honest starter items demonstrate text speech and native audio as different things.',
    protects: 'Correct expectations, reversible dismissal, and route reuse.',
  },
  add: {
    title: 'Choose the source, then supply it',
    principle: 'A single intake router replaces the current mixed form, file, and folder surface.',
    protects: 'Error recovery and correct mental models for PDF, EPUB, audio, text, and links.',
  },
  item: {
    title: 'Source structure stays canonical',
    principle: 'Authored chapters, preparation state, sessions, and margins remain separate layers.',
    protects: 'Books, PDFs, podcasts, and audiobooks from being flattened into one generic item.',
  },
  player: {
    title: 'One listening cockpit',
    principle: 'Transport, time, chapter, preparation, and sleep state share one calm hierarchy.',
    protects: 'Canonical media time and truthful buffering/preparation feedback.',
  },
  recording: {
    title: 'Recording is a guarded mode',
    principle: 'The source anchor is visibly locked and every unrelated navigation target is inert.',
    protects: 'A thought in progress, the resume point, and the user’s sense of safety.',
  },
  timeline: {
    title: 'Provenance before decoration',
    principle: 'Source, my margin, another person, and AI each have color, shape, label, and voice.',
    protects: 'Authorship, reply lineage, accessible scanning, and exact source return.',
  },
  sources: {
    title: 'Following is not importing',
    principle: 'The inbox offers new entries; the listener deliberately adds each one to the library.',
    protects: 'Consent, storage budget, privacy, and attention.',
  },
  margins: {
    title: 'The user’s thinking becomes first-class',
    principle: 'Captured thoughts can be reviewed across sessions without pretending to be source text.',
    protects: 'Private capture, representation lifecycles, and later sharing choices.',
  },
  share: {
    title: 'Preview exactly what leaves',
    principle: 'A recipient view is the final step, with private representations excluded by default.',
    protects: 'Consent, provenance, rights boundaries, and cancellation safety.',
  },
  storage: {
    title: 'Offline means accounted for',
    principle: 'One budget distinguishes reproducible media from recordings that should not be evicted.',
    protects: 'Device space, irreplaceable work, and honest automation.',
  },
};

const libraryRows = [
  { type: 'ESSAY · 18 MIN', title: 'The Shape of Attention', author: 'Maya Chen', tone: 'sage', state: 'Ready offline' },
  { type: 'PODCAST · 54 MIN', title: 'How Memory Finds a Place', author: 'Field Notes', tone: 'ochre', state: '24% listened' },
  { type: 'EPUB · 7 HR', title: 'Ways of Seeing Clearly', author: 'Jonah Bell', tone: 'clay', state: 'Preparing ch. 2' },
];

function TopBar({ back, title, action, onBack }: { back?: boolean; title?: string; action?: string; onBack?: () => void }) {
  return (
    <header className="topbar">
      {back ? <button className="icon ghost" aria-label="Go back" onClick={onBack}>←</button> : <span className="topbar-spacer" />}
      {title && <strong>{title}</strong>}
      {action ? <button className="text-action">{action}</button> : <span className="topbar-spacer" />}
    </header>
  );
}

function BottomTabs({ current, go }: { current: 'library' | 'sources' | 'margins'; go: (screen: ScreenName) => void }) {
  return (
    <nav className="tabbar" aria-label="Primary navigation">
      <button className={current === 'library' ? 'active' : ''} onClick={() => go('library')}><b>▤</b><span>Library</span></button>
      <button className={current === 'sources' ? 'active' : ''} onClick={() => go('sources')}><b>◉</b><span>Sources</span></button>
      <button className={current === 'margins' ? 'active' : ''} onClick={() => go('margins')}><b>✦</b><span>Margins</span></button>
    </nav>
  );
}

function MiniPlayer({ go }: { go: (screen: ScreenName) => void }) {
  return (
    <button className="mini-player" onClick={() => go('player')} aria-label="Open Now Playing">
      <span className="mini-art" />
      <span className="mini-copy"><small>NOW PLAYING</small><strong>How Memory Finds a Place</strong></span>
      <span className="mini-control" aria-hidden="true">Ⅱ</span>
    </button>
  );
}

function Library({ go }: { go: (screen: ScreenName) => void }) {
  return (
    <div className="screen root-screen">
      <div className="phone-scroll library-scroll">
        <div className="app-head">
          <button className="profile" aria-label="Open settings" onClick={() => go('storage')}>CM</button>
          <button className="round" aria-label="Add a source" onClick={() => go('add')}>＋</button>
        </div>
        <div className="overline">GOOD EVENING</div><h2 className="page-title">Your library</h2>
        <label className="search"><span>⌕</span><input aria-label="Search library" placeholder="Titles, authors, and shows" /><button aria-label="Filters">⌁</button></label>
        <div className="filter-row" aria-label="Library filters"><button className="chip selected">All</button><button className="chip">In progress</button><button className="chip">Offline</button></div>
        <div className="section-label"><span>CONTINUE LISTENING</span><button onClick={() => go('player')}>See session</button></div>
        <button className="hero-card" onClick={() => go('player')}>
          <span className="cover cover-main"><i>FIELD<br />NOTES</i></span>
          <span className="hero-copy">
            <small>PODCAST</small><strong>How Memory Finds a Place</strong><span>Field Notes · Chapter 3</span>
            <span className="progress"><i style={{ width: '54%' }} /></span>
            <span className="resume-row"><span>24 min left</span><b>▶</b></span>
          </span>
        </button>
        <div className="section-label"><span>RECENTLY ADDED</span><button>Recently added⌄</button></div>
        <div className="library-list">
          {libraryRows.map((book, index) => (
            <button className="library-row" key={book.title} onClick={() => index === 2 ? go('item') : go('player')}>
              <span className={`cover small ${book.tone}`} aria-hidden="true" />
              <span className="row-copy"><small>{book.type}</small><strong>{book.title}</strong><span>{book.author} · {book.state}</span></span>
              <span className="chevron">›</span>
            </button>
          ))}
        </div>
      </div>
      <MiniPlayer go={go} />
      <BottomTabs current="library" go={go} />
    </div>
  );
}

function Onboarding({ go }: { go: (screen: ScreenName) => void }) {
  return (
    <div className="screen paper-screen">
      <TopBar back title="Getting started" action="Skip" onBack={() => go('library')} />
      <div className="phone-scroll padded under-topbar">
        <div className="onboarding-mark"><span>≈</span></div>
        <div className="center-copy"><small>LISTEN YOUR WAY IN</small><h2>Meet Spoken Margins by ear.</h2><p>Start with either format. Both use the same player, timeline, and margin tools.</p></div>
        <button className="starter-card dark" onClick={() => go('player')}>
          <span className="starter-icon">▶</span><span><small>NATIVE AUDIO · 8 MIN</small><strong>A guided tour of Spoken Margins</strong><em>Includes actions for every way to add a source.</em></span><b>›</b>
        </button>
        <button className="starter-card light" onClick={() => go('item')}>
          <span className="starter-icon">Aa</span><span><small>ON-DEVICE VOICE · 6 MIN</small><strong>Welcome to Spoken Margins</strong><em>Learn chapters, playback, and anchored notes.</em></span><b>›</b>
        </button>
        <div className="route-card">
          <small>TRY IT WITH YOUR OWN SOURCE</small>
          <div className="route-links"><button onClick={() => go('add')}>Add a podcast</button><button onClick={() => go('add')}>Import a PDF</button><button onClick={() => go('add')}>Open a book</button></div>
        </div>
        <p className="microcopy center">The tour can update without reinstalling. Dismissing it is permanent unless you restore it in Settings.</p>
      </div>
    </div>
  );
}

function AddSource({ go }: { go: (screen: ScreenName) => void }) {
  const [method, setMethod] = useState('link');
  return (
    <div className="screen paper-screen">
      <TopBar back title="Add to library" onBack={() => go('library')} />
      <div className="phone-scroll padded under-topbar add-scroll">
        <div className="overline">CHOOSE A SOURCE</div><h2 className="page-title compact">What would you like to hear?</h2>
        <div className="method-grid">
          {[
            ['link', '↗', 'Web or podcast', 'Paste any public link'],
            ['text', '¶', 'Paste text', 'Notes or an excerpt'],
            ['document', '▧', 'Document or book', 'PDF, EPUB, Markdown'],
            ['audio', '♪', 'Audiobook file', 'MP3, M4A, M4B, MP4'],
          ].map(([id, icon, title, description]) => <button key={id} className={method === id ? 'method selected' : 'method'} onClick={() => setMethod(id)}><b>{icon}</b><strong>{title}</strong><span>{description}</span></button>)}
        </div>
        <div className="intake-card">
          <small>{method === 'link' ? 'PASTE A PUBLIC LINK' : method === 'text' ? 'PASTE YOUR TEXT' : method === 'document' ? 'CHOOSE ONE FILE' : 'CHOOSE ONE AUDIO FILE'}</small>
          {method === 'link' && <><label className="large-input"><span>↗</span><input aria-label="Source link" placeholder="Podcast, article, RSS, or audio URL" /></label><button className="primary wide" onClick={() => go('item')}>Review source</button></>}
          {method === 'text' && <><label className="large-input"><textarea aria-label="Text to import" placeholder="Paste text here…" /></label><button className="primary wide" onClick={() => go('item')}>Add text</button></>}
          {(method === 'document' || method === 'audio') && <><button className="file-drop" onClick={() => go('item')}><b>{method === 'audio' ? '♪' : '⇧'}</b><strong>Choose from Files</strong><span>Copied into Spoken Margins for reliable offline use</span></button></>}
        </div>
        <div className="share-tip"><b>□↑</b><span><strong>From another app?</strong><small>Use Share → Spoken Margins. It arrives here for review before import.</small></span></div>
        <p className="microcopy">Imports never interrupt what is already playing. Protected books and audio are rejected without leaving partial items.</p>
      </div>
    </div>
  );
}

function ItemDetail({ go }: { go: (screen: ScreenName) => void }) {
  return (
    <div className="screen paper-screen">
      <TopBar back action="•••" onBack={() => go('library')} />
      <div className="phone-scroll under-topbar item-scroll">
        <div className="item-hero">
          <div className="book-cover"><small>JONAH BELL</small><strong>Ways of<br />Seeing<br />Clearly</strong><i>FIELD EDITION</i></div>
          <div className="book-meta"><small>EPUB · 7 HR 12 MIN</small><h2>Ways of Seeing Clearly</h2><p>Jonah Bell</p><div className="status-line"><span>◉</span> Preparing chapter 2 · 41%</div></div>
        </div>
        <div className="item-actions"><button className="primary" onClick={() => go('player')}>▶ Continue</button><button className="secondary">⇩ Prepare</button></div>
        <div className="confidence-note"><b>Available now</b><span>Chapter 1 and the next 38 minutes are ready. Preparation continues while you listen.</span></div>
        <div className="segmented"><button className="active">Chapters</button><button>Sessions</button><button>Details</button></div>
        <div className="chapter-list">
          <button onClick={() => go('player')}><span className="chapter-num">01</span><span><strong>Orientation</strong><small>42 min · Ready offline</small></span><b>▶</b></button>
          <button onClick={() => go('player')}><span className="chapter-num active">02</span><span><strong>The Useful Blur</strong><small>56 min · 41% prepared</small><i className="tiny-progress"><i style={{ width: '41%' }} /></i></span><b>▶</b></button>
          <button><span className="chapter-num">03</span><span><strong>Edges and Exceptions</strong><small>48 min · Next</small></span><b>○</b></button>
          <button><span className="chapter-num">04</span><span><strong>A Practice of Return</strong><small>1 hr 6 min</small></span><b>○</b></button>
        </div>
      </div>
    </div>
  );
}

function Player({ go }: { go: (screen: ScreenName) => void }) {
  const [playing, setPlaying] = useState(true);
  return (
    <div className="screen player-screen">
      <TopBar back title="Now Playing" action="•••" onBack={() => go('library')} />
      <div className="phone-scroll player-scroll under-topbar">
        <div className="player-art"><span>FIELD</span><i>NOTES</i><b>03</b></div>
        <div className="player-title"><small>FIELD NOTES</small><h2>How Memory Finds a Place</h2><p>Chapter 3 · Rooms we can return to</p></div>
        <div className="time-control">
          <div className="time-track"><i className="buffered" style={{ width: '72%' }} /><i className="played" style={{ width: '54%' }} /><b style={{ left: '54%' }} /></div>
          <div><span>28:41</span><span>−24:19</span></div>
        </div>
        <div className="transport">
          <button aria-label="Back 15 seconds"><small>15</small>↶</button>
          <button className="play" aria-label={playing ? 'Pause' : 'Play'} onClick={() => setPlaying(!playing)}>{playing ? 'Ⅱ' : '▶'}</button>
          <button aria-label="Forward 30 seconds">↷<small>30</small></button>
        </div>
        <div className="player-options"><button>1.5×<span>Speed</span></button><button>◷ 28m<span>Sleep</span></button><button>⇩ Ready<span>Offline</span></button></div>
        <button className="interject" onClick={() => go('recording')}><span>●</span><strong>Interject</strong><small>Capture a thought at 28:41</small></button>
        <div className="player-lower">
          <button onClick={() => go('timeline')}><span>≡</span><strong>Timeline</strong><small>3 chapters · 2 margins</small><b>›</b></button>
          <button onClick={() => go('sources')}><span>＋</span><strong>Follow Field Notes?</strong><small>Offer shown after meaningful engagement</small><b>›</b></button>
        </div>
      </div>
    </div>
  );
}

function Recording({ go }: { go: (screen: ScreenName) => void }) {
  const bars = [25,42,65,34,80,56,31,72,88,47,62,29,76,53,37,68,83,45,64,32,51,74,41,58];
  return (
    <div className="screen recording-screen">
      <div className="record-top"><button onClick={() => go('player')}>Cancel</button><span>RECORDING</span><span /></div>
      <div className="record-body">
        <div className="anchor-lock"><b>◆</b><span><small>SOURCE ANCHOR LOCKED</small><strong>28:41 · Rooms we can return to</strong></span></div>
        <div className="record-orb"><i /><b>00:18</b></div>
        <div className="record-copy"><small>YOUR MARGIN</small><h2>Say what this moment brings up.</h2><p>Playback is paused. Timeline and source navigation stay locked until you finish or cancel.</p></div>
        <div className="waveform" aria-hidden="true">{bars.map((height, index) => <i key={index} style={{ height }} />)}</div>
        <button className="finish-recording" onClick={() => go('timeline')}><b>■</b><span><strong>Finish margin</strong><small>Save and return with context</small></span></button>
        <div className="record-safety"><span>Anchor</span><i /><span>Recording</span><i /><span>Resume</span></div>
      </div>
    </div>
  );
}

function Timeline({ go }: { go: (screen: ScreenName) => void }) {
  return (
    <div className="screen paper-screen timeline-screen">
      <TopBar back title="Timeline" action="View ▾" onBack={() => go('player')} />
      <div className="phone-scroll under-topbar timeline-scroll">
        <div className="timeline-head"><small>HOW MEMORY FINDS A PLACE</small><h2>Chapter 3</h2><p>Follow the source spine, or trace a conversation through its margins.</p></div>
        <div className="legend"><span><i className="source" />Source</span><span><i className="mine" />Mine</span><span><i className="other" />Avery</span><span><i className="ai" />AI</span></div>
        <div className="timeline-rail">
          <button className="timeline-entry source-entry" onClick={() => go('player')}><i /><span><small>SOURCE · 24:12</small><strong>Rooms we can return to</strong><em>Why remembered places preserve more than layout.</em></span><b>▶</b></button>
          <article className="timeline-entry mine-entry"><i /><span><small>MY MARGIN · 28:41</small><strong>“Maybe memory needs friction…”</strong><em>Clean transcript ready · 0:34</em><button onClick={() => go('share')}>Review & share</button></span><b>✦</b></article>
          <article className="timeline-entry other-entry"><i /><span><small>AVERY’S MARGIN · REPLY</small><strong>“I think the friction is social, too.”</strong><em>Imported layer · verified package</em></span><b>↳</b></article>
          <button className="timeline-entry source-entry" onClick={() => go('player')}><i /><span><small>SOURCE · 31:06</small><strong>Memory as a shared room</strong><em>Continue source playback from this exact point.</em></span><b>▶</b></button>
          <article className="timeline-entry ai-entry"><i /><span><small>ON-DEVICE SUMMARY</small><strong>Two ideas you returned to</strong><em>Generated from 2 selected margins</em></span><b>✣</b></article>
        </div>
      </div>
    </div>
  );
}

function Sources({ go }: { go: (screen: ScreenName) => void }) {
  return (
    <div className="screen root-screen">
      <div className="phone-scroll sources-scroll">
        <div className="app-head"><button className="profile" onClick={() => go('storage')}>CM</button><button className="icon paper" aria-label="Refresh sources">↻</button></div>
        <div className="overline">FOLLOWED SOURCES</div><h2 className="page-title">New for you</h2>
        <div className="consent-banner"><span>○</span><p><strong>Nothing downloads automatically.</strong> Following only brings new entries here for you to choose.</p></div>
        <div className="source-chips"><button className="active"><i className="source-avatar field" />All <b>6</b></button><button><i className="source-avatar aeon" />Aeon</button><button><i className="source-avatar field" />Field Notes</button></div>
        <div className="date-label">TODAY</div>
        <article className="inbox-card"><div className="inbox-art green-art"><span>AEON</span></div><div className="inbox-copy"><small>AEON · ARTICLE · 22 MIN</small><h3>The intelligence of detours</h3><p>A field guide to productive wandering.</p><div><button className="primary small-button">＋ Add</button><button className="text-button">Dismiss</button></div></div></article>
        <article className="inbox-card"><div className="inbox-art gold-art"><span>FN</span></div><div className="inbox-copy"><small>FIELD NOTES · PODCAST · 46 MIN</small><h3>When a map becomes a memory</h3><p>Released this morning.</p><div><button className="primary small-button">＋ Add</button><button className="text-button">Dismiss</button></div></div></article>
        <div className="date-label">EARLIER</div>
        <article className="inbox-card compact-card"><div className="inbox-art clay-art"><span>R</span></div><div className="inbox-copy"><small>THE READER · ESSAY</small><h3>Notes from the edge of sleep</h3><p>Seen yesterday</p></div><button className="chevron">›</button></article>
      </div>
      <MiniPlayer go={go} />
      <BottomTabs current="sources" go={go} />
    </div>
  );
}

function Margins({ go }: { go: (screen: ScreenName) => void }) {
  return (
    <div className="screen root-screen">
      <div className="phone-scroll margins-scroll">
        <div className="app-head"><button className="profile" onClick={() => go('storage')}>CM</button><button className="icon paper" aria-label="Search margins">⌕</button></div>
        <div className="overline">YOUR THINKING</div><h2 className="page-title">Margins</h2>
        <div className="margin-summary"><div><strong>14</strong><span>This month</span></div><div><strong>5</strong><span>Ready to review</span></div><div><strong>2</strong><span>Shared layers</span></div></div>
        <div className="filter-row"><button className="chip selected">All</button><button className="chip">Mine</button><button className="chip">With others</button></div>
        <div className="section-label"><span>RECENT</span><button>Newest⌄</button></div>
        <article className="margin-group"><div className="group-head"><div className="tiny-cover gold-art">FN</div><span><small>HOW MEMORY FINDS A PLACE</small><strong>Field Notes</strong></span><b>2</b></div><button className="margin-quote" onClick={() => go('timeline')}><i className="provenance mine">✦</i><span><small>MY MARGIN · TODAY, 9:42 PM</small><strong>“Maybe memory needs friction before it becomes a place.”</strong><em>Clean transcript · 28:41</em></span><b>›</b></button><button className="margin-quote" onClick={() => go('timeline')}><i className="provenance other">A</i><span><small>AVERY’S REPLY · SHARED LAYER</small><strong>“I think the friction is social, too.”</strong><em>Verified package · unread</em></span><b>›</b></button></article>
        <article className="margin-group"><div className="group-head"><div className="tiny-cover green-art">A</div><span><small>THE SHAPE OF ATTENTION</small><strong>Maya Chen</strong></span><b>1</b></div><button className="margin-quote" onClick={() => go('share')}><i className="provenance mine">✦</i><span><small>MY MARGIN · MONDAY</small><strong>“Attention isn’t a spotlight; it’s a negotiated border.”</strong><em>Raw audio retained · clean text ready</em></span><b>›</b></button></article>
      </div>
      <MiniPlayer go={go} />
      <BottomTabs current="margins" go={go} />
    </div>
  );
}

function SharePreview({ go }: { go: (screen: ScreenName) => void }) {
  const [audio, setAudio] = useState(false);
  const [context, setContext] = useState(true);
  return (
    <div className="screen share-screen">
      <TopBar back title="Recipient preview" onBack={() => go('timeline')} />
      <div className="phone-scroll padded under-topbar share-scroll">
        <div className="stepper"><span className="done" /><i /><span className="done" /><i /><span className="active" /></div>
        <div className="center-copy share-heading"><small>STEP 3 OF 3</small><h2>This is exactly what will leave your device.</h2></div>
        <article className="recipient-card">
          <div className="recipient-head"><span className="avatar">CM</span><span><strong>Cole’s margin</strong><small>on Field Notes</small></span><i>UNSIGNED</i></div>
          <div className="source-context"><small>HOW MEMORY FINDS A PLACE · 28:41</small><p>“…the rooms that persist are rarely the rooms we saw most clearly…”</p></div>
          <blockquote>Maybe memory needs friction before it becomes a place.</blockquote>
          <div className="provenance-note"><b>✦</b><span><strong>Cleaned from your recording</strong><small>Fillers removed. Meaning not materially rewritten.</small></span></div>
        </article>
        <div className="share-options">
          <label><span><strong>Bounded source context</strong><small>1 sentence before and after</small></span><input type="checkbox" checked={context} onChange={() => setContext(!context)} /></label>
          <label><span><strong>Original audio</strong><small>Private unless you include it</small></span><input type="checkbox" checked={audio} onChange={() => setAudio(!audio)} /></label>
        </div>
        <div className="excluded"><small>STAYS PRIVATE</small><p>Raw transcript · session history · other margins · diagnostics · source file</p></div>
        <button className="primary wide share-button">□↑ Share reviewed margin</button>
        <p className="microcopy center">Cancelling or a failed destination leaves your local margin unchanged.</p>
      </div>
    </div>
  );
}

function Storage({ go }: { go: (screen: ScreenName) => void }) {
  return (
    <div className="screen paper-screen">
      <TopBar back title="Offline & preparation" onBack={() => go('library')} />
      <div className="phone-scroll padded under-topbar storage-scroll">
        <div className="storage-total"><div className="storage-ring"><span><strong>3.2</strong><small>of 5 GB</small></span></div><div><small>OFFLINE STORAGE</small><h2>Ready when the network isn’t.</h2><p>1.8 GB remains under your limit.</p></div></div>
        <div className="storage-bar"><i className="podcasts" style={{ width: '34%' }} /><i className="books" style={{ width: '21%' }} /><i className="records" style={{ width: '9%' }} /></div>
        <div className="storage-key"><span><i className="podcasts" />Podcasts <b>1.7 GB</b></span><span><i className="books" />Prepared text <b>1.1 GB</b></span><span><i className="records" />Recordings <b>0.4 GB</b></span></div>
        <button className="budget-row"><span><strong>Storage limit</strong><small>Bounds all app-owned offline media</small></span><b>5 GB ›</b></button>
        <div className="setting-section"><small>AUTOMATIC AUDIO PREPARATION</small><label className="setting-row"><span><strong>While charging</strong><small>Continue eligible books and articles when iOS allows.</small></span><input type="checkbox" defaultChecked /></label><div className="setting-note"><b>◷</b><span><strong>Best effort, not overnight guaranteed</strong><small>Paused by Low Power Mode, heat, low storage, or your Stop action.</small></span></div></div>
        <div className="setting-section"><small>SAFE CLEAR ACTIONS</small><button className="clear-row"><span><strong>Clear reproducible media</strong><small>Source items and your recordings stay.</small></span><b>1.3 GB ›</b></button><button className="clear-row protected"><span><strong>Protected user recordings</strong><small>Never treated as ordinary cache.</small></span><b>412 MB</b></button></div>
      </div>
    </div>
  );
}

function Phone({ screen, go }: { screen: ScreenName; go: (screen: ScreenName) => void }) {
  return (
    <section className="phone" aria-label={`Spoken Margins ${screen} prototype`}>
      <div className="phone-status"><span>9:41</span><span>▮▮ ◒ ϟ</span></div>
      {screen === 'library' && <Library go={go} />}
      {screen === 'onboarding' && <Onboarding go={go} />}
      {screen === 'add' && <AddSource go={go} />}
      {screen === 'item' && <ItemDetail go={go} />}
      {screen === 'player' && <Player go={go} />}
      {screen === 'recording' && <Recording go={go} />}
      {screen === 'timeline' && <Timeline go={go} />}
      {screen === 'sources' && <Sources go={go} />}
      {screen === 'margins' && <Margins go={go} />}
      {screen === 'share' && <SharePreview go={go} />}
      {screen === 'storage' && <Storage go={go} />}
    </section>
  );
}

export default function Home() {
  const [screen, setScreen] = useState<ScreenName>('library');
  const note = screenNotes[screen];
  return (
    <main className="showroom">
      <aside className="studio-panel">
        <div className="studio-brand"><div className="brand-mark">≈</div><div><small>CONCEPT 01 · AUG 2026</small><strong>Spoken Margins</strong></div></div>
        <div className="studio-intro"><div className="eyebrow">EXPERIENCE OVERHAUL</div><h1>A quiet place to listen, think, and return.</h1><p>Explore a proposed product system grounded in the current app, active release lanes, and planned sharing foundation.</p></div>
        <div className="scene-picker" aria-label="Prototype scenes">
          {['FIND', 'LISTEN', 'RETURN', 'TRUST'].map(group => <div className="scene-group" key={group}><small>{group}</small><div>{scenes.filter(scene => scene.group === group).map(scene => <button className={screen === scene.id ? 'active' : ''} key={scene.id} onClick={() => setScreen(scene.id)}>{scene.label}<span>↗</span></button>)}</div></div>)}
        </div>
        <article className="design-note"><small>DESIGN INTENT</small><h2>{note.title}</h2><p>{note.principle}</p><div><span>PROTECTS</span><strong>{note.protects}</strong></div></article>
        <div className="studio-footer"><span>Warm editorial / native interaction</span><span>iPhone-first · iPad-aware</span></div>
      </aside>
      <Phone screen={screen} go={setScreen} />
    </main>
  );
}
