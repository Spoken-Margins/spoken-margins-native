package api_test

import (
	"bytes"
	"crypto/hkdf"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
	"time"

	"spokenmargins.dev/bridge/internal/api"
	"spokenmargins.dev/bridge/internal/clubs"
	"spokenmargins.dev/bridge/internal/config"
	"spokenmargins.dev/bridge/internal/links"
)

// The club mailbox through the real handler (#1799, docs/design/club-mailbox.md). A phone makes a club
// from one 32-byte secret K: four values come out of it with HKDF-SHA-256, the server gets the id and the
// hashes of two proofs, and every member who holds the link derives the same values and talks to the box.

type clubHarness struct {
	t          *testing.T
	srv        *api.Server
	h          http.Handler
	clock      *stepClock
	configPath string
	stateDir   string
	reqLog     *syncBuffer
	abuseLog   *syncBuffer
}

func newClubHarness(t *testing.T) *clubHarness {
	t.Helper()
	s, path := linkServer(t)
	stateDir := filepath.Join(filepath.Dir(s.PublicDir), "state")
	st, err := clubs.OpenStore(filepath.Join(stateDir, "clubs"))
	if err != nil {
		t.Fatal(err)
	}
	s.Clubs = st
	c := &clubHarness{t: t, srv: s, configPath: path, stateDir: stateDir, reqLog: &syncBuffer{}, abuseLog: &syncBuffer{}}
	c.clock = &stepClock{t: time.Date(2026, 11, 12, 13, 14, 15, 0, time.UTC)}
	s.Now = c.clock.Now
	s.RequestLog, s.AbuseLog = c.reqLog, c.abuseLog
	if _, err := config.Set(path, config.ServiceClubs, true); err != nil {
		t.Fatal(err)
	}
	c.h = s.Handler()
	return c
}

// clubKeys are what a phone derives from K (design section 2): the info strings and lengths are the design's.
type clubKeys struct {
	id, read, post, readHash, postHash string
	seal                               []byte
}

func deriveClub(t *testing.T, k []byte) clubKeys {
	t.Helper()
	derive := func(info string, n int) []byte {
		b, err := hkdf.Key(sha256.New, k, nil, info, n)
		if err != nil {
			t.Fatal(err)
		}
		return b
	}
	hash := func(b []byte) string { h := sha256.Sum256(b); return hex.EncodeToString(h[:]) }
	read, post := derive("sm-club-read-v1", 32), derive("sm-club-post-v1", 32)
	return clubKeys{
		id: hex.EncodeToString(derive("sm-club-id-v1", 16)), read: hex.EncodeToString(read), post: hex.EncodeToString(post),
		readHash: hash(read), postHash: hash(post), seal: derive("sm-club-seal-v1", 32),
	}
}

func secretK(seed byte) []byte {
	k := make([]byte, 32)
	for i := range k {
		k[i] = seed*7 + byte(i)*3
	}
	return k
}

// sealedPart is a part with the real sealed header and recognisable filler.
func sealedPart(part byte, n int, marker string) []byte {
	b := append([]byte("SMLINK"), 1, part)
	b = append(b, bytes.Repeat([]byte{0xA5}, n-8)...)
	copy(b[8:], marker)
	return b
}

type reply struct {
	code int
	body []byte
	hdr  http.Header
}

func (r reply) errCode() string {
	var v struct{ Error string }
	json.Unmarshal(r.body, &v)
	return v.Error
}

func (c *clubHarness) do(method, path string, body io.Reader, proof, addr string) reply {
	c.t.Helper()
	r := httptest.NewRequest(method, path, body)
	r.RemoteAddr = addr + ":4321"
	if proof != "" {
		r.Header.Set("Authorization", "Bearer "+proof)
	}
	w := httptest.NewRecorder()
	c.h.ServeHTTP(w, r)
	out, _ := io.ReadAll(w.Result().Body)
	return reply{code: w.Code, body: out, hdr: w.Result().Header}
}

const clubAddr = "192.0.2.77"

func createBody(k clubKeys, header []byte) []byte {
	b, _ := json.Marshal(map[string]string{"id": k.id, "readHash": k.readHash, "postHash": k.postHash, "header": base64.StdEncoding.EncodeToString(header)})
	return b
}

func (c *clubHarness) create(k clubKeys, header []byte, addr string) reply {
	c.t.Helper()
	return c.do("POST", api.PathClubs, bytes.NewReader(createBody(k, header)), "", addr)
}

