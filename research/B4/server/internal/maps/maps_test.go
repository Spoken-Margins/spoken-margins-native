package maps

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func encode(t *testing.T, v any) []byte {
	t.Helper()
	data, err := json.Marshal(v)
	if err != nil {
		t.Fatal(err)
	}
	return data
}

func TestParseTranscriptRefusals(t *testing.T) {
	if _, err := ParseTranscript(encode(t, testTranscript())); err != nil {
		t.Fatalf("good transcript refused: %v", err)
	}
	cases := map[string]func(*Transcript){
		"key too short":    func(tr *Transcript) { tr.EpisodeKey = testKey[:63] },
		"key upper case":   func(tr *Transcript) { tr.EpisodeKey = strings.ToUpper(testKey) },
		"key not hex":      func(tr *Transcript) { tr.EpisodeKey = "g" + testKey[1:] },
		"wrong schema":     func(tr *Transcript) { tr.Schema = "spokenmargins.episode-transcript.v2" },
		"no duration":      func(tr *Transcript) { tr.DurationMs = 0 },
		"no language":      func(tr *Transcript) { tr.Language = "" },
		"no segments":      func(tr *Transcript) { tr.Segments = nil },
		"same start twice": func(tr *Transcript) { tr.Segments[3].StartMs = tr.Segments[2].StartMs },
		"start goes back":  func(tr *Transcript) { tr.Segments[3].StartMs = 1 },
		"end before start": func(tr *Transcript) { tr.Segments[3].EndMs = tr.Segments[3].StartMs - 1 },
		"duplicate id":     func(tr *Transcript) { tr.Segments[3].ID = "s2" },
		"id with a space":  func(tr *Transcript) { tr.Segments[3].ID = "s 3" },
		"over 3000 segments": func(tr *Transcript) {
			tr.Segments = nil
			for i := 0; i <= MaxSegments; i++ {
				tr.Segments = append(tr.Segments, Segment{ID: fmt.Sprint(i), StartMs: int64(i), EndMs: int64(i)})
			}
		},
	}
	for name, change := range cases {
		tr := testTranscript()
		change(&tr)
		if _, err := ParseTranscript(encode(t, tr)); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}
	big := testTranscript()
	big.Segments[0].Text = strings.Repeat("a", MaxTranscriptBytes)
	if _, err := ParseTranscript(encode(t, big)); err == nil {
		t.Error("over 2 MB: accepted")
	}
	long := testTranscript()
	long.Segments[0].Text = strings.Repeat("a", MaxPromptBytes)
	if _, err := ParseTranscript(encode(t, long)); err == nil {
		t.Error("over the prompt limit: accepted")
	}
	fits := testTranscript()
	fits.Segments[0].Text = strings.Repeat("a", MaxPromptBytes-4000)
	if _, err := ParseTranscript(encode(t, fits)); err != nil {
		t.Errorf("under the prompt limit: refused: %v", err)
	}
	if _, err := ParseTranscript([]byte(`{"schema":`)); err == nil {
		t.Error("broken JSON: accepted")
	}
}

