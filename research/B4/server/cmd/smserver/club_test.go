package main

import (
	"bytes"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"spokenmargins.dev/bridge/internal/clubs"
	"spokenmargins.dev/bridge/internal/links"
	"spokenmargins.dev/bridge/internal/reportrules"
	"spokenmargins.dev/bridge/internal/reports"
)

// Two clubs with fixed proofs. The ids are 32 hex digits; the store checks only the shape and the hashes.
func clubFixture(t *testing.T, dir string, now time.Time) (st *clubs.Store, ids [2]string, reads [2]string) {
	t.Helper()
	st, err := clubs.OpenStore(filepath.Join(dir, "clubs"))
	if err != nil {
		t.Fatal(err)
	}
	for i := range ids {
		proof := strings.Repeat(string(rune('a'+i)), 64)
		postProof := strings.Repeat(string(rune('c'+i)), 64)
		hash, ok := clubs.HashProof(proof)
		postHash, ok2 := clubs.HashProof(postProof)
		if !ok || !ok2 {
			t.Fatal("test proof is not a proof")
		}
		ids[i] = strings.Repeat(string(rune('1'+i)), 32)
		reads[i] = proof
		header := append([]byte{'S', 'M', 'L', 'I', 'N', 'K', 1, links.PartClubHeader}, bytes.Repeat([]byte("h"), 56)...)
		if _, err := st.Create(ids[i], hash, postHash, header, now); err != nil {
			t.Fatal(err)
		}
		for n := 0; n < 2; n++ {
			post := append([]byte{'S', 'M', 'L', 'I', 'N', 'K', 1, links.PartPacket}, bytes.Repeat([]byte("p"), 56)...)
			if _, err := st.Post(ids[i], postProof, post, now); err != nil {
				t.Fatal(err)
			}
		}
	}
	return st, ids, reads
}

func runClub(t *testing.T, dir string, now time.Time, args ...string) (string, error) {
	t.Helper()
	var out bytes.Buffer
	err := clubCommand(append([]string{args[0], "-state", dir}, args[1:]...), &out, now)
	return out.String(), err
}

func TestClubDisableTakedownAndPostCommands(t *testing.T) {
	dir, now := t.TempDir(), time.Date(2026, 11, 12, 12, 0, 0, 0, time.UTC)
	st, ids, reads := clubFixture(t, dir, now)
	if out, err := runClub(t, dir, now, "disable", ids[0], "2"); err != nil || !strings.Contains(out, "post disabled") {
		t.Fatalf("disable post: %q %v", out, err)
	}
	f, err := st.Item(ids[0], reads[0], 2, now)
	if err != nil {
		t.Fatal(err)
	}
	if info, _ := f.Stat(); info.Size() != 0 {
		t.Error("the post is still served")
	}
	f.Close()
	if _, err := st.Item(ids[0], reads[0], 1, now); err != nil {
		t.Errorf("another post: %v", err)
	}
	if _, err := runClub(t, dir, now, "disable", ids[0], "7"); err == nil || !strings.Contains(err.Error(), "no such") {
		t.Errorf("a post not in the box: %v", err)
	}
	for _, bad := range []string{"0", "-1", "01", "x"} {
		if _, err := runClub(t, dir, now, "disable", ids[0], bad); err == nil {
			t.Errorf("post %q accepted", bad)
		}
	}
	if out, err := runClub(t, dir, now, "disable", ids[0]); err != nil || !strings.Contains(out, "30 days") {
		t.Fatalf("disable club: %q %v", out, err)
	}
	if _, err := st.List(ids[0], reads[0], 0, now); !errors.Is(err, clubs.ErrGone) {
		t.Errorf("a disabled club is served: %v", err)
	}
	if _, err := st.List(ids[1], reads[1], 0, now); err != nil {
		t.Errorf("another club: %v", err)
	}
	if out, err := runClub(t, dir, now, "takedown", ids[0]); err != nil || !strings.Contains(out, "ended") {
		t.Fatalf("takedown: %q %v", out, err)
	}
	if _, err := os.Stat(filepath.Join(dir, "clubs", ids[0], "header")); err == nil {
		t.Error("takedown left the header")
	}
	if _, err := runClub(t, dir, now, "disable", ids[0], "1"); err == nil || !strings.Contains(err.Error(), "already ended") {
		t.Errorf("a post of an ended club: %v", err)
	}
	if _, err := runClub(t, dir, now, "takedown", strings.Repeat("9", 32)); err == nil {
		t.Error("takedown of no club")
	}
	for _, args := range [][]string{{"takedown"}, {"disable"}, {"disable", ids[1], "1", "2"}, {"hold", ids[1]}, {"release-hold", ids[1]}, {"nope"}} {
		if _, err := runClub(t, dir, now, args...); err == nil {
			t.Errorf("%v: no usage error", args)
		}
	}
	if err := clubCommand(nil, &bytes.Buffer{}, now); err == nil {
		t.Error("no subcommand: no usage error")
	}
}

