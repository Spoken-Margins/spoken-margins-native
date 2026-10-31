package api_test

// Tests for the security review on #2986 (#2988), and the siblings of each
// finding.

import (
	"net/http"
	"net/http/httptest"
	"net/url"
	"testing"

	"spokenmargins.dev/bridge/internal/api"
	"spokenmargins.dev/bridge/internal/config"
)

// reviewRelayHarness is newHarness with testRelay and the relay switch on.
func reviewRelayHarness(t *testing.T) (*harness, string) {
	t.Helper()
	h := newHarness(t)
	rl, target := testRelay(t, "<rss/>")
	h.srv.Relay = rl
	if _, err := config.Set(h.configPath, config.ServiceRelay, true); err != nil {
		t.Fatal(err)
	}
	return h, target
}

func reviewGet(t *testing.T, h *harness, target string, headers map[string]string) int {
	t.Helper()
	req, _ := http.NewRequest("GET", h.http.URL+api.PathRelay+"?url="+url.QueryEscape(target), nil)
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	return resp.StatusCode
}

// Finding 3: one IPv6 client owns a /64, so a limit keyed per address gave
// it a fresh budget for every address it picked.
func TestReviewRelayLimitCoversAnIPv6Slash64(t *testing.T) {
	h, target := reviewRelayHarness(t)
	h.srv.TrustForwardedFor = true
	h.srv.RelayPerIPPerHour = 1
	o := map[string]string{"Origin": webOrigin, "X-Forwarded-For": "2001:db8:1:2::1"}
	if code := reviewGet(t, h, target, o); code != 200 {
		t.Fatalf("first: %d", code)
	}
	o["X-Forwarded-For"] = "2001:db8:1:2::2"
	if code := reviewGet(t, h, target, o); code != 429 {
		t.Fatalf("second address in the same /64 got %d, want 429", code)
	}
}

// Finding 3's class: clientKey is shared by every hourly limit (challenges,
// map uploads, links, link reports, the relay), so it is tested directly
// through the relay for each way an address can arrive.
func TestClientKeyGroupsIPv6ByItsSlash64(t *testing.T) {
	cases := []struct {
		name        string
		trust       bool
		first, next string // RemoteAddr or X-Forwarded-For
		same        bool
	}{
		{"peer, same /64", false, "[2001:db8:1:2::1]:4000", "[2001:db8:1:2:ffff::9]:5000", true},
		{"peer, next /64", false, "[2001:db8:1:2::1]:4000", "[2001:db8:1:3::1]:4000", false},
		{"forwarded, upper case and zero-padded", true, "2001:db8:1:2::1", "2001:0DB8:0001:0002::7", true},
		{"forwarded, next /64", true, "2001:db8:1:2::1", "2001:db8:1:3::1", false},
		{"forwarded IPv4 stays per address", true, "203.0.113.7", "203.0.113.8", false},
		{"forwarded IPv4-mapped is the IPv4 address", true, "::ffff:203.0.113.7", "203.0.113.7", true},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			h, target := reviewRelayHarness(t)
			h.srv.TrustForwardedFor = c.trust
			h.srv.RelayPerIPPerHour = 1
			handler := h.srv.Handler()
			send := func(addr string) int {
				req := httptest.NewRequest(http.MethodGet, api.PathRelay+"?url="+url.QueryEscape(target), nil)
				req.Header.Set("Origin", webOrigin)
				if c.trust {
					req.RemoteAddr = "127.0.0.1:4000"
					req.Header.Set("X-Forwarded-For", addr)
				} else {
					req.RemoteAddr = addr
				}
				rec := httptest.NewRecorder()
				handler.ServeHTTP(rec, req)
				return rec.Code
			}
			if code := send(c.first); code != 200 {
				t.Fatalf("first: %d", code)
			}
			want := 200
			if c.same {
				want = 429
			}
			if code := send(c.next); code != want {
				t.Fatalf("%s after %s: %d, want %d", c.next, c.first, code, want)
			}
		})
	}
}

// Finding 4: a cross-site <img> is a no-cors GET with no Origin.
func TestReviewRefusesNoCorsBrowserFetch(t *testing.T) {
	h, target := reviewRelayHarness(t)
	code := reviewGet(t, h, target, map[string]string{"Sec-Fetch-Mode": "no-cors", "Sec-Fetch-Site": "cross-site", "Sec-Fetch-Dest": "image"})
	if code == 200 {
		t.Fatal("a cross-site no-cors subresource request was relayed")
	}
}

// A page on another site can't spend a visitor's hourly budget either: a
// refused caller is answered before the limit counts it.
func TestRefusedCallersDoNotSpendTheBudget(t *testing.T) {
	h, target := reviewRelayHarness(t)
	h.srv.RelayPerIPPerHour = 1
	for _, hdr := range []map[string]string{{}, {"Origin": "https://evil.example"}} {
		for i := 0; i < 3; i++ {
			if code := reviewGet(t, h, target, hdr); code != 403 {
				t.Fatalf("refused caller %v: %d, want 403", hdr, code)
			}
		}
	}
	if code := reviewGet(t, h, target, map[string]string{"Origin": webOrigin}); code != 200 {
		t.Fatalf("the web app after refusals: %d, want 200", code)
	}
}