func TestWorkerMakesMapAndDeletesTranscript(t *testing.T) {
	api := newFakeAPI(t)
	svc, _, logs := newService(t, api, 10)
	if out, err := svc.Submit(testTranscript()); err != nil || out != Accepted {
		t.Fatalf("submit = %v, %v", out, err)
	}
	if !svc.Store.HasTranscript(testKey) {
		t.Fatal("transcript not queued")
	}
	svc.ProcessWaiting(context.Background())

	if api.callCount() != goodCalls {
		t.Fatalf("calls = %d, want %d", api.callCount(), goodCalls)
	}
	if svc.Store.HasTranscript(testKey) {
		t.Fatal("transcript kept after its map was made")
	}
	data, err := svc.Store.MapBytes(testKey)
	if err != nil {
		t.Fatal(err)
	}
	var m Map
	json.Unmarshal(data, &m)
	if m.Schema != MapSchema || m.EpisodeKey != testKey || m.Generator != "anthropic/"+DefaultModel ||
		m.CreatedAt != "2026-10-01T14:00:00Z" || len(m.Scenes) != 4 || m.DurationMs != 20*60000 {
		t.Fatalf("map = %s", data)
	}
	if strings.Contains(string(data), "lighthouse keeper number") {
		t.Fatal("map carries transcript text")
	}
	// The first call is the pick; every call named the model, asked for a
	// schema, and sent the key.
	if strings.Join(api.kinds, ",") != "pick,scene,scene,scene,scene" {
		t.Fatalf("calls %v", api.kinds)
	}
	body := api.bodies[1]
	if body["model"] != DefaultModel || api.keys[0] != "sk-test-secret-key" {
		t.Fatalf("request model %v key %q", body["model"], api.keys[0])
	}
	if _, ok := body["output_config"].(map[string]any)["format"]; !ok {
		t.Fatalf("request has no output format: %v", body["output_config"])
	}
	// Cost: per call, 13,000 in at $1/M plus 2,000 out at $5/M = $0.023.
	if spent := svc.Ledger.Spent(svc.Now()); spent != goodSpend {
		t.Fatalf("ledger = %d micro-dollars, want %d", spent, goodSpend)
	}
	// A second upload of the same episode makes no new work.
	if out, _ := svc.Submit(testTranscript()); out != AlreadyMapped || svc.Store.HasTranscript(testKey) {
		t.Fatalf("second submit = %v", out)
	}
	if containsAny(*logs, testKey) {
		t.Fatalf("log names the episode key: %v", *logs)
	}
}

func TestCapStopsCallsAndUploads(t *testing.T) {
	api := newFakeAPI(t)
	svc, clock, _ := newService(t, api, 10)
	if err := svc.Ledger.Add(clock.Now(), USDToMicro(10)); err != nil {
		t.Fatal(err)
	}
	if out, _ := svc.Submit(testTranscript()); out != CapReached {
		t.Fatalf("submit at the cap = %v, want CapReached", out)
	}

	// A transcript queued before the cap was reached is dropped without a call.
	svc.Store.PutTranscript(testTranscript(), clock.Now())
	svc.ProcessWaiting(context.Background())
	if api.callCount() != 0 || svc.Store.HasTranscript(testKey) || svc.Store.HasMap(testKey) {
		t.Fatalf("calls %d at the cap", api.callCount())
	}

	// Just under the cap, a call that could carry it over is refused at
	// upload, and not made for a transcript already waiting.
	svc2, clock2, _ := newService(t, api, 10)
	svc2.Ledger.Add(clock2.Now(), USDToMicro(9.99))
	if out, _ := svc2.Submit(testTranscript()); out != CapReached {
		t.Fatalf("submit just under the cap = %v, want CapReached", out)
	}
	svc2.Store.PutTranscript(testTranscript(), clock2.Now())
	svc2.ProcessWaiting(context.Background())
	if api.callCount() != 0 || svc2.Store.HasTranscript(testKey) {
		t.Fatalf("calls %d just under the cap", api.callCount())
	}

	// The next UTC month starts from zero.
	clock.Set(time.Date(2026, 11, 1, 0, 0, 1, 0, time.UTC))
	if out, _ := svc.Submit(testTranscript()); out != Accepted {
		t.Fatalf("submit in a new month = %v", out)
	}
	svc.ProcessWaiting(context.Background())
	if api.callCount() != goodCalls || !svc.Store.HasMap(testKey) {
		t.Fatalf("calls %d in the new month", api.callCount())
	}
}

