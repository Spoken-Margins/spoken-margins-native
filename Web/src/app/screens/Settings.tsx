import { useData } from '../data.tsx';
import { RELAY_BODY } from '../ui.tsx';

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
