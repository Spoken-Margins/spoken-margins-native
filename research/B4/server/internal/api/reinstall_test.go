package api_test

import (
	"bytes"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"spokenmargins.dev/bridge/internal/api"
	"spokenmargins.dev/bridge/internal/store"
)

// #2842 item 4, server half: a reinstall is a new random key, it registers as a
// stranger, and nothing the server holds ties it to the earlier install.
func TestReinstallGetsAFreshKeyThatNothingLinksToTheOldOne(t *testing.T) {
	h := newHarness(t)
	before := h.client()
	r, err := before.Register()
	expect(t, "first install registers", r, err, 201, "")
	r, err = before.Attested("/api/v1/ping", nil)
	expect(t, "first install pings", r, err, 200, "")

	// The listener deletes the app and installs it again: a new Secure Enclave
	// key. The server is not told the two belong to one phone.
	after := h.client()
	if bytes.Equal(before.Device.KeyID, after.Device.KeyID) {
		t.Fatal("two installs produced the same key id")
	}
	r, err = after.Attested("/api/v1/ping", nil)
	expect(t, "new key before it registers", r, err, 401, "unknown_key")
	r, err = after.Register()
	expect(t, "new key registers without the old one", r, err, 201, "")
	r, err = after.Attested("/api/v1/ping", nil)
	expect(t, "new key pings", r, err, 200, "")

	// Blocking the old key does not follow the listener to the new one, and the
	// old key's signatures do not work under the new key's id.
	if err := h.store.Block(store.Tag(before.Device.KeyID)); err != nil {
		t.Fatal(err)
	}
	r, err = before.Attested("/api/v1/ping", nil)
	expect(t, "old key after a block", r, err, 403, "refused")
	r, err = after.Attested("/api/v1/ping", nil)
	expect(t, "new key after the old one was blocked", r, err, 200, "")
	req, err := before.Signed("/api/v1/ping", nil)
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set(api.HeaderKeyID, base64.StdEncoding.EncodeToString(after.Device.KeyID))
	r, err = before.Send(req)
	expect(t, "old key's signature under the new key's id", r, err, 401, "invalid_assertion")

	// On disk: two records of the five declared fields, neither holding a key id
	// in any common encoding, and different public keys. (They may share the
	// environment, the days and the counter; those say nothing about a person.)
	if err := h.store.Flush(); err != nil {
		t.Fatal(err)
	}
	files, err := filepath.Glob(filepath.Join(h.stateDir, "installs", "*.json"))
	if err != nil || len(files) != 2 {
		t.Fatalf("install records: %v %v", files, err)
	}
	var records []map[string]any
	for _, path := range files {
		raw, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		for _, keyID := range [][]byte{before.Device.KeyID, after.Device.KeyID} {
			for _, form := range []string{string(keyID), hex.EncodeToString(keyID), base64.StdEncoding.EncodeToString(keyID), base64.RawURLEncoding.EncodeToString(keyID)} {
				if bytes.Contains(raw, []byte(form)) {
					t.Errorf("%s holds a key id", filepath.Base(path))
				}
			}
		}
		var record map[string]any
		if err := json.Unmarshal(raw, &record); err != nil {
			t.Fatal(err)
		}
		if len(record) != 5 {
			t.Errorf("%s has %d fields, want the 5 declared ones: %s", filepath.Base(path), len(record), raw)
		}
		records = append(records, record)
	}
	if records[0]["publicKey"] == records[1]["publicKey"] {
		t.Error("two installs stored the same public key")
	}
}