func TestLedgerSurvivesRestart(t *testing.T) {
	path := filepath.Join(t.TempDir(), "ledger.json")
	now := time.Date(2026, 10, 31, 23, 59, 0, 0, time.UTC)
	l, _ := OpenLedger(path)
	l.Add(now, 1234)
	l.Add(now, 1000)
	again, err := OpenLedger(path)
	if err != nil {
		t.Fatal(err)
	}
	if got := again.Spent(now); got != 2234 {
		t.Fatalf("after restart spent = %d, want 2234", got)
	}
	if got := again.Spent(now.Add(2 * time.Minute)); got != 0 {
		t.Fatalf("next month spent = %d, want 0", got)
	}
	// A damaged ledger is an error, never an empty month.
	os.WriteFile(path, []byte("{broken"), 0o600)
	if _, err := OpenLedger(path); err == nil {
		t.Fatal("damaged ledger opened")
	}
	if c := (Prices{InputPerMTok: 1, OutputPerMTok: 5}).Cost(13000, 2000); c != 23000 {
		t.Fatalf("cost = %d", c)
	}
}

func TestSweepDropsOldTranscripts(t *testing.T) {
	store, _ := OpenStore(t.TempDir())
	t0 := time.Date(2026, 10, 1, 8, 0, 0, 0, time.UTC)
	store.PutTranscript(testTranscript(), t0)
	if n, _ := store.Sweep(t0.Add(TranscriptMaxAge-time.Minute), TranscriptMaxAge); n != 0 || !store.HasTranscript(testKey) {
		t.Fatalf("swept a young transcript (%d)", n)
	}
	if n, _ := store.Sweep(t0.Add(TranscriptMaxAge), TranscriptMaxAge); n != 1 || store.HasTranscript(testKey) {
		t.Fatalf("kept an old transcript (%d)", n)
	}
	if keys, _ := store.WaitingKeys(); len(keys) != 0 {
		t.Fatalf("the order still lists %v", keys)
	}

	// Old and young entries mixed: the young ones stay, in arrival order.
	mixed := []string{strings.Repeat("1", 64), strings.Repeat("2", 64), strings.Repeat("3", 64), strings.Repeat("4", 64)}
	for i, key := range mixed {
		tr := testTranscript()
		tr.EpisodeKey = key
		arrived := t0
		if i%2 == 1 {
			arrived = t0.Add(time.Hour)
		}
		store.PutTranscript(tr, arrived)
	}
	if n, _ := store.Sweep(t0.Add(TranscriptMaxAge+time.Minute), TranscriptMaxAge); n != 2 {
		t.Fatalf("swept %d of the 2 old transcripts", n)
	}
	if got, _ := store.WaitingKeys(); strings.Join(got, ",") != mixed[1]+","+mixed[3] || !store.HasTranscript(mixed[1]) || store.HasTranscript(mixed[0]) {
		t.Fatalf("after a mixed sweep, WaitingKeys = %v", got)
	}
}

func TestTakedownKeepsMapDown(t *testing.T) {
	api := newFakeAPI(t)
	svc, _, _ := newService(t, api, 10)
	svc.Submit(testTranscript())
	svc.ProcessWaiting(context.Background())
	if deleted, err := svc.Store.Takedown(testKey); !deleted || err != nil {
		t.Fatalf("takedown = %v, %v", deleted, err)
	}
	if _, err := svc.Store.MapBytes(testKey); err != ErrNotFound {
		t.Fatalf("map still served: %v", err)
	}
	if out, _ := svc.Submit(testTranscript()); out != Withdrawn {
		t.Fatalf("upload after takedown = %v", out)
	}
	if svc.Store.HasTranscript(testKey) || api.callCount() != goodCalls {
		t.Fatal("upload after takedown made new work")
	}
	if _, err := svc.Store.Takedown("not-a-key"); err == nil {
		t.Fatal("takedown accepted a bad key")
	}
}

