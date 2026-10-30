import { useData } from '../data.tsx';
import { RELAY_BODY } from '../ui.tsx';

export function Settings() {
  const { settings, setSetting } = useData();
  const on = settings.relayAllowed;
  return (
    <section className="screen" aria-labelledby="settings-title">
      <header className="screen-header">
        <h1 id="settings-title">Settings</h1>
      </header>

      <section className="settings-section" aria-labelledby="relay-heading">
        <h2 id="relay-heading">Reading feeds through our server</h2>
        <p>{RELAY_BODY}</p>
        <p>Feeds your browser can read directly never go through the server.</p>
        <label className="switch-row">
          <span>
            <span className="switch-label">Use the server for feeds that need it</span>
            <span className="switch-state" data-state={on ? 'on' : 'off'}>
              {on ? 'On' : settings.relayAsked ? 'Off' : 'Off, you’ll be asked the first time a feed needs it'}
            </span>
          </span>
          <input
            type="checkbox"
            role="switch"
            className="switch"
            checked={on}
            onChange={(event) => {
              void setSetting('relayAllowed', event.target.checked);
              void setSetting('relayAsked', true);
            }}
          />
        </label>
      </section>

      <section className="settings-section" aria-labelledby="privacy-heading">
        <h2 id="privacy-heading">Privacy</h2>
        <p>
          The shows you follow, your place in each episode and your Margins are kept in this browser only. Nothing is sent to us, and there is no
          account. Clearing this site’s data in your browser removes them.
        </p>
        <p>Episodes play straight from each show’s own host, which sees the request as it would from any podcast app.</p>
        <p>The microphone is used only while you record a voice Margin.</p>
      </section>

      <section className="settings-section" aria-labelledby="about-heading">
        <h2 id="about-heading">About Spoken Margins</h2>
        <p>
          Listen to podcasts and Substack posts in their own voices, and leave written or spoken Margins at the moment they belong. Margins travel as
          .spokenmargins files, which the Spoken Margins iPhone app opens.
        </p>
        <p className="muted">Web app, early version. Source code under AGPL-3.0.</p>
      </section>
    </section>
  );
}
