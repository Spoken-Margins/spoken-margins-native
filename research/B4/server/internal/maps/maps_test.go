package maps

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
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
	if _, err := ParseTranscript([]byte(`{"schema":`)); err == nil {
		t.Error("broken JSON: accepted")
	}
}

func TestCheckAnswer(t *testing.T) {
	tr := testTranscript()
	scenes, err := CheckAnswer(tr, goodAnswer)
	if err != nil {
		t.Fatalf("good answer refused: %v", err)
	}
	want := []Scene{
		{StartMs: 0, EndMs: 7 * 60000},
		{StartMs: 7 * 60000, EndMs: 14 * 60000},
		{StartMs: 14 * 60000, EndMs: 20 * 60000},
	}
	for i, w := range want {
		if scenes[i].StartMs != w.StartMs || scenes[i].EndMs != w.EndMs || scenes[i].Title == "" {
			t.Fatalf("scene %d = %+v, want times %d-%d", i, scenes[i], w.StartMs, w.EndMs)
		}
	}

	quote := strings.Join(words(tr.Segments[7].Text)[2:12], " ") // ten words in a row
	bad := map[string]string{
		"malformed":    `{"scenes": [`,
		"two scenes":   answerJSON([3]string{"s0", "A", "B"}, [3]string{"s5", "C", "D"}),
		"unknown id":   answerJSON([3]string{"s0", "A", "B"}, [3]string{"s99", "C", "D"}, [3]string{"s15", "E", "F"}),
		"out of order": answerJSON([3]string{"s0", "A", "B"}, [3]string{"s14", "C", "D"}, [3]string{"s7", "E", "F"}),
		"same start":   answerJSON([3]string{"s0", "A", "B"}, [3]string{"s7", "C", "D"}, [3]string{"s7", "E", "F"}),
		"long title":   answerJSON([3]string{"s0", strings.Repeat("t", 81), "B"}, [3]string{"s7", "C", "D"}, [3]string{"s14", "E", "F"}),
		"long summary": answerJSON([3]string{"s0", "A", strings.Repeat("s", 301)}, [3]string{"s7", "C", "D"}, [3]string{"s14", "E", "F"}),
		"empty title":  answerJSON([3]string{"s0", " ", "B"}, [3]string{"s7", "C", "D"}, [3]string{"s14", "E", "F"}),
		"quotes":       answerJSON([3]string{"s0", "A", "B"}, [3]string{"s7", "C", "As they put it: " + strings.ToUpper(quote) + "!"}, [3]string{"s14", "E", "F"}),
		// A run that crosses from one segment into the next still counts.
		"quotes across segments": answerJSON([3]string{"s0", "A", strings.Join(append(words(tr.Segments[0].Text)[14:], words(tr.Segments[1].Text)[:5]...), " ")},
			[3]string{"s7", "C", "D"}, [3]string{"s14", "E", "F"}),
	}
	for name, text := range bad {
		if _, err := CheckAnswer(tr, text); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}
	// Nine words in a row is allowed.
	nine := strings.Join(words(tr.Segments[7].Text)[2:11], " ")
	ok := answerJSON([3]string{"s0", "A", "B"}, [3]string{"s7", "C", nine}, [3]string{"s14", "E", "F"})
	if _, err := CheckAnswer(tr, ok); err != nil {
		t.Errorf("nine copied words refused: %v", err)
	}
}