func TestProviderErrorsNeverCarryTheKey(t *testing.T) {
	api := newFakeAPI(t)
	api.status = 401 // the fake echoes the key in its error body
	svc, _, logs := newService(t, api, 10)
	svc.Submit(testTranscript())
	svc.ProcessWaiting(context.Background())
	if svc.Store.HasTranscript(testKey) || svc.Store.HasMap(testKey) {
		t.Fatal("failed calls left a transcript or made a map")
	}
	if containsAny(*logs, "sk-test-secret-key") || containsAny(*logs, "secret") {
		t.Fatalf("log carries the key: %v", *logs)
	}
	if !containsAny(*logs, "HTTP 401") {
		t.Fatalf("log doesn't say what failed: %v", *logs)
	}
	if spent := svc.Ledger.Spent(svc.Now()); spent != 0 {
		t.Fatalf("failed calls billed %d", spent)
	}
	if _, err := NewAnthropic("", "", ""); err == nil {
		t.Fatal("provider built without a key")
	}
}

func TestProviderRetriesOverloadThenAnswers(t *testing.T) {
	api := newFakeAPI(t)
	api.fail = []int{529, 500}
	svc, _, _ := newService(t, api, 10)
	svc.Provider.(*Anthropic).Backoff = []time.Duration{0, 0}
	svc.Submit(testTranscript())
	svc.ProcessWaiting(context.Background())
	if api.callCount() != goodCalls+2 || !svc.Store.HasMap(testKey) {
		t.Fatalf("calls %d, map %v", api.callCount(), svc.Store.HasMap(testKey))
	}
	// Overloaded answers bill nothing; only the good ones are in the ledger.
	if spent := svc.Ledger.Spent(svc.Now()); spent != goodSpend {
		t.Fatalf("ledger = %d", spent)
	}
}

func TestSwitchedOffWorkerMakesNoCalls(t *testing.T) {
	api := newFakeAPI(t)
	svc, _, _ := newService(t, api, 10)
	svc.Submit(testTranscript())
	svc.Enabled = func() bool { return false }
	svc.ProcessWaiting(context.Background())
	if api.callCount() != 0 || svc.Store.HasTranscript(testKey) || svc.Store.HasMap(testKey) {
		t.Fatalf("calls %d with maps off, transcript kept %v", api.callCount(), svc.Store.HasTranscript(testKey))
	}
}

// cancelling answers, then cancels the context, as a shutdown would.
type cancelling struct {
	cancel context.CancelFunc
	calls  int
}

func (c *cancelling) Generator() string { return "stub" }
func (c *cancelling) Generate(ctx context.Context, req Request) (Response, error) {
	c.calls++
	c.cancel()
	return Response{Text: goodScene, InputTokens: 13000, OutputTokens: 2000, Complete: true}, nil
}

func TestShutdownMidCallStillRecordsTheCost(t *testing.T) {
	api := newFakeAPI(t)
	svc, _, _ := newService(t, api, 10)
	ctx, cancel := context.WithCancel(context.Background())
	stub := &cancelling{cancel: cancel}
	svc.Provider = stub
	svc.Submit(testTranscript())
	svc.ProcessWaiting(ctx)
	if spent := svc.Ledger.Spent(svc.Now()); spent != 23000 {
		t.Fatalf("ledger = %d after a call answered during shutdown, want 23000", spent)
	}
	if !svc.Store.HasTranscript(testKey) {
		t.Fatal("transcript dropped on shutdown; it should wait for the next start")
	}
}

func TestLostAnswerIsCountedAndNotRetried(t *testing.T) {
	block := make(chan struct{})
	slow := newFakeAPI(t)
	slow.Config.Handler = http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		slow.mu.Lock()
		slow.calls++
		slow.mu.Unlock()
		<-block
	})
	t.Cleanup(func() { close(block) })
	svc, _, logs := newService(t, slow, 10)
	svc.Provider.(*Anthropic).client.Timeout = 50 * time.Millisecond
	svc.Provider.(*Anthropic).Backoff = []time.Duration{0, 0}
	svc.Submit(testTranscript())
	svc.ProcessWaiting(context.Background())
	// One HTTP call: a lost answer is never retried, by the provider or the
	// worker, and it is counted at the estimate.
	if slow.callCount() != 1 {
		t.Fatalf("calls = %d, want 1", slow.callCount())
	}
	tr := testTranscript()
	want := svc.estimate(buildPickRequest(tr, planBreaks(tr)))
	if spent := svc.Ledger.Spent(svc.Now()); spent != want || want == 0 {
		t.Fatalf("ledger = %d, want %d", spent, want)
	}
	if !containsAny(*logs, "answer lost") {
		t.Fatalf("logs %v", *logs)
	}
}

