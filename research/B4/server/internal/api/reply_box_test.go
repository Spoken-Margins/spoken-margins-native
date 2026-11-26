package api_test

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"spokenmargins.dev/bridge/internal/api"
	"spokenmargins.dev/bridge/internal/clubs"
	"spokenmargins.dev/bridge/internal/config"
	"spokenmargins.dev/bridge/internal/links"
	"spokenmargins.dev/bridge/internal/reports"
)

// Reply boxes through the real handler (#4675, docs/design/reply-mailbox.md, PR plan piece 2). The shared
// vector's upload headers are exactly what the phone sends; its reply part is what GET /l/<id>/reply must
// serve back byte for byte; its answer is a valid post for its box.

type replyVector struct {
	ID            string            `json:"id"`
	ReadProof     string            `json:"readProof"`
	PostProof     string            `json:"postProof"`
	ReadHash      string            `json:"readHash"`
	PostHash      string            `json:"postHash"`
	UploadHeaders map[string]string `json:"uploadHeaders"`
	ReplyPart     struct {
		SealedBase64 string `json:"sealedBase64"`
	} `json:"replyPart"`
	Answer struct {
		SealedBase64 string `json:"sealedBase64"`
	} `json:"answer"`
}

func loadReplyVector(t *testing.T) replyVector {
	t.Helper()
	data, err := os.ReadFile("../../../contracts/fixtures/reply-box-vector.json")
	if err != nil {
		t.Fatal(err)
	}
	var v replyVector
	if err := json.Unmarshal(data, &v); err != nil {
		t.Fatal(err)
	}
	return v
}