func (c *clubHarness) post(k clubKeys, packet []byte, addr string) reply {
	c.t.Helper()
	return c.do("POST", api.PathClubs+"/"+k.id+"/posts", bytes.NewReader(packet), k.post, addr)
}

func (c *clubHarness) list(k clubKeys, after int, addr string) reply {
	c.t.Helper()
	return c.do("GET", fmt.Sprintf("%s/%s/posts?after=%d", api.PathClubs, k.id, after), nil, k.read, addr)
}

func (c *clubHarness) item(k clubKeys, seq int, addr string) reply {
	c.t.Helper()
	return c.do("GET", fmt.Sprintf("%s/%s/posts/%d", api.PathClubs, k.id, seq), nil, k.read, addr)
}

type listing struct {
	Posts []struct {
		Seq  int
		Size int
	}
}

// The design's Done when for the server: one member makes a club, nine join with only the link, each posts
// three packets spread over test time (the per-address limit is 30 writes an hour), each fetches, and all
// ten end with the same 30 posts and no duplicate.
func TestTenMemberClubEndsWithTheSameThirtyPosts(t *testing.T) {
	c := newClubHarness(t)
	k := secretK(1)
	creator := deriveClub(t, k)
	header := sealedPart(links.PartClubHeader, 96, "the club's sealed name")
	if r := c.create(creator, header, clubAddr); r.code != 201 {
		t.Fatalf("create: HTTP %d %s", r.code, r.body)
	}
	c.clock.Advance(time.Hour) // the create used one of this address's 30 writes for its hour

	type member struct{ keys clubKeys }
	var members []member
	for i := 0; i < 10; i++ {
		// The creator and the nine joiners each hold only K, as a link carries it.
		members = append(members, member{deriveClub(t, k)})
	}
	for i, m := range members[1:] {
		got := c.item(m.keys, 0, clubAddr)
		if got.code != 200 || !bytes.Equal(got.body, header) {
			t.Fatalf("joiner %d: header HTTP %d, bytes equal %v", i, got.code, bytes.Equal(got.body, header))
		}
	}

	sent := map[string][]byte{}
	for round := 0; round < 3; round++ {
		for mi, m := range members {
			packet := sealedPart(2, 120+round*7+mi, fmt.Sprintf("member %d post %d", mi, round))
			r := c.post(m.keys, packet, clubAddr)
			if r.code != 201 {
				t.Fatalf("member %d round %d: HTTP %d %s", mi, round, r.code, r.body)
			}
			var out struct{ Seq int }
			json.Unmarshal(r.body, &out)
			sent[fmt.Sprint(out.Seq)] = packet
			c.clock.Advance(2 * time.Minute) // 30 posts over 58 minutes, inside one hour's 30
		}
	}
	if len(sent) != 30 {
		t.Fatalf("%d distinct post numbers from 30 posts", len(sent))
	}

	var firstView []string
	for mi, m := range members {
		l := c.list(m.keys, 0, "198.51.100."+fmt.Sprint(mi+1))
		var got listing
		if l.code != 200 || json.Unmarshal(l.body, &got) != nil || len(got.Posts) != 30 {
			t.Fatalf("member %d: list HTTP %d with %d posts, want 30: %s", mi, l.code, len(got.Posts), l.body)
		}
		var view []string
		seen := map[string]bool{}
		for i, p := range got.Posts {
			if p.Seq != i+1 {
				t.Fatalf("member %d: numbers jump at %d", mi, p.Seq)
			}
			r := c.item(m.keys, p.Seq, "198.51.100."+fmt.Sprint(mi+1))
			if r.code != 200 || !bytes.Equal(r.body, sent[fmt.Sprint(p.Seq)]) || p.Size != len(r.body) {
				t.Fatalf("member %d: post %d came back changed (HTTP %d)", mi, p.Seq, r.code)
			}
			sum := sha256.Sum256(r.body)
			d := hex.EncodeToString(sum[:])
			if seen[d] {
				t.Fatalf("member %d: a duplicate post", mi)
			}
			seen[d] = true
			view = append(view, d)
		}
		if mi == 0 {
			firstView = view
		} else if strings.Join(view, ",") != strings.Join(firstView, ",") {
			t.Fatalf("member %d ends with other posts than member 0", mi)
		}
	}
	// A member who already has 17 asks only for what came after.
	var tail listing
	r := c.list(members[3].keys, 17, clubAddr)
	json.Unmarshal(r.body, &tail)
	if len(tail.Posts) != 13 || tail.Posts[0].Seq != 18 {
		t.Fatalf("after=17: %d posts starting at %d, want 13 from 18", len(tail.Posts), tail.Posts[0].Seq)
	}
}

