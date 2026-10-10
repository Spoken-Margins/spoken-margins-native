package appattest_test

import (
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"

	"spokenmargins.dev/bridge/internal/appattest"
	"spokenmargins.dev/bridge/internal/appattest/fakeattest"
)

// Every other test in this package checks the verifier against fakeattest,
// which was written from the same reading of Apple's documentation as the
// verifier: the order of authData and clientDataHash in the nonce, the
// double SHA-256 of an assertion, the flag and AAGUID bytes, the nonce
// extension's shape. A misreading shared by both is invisible to them, and
// the app has no App Attest client yet, so nothing here has met bytes that
// Apple produced.
//
// This is the slot for those bytes. testdata/device-capture.json holds one
// attestation and one assertion captured from a real device (the
// development environment is fine); the verifier must accept them under
// Apple's own root. Until the owner supplies that file, the real-device test
// below SKIPS, loudly, and the package should be described as "unverified
// against Apple". Do not make up the file: a capture from fakeattest proves
// nothing.
//
//	{
//	  "appId": "J8SWC6J3VY.com.spokenmargins.native",
//	  "environment": "development",              // or "production"
//	  "verifyAt": "2026-10-08T12:00:00Z",        // a time inside the leaf certificate's validity
//	  "keyId": "<base64>", "challenge": "<base64: the server-side challenge bytes>",
//	  "attestation": "<base64: the CBOR object from attestKey>",
//	  "assertion": {
//	    "clientData": "<base64: the bytes passed to generateAssertion before hashing>",
//	    "assertion": "<base64: the CBOR object from generateAssertion>",
//	    "counterBefore": 0
//	  }
//	}
type deviceCapture struct {
	AppID       string `json:"appId"`
	Environment string `json:"environment"`
	VerifyAt    string `json:"verifyAt"`
	KeyID       string `json:"keyId"`
	Challenge   string `json:"challenge"`
	Attestation string `json:"attestation"`
	Assertion   struct {
		ClientData    string `json:"clientData"`
		Assertion     string `json:"assertion"`
		CounterBefore uint32 `json:"counterBefore"`
	} `json:"assertion"`
}

func verifyCapture(t *testing.T, c deviceCapture, roots *x509.CertPool) {
	t.Helper()
	b64 := func(name, value string) []byte {
		data, err := base64.StdEncoding.DecodeString(value)
		if err != nil || len(data) == 0 {
			t.Fatalf("capture field %s is not base64: %v", name, err)
		}
		return data
	}
	at, err := time.Parse(time.RFC3339, c.VerifyAt)
	if err != nil {
		t.Fatalf("verifyAt: %v", err)
	}
	v := &appattest.Verifier{
		Roots: roots, AppID: c.AppID, Now: func() time.Time { return at },
		AllowDevelopment: c.Environment == appattest.EnvironmentDevelopment,
	}
	key, err := v.VerifyAttestation(b64("keyId", c.KeyID), b64("challenge", c.Challenge), b64("attestation", c.Attestation))
	if err != nil {
		t.Fatalf("the attestation was refused: %v", err)
	}
	if key.Environment != c.Environment {
		t.Fatalf("environment %q, want %q", key.Environment, c.Environment)
	}
	counter, err := appattest.VerifyAssertion(c.AppID, key.PublicKey, c.Assertion.CounterBefore,
		b64("assertion.clientData", c.Assertion.ClientData), b64("assertion.assertion", c.Assertion.Assertion))
	if err != nil {
		t.Fatalf("the assertion was refused: %v", err)
	}
	if counter <= c.Assertion.CounterBefore {
		t.Fatalf("assertion counter %d did not pass %d", counter, c.Assertion.CounterBefore)
	}
}

func TestVerifierAcceptsARealDeviceCaptureUnderApplesRoot(t *testing.T) {
	data, err := os.ReadFile(filepath.Join("testdata", "device-capture.json"))
	if errors.Is(err, os.ErrNotExist) {
		t.Skip("UNVERIFIED AGAINST APPLE: no testdata/device-capture.json. Every other test here uses fakeattest, " +
			"which shares the verifier's reading of Apple's format; the owner must supply one real attestation and assertion.")
	}
	if err != nil {
		t.Fatal(err)
	}
	var c deviceCapture
	if err := json.Unmarshal(data, &c); err != nil {
		t.Fatal(err)
	}
	roots, err := appattest.PoolFromPEM(appattest.AppleRootPEM())
	if err != nil {
		t.Fatal(err)
	}
	verifyCapture(t, c, roots)
}

// The harness above is checked on a capture fakeattest makes, so that when a
// real file arrives a failure means the verifier, not this code. It is not
// evidence about Apple's format.
func TestDeviceCaptureHarnessWorksOnAFakeCapture(t *testing.T) {
	ca, _ := setup(t)
	pool, err := appattest.PoolFromPEM(ca.RootPEM())
	if err != nil {
		t.Fatal(err)
	}
	d, err := fakeattest.NewDevice(appID)
	if err != nil {
		t.Fatal(err)
	}
	challenge := []byte("server-side challenge")
	attestation, err := ca.Attest(d, challenge, fakeattest.Options{Development: true})
	if err != nil {
		t.Fatal(err)
	}
	clientData := []byte("POST /api/v1/ping")
	assertion, err := d.Assert(clientData)
	if err != nil {
		t.Fatal(err)
	}
	enc := base64.StdEncoding.EncodeToString
	c := deviceCapture{
		AppID: appID, Environment: appattest.EnvironmentDevelopment, VerifyAt: time.Now().UTC().Format(time.RFC3339),
		KeyID: enc(d.KeyID), Challenge: enc(challenge), Attestation: enc(attestation),
	}
	c.Assertion.ClientData, c.Assertion.Assertion = enc(clientData), enc(assertion)
	verifyCapture(t, c, pool)
}