func mustB64(t *testing.T, s string) []byte {
	t.Helper()
	b, err := base64.StdEncoding.DecodeString(s)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

// replyHarness is a server with links and the clubs store, links on, replies on and clubs OFF, so every
// test shows reply boxes working without the clubs switch.
func newReplyHarness(t *testing.T, origins ...string) *clubHarness {
	t.Helper()
	c := newClubHarness(t)
	st, err := links.OpenStore(filepath.Join(c.stateDir, "links"))
	if err != nil {
		t.Fatal(err)
	}
	c.srv.Links = st
	rs, err := reports.Open(filepath.Join(c.stateDir, "reports"))
	if err != nil {
		t.Fatal(err)
	}
	c.srv.Reports = rs
	c.srv.LinkInstallURL = "https://testflight.apple.com/join/fixture"
	c.srv.LinkOrigins = origins
	c.setSwitch(config.ServiceLinks, true)
	c.setSwitch(config.ServiceClubs, false)
	c.setSwitch(config.ServiceReplies, true)
	c.h = c.srv.Handler()
	return c
}

func (c *clubHarness) setSwitch(service string, on bool) {
	c.t.Helper()
	if _, err := config.Set(c.configPath, service, on); err != nil {
		c.t.Fatal(err)
	}
}

// uploadWith posts the share-link vector's link with extra request headers.
func (c *clubHarness) uploadWith(hdr map[string][]string) reply {
	c.t.Helper()
	data, ct := multipartLink(c.t, [][2][]byte{{[]byte("packet"), linkPacket}, {[]byte("preview"), linkPreview}})
	r := httptest.NewRequest("POST", api.PathLinks, bytes.NewReader(data))
	r.RemoteAddr = clubAddr + ":4321"
	r.Header.Set("Content-Type", ct)
	for k, vs := range hdr {
		for _, v := range vs {
			r.Header.Add(k, v)
		}
	}
	w := httptest.NewRecorder()
	c.h.ServeHTTP(w, r)
	out, _ := io.ReadAll(w.Result().Body)
	return reply{code: w.Code, body: out, hdr: w.Result().Header}
}

func vectorHeaders(v replyVector) map[string][]string {
	h := map[string][]string{}
	for k, val := range v.UploadHeaders {
		h[k] = []string{val}
	}
	return h
}

// uploaded makes a link with the given headers and returns its id and the decoded 201 body.
func (c *clubHarness) uploaded(hdr map[string][]string) (string, map[string]any) {
	c.t.Helper()
	r := c.uploadWith(hdr)
	if r.code != 201 {
		c.t.Fatalf("upload: %d %s", r.code, r.body)
	}
	var out map[string]any
	if err := json.Unmarshal(r.body, &out); err != nil {
		c.t.Fatal(err)
	}
	return out["id"].(string), out
}

// req is one request with an optional bearer proof and Origin.
func (c *clubHarness) req(method, path string, body []byte, proof, origin string, hdr map[string]string) reply {
	c.t.Helper()
	r := httptest.NewRequest(method, path, bytes.NewReader(body))
	r.RemoteAddr = clubAddr + ":4321"
	if proof != "" {
		r.Header.Set("Authorization", "Bearer "+proof)
	}
	if origin != "" {
		r.Header.Set("Origin", origin)
	}
	for k, v := range hdr {
		r.Header.Set(k, v)
	}
	w := httptest.NewRecorder()
	c.h.ServeHTTP(w, r)
	out, _ := io.ReadAll(w.Result().Body)
	return reply{code: w.Code, body: out, hdr: w.Result().Header}
}

func postsPath(id string) string { return api.PathClubs + "/" + id + "/posts" }

func TestTheVectorsUploadMakesABoxItsPartIsServedAndItsAnswerPostsAndReads(t *testing.T) {
	c := newReplyHarness(t)
	v := loadReplyVector(t)
	// The vector's hashes are what the server computes from its proofs.
	if h, _ := clubs.HashProof(v.ReadProof); h != v.ReadHash || v.UploadHeaders[api.HeaderReplyReadHash] != v.ReadHash {
		t.Fatal("vector read hash disagrees with the server's hash of the read proof")
	}
	if h, _ := clubs.HashProof(v.PostProof); h != v.PostHash || v.UploadHeaders[api.HeaderReplyPostHash] != v.PostHash {
		t.Fatal("vector post hash disagrees with the server's hash of the post proof")
	}
	linkID, out := c.uploaded(vectorHeaders(v))
	if out["replyBox"] != true {
		t.Fatalf("201 body %v has no replyBox: true", out)
	}
	r := c.req("GET", "/l/"+linkID+"/reply", nil, "", "", nil)
	if r.code != 200 || !bytes.Equal(r.body, mustB64(t, v.ReplyPart.SealedBase64)) || r.hdr.Get("Content-Type") != "application/octet-stream" || r.hdr.Get("Cache-Control") != "no-store" {
		t.Fatalf("GET reply: %d %q", r.code, r.hdr.Get("Content-Type"))
	}
	ans := mustB64(t, v.Answer.SealedBase64)
	r = c.req("POST", postsPath(v.ID), ans, v.PostProof, "", nil)
	if r.code != 201 || strings.TrimSpace(string(r.body)) != `{"seq":1}` {
		t.Fatalf("post the vector's answer: %d %s", r.code, r.body)
	}
	r = c.req("GET", postsPath(v.ID)+"?after=0", nil, v.ReadProof, "", nil)
	if r.code != 200 || strings.TrimSpace(string(r.body)) != fmt.Sprintf(`{"posts":[{"seq":1,"size":%d}]}`, len(ans)) {
		t.Fatalf("list: %d %s", r.code, r.body)
	}
	r = c.req("GET", postsPath(v.ID)+"/1", nil, v.ReadProof, "", nil)
	if r.code != 200 || !bytes.Equal(r.body, ans) {
		t.Fatalf("fetch: %d", r.code)
	}
	// A reply box has no header: item 0 is not found, even for its sender.
	if r = c.req("GET", postsPath(v.ID)+"/0", nil, v.ReadProof, "", nil); r.code != 404 {
		t.Fatalf("item 0: %d", r.code)
	}
	// The post proof reads nothing.
	if r = c.req("GET", postsPath(v.ID)+"?after=0", nil, v.PostProof, "", nil); r.code != 404 {
		t.Fatalf("list with the post proof: %d", r.code)
	}
}

func TestAnUploadWithoutTheHeadersIsTodaysUpload(t *testing.T) {
	c := newReplyHarness(t)
	linkID, out := c.uploaded(nil)
	var keys []string
	for k := range out {
		keys = append(keys, k)
	}
	if got := strings.Join(sortStrings(keys), ","); got != "expiresAt,id,path" {
		t.Fatalf("201 body keys %s, want exactly today's expiresAt,id,path", got)
	}
	if r := c.req("GET", "/l/"+linkID+"/reply", nil, "", "", nil); r.code != 404 || r.errCode() != "not_found" {
		t.Fatalf("GET reply of a link with none: %d %s", r.code, r.body)
	}
	entries, _ := os.ReadDir(filepath.Join(c.stateDir, "links", linkID))
	for _, e := range entries {
		if e.Name() == "reply" {
			t.Fatal("a link uploaded without headers has a reply part")
		}
	}
	if entries, _ := os.ReadDir(filepath.Join(c.stateDir, "clubs")); len(entries) != 0 {
		t.Fatalf("a link uploaded without headers made %d boxes", len(entries))
	}
}

func sortStrings(s []string) []string {
	for i := range s {
		for j := i + 1; j < len(s); j++ {
			if s[j] < s[i] {
				s[i], s[j] = s[j], s[i]
			}
		}
	}
	return s
}

func TestMalformedReplyHeadersMakeALinkWithNoBox(t *testing.T) {
	v := loadReplyVector(t)
	good := vectorHeaders(v)
	with := func(name string, vals ...string) map[string][]string {
		h := map[string][]string{}
		for k, val := range good {
			h[k] = val
		}
		if vals == nil {
			delete(h, name)
		} else {
			h[name] = vals
		}
		return h
	}
	part := mustB64(t, v.ReplyPart.SealedBase64)
	wrongPart := append([]byte{}, part...)
	wrongPart[7] = links.PartPacket
	big := append(append([]byte{}, part[:8]...), make([]byte, links.MaxReplyBytes+1-8)...)
	cases := map[string]map[string][]string{
		"no id":               with(api.HeaderReplyID),
		"no read hash":        with(api.HeaderReplyReadHash),
		"no post hash":        with(api.HeaderReplyPostHash),
		"no part":             with(api.HeaderReplyPart),
		"upper-case id":       with(api.HeaderReplyID, strings.ToUpper(v.ID)),
		"short id":            with(api.HeaderReplyID, v.ID[:30]),
		"short hash":          with(api.HeaderReplyReadHash, v.ReadHash[:63]),
		"one hash for both":   with(api.HeaderReplyPostHash, v.ReadHash),
		"two ids":             with(api.HeaderReplyID, v.ID, v.ID),
		"part not base64":     with(api.HeaderReplyPart, "%%%not-base64%%%"),
		"part base64url":      with(api.HeaderReplyPart, base64.RawURLEncoding.EncodeToString(part)),
		"part is a packet":    with(api.HeaderReplyPart, base64.StdEncoding.EncodeToString(wrongPart)),
		"part over 1 KiB":     with(api.HeaderReplyPart, base64.StdEncoding.EncodeToString(big)),
		"part empty":          with(api.HeaderReplyPart, ""),
		"part not sealed":     with(api.HeaderReplyPart, base64.StdEncoding.EncodeToString([]byte(`{"v":1}`))),
		"id is not the box's": with(api.HeaderReplyID, "zz"+v.ID[2:]),
	}
	for name, hdr := range cases {
		t.Run(name, func(t *testing.T) {
			c := newReplyHarness(t)
			linkID, out := c.uploaded(hdr)
			if _, ok := out["replyBox"]; ok {
				t.Fatalf("201 body %v carries replyBox", out)
			}
			if c.srv.Clubs.Box(v.ID).Exists {
				t.Fatal("a box was made")
			}
			if r := c.req("GET", "/l/"+linkID+"/reply", nil, "", "", nil); r.code != 404 {
				t.Fatalf("GET reply: %d", r.code)
			}
			if r := c.req("GET", "/l/"+linkID+"/packet", nil, "", "", nil); r.code != 200 || !bytes.Equal(r.body, linkPacket) {
				t.Fatalf("the link itself is broken: %d", r.code)
			}
		})
	}
}

func TestRepliesOffMakesALinkWithNoBoxAndServesNoPart(t *testing.T) {
	c := newReplyHarness(t)
	v := loadReplyVector(t)
	c.setSwitch(config.ServiceReplies, false)
	_, out := c.uploaded(vectorHeaders(v))
	if _, ok := out["replyBox"]; ok || c.srv.Clubs.Box(v.ID).Exists {
		t.Fatalf("replies off made a box: %v", out)
	}
	// A box made while on: its part is not served while replies is off, so the page shows today's file path.
	c.setSwitch(config.ServiceReplies, true)
	linkID, out := c.uploaded(vectorHeaders(v))
	if out["replyBox"] != true {
		t.Fatalf("on: %v", out)
	}
	c.setSwitch(config.ServiceReplies, false)
	if r := c.req("GET", "/l/"+linkID+"/reply", nil, "", "", nil); r.code != 404 {
		t.Fatalf("GET reply with replies off: %d", r.code)
	}
	ans := mustB64(t, v.Answer.SealedBase64)
	for _, r := range []reply{
		c.req("POST", postsPath(v.ID), ans, v.PostProof, "", nil),
		c.req("GET", postsPath(v.ID), nil, v.ReadProof, "", nil),
		c.req("POST", api.PathClubs+"/"+v.ID+"/close", nil, v.ReadProof, "", nil),
	} {
		if r.code != 503 || r.errCode() != "disabled" {
			t.Errorf("a reply-box route with replies off: %d %s", r.code, r.body)
		}
	}
}

func TestReplyBoxesWorkWithClubsOffAndClubsStayClosed(t *testing.T) {
	c := newReplyHarness(t)
	v := loadReplyVector(t)
	c.uploaded(vectorHeaders(v))
	ans := mustB64(t, v.Answer.SealedBase64)
	if r := c.req("POST", postsPath(v.ID), ans, v.PostProof, "", nil); r.code != 201 {
		t.Fatalf("post: %d %s", r.code, r.body)
	}
	if r := c.req("POST", postsPath(v.ID), ans, v.PostProof, "", nil); r.code != 201 {
		t.Fatalf("post 2: %d %s", r.code, r.body)
	}
	if r := c.req("GET", postsPath(v.ID)+"?after=0", nil, v.ReadProof, "", nil); r.code != 200 {
		t.Fatalf("list: %d %s", r.code, r.body)
	}
	if r := c.req("GET", postsPath(v.ID)+"/2", nil, v.ReadProof, "", nil); r.code != 200 {
		t.Fatalf("fetch: %d", r.code)
	}
	rep := c.report(v.ID, form("category", "harassment", "post", "1"), v.ReadProof, clubAddr)
	if rep.code != 200 || !rep.answer(t).Filed {
		t.Fatalf("post report: %d %s", rep.code, rep.body)
	}
	a := rep.answer(t)
	if r := c.reportTo(api.PathClubs+"/"+v.ID+"/report/reason", form("ref", a.Ref, "reason", "they were rude"), "", clubAddr); r.code != 200 {
		t.Fatalf("report reason: %d %s", r.code, r.body)
	}
	if r := c.req("POST", api.PathClubs+"/"+v.ID+"/close", nil, v.ReadProof, "", nil); r.code != 200 || strings.TrimSpace(string(r.body)) != `{"closed":true}` {
		t.Fatalf("close: %d %s", r.code, r.body)
	}
	// Club creation stays governed by clubs alone.
	k := deriveClub(t, secretK(60))
	if r := c.create(k, sealedPart(links.PartClubHeader, 80, "h"), clubAddr); r.code != 503 || r.errCode() != "disabled" {
		t.Fatalf("create with clubs off: %d %s", r.code, r.body)
	}
	// And an ordinary club's routes stay off too: with clubs on, make one, then switch clubs off again.
	c.setSwitch(config.ServiceClubs, true)
	if r := c.create(k, sealedPart(links.PartClubHeader, 80, "h"), clubAddr); r.code != 201 {
		t.Fatalf("create with clubs on: %d", r.code)
	}
	c.setSwitch(config.ServiceClubs, false)
	if r := c.list(k, 0, clubAddr); r.code != 503 {
		t.Fatalf("an ordinary club's list with clubs off: %d", r.code)
	}
	// Close is for reply boxes only.
	c.setSwitch(config.ServiceClubs, true)
	if r := c.req("POST", api.PathClubs+"/"+k.id+"/close", nil, k.read, "", nil); r.code != 404 {
		t.Fatalf("close an ordinary club: %d %s", r.code, r.body)
	}
}

func TestCloseNeedsTheReadProofAndStopsPostsOnly(t *testing.T) {
	c := newReplyHarness(t, webApp)
	v := loadReplyVector(t)
	c.uploaded(vectorHeaders(v))
	ans := mustB64(t, v.Answer.SealedBase64)
	c.req("POST", postsPath(v.ID), ans, v.PostProof, "", nil)
	closePath := api.PathClubs + "/" + v.ID + "/close"
	for name, proof := range map[string]string{"post proof": v.PostProof, "stranger": deriveClub(t, secretK(61)).read, "none": ""} {
		if r := c.req("POST", closePath, nil, proof, "", nil); r.code != 404 || r.errCode() != "not_found" {
			t.Errorf("close with %s: %d %s", name, r.code, r.body)
		}
	}
	if r := c.req("POST", closePath, nil, v.ReadProof, "", nil); r.code != 200 {
		t.Fatalf("close: %d %s", r.code, r.body)
	}
	if r := c.req("POST", closePath, nil, v.ReadProof, "", nil); r.code != 200 {
		t.Fatalf("close again: %d %s", r.code, r.body)
	}
	// A friend's browser reads the neutral 410.
	r := c.req("POST", postsPath(v.ID), ans, v.PostProof, webApp, nil)
	if r.code != 410 || r.errCode() != "expired_or_removed" || r.hdr.Get("Access-Control-Allow-Origin") != webApp {
		t.Fatalf("post to a closed box from the web app: %d %s ACAO %q", r.code, r.body, r.hdr.Get("Access-Control-Allow-Origin"))
	}
	// The sender still reads and reports.
	if r := c.req("GET", postsPath(v.ID)+"/1", nil, v.ReadProof, "", nil); r.code != 200 {
		t.Fatalf("fetch after close: %d", r.code)
	}
	if r := c.report(v.ID, form("category", "other", "post", "1"), v.ReadProof, clubAddr); r.code != 200 {
		t.Fatalf("post report on a closed box: %d %s", r.code, r.body)
	}
}

func TestATakedownOrTheLinksEndStopsPosts(t *testing.T) {
	c := newReplyHarness(t)
	v := loadReplyVector(t)
	ans := mustB64(t, v.Answer.SealedBase64)

	// A link reported with "Report this link" comes down at once, and its box takes no more posts.
	linkID, _ := c.uploaded(vectorHeaders(v))
	if r := c.req("POST", postsPath(v.ID), ans, v.PostProof, "", nil); r.code != 201 {
		t.Fatalf("post: %d", r.code)
	}
	rep := c.req("POST", "/l/"+linkID+"/report", []byte("category=copyright"), "", "", map[string]string{"Content-Type": "application/x-www-form-urlencoded"})
	if rep.code != 200 {
		t.Fatalf("link report: %d %s", rep.code, rep.body)
	}
	if r := c.req("POST", postsPath(v.ID), ans, v.PostProof, "", nil); r.code != 410 || r.errCode() != "expired_or_removed" {
		t.Fatalf("post after the link's takedown: %d %s", r.code, r.body)
	}
	// A stranger still gets the 404, not the link's state.
	if r := c.req("POST", postsPath(v.ID), ans, deriveClub(t, secretK(62)).post, "", nil); r.code != 404 {
		t.Fatalf("stranger after takedown: %d", r.code)
	}
	// The sender still collects what arrived, and the part is gone with the link.
	if r := c.req("GET", postsPath(v.ID)+"/1", nil, v.ReadProof, "", nil); r.code != 200 {
		t.Fatalf("fetch after takedown: %d", r.code)
	}
	if r := c.req("GET", "/l/"+linkID+"/reply", nil, "", "", nil); r.code != 410 {
		t.Fatalf("GET reply of a taken-down link: %d", r.code)
	}
	if _, err := os.Stat(filepath.Join(c.stateDir, "links", linkID, "reply")); !os.IsNotExist(err) {
		t.Fatal("the takedown left the reply part on disk")
	}

	// The owner's takedown, and the link running out, do the same.
	for name, end := range map[string]func(id string){
		"owner takedown": func(id string) { c.srv.Links.Takedown(id) },
		"link expiry":    func(string) { c.clock.Advance(links.Lifetime) },
	} {
		c2 := newReplyHarness(t)
		c = c2
		linkID, out := c.uploaded(vectorHeaders(v))
		if out["replyBox"] != true {
			t.Fatalf("%s: no box", name)
		}
		end(linkID)
		if r := c.req("POST", postsPath(v.ID), ans, v.PostProof, "", nil); r.code != 410 {
			t.Errorf("%s: post %d %s", name, r.code, r.body)
		}
		if r := c.req("GET", "/l/"+linkID+"/reply", nil, "", "", nil); r.code != 410 {
			t.Errorf("%s: GET reply %d", name, r.code)
		}
		if r := c.req("GET", postsPath(v.ID)+"?after=0", nil, v.ReadProof, "", nil); r.code != 200 {
			t.Errorf("%s: list %d", name, r.code)
		}
	}
	// Seven days after the link's end the box is gone for its sender too.
	c.clock.Advance(7 * 24 * time.Hour)
	if r := c.req("GET", postsPath(v.ID)+"?after=0", nil, v.ReadProof, "", nil); r.code != 410 {
		t.Errorf("list seven days after the link: %d", r.code)
	}
}

func TestReplyPostCORSIsForListedOriginsAndReplyBoxesOnly(t *testing.T) {
	c := newReplyHarness(t, webApp)
	v := loadReplyVector(t)
	linkID, _ := c.uploaded(vectorHeaders(v))
	ans := mustB64(t, v.Answer.SealedBase64)
	pre := func(id, origin, method, headers string) reply {
		h := map[string]string{"Access-Control-Request-Method": method}
		if headers != "" {
			h["Access-Control-Request-Headers"] = headers
		}
		return c.req("OPTIONS", postsPath(id), nil, "", origin, h)
	}
	r := pre(v.ID, webApp, "POST", "authorization, content-type")
	if r.code != 204 || r.hdr.Get("Access-Control-Allow-Origin") != webApp || r.hdr.Get("Access-Control-Allow-Methods") != "POST" ||
		!strings.Contains(strings.ToLower(r.hdr.Get("Access-Control-Allow-Headers")), "authorization") ||
		!strings.Contains(strings.ToLower(r.hdr.Get("Access-Control-Allow-Headers")), "content-type") {
		t.Fatalf("preflight from the web app: %d %v", r.code, r.hdr)
	}
	k := deriveClub(t, secretK(63))
	c.setSwitch(config.ServiceClubs, true)
	if r := c.create(k, sealedPart(links.PartClubHeader, 80, "h"), clubAddr); r.code != 201 {
		t.Fatalf("create club: %d", r.code)
	}
	for name, r := range map[string]reply{
		"other origin":       pre(v.ID, "https://evil.example", "POST", "authorization"),
		"lookalike origin":   pre(v.ID, webApp+".evil.example", "POST", ""),
		"GET":                pre(v.ID, webApp, "GET", ""),
		"extra header":       pre(v.ID, webApp, "POST", "authorization, x-sm-key-id"),
		"ordinary club":      pre(k.id, webApp, "POST", "authorization"),
		"unknown id":         pre(deriveClub(t, secretK(64)).id, webApp, "POST", "authorization"),
		"ordinary club post": c.req("POST", postsPath(k.id), sealedPart(links.PartPacket, 100, "p"), k.post, webApp, nil),
		"ordinary club list": c.req("GET", postsPath(k.id), nil, k.read, webApp, nil),
		"reply list":         c.req("GET", postsPath(v.ID), nil, v.ReadProof, webApp, nil),
		"other origin post":  c.req("POST", postsPath(v.ID), ans, v.PostProof, "https://evil.example", nil),
	} {
		if r.code == 0 {
			continue
		}
		if r.hdr.Get("Access-Control-Allow-Origin") != "" || r.hdr.Get("Access-Control-Allow-Methods") != "" {
			t.Errorf("%s: CORS %v", name, r.hdr)
		}
		if len(r.hdr.Values("Access-Control-Allow-Credentials")) != 0 {
			t.Errorf("%s: credentials allowed", name)
		}
	}
	// Every answer the post route gives a browser is readable: success and each error.
	readable := func(label string, r reply, code int, errCode string) {
		t.Helper()
		if r.code != code || (errCode != "" && r.errCode() != errCode) {
			t.Errorf("%s: %d %s, want %d %s", label, r.code, r.body, code, errCode)
		}
		if r.hdr.Get("Access-Control-Allow-Origin") != webApp {
			t.Errorf("%s: not readable by the web app (ACAO %q)", label, r.hdr.Get("Access-Control-Allow-Origin"))
		}
		if len(r.hdr.Values("Access-Control-Allow-Credentials")) != 0 {
			t.Errorf("%s: credentials allowed", label)
		}
	}
	readable("201", c.req("POST", postsPath(v.ID), ans, v.PostProof, webApp, nil), 201, "")
	readable("404 wrong proof", c.req("POST", postsPath(v.ID), ans, deriveClub(t, secretK(65)).post, webApp, nil), 404, "not_found")
	readable("413", c.req("POST", postsPath(v.ID), sealedPart(links.PartPacket, clubs.ReplyMaxPostBytes+1, "big"), v.PostProof, webApp, nil), 413, "too_large")
	c.setSwitch(config.ServiceReplies, false)
	readable("503", c.req("POST", postsPath(v.ID), ans, v.PostProof, webApp, nil), 503, "disabled")
	c.setSwitch(config.ServiceReplies, true)
	// Fill the box to its 20 answers (the per-address hour allows 30 writes, so the clock moves on).
	for {
		var l listing
		json.Unmarshal(c.req("GET", postsPath(v.ID), nil, v.ReadProof, "", nil).body, &l)
		if len(l.Posts) >= clubs.ReplyMaxPosts {
			break
		}
		c.clock.Advance(time.Hour)
		if r := c.req("POST", postsPath(v.ID), ans, v.PostProof, "", nil); r.code != 201 {
			t.Fatalf("post %d: %d %s", len(l.Posts)+1, r.code, r.body)
		}
	}
	c.clock.Advance(time.Hour)
	readable("409", c.req("POST", postsPath(v.ID), ans, v.PostProof, webApp, nil), 409, "club_full")
	for i := 0; i < 40; i++ {
		c.req("POST", postsPath(v.ID), ans, v.PostProof, webApp, nil)
	}
	readable("429", c.req("POST", postsPath(v.ID), ans, v.PostProof, webApp, nil), 429, "rate_limited")
	c.srv.Links.Takedown(linkID)
	c.clock.Advance(time.Hour)
	readable("410", c.req("POST", postsPath(v.ID), ans, v.PostProof, webApp, nil), 410, "expired_or_removed")

	// Close is the phone's alone: no CORS.
	if r := c.req("POST", api.PathClubs+"/"+v.ID+"/close", nil, v.ReadProof, webApp, nil); r.code != 200 || r.hdr.Get("Access-Control-Allow-Origin") != "" {
		t.Errorf("close from a browser origin: %d ACAO %q", r.code, r.hdr.Get("Access-Control-Allow-Origin"))
	}

	// GET /l/<id>/reply answers the link's CORS, and its preflight is answered next to the others.
	r = c.req("GET", "/l/"+linkID+"/reply", nil, "", webApp, nil)
	if r.code != 410 || r.hdr.Get("Access-Control-Allow-Origin") != webApp {
		t.Fatalf("GET reply from the web app: %d ACAO %q", r.code, r.hdr.Get("Access-Control-Allow-Origin"))
	}
	r = c.req("OPTIONS", "/l/"+linkID+"/reply", nil, "", webApp, map[string]string{"Access-Control-Request-Method": "GET"})
	if r.code != 204 || r.hdr.Get("Access-Control-Allow-Origin") != webApp {
		t.Fatalf("preflight of GET reply: %d", r.code)
	}
}

func TestReplyCORSIsOffWithNoOrigins(t *testing.T) {
	c := newReplyHarness(t)
	v := loadReplyVector(t)
	linkID, _ := c.uploaded(vectorHeaders(v))
	r := c.req("POST", postsPath(v.ID), mustB64(t, v.Answer.SealedBase64), v.PostProof, webApp, nil)
	if r.code != 201 || r.hdr.Get("Access-Control-Allow-Origin") != "" || len(r.hdr.Values("Vary")) != 0 {
		t.Fatalf("post with no origins listed: %d %v", r.code, r.hdr)
	}
	for _, path := range []string{postsPath(v.ID), "/l/" + linkID + "/reply"} {
		if r := c.req("OPTIONS", path, nil, "", webApp, map[string]string{"Access-Control-Request-Method": "POST"}); r.code != 405 {
			t.Errorf("OPTIONS %s with no origins: %d, want 405", path, r.code)
		}
	}
}

func TestNoReplyBoxSecretReachesALog(t *testing.T) {
	c := newReplyHarness(t, webApp)
	v := loadReplyVector(t)
	var stdlog syncBuffer
	log.SetOutput(&stdlog)
	defer log.SetOutput(os.Stderr)

	linkID, _ := c.uploaded(vectorHeaders(v))
	// A second upload with the same box id: the box exists, so this link gets none, and says so in the log.
	other, out := c.uploaded(vectorHeaders(v))
	if _, ok := out["replyBox"]; ok {
		t.Fatal("a second link took the same box")
	}
	ans := mustB64(t, v.Answer.SealedBase64)
	c.req("GET", "/l/"+linkID+"/reply", nil, "", webApp, nil)
	c.req("GET", "/l/"+other+"/reply", nil, "", webApp, nil)
	c.req("OPTIONS", postsPath(v.ID), nil, "", webApp, map[string]string{"Access-Control-Request-Method": "POST"})
	c.req("POST", postsPath(v.ID), ans, v.PostProof, webApp, nil)
	c.req("POST", postsPath(v.ID), ans, deriveClub(t, secretK(66)).post, webApp, nil)
	c.req("GET", postsPath(v.ID)+"?after=0", nil, v.ReadProof, "", nil)
	c.req("GET", postsPath(v.ID)+"/1", nil, v.ReadProof, "", nil)
	c.report(v.ID, form("category", "harassment", "post", "1"), v.ReadProof, clubAddr)
	c.report(v.ID, url.Values{"category": {"abuse_material"}, "link": {"https://example.test/c/" + v.ID + "#SECRETBOXKEY"}}, "", clubAddr)
	c.req("POST", api.PathClubs+"/"+v.ID+"/close", nil, v.ReadProof, "", nil)
	if err := c.srv.Flush(); err != nil {
		t.Fatal(err)
	}
	routes := map[string]bool{}
	for _, line := range jsonLines(t, c.reqLog.String()) {
		routes[line["route"].(string)] = true
	}
	for route := range routes {
		if route != "/api/v1/clubs/*" && route != "/l/*" && route != api.PathLinks {
			t.Errorf("a reply-box request was logged under route %q", route)
		}
	}
	for _, line := range jsonLines(t, c.abuseLog.String()) {
		if id, ok := line["id"]; ok && id != "club" {
			t.Errorf("an abuse-log line names %v", id)
		}
	}
	secrets := map[string]string{
		"box id": v.ID, "read proof": v.ReadProof, "post proof": v.PostProof, "read hash": v.ReadHash, "post hash": v.PostHash,
		"link id": linkID, "second link id": other, "reply part": v.UploadHeaders[api.HeaderReplyPart][:24],
		"answer": v.Answer.SealedBase64[:24], "box key": "SECRETBOXKEY", "address": clubAddr,
	}
	for name, text := range map[string]string{"request log": c.reqLog.String(), "abuse log": c.abuseLog.String(), "process log": stdlog.String()} {
		for what, secret := range secrets {
			if strings.Contains(text, secret) {
				t.Errorf("the %s holds the %s", name, what)
			}
		}
	}
	if !strings.Contains(stdlog.String(), "replies: reply box not made") {
		t.Errorf("the refused second box left no line in the process log: %q", stdlog.String())
	}
}

// The owner's switch command knows replies, and it is off by default.
func TestRepliesIsAKnownSwitchAndOffByDefault(t *testing.T) {
	if config.Default().Enabled(config.ServiceReplies) {
		t.Fatal("replies on in the default config")
	}
	c := newClubHarness(t)
	r := c.do(http.MethodGet, "/api/v1/health", nil, "", clubAddr)
	var health struct{ Services map[string]string }
	json.Unmarshal(r.body, &health)
	if health.Services["replies"] != "off" {
		t.Fatalf("health services %v", health.Services)
	}
}