func TestClubsAreOffUntilTheSwitchIsOnAndHealthStaysUp(t *testing.T) {
	c := newClubHarness(t)
	k := deriveClub(t, secretK(2))
	if _, err := config.Set(c.configPath, config.ServiceClubs, false); err != nil {
		t.Fatal(err)
	}
	header := sealedPart(links.PartClubHeader, 64, "h")
	for name, r := range map[string]reply{
		"create": c.create(k, header, clubAddr),
		"post":   c.post(k, sealedPart(2, 64, "p"), clubAddr),
		"list":   c.list(k, 0, clubAddr),
		"item":   c.item(k, 0, clubAddr),
	} {
		if r.code != 503 || r.errCode() != "disabled" || r.hdr.Get("Retry-After") == "" {
			t.Errorf("%s with clubs off: HTTP %d %s, want 503 disabled", name, r.code, r.body)
		}
	}
	h := c.do("GET", "/api/v1/health", nil, "", clubAddr)
	var health struct{ Services map[string]string }
	json.Unmarshal(h.body, &health)
	if h.code != 200 || health.Services["clubs"] != "off" {
		t.Fatalf("health with clubs off: %d %v", h.code, health.Services)
	}
	if config.Default().Enabled(config.ServiceClubs) {
		t.Fatal("clubs are on in the default config: a new switch must start off")
	}
	// On, but with no store (the folder could not be opened), still 503.
	if _, err := config.Set(c.configPath, config.ServiceClubs, true); err != nil {
		t.Fatal(err)
	}
	if r := c.create(k, header, clubAddr); r.code != 201 {
		t.Fatalf("create with clubs on: HTTP %d %s", r.code, r.body)
	}
	c.srv.Clubs = nil
	if r := c.list(k, 0, clubAddr); r.code != 503 {
		t.Fatalf("no store: HTTP %d, want 503", r.code)
	}
}

func TestCreateAnswers(t *testing.T) {
	c := newClubHarness(t)
	k := deriveClub(t, secretK(3))
	header := sealedPart(links.PartClubHeader, 64, "h")
	if r := c.create(k, header, clubAddr); r.code != 201 {
		t.Fatalf("create: %d %s", r.code, r.body)
	}
	// A retry after a lost answer: 200, and the stored header is the first one.
	if r := c.create(k, sealedPart(links.PartClubHeader, 80, "retry"), clubAddr); r.code != 200 {
		t.Fatalf("repeat: %d %s", r.code, r.body)
	}
	if got := c.item(k, 0, clubAddr); !bytes.Equal(got.body, header) {
		t.Fatal("a repeat replaced the header")
	}
	other := deriveClub(t, secretK(4))
	clash := other
	clash.id = k.id
	if r := c.create(clash, header, clubAddr); r.code != 409 || r.errCode() != "id_in_use" {
		t.Fatalf("same id, other hashes: %d %s", r.code, r.body)
	}
	good := func(m map[string]string) []byte { b, _ := json.Marshal(m); return b }
	fresh := deriveClub(t, secretK(5))
	base := map[string]string{"id": fresh.id, "readHash": fresh.readHash, "postHash": fresh.postHash, "header": base64.StdEncoding.EncodeToString(header)}
	with := func(k, v string) []byte {
		m := map[string]string{}
		for a, b := range base {
			m[a] = b
		}
		m[k] = v
		return good(m)
	}
	for name, tc := range map[string]struct {
		body []byte
		code int
		err  string
	}{
		"not json":              {[]byte("id=1"), 400, "bad_request"},
		"empty":                 {nil, 400, "bad_request"},
		"unknown field":         {with("member", "me"), 400, "bad_request"},
		"two documents":         {append(good(base), good(base)...), 400, "bad_request"},
		"bad base64":            {with("header", "***"), 400, "bad_request"},
		"short id":              {with("id", fresh.id[:30]), 400, "bad_request"},
		"bad hash":              {with("readHash", "zz"), 400, "bad_request"},
		"plain text header":     {with("header", base64.StdEncoding.EncodeToString(bytes.Repeat([]byte("x"), 64))), 400, "bad_packet"},
		"a packet as a header":  {with("header", base64.StdEncoding.EncodeToString(sealedPart(2, 64, "p"))), 400, "bad_packet"},
		"header over its limit": {with("header", base64.StdEncoding.EncodeToString(sealedPart(links.PartClubHeader, clubs.MaxHeaderBytes+1, "h"))), 413, "too_large"},
		"body over its limit":   {with("header", strings.Repeat("A", 40<<10)), 413, "too_large"},
	} {
		r := c.do("POST", api.PathClubs, bytes.NewReader(tc.body), "", clubAddr)
		if r.code != tc.code || r.errCode() != tc.err {
			t.Errorf("%s: HTTP %d %s, want %d %s", name, r.code, r.body, tc.code, tc.err)
		}
		c.clock.Advance(time.Hour) // keep these checks clear of the rate limit
	}
	if r := c.create(fresh, header, clubAddr); r.code != 201 {
		t.Fatalf("a club after all those refusals: %d %s", r.code, r.body)
	}
}