func TestLogsNeverNameAPath(t *testing.T) {
	err := &os.PathError{Op: "remove", Path: "/var/lib/smserver/maps/transcripts/" + testKey + ".json", Err: os.ErrPermission}
	if got := quiet(fmt.Errorf("wrapped: %w", err)); strings.Contains(got, testKey) || !strings.Contains(got, "permission") {
		t.Fatalf("quiet = %q", got)
	}
	lerr := &os.LinkError{Op: "rename", Old: "a", New: "/x/maps/" + testKey + ".json", Err: os.ErrExist}
	if got := quiet(lerr); strings.Contains(got, testKey) {
		t.Fatalf("quiet = %q", got)
	}
}

func TestWaitingKeysOldestFirst(t *testing.T) {
	store, _ := OpenStore(t.TempDir())
	keys := []string{strings.Repeat("b", 64), strings.Repeat("a", 64), strings.Repeat("c", 64)}
	for _, key := range keys {
		tr := testTranscript()
		tr.EpisodeKey = key
		store.PutTranscript(tr, time.Now())
	}
	got, err := store.WaitingKeys()
	if err != nil || strings.Join(got, ",") != strings.Join(keys, ",") {
		t.Fatalf("WaitingKeys = %v, %v", got, err)
	}
	store.DeleteTranscript(keys[1])
	if got, _ := store.WaitingKeys(); strings.Join(got, ",") != keys[0]+","+keys[2] {
		t.Fatalf("after a delete, WaitingKeys = %v", got)
	}
}

// Nothing of a transcript is ever written to disk (#1730): not on upload, not
// while it waits, not while it is mapped, and not after.
func TestNoTranscriptTextIsEverWrittenToDisk(t *testing.T) {
	api := newFakeAPI(t)
	svc, _, _ := newService(t, api, 10)
	dir := svc.Store.dir
	tr := testTranscript()
	if out, err := svc.Submit(tr); out != Accepted || err != nil {
		t.Fatalf("Submit: %v %v", out, err)
	}
	needle := []byte(tr.Segments[0].Text)
	scan := func(stage string) {
		t.Helper()
		err := filepath.WalkDir(dir, func(path string, d fs.DirEntry, err error) error {
			if err != nil || d.IsDir() {
				return err
			}
			data, rerr := os.ReadFile(path)
			if rerr != nil {
				return rerr
			}
			if bytes.Contains(data, needle) {
				t.Errorf("%s: transcript text found in %s", stage, path)
			}
			return nil
		})
		if err != nil {
			t.Fatal(err)
		}
		if _, err := os.Stat(filepath.Join(dir, "transcripts")); err == nil {
			t.Errorf("%s: a transcripts directory exists", stage)
		}
	}
	scan("waiting")
	svc.ProcessWaiting(context.Background())
	if !svc.Store.HasMap(testKey) || svc.Store.HasTranscript(testKey) {
		t.Fatalf("map %v, transcript kept %v", svc.Store.HasMap(testKey), svc.Store.HasTranscript(testKey))
	}
	scan("mapped")
}

