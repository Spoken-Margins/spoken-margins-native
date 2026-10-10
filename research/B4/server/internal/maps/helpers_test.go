package maps

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

const testKey = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

// testTranscript is a 20-segment episode, one minute a segment, whose text
// is distinct enough for the copy check to bite.
func testTranscript() Transcript {
	t := Transcript{Schema: TranscriptSchema, EpisodeKey: testKey, DurationMs: 20 * 60000, Language: "en"}
	for i := 0; i < 20; i++ {
		t.Segments = append(t.Segments, Segment{
			ID:      fmt.Sprintf("s%d", i),
			StartMs: int64(i) * 60000,
			EndMs:   int64(i+1) * 60000,
			Text:    fmt.Sprintf("In part %d the host walks through the history of lighthouse keeper number %d and the storms they logged.", i, i),
		})
	}
	return t
}

func answerJSON(scenes ...[3]string) string {
	type sc struct {
		FirstSegmentID string `json:"firstSegmentId"`
		Title          string `json:"title"`
		Summary        string `json:"summary"`
	}
	var a struct {
		Scenes []sc `json:"scenes"`
	}
	for _, s := range scenes {
		a.Scenes = append(a.Scenes, sc{s[0], s[1], s[2]})
	}
	data, _ := json.Marshal(a)
	return string(data)
}

var goodAnswer = answerJSON(
	[3]string{"s0", "Opening", "The host sets out why old coastal stations matter."},
	[3]string{"s7", "Keepers", "Who tended the lights and what daily duty looked like."},
	[3]string{"s14", "Storm logs", "Records of severe weather and what they reveal."},
)

// fakeAPI stands in for Anthropic's Messages API. Each call takes the next
// answer; the last one repeats.
type fakeAPI struct {
	*httptest.Server
	mu      sync.Mutex
	answers []string
	calls   int
	bodies  []map[string]any
	keys    []string
	status  int   // when nonzero, every call fails with this status
	fail    []int // statuses for the first calls, before any answer
	// stopReason overrides "end_turn", the reason of a finished answer.
	stopReason string
	// cacheWrite and cacheRead are reported as cache token usage.
	cacheWrite, cacheRead int
}

func newFakeAPI(t *testing.T, answers ...string) *fakeAPI {
	f := &fakeAPI{answers: answers}
	f.Server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		f.mu.Lock()
		defer f.mu.Unlock()
		if r.URL.Path != "/v1/messages" {
			http.NotFound(w, r)
			return
		}
		f.calls++
		f.keys = append(f.keys, r.Header.Get("X-Api-Key"))
		data, _ := io.ReadAll(r.Body)
		var body map[string]any
		json.Unmarshal(data, &body)
		f.bodies = append(f.bodies, body)
		w.Header().Set("Content-Type", "application/json")
		status := f.status
		if len(f.fail) > 0 {
			status, f.fail = f.fail[0], f.fail[1:]
		}
		if status != 0 {
			w.WriteHeader(status)
			fmt.Fprintf(w, `{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key %s"}}`, r.Header.Get("X-Api-Key"))
			return
		}
		text := f.answers[0]
		if len(f.answers) > 1 {
			text, f.answers = f.answers[0], f.answers[1:]
		}
		stopReason := "end_turn"
		if f.stopReason != "" {
			stopReason = f.stopReason
		}
		json.NewEncoder(w).Encode(map[string]any{
			"id": "msg_test", "type": "message", "role": "assistant", "model": DefaultModel,
			"content":     []map[string]any{{"type": "text", "text": text}},
			"stop_reason": stopReason, "stop_sequence": nil,
			"usage": map[string]any{
				"input_tokens": 13000, "output_tokens": 2000,
				"cache_creation_input_tokens": f.cacheWrite, "cache_read_input_tokens": f.cacheRead,
			},
		})
	}))
	t.Cleanup(f.Close)
	return f
}

func (f *fakeAPI) callCount() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.calls
}

// fakeClock is a settable time source.
type fakeClock struct {
	mu  sync.Mutex
	now time.Time
}

func (c *fakeClock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.now
}

func (c *fakeClock) Set(t time.Time) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.now = t
}

// newService builds a service against the fake API in a temp directory.
func newService(t *testing.T, api *fakeAPI, capUSD float64) (*Service, *fakeClock, *[]string) {
	t.Helper()
	dir := t.TempDir()
	store, err := OpenStore(dir)
	if err != nil {
		t.Fatal(err)
	}
	ledger, err := OpenLedger(dir + "/ledger.json")
	if err != nil {
		t.Fatal(err)
	}
	provider, err := NewAnthropic("sk-test-secret-key", "", api.URL)
	if err != nil {
		t.Fatal(err)
	}
	clock := &fakeClock{now: time.Date(2026, 10, 1, 14, 30, 0, 0, time.UTC)}
	var logs []string
	var mu sync.Mutex
	svc := &Service{
		Store: store, Ledger: ledger, Provider: provider,
		Prices:      Prices{InputPerMTok: 1, OutputPerMTok: 5},
		CapMicroUSD: USDToMicro(capUSD),
		Now:         clock.Now,
		Logf: func(format string, args ...any) {
			mu.Lock()
			defer mu.Unlock()
			logs = append(logs, fmt.Sprintf(format, args...))
		},
	}
	return svc, clock, &logs
}

func containsAny(haystack []string, needle string) bool {
	for _, h := range haystack {
		if strings.Contains(h, needle) {
			return true
		}
	}
	return false
}
