// smserver is the Spoken Margins server (bridge stream, M1 skeleton).
//
//	smserver serve   -state DIR -public DIR [-listen 127.0.0.1:8795] [-attest-root PEM] [-allow-development] [-relay-origins https://web.example] [-link-origins https://web.example]
//	smserver block   -state DIR TAG      refuse one install from now on
//	smserver unblock -state DIR TAG
//	smserver switch  -public DIR [-minimum-build N] SERVICE on|off   the kill switch
//	smserver purge   -state DIR [-idle-days 90]
//	smserver validate-manifest FILE
//	smserver publish-manifest -public DIR FILE   the only way the manifest should change
//	smserver takedown-map -state DIR EPISODEKEY   delete a listening map at once and keep it down
//	smserver hold    -state DIR -report REPORTID [-link-file FILE|-] ID   hold a CyberTipline-reported link for a year
//	smserver release-hold -state DIR -reason TEXT ID   end a hold early and delete the held copy
//	smserver make-test-ca DIR            a fake Apple CA for local testing
//
// Admin is CLI-only, on the box: there is no remote admin endpoint to attack.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"spokenmargins.dev/bridge/internal/api"
	"spokenmargins.dev/bridge/internal/appattest"
	"spokenmargins.dev/bridge/internal/appattest/fakeattest"
	"spokenmargins.dev/bridge/internal/config"
	"spokenmargins.dev/bridge/internal/links"
	"spokenmargins.dev/bridge/internal/manifest"
	"spokenmargins.dev/bridge/internal/maps"
	"spokenmargins.dev/bridge/internal/relay"
	"spokenmargins.dev/bridge/internal/reportrules"
	"spokenmargins.dev/bridge/internal/reports"
	"spokenmargins.dev/bridge/internal/store"
	"spokenmargins.dev/bridge/internal/tokens"
	"spokenmargins.dev/bridge/internal/weborigin"
)

const (
	defaultAppID = "J8SWC6J3VY.com.spokenmargins.native"
	// abuseLogDays bounds how long an over-limit install's tag is kept.
	abuseLogDays = 30
)

func main() {
	if len(os.Args) < 2 {
		usage()
	}
	cmd, args := os.Args[1], os.Args[2:]
	var err error
	switch cmd {
	case "serve":
		err = serve(args)
	case "block", "unblock":
		err = block(cmd, args)
	case "switch":
		err = switchService(args)
	case "purge":
		err = purge(args)
	case "validate-manifest":
		err = validateManifest(args)
	case "publish-manifest":
		err = publishManifest(args)
	case "make-test-ca":
		err = makeTestCA(args)
	case "takedown":
		err = takedownLink(args)
	case "takedown-map":
		err = takedownMap(args)
	case "hold":
		err = holdLink(args)
	case "release-hold":
		err = releaseHold(args)
	default:
		usage()
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "smserver:", err)
		os.Exit(1)
	}
}

func usage() {
	fmt.Fprintln(os.Stderr, "usage: smserver serve|block|unblock|switch|purge|validate-manifest|publish-manifest|make-test-ca|takedown|takedown-map|hold|release-hold [flags]")
	os.Exit(2)
}

// parseRelayOrigins reads -relay-origins. A bad entry stops the server
// rather than being skipped, so a typo can't quietly leave the relay open
// to fewer (or other) origins than the owner meant.
func parseRelayOrigins(s string) ([]string, error) {
	var out []string
	for _, o := range strings.Split(s, ",") {
		o = strings.TrimSpace(o)
		if !relay.ValidOrigin(o) {
			return nil, fmt.Errorf("relay: %q is not an origin like https://web.example.com", o)
		}
		out = append(out, o)
	}
	return out, nil
}

func configPath(public string) string {
	return filepath.Join(public, filepath.FromSlash(strings.TrimPrefix(api.PathConfig, "/")))
}

