package api_test

import (
	"os"
	"regexp"
	"strings"
	"testing"
)

// caddyURIFilter reads the request>uri filter from the deployed Caddy
// global block and applies it the way Caddy's regexp log filter does
// (ReplaceAllString).
func caddyURIFilter(t *testing.T) func(string) string {
	t.Helper()
	b, err := os.ReadFile("../../../deploy/caddy-global.caddy")
	if err != nil {
		t.Fatal(err)
	}
	m := regexp.MustCompile(`request>uri regexp (\S+) (\S+)`).FindStringSubmatch(string(b))
	if m == nil {
		t.Fatal("no uri filter")
	}
	re := regexp.MustCompile(m[1])
	return func(uri string) string { return re.ReplaceAllString(uri, m[2]) }
}

// Review finding 1 on #2986: Caddy's error log (a 502 while smserver is
// down) kept the relay's query, which is the fetched URL and may hold a
// private feed's token.
func TestReviewCaddyErrorLogDropsRelayURL(t *testing.T) {
	logged := caddyURIFilter(t)("/api/v1/relay?url=https%3A%2F%2Ffeeds.example%2Fprivate%3Ftoken%3Dlistener-secret")
	if strings.Contains(logged, "listener-secret") || strings.Contains(logged, "url=") {
		t.Fatalf("Caddy error log would keep %q", logged)
	}
}

// Finding 1's class: anything private in a URI Caddy logs. Paths that name a
// share link or an episode are reduced to their route, as before, and no
// query string is logged on any route; other paths are kept for debugging.
func TestCaddyErrorLogKeepsOnlyRoutes(t *testing.T) {
	filter := caddyURIFilter(t)
	for in, want := range map[string]string{
		"/api/v1/relay?url=https%3A%2F%2Fa.example%2Ffeed": "/api/v1/relay?*",
		"/api/v1/relay?url=x&url=y":                        "/api/v1/relay?*",
		"/l/8badf00d8badf00d8badf00d8badf00d":              "/l/*",
		"/l/8badf00d8badf00d/packet":                       "/l/*",
		"/l/8badf00d/report?x=1":                           "/l/*",
		"/api/v1/maps/5ec2e7a1a1a1":                        "/api/v1/maps/*",
		"/api/v1/maps/transcripts":                         "/api/v1/maps/*",
		"/api/v1/health":                                   "/api/v1/health",
		"/api/v1/health?token=secret":                      "/api/v1/health?*",
		"/api/v1/ping?":                                    "/api/v1/ping?*",
		"/library?a=b?c=d":                                 "/library?*",
		"/":                                                "/",
	} {
		if got := filter(in); got != want {
			t.Errorf("%s logged as %q, want %q", in, got, want)
		}
	}
}
