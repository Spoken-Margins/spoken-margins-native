package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	"errors"
	"spokenmargins.dev/bridge/internal/config"
	"spokenmargins.dev/bridge/internal/links"
	"spokenmargins.dev/bridge/internal/maps"
)

const secretKey = "sk-ant-test-0123456789-SECRET"

// TestMain lets a test run this binary's main in a child process, so the
// real startup and error output can be checked.
func TestMain(m *testing.M) {
	if os.Getenv("SMSERVER_TEST_MAIN") == "1" {
		os.Args = append([]string{"smserver"}, strings.Fields(os.Getenv("SMSERVER_TEST_ARGS"))...)
		main()
		os.Exit(0)
	}
	os.Exit(m.Run())
}

func freePort(t *testing.T) string {
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close()
	return l.Addr().String()
}

type lockedBuffer struct {
	mu sync.Mutex
	b  bytes.Buffer
}

func (l *lockedBuffer) Write(p []byte) (int, error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.b.Write(p)
}

func (l *lockedBuffer) String() string {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.b.String()
}

// The API key reaches the provider and nothing else: not the startup log,
// not the worker's error lines (even when the provider echoes the key back),
// not the request log, not config.json.
func TestServeNeverPrintsTheAPIKey(t *testing.T) {
	var sawKey bool
	var mu sync.Mutex
	fake := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		sawKey = r.Header.Get("X-Api-Key") == secretKey
		mu.Unlock()
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(401)
		fmt.Fprintf(w, `{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key %s"}}`, r.Header.Get("X-Api-Key"))
	}))
	defer fake.Close()

	dir := t.TempDir()
	state, public := filepath.Join(dir, "state"), filepath.Join(dir, "public")
	cfg := configPath(public)
	if err := config.Write(cfg, config.Default()); err != nil {
		t.Fatal(err)
	}
	if _, err := config.Set(cfg, config.ServiceMaps, true); err != nil {
		t.Fatal(err)
	}
	addr := freePort(t)
	cmd := exec.Command(os.Args[0])
	cmd.Env = append(os.Environ(),
		"SMSERVER_TEST_MAIN=1",
		"ANTHROPIC_API_KEY="+secretKey,
		fmt.Sprintf("SMSERVER_TEST_ARGS=serve -listen %s -state %s -public %s -maps-api-base %s", addr, state, public, fake.URL),
	)
	var out lockedBuffer
	cmd.Stdout, cmd.Stderr = &out, &out
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	defer cmd.Process.Kill()

	var resp *http.Response
	var err error
	for i := 0; i < 100; i++ {
		resp, err = http.Get("http://" + addr + "/api/v1/health")
		if err == nil {
			resp.Body.Close()
			break
		}
		time.Sleep(50 * time.Millisecond)
	}
	if err != nil {
		t.Fatalf("server didn't start: %v\n%s", err, out.String())
	}
	body, _ := json.Marshal(map[string]any{
		"schema": maps.TranscriptSchema, "episodeKey": strings.Repeat("ab", 32), "durationMs": 180000, "language": "en",
		// Three minutes: long enough for three scenes, so the worker calls.
		"segments": []map[string]any{
			{"id": "a", "startMs": 0, "endMs": 60000, "text": "hello"},
			{"id": "b", "startMs": 60000, "endMs": 120000, "text": "middle"},
			{"id": "c", "startMs": 120000, "endMs": 180000, "text": "goodbye"},
		},
	})
	resp, err = http.Post("http://"+addr+"/api/v1/maps/transcripts", "application/json", bytes.NewReader(body))
	if err != nil || resp.StatusCode != 202 {
		t.Fatalf("upload: %v %v\n%s", resp, err, out.String())
	}
	resp.Body.Close()
	for i := 0; i < 100 && !strings.Contains(out.String(), "dropped a transcript"); i++ {
		time.Sleep(50 * time.Millisecond)
	}
	cmd.Process.Signal(syscall.SIGTERM)
	cmd.Wait()

	logs := out.String()
	mu.Lock()
	defer mu.Unlock()
	if !sawKey {
		t.Fatalf("the provider never received the key\n%s", logs)
	}
	if !strings.Contains(logs, "maps: making maps with anthropic/claude-haiku-5-5, capped at $10.00 a month") ||
		!strings.Contains(logs, "HTTP 401") || !strings.Contains(logs, "dropped a transcript") {
		t.Fatalf("expected startup and failure lines missing:\n%s", logs)
	}
	if strings.Contains(logs, secretKey) || strings.Contains(logs, "SECRET") {
		t.Fatalf("output shows the API key:\n%s", logs)
	}
	if data, _ := os.ReadFile(cfg); bytes.Contains(data, []byte("SECRET")) || bytes.Contains(data, []byte("cap")) {
		t.Fatalf("config.json carries a private setting: %s", data)
	}
}