func serve(args []string) error {
	fs := flag.NewFlagSet("serve", flag.ExitOnError)
	listen := fs.String("listen", "127.0.0.1:8795", "address to listen on (keep it loopback behind Caddy)")
	stateDir := fs.String("state", "state", "directory for install records and the block list")
	public := fs.String("public", "public", "web root holding api/v1/config.json and bridge/v1/manifest.json")
	appID := fs.String("app-id", defaultAppID, "TeamID.bundleID the attestations must name")
	rootPath := fs.String("attest-root", "", "PEM root to trust instead of Apple's (local testing only)")
	allowDev := fs.Bool("allow-development", false, "accept App Attest development-environment keys (debug builds)")
	behindProxy := fs.Bool("behind-proxy", false, "take the client address from X-Forwarded-For when the peer is loopback")
	idleDays := fs.Int("idle-days", 90, "delete install records unused for this many days")
	installURL := fs.String("links-install-url", "", "App Store listing or TestFlight invitation (required for links)")
	relayOrigins := fs.String("relay-origins", "", "comma-separated web app origins that may use the feed relay (required for relay)")
	linkOrigins := fs.String("link-origins", "", "comma-separated web app origins that may read sealed link packets and previews (CORS); empty sends no CORS headers")
	var mf mapsFlags
	mf.register(fs)
	fs.Parse(args)

	if *installURL != "" && !links.ValidInstallURL(*installURL) {
		return errors.New("links: install URL must be an App Store listing or TestFlight invitation")
	}
	var feedRelay *relay.Relay
	if *relayOrigins != "" {
		origins, err := parseRelayOrigins(*relayOrigins)
		if err != nil {
			return err
		}
		feedRelay = &relay.Relay{Origins: origins}
	}
	// A bad entry stops the server rather than being skipped, so a typo
	// can't quietly open the links to other origins than the owner meant.
	webOrigins, err := weborigin.Parse(*linkOrigins)
	if err != nil {
		return fmt.Errorf("links: -link-origins: %w", err)
	}
	linkStore, err := links.OpenStore(filepath.Join(*stateDir, "links"))
	if err != nil {
		// Optional link storage must not take health or the bridge down.
		log.Print("links: unavailable")
		linkStore = nil
	}
	// Links come up only with somewhere to record a report (#2239): a link nobody can report is not served.
	reportStore, err := reports.Open(filepath.Join(*stateDir, "reports"))
	if err != nil {
		log.Print("reports: unavailable, links off")
		reportStore = nil
		linkStore = nil
	}
	rootPEM := appattest.AppleRootPEM()
	if *rootPath != "" {
		data, err := os.ReadFile(*rootPath)
		if err != nil {
			return err
		}
		rootPEM = data
		log.Printf("WARNING: trusting %s instead of Apple's App Attestation root; for local testing only", *rootPath)
	}
	pool, err := appattest.PoolFromPEM(rootPEM)
	if err != nil {
		return err
	}
	st, err := store.Open(*stateDir)
	if err != nil {
		return err
	}
	cfgPath := configPath(*public)
	if _, err := os.Stat(cfgPath); errors.Is(err, os.ErrNotExist) {
		if err := config.Write(cfgPath, config.Default()); err != nil {
			return err
		}
		log.Printf("wrote default config to %s", cfgPath)
	}

	// The key comes from the service's environment file and is removed from
	// the environment once read.
	apiKey := os.Getenv(mapsKeyEnv)
	os.Unsetenv(mapsKeyEnv)
	mapStore, mapService, err := setupMaps(*stateDir, mf, apiKey, log.Printf)
	if err != nil {
		return err
	}
	// Anonymous tokens (#737). Keys are made on first use, so with the
	// tokens switch off this only creates two empty directories. If even
	// that fails, the server still starts and token routes answer 503.
	issuer, err := tokens.Open(filepath.Join(*stateDir, "tokens"))
	if err != nil {
		log.Printf("tokens: unavailable: %v", err)
		issuer = nil
	}
	srv := &api.Server{
		Verifier:          &appattest.Verifier{Roots: pool, AppID: *appID, AllowDevelopment: *allowDev},
		Store:             st,
		Config:            &config.Reader{Path: cfgPath},
		PublicDir:         *public,
		RequestLog:        os.Stdout,
		AbuseLog:          appendFile(filepath.Join(*stateDir, "abuse.log")),
		TrustForwardedFor: *behindProxy,
		MapStore:          mapStore,
		Maps:              mapService,
		Tokens:            issuer,
		Links:             linkStore,
		Reports:           reportStore,
		LinkInstallURL:    *installURL,
		Relay:             feedRelay,
		LinkOrigins:       webOrigins,
	}
	httpServer := &http.Server{
		Addr:              *listen,
		Handler:           srv.Handler(),
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       30 * time.Second,
		WriteTimeout:      30 * time.Second,
		IdleTimeout:       60 * time.Second,
		MaxHeaderBytes:    16 << 10,
		// The standard library's own error log can include peer addresses.
		ErrorLog: log.New(discard{}, "", 0),
	}

	if mapService != nil {
		mapService.Enabled = func() bool {
			doc, err := srv.Config.Current()
			return err == nil && doc.Enabled(config.ServiceMaps)
		}
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	sweepTranscripts := func() {
		if n, err := mapStore.Sweep(time.Now(), maps.TranscriptMaxAge); err != nil {
			log.Printf("maps: transcript sweep failed: %v", err)
		} else if n > 0 {
			log.Printf("maps: swept %d old transcripts", n)
		}
	}
	sweepTranscripts()
	if mapService != nil {
		go mapService.Run(ctx)
	}
	go func() {
		purgeOnce := func() {
			if linkStore != nil {
				if n, err := linkStore.Sweep(time.Now()); err != nil {
					log.Print("links: daily sweep failed")
				} else if n > 0 {
					log.Printf("links: swept %d expired packets", n)
				}
				if n, err := linkStore.SweepHeld(time.Now()); err != nil {
					log.Print("links: held-link sweep failed")
				} else if n > 0 {
					log.Printf("links: deleted %d held links at one year", n)
				}
			}
			if reportStore != nil {
				cfg := reportrules.DefaultConfig()
				if n, err := reportStore.Sweep(time.Now(), cfg.ReasonWindow, cfg.StrikeWindow); err != nil {
					log.Print("reports: daily sweep failed")
				} else if n > 0 {
					log.Printf("reports: deleted %d records past 90 days", n)
				}
			}
			if n, err := st.Purge(time.Now(), *idleDays); err != nil {
				log.Printf("purge failed: %v", err)
			} else if n > 0 {
				log.Printf("purged %d idle install records", n)
			}
			if issuer != nil {
				if n, err := issuer.Prune(time.Now()); err != nil {
					log.Printf("tokens: prune failed: %v", err)
				} else if n > 0 {
					log.Printf("tokens: pruned %d expired key months", n)
				}
			}
			if _, err := store.PruneHourLog(filepath.Join(*stateDir, "abuse.log"), time.Now(), abuseLogDays); err != nil {
				log.Printf("abuse log prune failed: %v", err)
			}
		}
		purgeOnce()
		t := time.NewTicker(24 * time.Hour)
		defer t.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-t.C:
				purgeOnce()
			}
		}
	}()
	go func() {
		// Logs and install records are written once an hour, never per request.
		t := time.NewTicker(time.Hour)
		defer t.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-t.C:
				if err := srv.Flush(); err != nil {
					log.Printf("hourly flush failed: %v", err)
				}
				// Hourly, with a 23-hour limit, so no transcript outlives a day.
				sweepTranscripts()
			}
		}
	}()
	go func() {
		<-ctx.Done()
		shutdown, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		httpServer.Shutdown(shutdown)
	}()
	log.Printf("smserver %s listening on %s", api.Version, *listen)
	if err := httpServer.ListenAndServe(); !errors.Is(err, http.ErrServerClosed) {
		return err
	}
	return srv.Flush()
}

