import { useState } from 'react';
import { useData } from '../data.tsx';
import { downloadFile } from '../download.ts';
import { DownloadIcon } from '../icons.tsx';
import { backupSummary, buildBackup } from '../logic/backup.ts';
import { plainError } from '../logic/messages.ts';
import { lastBackupLine, persistNote } from '../logic/storage.ts';
import { services } from '../services.ts';
import { RELAY_BODY, useUi } from '../ui.tsx';

export function Settings() {
  const { settings, setSetting } = useData();
  const on = settings.relayAllowed;
  return (
    <div className="screen">
      <header className="screen-header">
        <h1 id="settings-title" tabIndex={-1}>
          Settings
        </h1>
      </header>

      {/* The control comes first and the long explanation folds away: a short screen to scan, with the
          full text one tap down. Sections aren't labelled regions, so the screen adds no landmarks. */}
      <section className="settings-section">
        <h2>Reading feeds through our server</h2>
        <label className="switch-row">
          <span>
            <span className="switch-label">Use the server for feeds that need it</span>
            {/* Out of the switch's name (its role already says on or off) and read as its description. */}
            <span id="relay-state" className="switch-state" data-state={on ? 'on' : 'off'} aria-hidden="true">
              {on ? 'On' : settings.relayAsked ? 'Off' : 'Off, you’ll be asked the first time a feed needs it'}
            </span>
          </span>
          <input
            type="checkbox"
            role="switch"
            className="switch"
            checked={on}
            aria-describedby="relay-state"
            onChange={(event) => {
              void setSetting('relayAllowed', event.target.checked);
              void setSetting('relayAsked', true);
            }}
          />
        </label>
        <p>Only for feeds your browser can’t read. The server keeps nothing.</p>
        <details className="more">
          <summary>How this works</summary>
          <p>{RELAY_BODY}</p>
          <p>Feeds your browser can read directly never go through the server.</p>
        </details>
      </section>

      <BackupSection />

      <section className="settings-section">
        <h2>Privacy</h2>
        <p>Your shows, your place in each episode and your Margins stay in this browser. Nothing is sent to us, and there is no account.</p>
        <details className="more">
          <summary>More about privacy</summary>
          <p>Clearing this site’s data in your browser removes them.</p>
          <p>Episodes play straight from each show’s own host, which sees the request as it would from any podcast app.</p>
          <p>The microphone is used only while you record a voice Margin.</p>
        </details>
      </section>

      <section className="settings-section">
        <h2>About Spoken Margins</h2>
        <p>
          Listen to podcasts and Substack posts in their own voices, and leave written or spoken Margins at the moment they belong. Margins travel as
          .spokenmargins files, which the Spoken Margins iPhone app opens.
        </p>
        <p className="muted">Web app, early version. Source code under AGPL-3.0.</p>
      </section>
    </div>
  );
}

/**
 * Backing up (#3012). Margins live only in this browser, which may clear them, so one tap saves all of them in
 * files the iPhone app and this web app open. Says when that last happened, and, quietly, when the browser
 * hasn't agreed to keep them.
 */
function BackupSection() {
  const data = useData();
  const { toast } = useUi();
  const [busy, setBusy] = useState(false);
  const note = persistNote(data.persist, data.settings.persistAsked);
  const count = data.margins.length;

  const backUp = async () => {
    setBusy(true);
    try {
      const result = await buildBackup(data, (episode, margins, show) => services.packets.writePacket(episode, margins, show));
      if (result.file) {
        downloadFile(new File([result.file.bytes as BlobPart], result.file.name, { type: result.file.mimeType }));
        await data.setSetting('lastBackupAt', new Date().toISOString());
      }
      const summary = backupSummary(result, (error) => plainError(error));
      toast(summary.text, summary.problem ? 'problem' : 'info');
    } catch (error) {
      toast(`Your Margins weren’t backed up. ${plainError(error)}`, 'problem');
    } finally {
      setBusy(false);
    }
  };

  return (
    <section className="settings-section" aria-labelledby="backup-title">
      <h2 id="backup-title">Backing up your Margins</h2>
      <p>Your Margins are kept only in this browser. A backup saves all of them as a file that the iPhone app and this web app open.</p>
      {note && (
        <p className="storage-note" data-testid="storage-note">
          {note}
        </p>
      )}
      <p data-testid="last-backup">{lastBackupLine(data.settings.lastBackupAt || undefined)}</p>
      <button type="button" className="button backup-button" disabled={busy || count === 0} onClick={() => void backUp()}>
        <DownloadIcon />
        Back up all Margins
      </button>
      {count === 0 && <p className="muted">No Margins yet.</p>}
    </section>
  );
}
