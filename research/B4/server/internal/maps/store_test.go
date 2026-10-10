package maps

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// A key is a file name, so a key that isn't 64 lowercase hex characters must
// never reach the file system: "../ledger" would read the spend ledger and
// "../transcripts/<key>" would serve a transcript the service promises never
// to serve. Both files really exist here, in the layout the server uses, so a
// missing guard makes the lookup succeed instead of failing for want of a file.
func TestStoreRefusesKeysThatLeaveTheMapsDirectory(t *testing.T) {
	dir := t.TempDir()
	store, err := OpenStore(dir)
	if err != nil {
		t.Fatal(err)
	}
	ledgerPath := filepath.Join(dir, "ledger.json")
	const ledgerText = `{"month":"2026-10","spentMicroUSD":1500,"calls":1}`
	if err := os.WriteFile(ledgerPath, []byte(ledgerText), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := store.PutTranscript(testTranscript(), time.Now()); err != nil {
		t.Fatal(err)
	}
	if err := store.PutMap(Map{Schema: MapSchema, EpisodeKey: testKey, Scenes: []Scene{{EndMs: 1000}}}); err != nil {
		t.Fatal(err)
	}

	// The two real files are reachable by their real names...
	if _, err := store.MapBytes(testKey); err != nil {
		t.Fatalf("control: the stored map is not readable: %v", err)
	}
	if !store.HasTranscript(testKey) {
		t.Fatal("control: the queued transcript is not found")
	}
	// ...and by no other spelling.
	for name, key := range map[string]string{
		"parent directory":         "../ledger",
		"transcript by path":       "../transcripts/" + testKey,
		"map by a longer path":     "../maps/" + testKey,
		"upper-case key":           strings.ToUpper(testKey),
		"63 characters":            testKey[:63],
		"65 characters":            testKey + "0",
		"a .json suffix":           testKey + ".json",
		"a trailing newline":       testKey + "\n",
		"empty":                    "",
		"dot":                      ".",
		"dot dot":                  "..",
		"NUL after a valid prefix": testKey[:60] + "\x00ab",
	} {
		if data, err := store.MapBytes(key); err != ErrNotFound || data != nil {
			t.Errorf("MapBytes(%s): %q, %v; want ErrNotFound", name, data, err)
		}
		if store.HasMap(key) || store.HasTranscript(key) || store.Withdrawn(key) {
			t.Errorf("%s: HasMap, HasTranscript or Withdrawn answered yes", name)
		}
	}
}

// A takedown with a bad key writes and deletes files by that key's name, so a
// traversal here would delete the ledger, which would reset the spend cap.
func TestTakedownRefusesTraversalKeysAndKeepsTheLedger(t *testing.T) {
	dir := t.TempDir()
	store, err := OpenStore(dir)
	if err != nil {
		t.Fatal(err)
	}
	ledgerPath := filepath.Join(dir, "ledger.json")
	const ledgerText = `{"month":"2026-10","spentMicroUSD":1500,"calls":1}`
	if err := os.WriteFile(ledgerPath, []byte(ledgerText), 0o600); err != nil {
		t.Fatal(err)
	}
	for _, key := range []string{"../ledger", "../transcripts/" + testKey, "..", ""} {
		if deleted, err := store.Takedown(key); deleted || err == nil {
			t.Errorf("Takedown(%q) = %v, %v; want a refusal", key, deleted, err)
		}
	}
	if data, err := os.ReadFile(ledgerPath); err != nil || string(data) != ledgerText {
		t.Fatalf("a refused takedown changed the ledger: %q, %v", data, err)
	}
	if entries, _ := os.ReadDir(filepath.Join(dir, "withdrawn")); len(entries) != 0 {
		t.Fatalf("a refused takedown withdrew something: %v", entries)
	}
}
