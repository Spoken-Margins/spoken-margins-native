package api_test

import (
	"encoding/json"
	"log"
	"net/http"
	"net/http/httptest"
	"sort"
	"strings"
	"testing"
	"time"
)

// jsonLines decodes a log the server wrote, one JSON object per line.
func jsonLines(t *testing.T, text string) []map[string]any {
	t.Helper()
	var out []map[string]any
	for _, line := range strings.Split(strings.TrimSpace(text), "\n") {
		if line == "" {
			continue
		}
		var v map[string]any
		if err := json.Unmarshal([]byte(line), &v); err != nil {
			t.Fatalf("log line %q: %v", line, err)
		}
		out = append(out, v)
	}
	return out
}

func keysOf(v map[string]any) string {
	var keys []string
	for k := range v {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return strings.Join(keys, ",")
}

// The logs say what happened in which hour, and nothing finer: no minute, no
// second, no per-request line, no extra field that could identify a request
// or a client. The key sets are compared exactly, so a new field fails here
// and has to be argued for.
func TestLogsCarryTheHourAndNothingFiner(t *testing.T) {
	h := newHarness(t)
	clock := withClock(h)
	clock.Advance(34*time.Minute + 56*time.Second + 789*time.Millisecond) // 12:34:56.789
	c := h.client()
	c.Now = clock.Now
	if r, err := c.Register(); err != nil || r.Status != 201 {
		t.Fatalf("register: %v %v", r, err)
	}
	c.Get("/api/v1/health")
	c.Get("/api/v1/nothing-here")
	for i := 0; i < 6; i++ { // the harness allows 5 pings an hour per install
		c.Attested("/api/v1/ping", nil)
	}
	if err := h.srv.Flush(); err != nil {
		t.Fatal(err)
	}

	requests, abuse := jsonLines(t, h.reqLog.String()), jsonLines(t, h.abuseLog.String())
	if len(requests) < 4 || len(abuse) != 1 {
		t.Fatalf("expected request lines and one abuse line:\n%s\n%s", h.reqLog.String(), h.abuseLog.String())
	}
	for _, line := range requests {
		if line["hour"] != "2026-10-07T12" || keysOf(line) != "count,hour,latency,method,route,status" {
			t.Errorf("request line %v: want hour 2026-10-07T12 and exactly count, hour, latency, method, route, status", line)
		}
	}
	for _, line := range abuse {
		if line["hour"] != "2026-10-07T12" || keysOf(line) != "count,hour,reason,tag" {
			t.Errorf("abuse line %v: want hour 2026-10-07T12 and exactly count, hour, reason, tag", line)
		}
	}
	for _, text := range []string{h.reqLog.String(), h.abuseLog.String()} {
		if strings.Contains(text, "T12:") {
			t.Errorf("a log names the minute or second:\n%s", text)
		}
	}
}

// net/http's own message for a panic in a handler names the peer address, so
// the server catches the panic itself: the client gets a plain 500, the
// request is counted like any other, and net/http logs nothing. A server with
// no config reader panics in /api/v1/health, which stands in for any bug.
func TestPanicInAHandlerIsAnInternalErrorAndNamesNoPeer(t *testing.T) {
	h := newHarness(t)
	withClock(h)
	h.srv.Config = nil
	var netHTTPLog syncBuffer
	srv := httptest.NewUnstartedServer(h.srv.Handler())
	srv.Config.ErrorLog = log.New(&netHTTPLog, "", 0)
	srv.Start()
	t.Cleanup(srv.Close)

	resp, err := http.Get(srv.URL + "/api/v1/health")
	if err != nil {
		t.Fatalf("a panicking handler dropped the connection: %v", err)
	}
	var body map[string]string
	decodeJSON(t, resp, &body)
	if resp.StatusCode != 500 || body["error"] != "internal" {
		t.Fatalf("HTTP %d %v, want 500 internal", resp.StatusCode, body)
	}
	if err := h.srv.Flush(); err != nil {
		t.Fatal(err)
	}
	lines := jsonLines(t, h.reqLog.String())
	if len(lines) != 1 || lines[0]["route"] != "/api/v1/health" || lines[0]["status"] != float64(500) || lines[0]["count"] != float64(1) {
		t.Fatalf("request log after a panic: %s", h.reqLog.String())
	}
	if got := netHTTPLog.String(); got != "" {
		t.Fatalf("net/http logged the panic (with the peer's address):\n%s", got)
	}
}