// Anyone without the proof, for a club that exists, one that ended, one disabled, or none at all, gets the
// same answer byte for byte. A member with the proof learns the club is gone.
func TestStrangersCannotTellWhichIdsAreClubs(t *testing.T) {
	c := newClubHarness(t)
	live, ended, disabled, never := deriveClub(t, secretK(6)), deriveClub(t, secretK(7)), deriveClub(t, secretK(8)), deriveClub(t, secretK(9))
	for _, k := range []clubKeys{live, ended, disabled} {
		if r := c.create(k, sealedPart(links.PartClubHeader, 64, "h"), clubAddr); r.code != 201 {
			t.Fatalf("create: %d %s", r.code, r.body)
		}
		if r := c.post(k, sealedPart(2, 64, "p"), "203.0.113.5"); r.code != 201 {
			t.Fatalf("post: %d %s", r.code, r.body)
		}
		c.clock.Advance(time.Hour)
	}
	if err := c.srv.Clubs.Takedown(ended.id, c.clock.Now()); err != nil {
		t.Fatal(err)
	}
	if err := c.srv.Clubs.Disable(disabled.id, c.clock.Now()); err != nil {
		t.Fatal(err)
	}
	stranger := deriveClub(t, secretK(10))
	bad := map[string]string{"": "", "short": "abcd", "upper": strings.ToUpper(live.read), "another club's": stranger.read, "the post proof": live.post}
	var want reply
	n := 0
	for _, k := range []clubKeys{live, ended, disabled, never} {
		for name, proof := range bad {
			for _, call := range []struct {
				what   string
				method string
				path   string
				body   []byte
			}{
				{"list", "GET", "/posts?after=0", nil},
				{"header", "GET", "/posts/0", nil},
				{"item", "GET", "/posts/1", nil},
				{"missing item", "GET", "/posts/99", nil},
				{"bad number", "GET", "/posts/x", nil},
				{"post", "POST", "/posts", sealedPart(2, 64, "p")},
			} {
				p := proof
				if call.what == "post" && name == "the post proof" {
					p = stranger.post
				}
				r := c.do(call.method, api.PathClubs+"/"+k.id+call.path, bytes.NewReader(call.body), p, "198.51.100.9")
				c.clock.Advance(time.Minute)
				if n == 0 {
					want = r
				}
				n++
				if r.code != 404 || r.errCode() != "not_found" || !bytes.Equal(r.body, want.body) {
					t.Errorf("%s %s with %s proof: HTTP %d %s, want the one 404 not_found", call.what, k.id[:6], name, r.code, r.body)
				}
				if r.hdr.Get("Retry-After") != "" {
					t.Errorf("a stranger's answer carried Retry-After")
				}
				c.clock.Advance(time.Hour) // never reach the per-address limit
			}
		}
	}
	// A member of a club that ended or was disabled is told so; a member of a live club is served.
	for name, k := range map[string]clubKeys{"ended": ended, "disabled": disabled} {
		for what, r := range map[string]reply{"list": c.list(k, 0, clubAddr), "header": c.item(k, 0, clubAddr), "post": c.post(k, sealedPart(2, 64, "p"), "203.0.113.6")} {
			if r.code != 410 || r.errCode() != "expired_or_removed" {
				t.Errorf("a member of the %s club, %s: HTTP %d %s, want 410", name, what, r.code, r.body)
			}
		}
	}
	if r := c.list(live, 0, clubAddr); r.code != 200 {
		t.Errorf("a member of the live club: HTTP %d", r.code)
	}
	// The same ids, asked for a club with the right proof but over the post path with the wrong kind.
	if r := c.do("POST", api.PathClubs+"/"+live.id+"/posts", bytes.NewReader(sealedPart(2, 64, "p")), live.read, "203.0.113.7"); r.code != 404 {
		t.Errorf("posting with the read proof: HTTP %d, want 404", r.code)
	}
}