func TestClubHoldShowReportedLinkAndReleaseCommands(t *testing.T) {
	dir, now := t.TempDir(), time.Date(2026, 11, 12, 12, 0, 0, 0, time.UTC)
	st, ids, reads := clubFixture(t, dir, now)
	invite := filepath.Join(t.TempDir(), "invite.txt")
	if err := os.WriteFile(invite, []byte("https://share.example/c/"+ids[0]+"#k=KEY\u202e\nSECOND"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := runClub(t, dir, now, "hold", ids[0]); err == nil {
		t.Fatal("a hold without a report id")
	}
	if out, err := runClub(t, dir, now, "hold", "-report", "NCMEC-1", "-link-file", invite, ids[0]); err != nil || !strings.Contains(out, "held for one year") {
		t.Fatalf("hold: %q %v", out, err)
	}
	if _, err := st.List(ids[0], reads[0], 0, now); !errors.Is(err, clubs.ErrGone) {
		t.Errorf("a held club is served: %v", err)
	}
	for _, name := range []string{"header", "posts/1", "posts/2", "reported-link", "hold.json"} {
		if _, err := os.Stat(filepath.Join(dir, "clubs-held", ids[0], name)); err != nil {
			t.Errorf("held copy lacks %s: %v", name, err)
		}
	}
	out, err := runClub(t, dir, now, "show-reported-link", ids[0])
	if err != nil || !strings.Contains(out, "altered: control or invisible") || strings.Contains(out, "\u202e") || strings.Contains(out, "\n\n") || !strings.Contains(out, "1 reported link(s)") {
		t.Fatalf("show-reported-link: %q %v", out, err)
	}
	if _, err := runClub(t, dir, now, "show-reported-link", ids[1]); err == nil {
		t.Error("an unheld club's links were shown")
	}
	// An empty or oversize link file is refused before anything is held.
	empty := filepath.Join(t.TempDir(), "empty")
	os.WriteFile(empty, nil, 0o600)
	if _, err := runClub(t, dir, now, "hold", "-report", "R", "-link-file", empty, ids[1]); err == nil {
		t.Error("an empty link file was accepted")
	}
	if _, err := st.List(ids[1], reads[1], 0, now); err != nil {
		t.Errorf("a refused hold changed the club: %v", err)
	}
	if _, err := runClub(t, dir, now, "release-hold", ids[0]); err == nil {
		t.Error("release without a reason")
	}
	if out, err := runClub(t, dir, now, "release-hold", "-reason", "law-enforcement request 12", ids[0]); err != nil || !strings.Contains(out, "held copy deleted") {
		t.Fatalf("release: %q %v", out, err)
	}
	if _, err := os.Stat(filepath.Join(dir, "clubs-held", ids[0])); err == nil {
		t.Error("the held copy is still there")
	}
	log, _ := os.ReadFile(filepath.Join(dir, "clubs-held", "access.log"))
	if strings.Contains(string(log), "KEY") || !strings.Contains(string(log), "law-enforcement request 12") {
		t.Errorf("access log: %s", log)
	}
}

func TestReportsCommandListsClubReportsWithWhatTheyDid(t *testing.T) {
	dir, now := t.TempDir(), time.Date(2026, 11, 12, 12, 0, 0, 0, time.UTC)
	st, ids, reads := clubFixture(t, dir, now)
	rs, err := reports.Open(filepath.Join(dir, "reports"))
	if err != nil {
		t.Fatal(err)
	}
	add := func(ref, id string, post int, cat reportrules.Category, reason string) {
		if err := rs.Add(reports.Record{Ref: ref, ClubID: id, Post: post, Category: cat, At: now, Reason: reason}); err != nil {
			t.Fatal(err)
		}
	}
	other := strings.Repeat("5", 32)
	add("POSTDOWN2345", ids[0], 1, reportrules.Harassment, "it is a \x1b[31mjoke")
	add("POSTSERVED23", ids[0], 2, reportrules.Other, "")
	add("CLUBHELD2345", ids[1], 0, reportrules.AbuseMaterial, "see https://x/c/"+ids[1]+"#SECRETKEY")
	add("CLUBMISSING2", other, 0, reportrules.Other, "")
	if err := st.DisablePost(ids[0], reads[0], 1, now); err != nil {
		t.Fatal(err)
	}
	if err := st.Hold(ids[1], "form-CLUBHELD2345", []byte("https://x/c/"+ids[1]+"#SECRETKEY"), now); err != nil {
		t.Fatal(err)
	}
	var out bytes.Buffer
	if err := listReports([]string{"-state", dir}, &out, now); err != nil {
		t.Fatal(err)
	}
	got := out.String()
	for _, want := range []string{
		"POSTDOWN2345  2026-11-12 12:00Z  harassment        club " + ids[0] + " post 1  post disabled",
		"POSTSERVED23  2026-11-12 12:00Z  other             club " + ids[0] + " post 2  post STILL SERVED",
		"CLUBHELD2345  2026-11-12 12:00Z  abuse_material    club " + ids[1] + "  taken down, held",
		"CLUBMISSING2  2026-11-12 12:00Z  other             club " + other + "  no such club",
		"4 report(s)",
	} {
		if !strings.Contains(got, want) {
			t.Errorf("the list lacks %q:\n%s", want, got)
		}
	}
	if strings.Contains(got, "SECRETKEY") || strings.Contains(got, "\x1b") {
		t.Errorf("the list shows a key or a control character:\n%q", got)
	}
}