// appendFile opens the file for each write, so the daily prune can replace
// it by rename without the server writing into the old, unlinked copy.
type appendFile string

func (a appendFile) Write(p []byte) (int, error) {
	f, err := os.OpenFile(string(a), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		return 0, err
	}
	defer f.Close()
	return f.Write(p)
}

type discard struct{}

func (discard) Write(p []byte) (int, error) { return len(p), nil }

func block(cmd string, args []string) error {
	fs := flag.NewFlagSet(cmd, flag.ExitOnError)
	stateDir := fs.String("state", "state", "state directory")
	fs.Parse(args)
	if fs.NArg() != 1 {
		return fmt.Errorf("%s needs one install tag", cmd)
	}
	st, err := store.Open(*stateDir)
	if err != nil {
		return err
	}
	if cmd == "block" {
		err = st.Block(fs.Arg(0))
	} else {
		err = st.Unblock(fs.Arg(0))
	}
	if err == nil {
		fmt.Printf("%sed %s\n", cmd, fs.Arg(0))
	}
	return err
}

func switchService(args []string) error {
	fs := flag.NewFlagSet("switch", flag.ExitOnError)
	public := fs.String("public", "public", "web root")
	minimumBuild := fs.Int("minimum-build", config.KeepMinimumBuild, "app builds below this number get the service off; 0 removes the limit; leave out to keep it")
	fs.Parse(args)
	if fs.NArg() != 2 || (fs.Arg(1) != "on" && fs.Arg(1) != "off") {
		return fmt.Errorf("usage: smserver switch -public DIR [-minimum-build N] SERVICE on|off (services: %v)", config.KnownServices)
	}
	doc, err := config.SetWithMinimumBuild(configPath(*public), fs.Arg(0), fs.Arg(1) == "on", *minimumBuild)
	if err == nil {
		fmt.Println(doc.Summary())
	}
	return err
}