// A stranger's post is refused before its body is read, so it cannot make the server buffer a packet.
type countingBody struct{ read int }

func (b *countingBody) Read(p []byte) (int, error) {
	b.read += len(p)
	for i := range p {
		p[i] = 0
	}
	return len(p), nil
}

func TestAStrangersPostIsRefusedBeforeItsBodyIsRead(t *testing.T) {
	c := newClubHarness(t)
	k := deriveClub(t, secretK(11))
	c.create(k, sealedPart(links.PartClubHeader, 64, "h"), clubAddr)
	body := &countingBody{}
	r := httptest.NewRequest("POST", api.PathClubs+"/"+k.id+"/posts", body)
	r.Header.Set("Authorization", "Bearer "+hex.EncodeToString(bytes.Repeat([]byte{1}, 32)))
	r.RemoteAddr = "198.51.100.1:1"
	w := httptest.NewRecorder()
	c.h.ServeHTTP(w, r)
	if w.Code != 404 || body.read != 0 {
		t.Fatalf("HTTP %d after reading %d bytes, want 404 after reading none", w.Code, body.read)
	}
	// A member whose declared length is over the cap is refused without reading either.
	body = &countingBody{}
	r = httptest.NewRequest("POST", api.PathClubs+"/"+k.id+"/posts", body)
	r.ContentLength = clubs.MaxPostBytes + 1
	r.Header.Set("Authorization", "Bearer "+k.post)
	r.RemoteAddr = "198.51.100.2:1"
	w = httptest.NewRecorder()
	c.h.ServeHTTP(w, r)
	if w.Code != 413 || body.read != 0 {
		t.Fatalf("HTTP %d after reading %d bytes, want 413 after reading none", w.Code, body.read)
	}
}

func TestPostsAreRefusedWhenTheyAreNotPacketsOrAreTooBig(t *testing.T) {
	c := newClubHarness(t)
	k := deriveClub(t, secretK(12))
	c.create(k, sealedPart(links.PartClubHeader, 64, "h"), clubAddr)
	c.clock.Advance(time.Hour)
	for name, tc := range map[string]struct {
		body []byte
		code int
		err  string
	}{
		"empty":              {nil, 400, "bad_packet"},
		"plain text":         {bytes.Repeat([]byte("hello"), 30), 400, "bad_packet"},
		"a header as a post": {sealedPart(links.PartClubHeader, 64, "h"), 400, "bad_packet"},
		"over 20 MB":         {sealedPart(2, clubs.MaxPostBytes+1, "big"), 413, "too_large"},
	} {
		r := c.post(k, tc.body, "198.51.100.3")
		c.clock.Advance(time.Hour)
		if r.code != tc.code || r.errCode() != tc.err {
			t.Errorf("%s: HTTP %d %s, want %d %s", name, r.code, r.body, tc.code, tc.err)
		}
	}
	if r := c.post(k, sealedPart(2, clubs.MaxPostBytes, "max"), "198.51.100.4"); r.code != 201 {
		t.Errorf("a post of exactly 20 MB: HTTP %d %s", r.code, r.body)
	}
}

func TestCapsAnswerClubFullAndFull(t *testing.T) {
	c := newClubHarness(t)
	c.srv.Clubs.Limits = clubs.Limits{MaxPosts: 2, MaxClubBytes: 1 << 20, MaxTotalBytes: 1 << 20}
	k := deriveClub(t, secretK(13))
	c.create(k, sealedPart(links.PartClubHeader, 64, "h"), clubAddr)
	for i := 0; i < 2; i++ {
		if r := c.post(k, sealedPart(2, 100, "p"), clubAddr); r.code != 201 {
			t.Fatalf("post %d: %d %s", i, r.code, r.body)
		}
	}
	if r := c.post(k, sealedPart(2, 100, "p"), clubAddr); r.code != 409 || r.errCode() != "club_full" {
		t.Fatalf("a third post: HTTP %d %s, want 409 club_full", r.code, r.body)
	}
	// The folder's own cap: 503 full, with Retry-After, which the app already reads as "couldn't right now".
	c.srv.Clubs.Limits = clubs.Limits{MaxPosts: 50, MaxClubBytes: 1 << 20, MaxTotalBytes: c.srv.Clubs.Total() + 10}
	r := c.post(k, sealedPart(2, 100, "p"), clubAddr)
	if r.code != 503 || r.errCode() != "full" || r.hdr.Get("Retry-After") == "" {
		t.Fatalf("a post past the folder's cap: HTTP %d %s", r.code, r.body)
	}
	other := deriveClub(t, secretK(14))
	if r := c.create(other, sealedPart(links.PartClubHeader, 64, "h"), clubAddr); r.code != 503 || r.errCode() != "full" {
		t.Fatalf("a club past the folder's cap: HTTP %d %s", r.code, r.body)
	}
}

