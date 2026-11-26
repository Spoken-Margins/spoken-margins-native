package main

import (
	"bytes"
	"strings"
	"testing"
	"time"

	"spokenmargins.dev/bridge/internal/clubs"
	"spokenmargins.dev/bridge/internal/links"
)

// `smserver replies count` (#4675, docs/design/reply-mailbox.md answer 6): two numbers, no id.
func TestRepliesCountPrintsTwoNumbersAndNamesNoBox(t *testing.T) {
	dir, now := t.TempDir(), time.Date(2026, 11, 26, 12, 0, 0, 0, time.UTC)
	st, clubIDs, _ := clubFixture(t, dir, now) // two ordinary clubs, each with posts: not counted
	var names []string
	for i := 0; i < 3; i++ {
		id := strings.Repeat(string(rune('5'+i)), 32)
		readProof, postProof := strings.Repeat(string(rune('a'+i)), 64), strings.Repeat(string(rune('d'+i)), 64)
		readHash, _ := clubs.HashProof(readProof)
		postHash, _ := clubs.HashProof(postProof)
		linkID := strings.Repeat(string(rune('a'+i)), 32)
		if err := st.CreateReply(id, readHash, postHash, linkID, now.Add(links.Lifetime), now); err != nil {
			t.Fatal(err)
		}
		names = append(names, id, linkID, readHash, postHash)
		if i == 0 {
			post := append([]byte{'S', 'M', 'L', 'I', 'N', 'K', 1, links.PartPacket}, bytes.Repeat([]byte("p"), 56)...)
			if _, err := st.Post(id, postProof, post, now); err != nil {
				t.Fatal(err)
			}
		}
	}
	var out bytes.Buffer
	if err := repliesCommand([]string{"count", "-state", dir}, &out, now); err != nil {
		t.Fatal(err)
	}
	if got, want := out.String(), "reply boxes: 3\nwith at least one answer: 1\n"; got != want {
		t.Fatalf("output %q, want %q", got, want)
	}
	for _, name := range append(names, clubIDs[:]...) {
		if strings.Contains(out.String(), name) {
			t.Fatalf("the count names %s", name)
		}
	}
	for _, bad := range [][]string{nil, {"list"}, {"count", "-state", dir, "extra"}} {
		if err := repliesCommand(bad, &out, now); err == nil {
			t.Errorf("replies %v: no error", bad)
		}
	}
}