func TestWorkerMakesMapAndDeletesTranscript(t *testing.T) {
	api := newFakeAPI(t, goodAnswer)
	svc, _, logs := newService(t, api, 10)
	if out, err := svc.Submit(testTranscript()); err != nil || out != Accepted {
		t.Fatalf("submit = %v, %v", out, err)
	}
	if !svc.Store.HasTranscript(testKey) {
		t.Fatal("transcript not queued")
	}
	svc.ProcessWaiting(context.Background())

	if api.callCount() != 1 {
		t.Fatalf("calls = %d, want 1", api.callCount())
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
		m.CreatedAt != "2026-10-01T14:00:00Z" || len(m.Scenes) != 3 || m.DurationMs != 20*60000 {
		t.Fatalf("map = %s", data)
	}
	if strings.Contains(string(data), "lighthouse keeper number") {
		t.Fatal("map carries transcript text")
	}
	// The request named the model, asked for the scene schema, and sent the key.
	body := api.bodies[0]
	if body["model"] != DefaultModel || api.keys[0] != "sk-test-secret-key" {
		t.Fatalf("request model %v key %q", body["model"], api.keys[0])
	}
	if _, ok := body["output_config"].(map[string]any)["format"]; !ok {
		t.Fatalf("request has no output format: %v", body["output_config"])
	}
	// Cost: 13,000 in at $1/M plus 2,000 out at $5/M = $0.023.
	if spent := svc.Ledger.Spent(svc.Now()); spent != 23000 {
		t.Fatalf("ledger = %d micro-dollars, want 23000", spent)
	}
	// A second upload of the same episode makes no new work.
	if out, _ := svc.Submit(testTranscript()); out != AlreadyMapped || svc.Store.HasTranscript(testKey) {
		t.Fatalf("second submit = %v", out)
	}
	if containsAny(*logs, testKey) {
		t.Fatalf("log names the episode key: %v", *logs)
	}
}

func TestWorkerRetriesOnceThenDrops(t *testing.T) {
	tr := testTranscript()
	quote := strings.Join(words(tr.Segments[7].Text)[0:12], " ")
	bad := map[string]string{
		"malformed":    `not json`,
		"out of order": answerJSON([3]string{"s0", "A", "B"}, [3]string{"s14", "C", "D"}, [3]string{"s7", "E", "F"}),
		"quotes":       answerJSON([3]string{"s0", "A", "B"}, [3]string{"s7", "C", quote}, [3]string{"s14", "E", "F"}),
	}
	for name, answer := range bad {
		t.Run(name+" then good", func(t *testing.T) {
			api := newFakeAPI(t, answer, goodAnswer)
			svc, _, _ := newService(t, api, 10)
			svc.Submit(tr)
			svc.ProcessWaiting(context.Background())
			if api.callCount() != 2 || !svc.Store.HasMap(testKey) || svc.Store.HasTranscript(testKey) {
				t.Fatalf("calls %d, map %v, transcript %v", api.callCount(), svc.Store.HasMap(testKey), svc.Store.HasTranscript(testKey))
			}
		})
		t.Run(name+" twice", func(t *testing.T) {
			api := newFakeAPI(t, answer)
			svc, _, logs := newService(t, api, 10)
			svc.Submit(tr)
			svc.ProcessWaiting(context.Background())
			if api.callCount() != 2 || svc.Store.HasMap(testKey) || svc.Store.HasTranscript(testKey) {
				t.Fatalf("calls %d, map %v, transcript %v", api.callCount(), svc.Store.HasMap(testKey), svc.Store.HasTranscript(testKey))
			}
			if !containsAny(*logs, "dropped a transcript") {
				t.Fatalf("logs %v", *logs)
			}
			// Both failed answers were billed.
			if spent := svc.Ledger.Spent(svc.Now()); spent != 46000 {
				t.Fatalf("ledger = %d", spent)
			}
		})
	}
}

func TestCapStopsCallsAndUploads(t *testing.T) {
	api := newFakeAPI(t, goodAnswer)
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

	// Just under the cap, a call that could carry it over isn't made either.
	svc2, clock2, _ := newService(t, api, 10)
	svc2.Ledger.Add(clock2.Now(), USDToMicro(9.99))
	svc2.Submit(testTranscript())
	svc2.ProcessWaiting(context.Background())
	if api.callCount() != 0 {
		t.Fatalf("calls %d just under the cap", api.callCount())
	}

	// The next UTC month starts from zero.
	clock.Set(time.Date(2026, 11, 1, 0, 0, 1, 0, time.UTC))
	if out, _ := svc.Submit(testTranscript()); out != Accepted {
		t.Fatalf("submit in a new month = %v", out)
	}
	svc.ProcessWaiting(context.Background())
	if api.callCount() != 1 || !svc.Store.HasMap(testKey) {
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

func TestSweepDeletesOldTranscripts(t *testing.T) {
	store, _ := OpenStore(t.TempDir())
	t0 := time.Date(2026, 10, 1, 8, 0, 0, 0, time.UTC)
	store.PutTranscript(testTranscript(), t0)
	if n, _ := store.Sweep(t0.Add(22*time.Hour), TranscriptMaxAge); n != 0 || !store.HasTranscript(testKey) {
		t.Fatalf("swept a 22-hour-old transcript (%d)", n)
	}
	if n, _ := store.Sweep(t0.Add(24*time.Hour), TranscriptMaxAge); n != 1 || store.HasTranscript(testKey) {
		t.Fatalf("kept a 24-hour-old transcript (%d)", n)
	}
	// One that can't be read goes at once.
	os.WriteFile(store.transcriptPath(testKey), []byte("junk"), 0o600)
	if n, _ := store.Sweep(t0, TranscriptMaxAge); n != 1 {
		t.Fatalf("kept an unreadable transcript (%d)", n)
	}
}

func TestTakedownKeepsMapDown(t *testing.T) {
	api := newFakeAPI(t, goodAnswer)
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
	if svc.Store.HasTranscript(testKey) || api.callCount() != 1 {
		t.Fatal("upload after takedown made new work")
	}
	if _, err := svc.Store.Takedown("not-a-key"); err == nil {
		t.Fatal("takedown accepted a bad key")
	}
}

func TestProviderErrorsNeverCarryTheKey(t *testing.T) {
	api := newFakeAPI(t, goodAnswer)
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
	api := newFakeAPI(t, goodAnswer)
	api.fail = []int{529, 500}
	svc, _, _ := newService(t, api, 10)
	svc.Provider.(*Anthropic).Backoff = []time.Duration{0, 0}
	svc.Submit(testTranscript())
	svc.ProcessWaiting(context.Background())
	if api.callCount() != 3 || !svc.Store.HasMap(testKey) {
		t.Fatalf("calls %d, map %v", api.callCount(), svc.Store.HasMap(testKey))
	}
	// Overloaded answers bill nothing; only the good one is in the ledger.
	if spent := svc.Ledger.Spent(svc.Now()); spent != 23000 {
		t.Fatalf("ledger = %d", spent)
	}
}