func TestPerAddressLimits(t *testing.T) {
	c := newClubHarness(t)
	k := deriveClub(t, secretK(15))
	if r := c.create(k, sealedPart(links.PartClubHeader, 64, "h"), clubAddr); r.code != 201 {
		t.Fatalf("create: %d", r.code)
	}
	// 29 more writes make 30 in the hour; the 31st is refused, even one with a wrong proof, which counts.
	for i := 0; i < 29; i++ {
		if r := c.post(k, sealedPart(2, 64, "p"), clubAddr); r.code != 201 {
			t.Fatalf("write %d: %d %s", i+2, r.code, r.body)
		}
	}
	for what, r := range map[string]reply{
		"a post":                  c.post(k, sealedPart(2, 64, "p"), clubAddr),
		"a create":                c.create(deriveClub(t, secretK(16)), sealedPart(links.PartClubHeader, 64, "h"), clubAddr),
		"a post with a bad proof": c.do("POST", api.PathClubs+"/"+k.id+"/posts", bytes.NewReader(sealedPart(2, 64, "p")), "x", clubAddr),
	} {
		if r.code != 429 || r.errCode() != "rate_limited" {
			t.Errorf("the 31st write (%s): HTTP %d %s, want 429", what, r.code, r.body)
		}
	}
	// Another network is unaffected, reads are never counted, and the hour ends the limit.
	if r := c.post(k, sealedPart(2, 64, "p"), "198.51.100.50"); r.code != 201 {
		t.Errorf("another address: %d", r.code)
	}
	for i := 0; i < 150; i++ {
		if r := c.list(k, 0, clubAddr); r.code != 200 {
			t.Fatalf("read %d from the limited address: %d", i, r.code)
		}
	}
	c.clock.Advance(time.Hour)
	if r := c.post(k, sealedPart(2, 64, "p"), clubAddr); r.code != 201 {
		t.Errorf("after the hour: %d %s", r.code, r.body)
	}
}

func TestPerAddressByteLimit(t *testing.T) {
	c := newClubHarness(t)
	c.srv.ClubBytesPerIPPerHour = 1000
	k := deriveClub(t, secretK(17))
	c.create(k, sealedPart(links.PartClubHeader, 64, "h"), clubAddr)
	for i := 0; i < 2; i++ {
		if r := c.post(k, sealedPart(2, 400, "p"), clubAddr); r.code != 201 {
			t.Fatalf("post %d: %d %s", i, r.code, r.body)
		}
	}
	if r := c.post(k, sealedPart(2, 201, "p"), clubAddr); r.code != 429 {
		t.Fatalf("201 bytes into 200 left of the hour: HTTP %d, want 429", r.code)
	}
	if r := c.post(k, sealedPart(2, 200, "p"), clubAddr); r.code != 201 {
		t.Fatalf("200 bytes into 200 left: HTTP %d %s", r.code, r.body)
	}
	c.clock.Advance(time.Hour)
	if r := c.post(k, sealedPart(2, 400, "p"), clubAddr); r.code != 201 {
		t.Fatalf("after the hour: %d", r.code)
	}
}