func TestServeWithoutKeyStillStarts(t *testing.T) {
	var logs []string
	store, svc, err := setupMaps(t.TempDir(), mapsFlags{capUSD: 10}, "", func(f string, a ...any) {
		logs = append(logs, fmt.Sprintf(f, a...))
	})
	if err != nil || store == nil || svc != nil {
		t.Fatalf("setupMaps without a key = %v, %v, %v", store, svc, err)
	}
	if len(logs) != 1 || !strings.Contains(logs[0], "uploads are refused") {
		t.Fatalf("logs %v", logs)
	}
	// A damaged ledger refuses uploads rather than starting from zero.
	state := t.TempDir()
	os.MkdirAll(filepath.Join(state, "maps"), 0o700)
	os.WriteFile(filepath.Join(state, "maps", "ledger.json"), []byte("{"), 0o600)
	if _, svc, err := setupMaps(state, mapsFlags{capUSD: 10}, secretKey, func(string, ...any) {}); err != nil || svc != nil {
		t.Fatalf("damaged ledger: service %v, err %v", svc, err)
	}
}

func TestTakedownMapCommand(t *testing.T) {
	state := t.TempDir()
	store, err := maps.OpenStore(filepath.Join(state, "maps"))
	if err != nil {
		t.Fatal(err)
	}
	key := strings.Repeat("cd", 32)
	if err := store.PutMap(maps.Map{Schema: maps.MapSchema, EpisodeKey: key}); err != nil {
		t.Fatal(err)
	}
	if err := takedownMap([]string{"-state", state, key}); err != nil {
		t.Fatal(err)
	}
	if store.HasMap(key) || !store.Withdrawn(key) {
		t.Fatal("map still there after takedown-map")
	}
	if err := takedownMap([]string{"-state", state, "nope"}); err == nil {
		t.Fatal("takedown-map accepted a bad key")
	}
}

func TestLinkTakedownCommand(t *testing.T) {
	dir := t.TempDir()
	st, err := links.OpenStore(filepath.Join(dir, "links"))
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now()
	// Parts sealed on the phone (#805): the header, nonce and tag of each, with opaque bytes between.
	sealed := func(part byte) []byte {
		return append([]byte{'S', 'M', 'L', 'I', 'N', 'K', 1, part}, []byte("twelve-nonce opaque ciphertext sixteen-byte-tag")...)
	}
	id, _, err := st.Put(sealed(links.PartPacket), sealed(links.PartPreview), now)
	if err != nil {
		t.Fatal(err)
	}
	if err := takedownLink([]string{"-state", dir, id}); err != nil {
		t.Fatal(err)
	}
	if _, err := st.Packet(id, now); !errors.Is(err, links.ErrGone) {
		t.Fatal("CLI did not delete link")
	}
	for _, name := range []string{"packet", "preview", "preview.json"} {
		if _, err := os.Stat(filepath.Join(dir, "links", id, name)); !errors.Is(err, os.ErrNotExist) {
			t.Fatal("CLI left content")
		}
	}
	if err := takedownLink([]string{"-state", dir, "../"}); err == nil {
		t.Fatal("invalid id")
	}
	if err := takedownLink([]string{"-state", dir}); err == nil {
		t.Fatal("missing id")
	}
}