func purge(args []string) error {
	fs := flag.NewFlagSet("purge", flag.ExitOnError)
	stateDir := fs.String("state", "state", "state directory")
	idleDays := fs.Int("idle-days", 90, "delete records unused for this many days")
	fs.Parse(args)
	st, err := store.Open(*stateDir)
	if err != nil {
		return err
	}
	n, err := st.Purge(time.Now(), *idleDays)
	if err == nil {
		_, err = store.PruneHourLog(filepath.Join(*stateDir, "abuse.log"), time.Now(), abuseLogDays)
	}
	if err == nil {
		left, _ := st.Count()
		fmt.Printf("purged %d, %d remain\n", n, left)
	}
	return err
}

func validateManifest(args []string) error {
	if len(args) != 1 {
		return errors.New("usage: smserver validate-manifest FILE")
	}
	data, err := os.ReadFile(args[0])
	if err != nil {
		return err
	}
	m, err := manifest.Validate(data)
	if err != nil {
		return err
	}
	fmt.Printf("ok: %d sources\n", len(m.Sources))
	return nil
}

func publishManifest(args []string) error {
	fs := flag.NewFlagSet("publish-manifest", flag.ExitOnError)
	public := fs.String("public", "public", "web root")
	fs.Parse(args)
	if fs.NArg() != 1 {
		return errors.New("usage: smserver publish-manifest -public DIR FILE")
	}
	data, err := os.ReadFile(fs.Arg(0))
	if err != nil {
		return err
	}
	m, err := manifest.Publish(filepath.Join(*public, filepath.FromSlash(strings.TrimPrefix(api.PathManifest, "/"))), data)
	if err == nil {
		fmt.Printf("published: %d sources\n", len(m.Sources))
	}
	return err
}