// What a member's phone relies on: the bytes are as they came, nothing is cached or indexed, and nothing
// says where it came from.
func TestResponsesAreNotCachedAndCarryNoAddress(t *testing.T) {
	c := newClubHarness(t)
	k := deriveClub(t, secretK(18))
	c.create(k, sealedPart(links.PartClubHeader, 64, "h"), clubAddr)
	c.post(k, sealedPart(2, 64, "p"), clubAddr)
	for what, r := range map[string]reply{"list": c.list(k, 0, clubAddr), "item": c.item(k, 1, clubAddr), "header": c.item(k, 0, clubAddr), "stranger": c.item(deriveClub(t, secretK(19)), 1, clubAddr)} {
		if r.hdr.Get("Cache-Control") != "no-store" || r.hdr.Get("Referrer-Policy") != "no-referrer" || r.hdr.Get("X-Robots-Tag") == "" {
			t.Errorf("%s: headers %v", what, r.hdr)
		}
		if strings.Contains(fmt.Sprint(r.hdr), clubAddr) || bytes.Contains(r.body, []byte(clubAddr)) {
			t.Errorf("%s: the answer names the requester's address", what)
		}
	}
	if r := c.item(k, 1, clubAddr); r.hdr.Get("Content-Type") != "application/octet-stream" {
		t.Errorf("a post is served as %q", r.hdr.Get("Content-Type"))
	}
}

// design section 4, test 1: nothing a club request carries reaches either log or the state folder as
// anything but the route name and a count, and no address reaches disk at all.
func TestNoClubIdProofNumberPacketOrAddressReachesALogOrDisk(t *testing.T) {
	c := newClubHarness(t)
	k := deriveClub(t, secretK(20))
	const marker = "TOP-SECRET-PACKET-CONTENT-7f3a"
	header := sealedPart(links.PartClubHeader, 120, "TOP-SECRET-CLUB-NAME")
	packet := sealedPart(2, 200, marker)
	c.create(k, header, clubAddr)
	c.post(k, packet, clubAddr)
	c.post(k, packet, clubAddr)
	c.list(k, 0, clubAddr)
	c.item(k, 2, clubAddr)
	c.item(k, 0, clubAddr)
	// Failures and refusals are logged as counts too.
	stranger := deriveClub(t, secretK(21))
	c.item(stranger, 1, clubAddr)
	c.do("GET", api.PathClubs+"/"+k.id+"/posts/not-a-number", nil, "wrong", clubAddr)
	for i := 0; i < 32; i++ { // past the per-address limit, so some answers are 429
		c.post(k, packet, clubAddr)
	}
	c.srv.Clubs.Takedown(k.id, c.clock.Now())
	c.list(k, 0, clubAddr)
	if err := c.srv.Flush(); err != nil {
		t.Fatal(err)
	}

	requests := jsonLines(t, c.reqLog.String())
	var statuses = map[float64]bool{}
	for _, line := range requests {
		if keysOf(line) != "count,hour,latency,method,route,status" {
			t.Errorf("request line %v: want exactly count, hour, latency, method, route, status", line)
		}
		if line["route"] != "/api/v1/clubs/*" {
			t.Errorf("a club request is logged under route %v, want /api/v1/clubs/*", line["route"])
		}
		statuses[line["status"].(float64)] = true
	}
	for _, want := range []float64{200, 201, 404, 410, 429} {
		if !statuses[want] {
			t.Errorf("the log has no %v line; the test did not reach every kind of answer", want)
		}
	}
	if abuse := strings.TrimSpace(c.abuseLog.String()); abuse != "" {
		t.Errorf("club requests wrote to the abuse log (clubs carry no install tag, and a refusal is only a count in the request log):\n%s", abuse)
	}

	secrets := map[string]string{
		"club id": k.id, "read proof": k.read, "post proof": k.post, "read hash": k.readHash, "post hash": k.postHash,
		"packet marker": marker, "club name": "TOP-SECRET-CLUB-NAME", "requester's address": clubAddr, "post path": "/posts",
		"header, base64": base64.StdEncoding.EncodeToString(header)[:40], "packet, base64": base64.StdEncoding.EncodeToString(packet)[:40],
	}
	logs := map[string]string{"request log": c.reqLog.String(), "abuse log": c.abuseLog.String()}
	for name, text := range logs {
		for what, secret := range secrets {
			if strings.Contains(text, secret) {
				t.Errorf("the %s holds the %s", name, what)
			}
		}
	}
	// The server wrote nothing into its state folder that names the requester's address; the ids, hashes,
	// headers and sealed bytes are in clubs/, as designed, and nowhere else.
	filepath.WalkDir(c.stateDir, func(p string, d os.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return nil
		}
		data, _ := os.ReadFile(p)
		rel, _ := filepath.Rel(c.stateDir, p)
		if bytes.Contains(data, []byte(clubAddr)) || bytes.Contains([]byte(rel), []byte(clubAddr)) {
			t.Errorf("%s holds the requester's address", rel)
		}
		for what, secret := range map[string]string{"read proof": k.read, "post proof": k.post} {
			if bytes.Contains(data, []byte(secret)) || strings.Contains(rel, secret) {
				t.Errorf("%s holds a %s", rel, what)
			}
		}
		if !strings.HasPrefix(rel, "clubs"+string(filepath.Separator)) && (bytes.Contains(data, []byte(k.id)) || bytes.Contains(data, []byte(marker))) {
			t.Errorf("%s, outside clubs/, names a club or holds a packet", rel)
		}
		return nil
	})
}