// A transcript file left by the earlier file-backed queue is removed on open.
func TestOpenStoreRemovesTranscriptsLeftOnDisk(t *testing.T) {
	dir := t.TempDir()
	old := filepath.Join(dir, "transcripts")
	if err := os.MkdirAll(old, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(old, testKey+".json"), []byte(`{"transcript":"left"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	store, err := OpenStore(dir)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(old); !errors.Is(err, fs.ErrNotExist) {
		t.Fatalf("the old transcripts directory survived: %v", err)
	}
	if store.HasTranscript(testKey) {
		t.Fatal("an old file came back as a waiting transcript")
	}
}

// A spend runs only when the transcript is about to be queued, and a failed
// spend queues nothing (#743).
func TestSubmitSpendingChargesOnlyQueuedWork(t *testing.T) {
	svc, _, _ := newService(t, newFakeAPI(t), 10)
	spent := 0
	spend := func() error { spent++; return nil }

	if out, err := svc.SubmitSpending(testTranscript(), func() error { return errors.New("token spent") }); out != SpendFailed || err == nil {
		t.Fatalf("failed spend: got %v %v, want SpendFailed", out, err)
	}
	if n, _ := svc.Store.CountTranscripts(); n != 0 {
		t.Fatalf("%d transcripts queued after a failed spend", n)
	}
	if out, err := svc.SubmitSpending(testTranscript(), spend); out != Accepted || err != nil || spent != 1 {
		t.Fatalf("first upload: %v %v, %d spends", out, err, spent)
	}
	if out, _ := svc.SubmitSpending(testTranscript(), spend); out != Accepted || spent != 1 {
		t.Fatalf("already waiting: %v, %d spends, want no new spend", out, spent)
	}
}

// Uploads of one episode racing with different tokens pay once between
// them, and racing uploads can't overfill the queue.
func TestSubmitSpendingRacesPayOnce(t *testing.T) {
	svc, _, _ := newService(t, newFakeAPI(t), 10)
	var spends atomic.Int32
	var wg sync.WaitGroup
	for i := 0; i < 16; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			svc.SubmitSpending(testTranscript(), func() error { spends.Add(1); return nil })
		}()
	}
	wg.Wait()
	if n := spends.Load(); n != 1 {
		t.Fatalf("%d spends for one queued transcript, want 1", n)
	}

	svc.MaxWaiting = 3
	for i := 0; i < 16; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			tr := testTranscript()
			tr.EpisodeKey = fmt.Sprintf("%064x", i+1)
			svc.SubmitSpending(tr, func() error { return nil })
		}(i)
	}
	wg.Wait()
	if n, _ := svc.Store.CountTranscripts(); n != 3 {
		t.Fatalf("%d transcripts waiting, want MaxWaiting 3", n)
	}
}

func TestNameGrounding(t *testing.T) {
	source := "Grace Hopper joined the navy. Hopper's compiler changed things in Boston."
	cases := []struct {
		summary string
		want    string
	}{
		{"The story of Grace Hopper in Boston.", ""},
		{"Hopper's compiler comes up.", ""},
		{"Dr. Hopper is introduced.", ""},                // abbreviation, not a sentence end
		{"Compilers matter. Lovelace is mentioned.", ""}, // sentence start is skipped
		{"A talk about Ada Lovelace.", "Ada"},
		{"The host visits Paris.", "Paris"},
		{"A short plain summary with no names.", ""},
	}
	for _, c := range cases {
		if got := ungroundedName(c.summary, source, "en"); got != c.want {
			t.Errorf("%q: got %q, want %q", c.summary, got, c.want)
		}
	}

	// Acronyms: a dotted form, initials of words in a row, and plurals.
	source = "Today we ask what A.I. means for the U.S. and why large language models hallucinate. The NFL weighs in."
	cases = []struct {
		summary string
		want    string
	}{
		{"How AI changes work.", ""},
		{"What the US makes of it.", ""},
		{"Why LLMs make things up.", ""},
		{"Why LLM answers drift.", ""},
		{"How the NFLs view it.", ""},
		{"The NBA weighs in.", "NBA"},     // no such initials or word
		{"Talk of Ng and friends.", "Ng"}, // not all capitals, so no initials
	}
	for _, c := range cases {
		if got := ungroundedName(c.summary, source, "en"); got != c.want {
			t.Errorf("%q: got %q, want %q", c.summary, got, c.want)
		}
	}
}
