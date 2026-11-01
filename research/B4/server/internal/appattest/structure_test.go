package appattest_test

import (
	"bytes"
	"errors"
	"testing"

	"spokenmargins.dev/bridge/internal/appattest"
	"spokenmargins.dev/bridge/internal/appattest/fakeattest"
	"spokenmargins.dev/bridge/internal/cbor"
)

// mutateAttestation decodes a valid attestation, lets edit change its top
// level and attStmt (string-keyed maps), and encodes it again. TestRejectsBadAttestations
// builds wrong attestations by changing what the device signs; these change the
// object's shape, which a real device never sends but a client of ours can.
func mutateAttestation(t *testing.T, object []byte, edit func(top, stmt map[string]any)) []byte {
	t.Helper()
	decoded, err := cbor.Decode(object)
	if err != nil {
		t.Fatal(err)
	}
	asStrings := func(m map[any]any) map[string]any {
		out := map[string]any{}
		for k, v := range m {
			out[k.(string)] = v
		}
		return out
	}
	top := asStrings(decoded.(map[any]any))
	stmt := asStrings(top["attStmt"].(map[any]any))
	edit(top, stmt)
	if _, kept := top["attStmt"]; kept {
		top["attStmt"] = stmt
	}
	out, err := cbor.Encode(top)
	if err != nil {
		t.Fatal(err)
	}
	return out
}

func TestRejectsMalformedAttestationObjects(t *testing.T) {
	ca, v := setup(t)
	challenge := []byte("the real challenge")
	d, _ := fakeattest.NewDevice(appID)
	valid, err := ca.Attest(d, challenge, fakeattest.Options{})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := v.VerifyAttestation(d.KeyID, challenge, valid); err != nil {
		t.Fatalf("the unmodified object must verify, or these cases prove nothing: %v", err)
	}

	cases := []struct {
		name string
		edit func(top, stmt map[string]any)
	}{
		{"another format", func(top, _ map[string]any) { top["fmt"] = "packed" }},
		{"no format", func(top, _ map[string]any) { delete(top, "fmt") }},
		{"no attStmt", func(top, _ map[string]any) { delete(top, "attStmt") }},
		{"no authData", func(top, _ map[string]any) { delete(top, "authData") }},
		{"authData is text", func(top, _ map[string]any) { top["authData"] = "not bytes" }},
		{"no certificate chain", func(_, stmt map[string]any) { delete(stmt, "x5c") }},
		{"credential certificate only", func(_, stmt map[string]any) {
			stmt["x5c"] = stmt["x5c"].([]any)[:1]
		}},
		{"intermediate only", func(_, stmt map[string]any) {
			chain := stmt["x5c"].([]any)
			stmt["x5c"] = []any{chain[1], chain[1]}
		}},
		{"chain in the wrong order", func(_, stmt map[string]any) {
			chain := stmt["x5c"].([]any)
			stmt["x5c"] = []any{chain[1], chain[0]}
		}},
		{"certificate entry is text", func(_, stmt map[string]any) {
			stmt["x5c"] = []any{"leaf", "intermediate"}
		}},
		{"certificate is not DER", func(_, stmt map[string]any) {
			stmt["x5c"] = []any{[]byte("leaf"), []byte("intermediate")}
		}},
		{"authData cut short (refused by the nonce binding)", func(top, _ map[string]any) {
			top["authData"] = top["authData"].([]byte)[:36]
		}},
		{"authData cut inside the credential data (refused by the nonce binding)", func(top, _ map[string]any) {
			top["authData"] = top["authData"].([]byte)[:60]
		}},
		{"authData with a flipped byte", func(top, _ map[string]any) {
			b := append([]byte(nil), top["authData"].([]byte)...)
			b[10] ^= 0x01
			top["authData"] = b
		}},
	}
	for _, c := range cases {
		object := mutateAttestation(t, valid, c.edit)
		if _, err := v.VerifyAttestation(d.KeyID, challenge, object); !errors.Is(err, appattest.ErrInvalid) {
			t.Errorf("%s: want ErrInvalid, got %v", c.name, err)
		}
	}

	// A key id of the wrong length or no key id at all.
	for name, keyID := range map[string][]byte{"empty key id": nil, "short key id": d.KeyID[:16]} {
		if _, err := v.VerifyAttestation(keyID, challenge, valid); !errors.Is(err, appattest.ErrInvalid) {
			t.Errorf("%s: want ErrInvalid, got %v", name, err)
		}
	}
	// An empty challenge is not the challenge the object was made for.
	if _, err := v.VerifyAttestation(d.KeyID, nil, valid); !errors.Is(err, appattest.ErrInvalid) {
		t.Errorf("empty challenge: want ErrInvalid, got %v", err)
	}
}

func TestRejectsMalformedAssertions(t *testing.T) {
	ca, v := setup(t)
	d, _ := fakeattest.NewDevice(appID)
	challenge := []byte("c")
	obj, _ := ca.Attest(d, challenge, fakeattest.Options{})
	key, err := v.VerifyAttestation(d.KeyID, challenge, obj)
	if err != nil {
		t.Fatal(err)
	}
	data := []byte("request")
	good, _ := d.Assert(data)
	if _, err := appattest.VerifyAssertion(appID, key.PublicKey, 0, data, good); err != nil {
		t.Fatalf("the unmodified assertion must verify, or these cases prove nothing: %v", err)
	}

	edit := func(f func(m map[string]any)) []byte {
		decoded, err := cbor.Decode(good)
		if err != nil {
			t.Fatal(err)
		}
		m := map[string]any{}
		for k, val := range decoded.(map[any]any) {
			m[k.(string)] = val
		}
		f(m)
		out, err := cbor.Encode(m)
		if err != nil {
			t.Fatal(err)
		}
		return out
	}
	cases := map[string][]byte{
		"empty":                nil,
		"not cbor":             []byte("{\"signature\":\"\"}"),
		"no signature":         edit(func(m map[string]any) { delete(m, "signature") }),
		"no authenticatorData": edit(func(m map[string]any) { delete(m, "authenticatorData") }),
		"signature is text":    edit(func(m map[string]any) { m["signature"] = "signed" }),
		"empty signature":      edit(func(m map[string]any) { m["signature"] = []byte{} }),
		"signature bit flipped": edit(func(m map[string]any) {
			s := bytes.Clone(m["signature"].([]byte))
			s[len(s)-1] ^= 1
			m["signature"] = s
		}),
		"authenticatorData bit flipped": edit(func(m map[string]any) {
			a := bytes.Clone(m["authenticatorData"].([]byte))
			a[36] ^= 1 // the counter's low byte
			m["authenticatorData"] = a
		}),
		"authenticatorData cut short": edit(func(m map[string]any) { m["authenticatorData"] = m["authenticatorData"].([]byte)[:20] }),
	}
	for name, assertion := range cases {
		if _, err := appattest.VerifyAssertion(appID, key.PublicKey, 0, data, assertion); !errors.Is(err, appattest.ErrInvalid) {
			t.Errorf("%s: want ErrInvalid, got %v", name, err)
		}
	}
}
