// smserver is the Spoken Margins server (bridge stream, M1 skeleton).
//
//	smserver serve   -state DIR -public DIR [-listen 127.0.0.1:8787] [-attest-root PEM] [-allow-development]
//	smserver block   -state DIR TAG      refuse one install from now on
//	smserver unblock -state DIR TAG
//	smserver switch  -public DIR SERVICE on|off   the kill switch
//	smserver purge   -state DIR [-idle-days 90]
//	smserver validate-manifest FILE
//	smserver make-test-ca DIR            a fake Apple CA for local testing
//
// Admin is CLI-only, on the box: there is no remote admin endpoint to attack.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
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
	"spokenmargins.dev/bridge/internal/manifest"
	"spokenmargins.dev/bridge/internal/store"
)

const defaultAppID = "J8SWC6J3VY.com.spokenmargins.native"

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
	case "make-test-ca":
		err = makeTestCA(args)
	default:
		usage()
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "smserver:", err)
		os.Exit(1)
	}
}

func usage() {
	fmt.Fprintln(os.Stderr, "usage: smserver serve|block|unblock|switch|purge|validate-manifest|make-test-ca [flags]")
	os.Exit(2)
}

func configPath(public string) string {
	return filepath.Join(public, filepath.FromSlash(strings.TrimPrefix(api.PathConfig, "/")))
}

func serve(args []string) error {
	fs := flag.NewFlagSet("serve", flag.ExitOnError)
	listen := fs.String("listen", "127.0.0.1:8787", "address to listen on (keep it loopback behind Caddy)")
	stateDir := fs.String("state", "state", "directory for install records and the block list")
	public := fs.String("public", "public", "web root holding api/v1/config.json and bridge/v1/manifest.json")
	appID := fs.String("app-id", defaultAppID, "TeamID.bundleID the attestations must name")
	rootPath := fs.String("attest-root", "", "PEM root to trust instead of Apple's (local testing only)")
	allowDev := fs.Bool("allow-development", false, "accept App Attest development-environment keys (debug builds)")
	behindProxy := fs.Bool("behind-proxy", false, "take the client address from X-Forwarded-For when the peer is loopback")
	idleDays := fs.Int("idle-days", 90, "delete install records unused for this many days")
	fs.Parse(args)

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
	abuse, err := os.OpenFile(filepath.Join(*stateDir, "abuse.log"), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	defer abuse.Close()

	srv := &api.Server{
		Verifier:          &appattest.Verifier{Roots: pool, AppID: *appID, AllowDevelopment: *allowDev},
		Store:             st,
		Config:            &config.Reader{Path: cfgPath},
		PublicDir:         *public,
		RequestLog:        os.Stdout,
		AbuseLog:          abuse,
		TrustForwardedFor: *behindProxy,
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

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	go func() {
		purgeOnce := func() {
			if n, err := st.Purge(time.Now(), *idleDays); err != nil {
				log.Printf("purge failed: %v", err)
			} else if n > 0 {
				log.Printf("purged %d idle install records", n)
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
		<-ctx.Done()
		shutdown, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		httpServer.Shutdown(shutdown)
	}()
	log.Printf("smserver %s listening on %s", api.Version, *listen)
	if err := httpServer.ListenAndServe(); !errors.Is(err, http.ErrServerClosed) {
		return err
	}
	return nil
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
	fs.Parse(args)
	if fs.NArg() != 2 || (fs.Arg(1) != "on" && fs.Arg(1) != "off") {
		return fmt.Errorf("usage: smserver switch -public DIR SERVICE on|off (services: %v)", config.KnownServices)
	}
	doc, err := config.Set(configPath(*public), fs.Arg(0), fs.Arg(1) == "on")
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