func makeTestCA(args []string) error {
	if len(args) != 1 {
		return errors.New("usage: smserver make-test-ca DIR")
	}
	ca, err := fakeattest.NewCA()
	if err != nil {
		return err
	}
	if err := ca.Save(args[0]); err != nil {
		return err
	}
	fmt.Printf("wrote %s/test-root.pem (start serve with -attest-root) and %s/test-ca.pem (for smclient)\n", args[0], args[0])
	return nil
}

func takedownMap(args []string) error {
	fs := flag.NewFlagSet("takedown-map", flag.ExitOnError)
	stateDir := fs.String("state", "state", "state directory")
	fs.Parse(args)
	if fs.NArg() != 1 {
		return errors.New("usage: smserver takedown-map -state DIR EPISODEKEY")
	}
	ms, err := maps.OpenStore(filepath.Join(*stateDir, "maps"))
	if err != nil {
		return err
	}
	deleted, err := ms.Takedown(fs.Arg(0))
	if err != nil {
		return err
	}
	if deleted {
		fmt.Println("map deleted; no new map will be made for this episode")
	} else {
		fmt.Println("no map was stored; no map will be made for this episode")
	}
	return nil
}

func takedownLink(args []string) error {
	fs := flag.NewFlagSet("takedown", flag.ExitOnError)
	state := fs.String("state", "state", "state directory")
	fs.Parse(args)
	if fs.NArg() != 1 {
		return errors.New("usage: smserver takedown -state DIR ID")
	}
	st, err := links.OpenStore(filepath.Join(*state, "links"))
	if err != nil {
		return err
	}
	if err := st.Takedown(fs.Arg(0)); err != nil {
		return err
	}
	fmt.Println("shared link removed")
	return nil
}

const maxReportedLink = 64 << 10

// holdLink moves a reported link into restricted storage for a year and takes it down (#2235). The
// reported link, key included, is read from -link-file (or stdin with "-") and stored unread; it is
// never printed or logged.
func holdLink(args []string) error {
	fs := flag.NewFlagSet("hold", flag.ExitOnError)
	state := fs.String("state", "state", "state directory")
	report := fs.String("report", "", "the CyberTipline report id")
	linkFile := fs.String("link-file", "", "file holding the full reported link, or - for stdin")
	fs.Parse(args)
	if fs.NArg() != 1 || *report == "" {
		return errors.New("usage: smserver hold -state DIR -report REPORTID [-link-file FILE|-] ID")
	}
	var full []byte
	switch *linkFile {
	case "":
	case "-":
		data, err := io.ReadAll(io.LimitReader(os.Stdin, maxReportedLink+1))
		if err != nil {
			return err
		}
		full = data
	default:
		data, err := os.ReadFile(*linkFile)
		if err != nil {
			return err
		}
		full = data
	}
	if *linkFile != "" && (len(full) == 0 || len(full) > maxReportedLink) {
		return fmt.Errorf("the reported link must be between 1 and %d bytes", maxReportedLink)
	}
	st, err := links.OpenStore(filepath.Join(*state, "links"))
	if err != nil {
		return err
	}
	if err := st.Hold(fs.Arg(0), *report, full, time.Now()); err != nil {
		return err
	}
	fmt.Println("link taken down and held for one year")
	return nil
}

func releaseHold(args []string) error {
	fs := flag.NewFlagSet("release-hold", flag.ExitOnError)
	state := fs.String("state", "state", "state directory")
	reason := fs.String("reason", "", "why the hold ends early (goes in the access log)")
	fs.Parse(args)
	if fs.NArg() != 1 || *reason == "" {
		return errors.New("usage: smserver release-hold -state DIR -reason TEXT ID")
	}
	st, err := links.OpenStore(filepath.Join(*state, "links"))
	if err != nil {
		return err
	}
	if err := st.ReleaseHeld(fs.Arg(0), *reason, time.Now()); err != nil {
		return err
	}
	fmt.Println("hold ended and the held copy deleted")
	return nil
}