// The route name the log uses for the landing page is held now, so slice 4 cannot start by logging a club
// id.
func TestEveryClubPathIsLoggedAsOneRoute(t *testing.T) {
	c := newClubHarness(t)
	for _, path := range []string{"/api/v1/clubs", "/api/v1/clubs/abc", "/api/v1/clubs/abc/posts/3?after=1", "/c/0123456789abcdef"} {
		c.do("GET", path, nil, "", clubAddr)
	}
	c.do("GET", "/api/v1/clubsX", nil, "", clubAddr)
	if err := c.srv.Flush(); err != nil {
		t.Fatal(err)
	}
	counts := map[string]float64{}
	for _, line := range jsonLines(t, c.reqLog.String()) {
		counts[line["route"].(string)] += line["count"].(float64)
	}
	var routes []string
	for route, n := range counts {
		routes = append(routes, fmt.Sprintf("%s x%v", route, n))
	}
	sort.Strings(routes)
	if got, want := strings.Join(routes, ","), "/api/v1/clubs/* x3,/c/* x1,other x1"; got != want {
		t.Fatalf("routes %s, want %s", got, want)
	}
}

// Club posts share the one buffered-packet slot with share-link uploads: while one packet is being read, a
// second answers 503 busy and is not stored.
type gatedBody struct {
	started chan struct{}
	release chan struct{}
	sent    bool
	data    []byte
}

func (b *gatedBody) Read(p []byte) (int, error) {
	if !b.sent {
		b.sent = true
		close(b.started)
		<-b.release
	}
	if len(b.data) == 0 {
		return 0, io.EOF
	}
	n := copy(p, b.data)
	b.data = b.data[n:]
	return n, nil
}

func TestASecondPostWhileOneIsBeingReadAnswersBusy(t *testing.T) {
	c := newClubHarness(t)
	k := deriveClub(t, secretK(22))
	c.create(k, sealedPart(links.PartClubHeader, 64, "h"), clubAddr)
	gate := &gatedBody{started: make(chan struct{}), release: make(chan struct{}), data: sealedPart(2, 64, "first")}
	done := make(chan reply)
	go func() {
		done <- c.do("POST", api.PathClubs+"/"+k.id+"/posts", gate, k.post, "198.51.100.20")
	}()
	<-gate.started
	r := c.post(k, sealedPart(2, 64, "second"), "198.51.100.21")
	if r.code != 503 || r.errCode() != "busy" {
		t.Errorf("a second post while one is read: HTTP %d %s, want 503 busy", r.code, r.body)
	}
	close(gate.release)
	if first := <-done; first.code != 201 {
		t.Errorf("the first post: HTTP %d %s", first.code, first.body)
	}
	var l listing
	json.Unmarshal(c.list(k, 0, clubAddr).body, &l)
	if len(l.Posts) != 1 {
		t.Errorf("%d posts kept, want only the first", len(l.Posts))
	}
}

// A body with no declared length that runs past 20 MB is cut off and refused, not buffered.
func TestAnUndeclaredBodyPast20MBIsRefused(t *testing.T) {
	c := newClubHarness(t)
	k := deriveClub(t, secretK(23))
	c.create(k, sealedPart(links.PartClubHeader, 64, "h"), clubAddr)
	body := &countingBody{}
	r := httptest.NewRequest("POST", api.PathClubs+"/"+k.id+"/posts", body)
	r.ContentLength = -1
	r.Header.Set("Authorization", "Bearer "+k.post)
	r.RemoteAddr = "198.51.100.30:1"
	w := httptest.NewRecorder()
	c.h.ServeHTTP(w, r)
	if w.Code != 413 {
		t.Fatalf("HTTP %d, want 413", w.Code)
	}
	if body.read > clubs.MaxPostBytes+(1<<20) {
		t.Fatalf("read %d bytes of an endless body, want it stopped near 20 MB", body.read)
	}
}
