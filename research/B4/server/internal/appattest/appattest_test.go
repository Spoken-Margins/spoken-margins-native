package appattest_test

import (
	"crypto/sha256"
	"crypto/x509"
	"errors"
	"testing"
	"time"

	"spokenmargins.dev/bridge/internal/appattest"
	"spokenmargins.dev/bridge/internal/appattest/fakeattest"
)

const appID = "J8SWC6J3VY.com.spokenmargins.native"

func setup(t *testing.T) (*fakeattest.CA, *appattest.Verifier) {
	t.Helper()
	ca, err := fakeattest.NewCA()
	if err != nil {
		t.Fatal(err)
	}
	pool, err := appattest.PoolFromPEM(ca.RootPEM())
	if err != nil {
		t.Fatal(err)
	}
	return ca, &appattest.Verifier{Roots: pool, AppID: appID}
}

func TestAppleRootIsEmbedded(t *testing.T) {
	pool, err := appattest.PoolFromPEM(appattest.AppleRootPEM())
	if err != nil {
		t.Fatal(err)
	}
	_ = pool
	c, err := x509.ParseCertificate(mustPEM(t, appattest.AppleRootPEM()))
	if err != nil {
		t.Fatal(err)
	}
	fp := sha256.Sum256(c.Raw)
	const want = "1cb9823ba28ba6ad2d33a006941de2ae4f513ef1d4e831b9f7e0fa7b6242c932"
	if got := hexString(fp[:]); got != want {
		t.Fatalf("Apple root fingerprint %s, want %s", got, want)
	}
}

func TestValidAttestationAndAssertions(t *testing.T) {
	ca, v := setup(t)
	d, _ := fakeattest.NewDevice(appID)
	challenge := []byte("server challenge 0123456789abcdef")
	obj, err := ca.Attest(d, challenge, fakeattest.Options{})
	if err != nil {
		t.Fatal(err)
	}
	key, err := v.VerifyAttestation(d.KeyID, challenge, obj)
	if err != nil {
		t.Fatalf("valid attestation rejected: %v", err)
	}
	if key.Environment != appattest.EnvironmentProduction {
		t.Fatalf("environment %q", key.Environment)
	}
	stored, _ := appattest.MarshalPublicKey(key.PublicKey)
	pub, err := appattest.ParsePublicKey(stored)
	if err != nil {
		t.Fatal(err)
	}

	last := uint32(0)
	for i := 0; i < 3; i++ {
		data := []byte("request body hash and route")
		a, _ := d.Assert(data)
		c, err := appattest.VerifyAssertion(appID, pub, last, data, a)
		if err != nil {
			t.Fatalf("assertion %d rejected: %v", i, err)
		}
		// A replay of the same assertion must fail once its counter is stored.
		if _, err := appattest.VerifyAssertion(appID, pub, c, data, a); !errors.Is(err, appattest.ErrInvalid) {
			t.Fatalf("replayed assertion accepted: %v", err)
		}
		last = c
	}

	a, _ := d.Assert([]byte("signed this"))
	if _, err := appattest.VerifyAssertion(appID, pub, last, []byte("but sent this"), a); err == nil {
		t.Fatal("assertion over different client data accepted")
	}
	a, _ = d.Assert([]byte("x"))
	if _, err := appattest.VerifyAssertion("OTHERTEAM.com.example", pub, last, []byte("x"), a); err == nil {
		t.Fatal("assertion accepted for another app id")
	}
	other, _ := fakeattest.NewDevice(appID)
	a, _ = other.Assert([]byte("x"))
	if _, err := appattest.VerifyAssertion(appID, pub, 0, []byte("x"), a); err == nil {
		t.Fatal("assertion from another key accepted")
	}
}

func TestRejectsBadAttestations(t *testing.T) {
	ca, v := setup(t)
	otherCA, _ := fakeattest.NewCA()
	challenge := []byte("the real challenge")
	cases := []struct {
		name  string
		build func(d *fakeattest.Device) ([]byte, []byte, []byte) // keyID, challenge, object
	}{
		{"wrong challenge", func(d *fakeattest.Device) ([]byte, []byte, []byte) {
			o, _ := ca.Attest(d, []byte("another challenge"), fakeattest.Options{})
			return d.KeyID, challenge, o
		}},
		{"untrusted root", func(d *fakeattest.Device) ([]byte, []byte, []byte) {
			o, _ := otherCA.Attest(d, challenge, fakeattest.Options{})
			return d.KeyID, challenge, o
		}},
		{"other app", func(d *fakeattest.Device) ([]byte, []byte, []byte) {
			o, _ := ca.Attest(d, challenge, fakeattest.Options{AppID: "OTHERTEAM.com.example"})
			return d.KeyID, challenge, o
		}},
		{"key id mismatch", func(d *fakeattest.Device) ([]byte, []byte, []byte) {
			o, _ := ca.Attest(d, challenge, fakeattest.Options{})
			other, _ := fakeattest.NewDevice(appID)
			return other.KeyID, challenge, o
		}},
		{"credential id mismatch", func(d *fakeattest.Device) ([]byte, []byte, []byte) {
			o, _ := ca.Attest(d, challenge, fakeattest.Options{CredentialID: make([]byte, 32)})
			return d.KeyID, challenge, o
		}},
		{"nonzero counter", func(d *fakeattest.Device) ([]byte, []byte, []byte) {
			o, _ := ca.Attest(d, challenge, fakeattest.Options{Counter: 5})
			return d.KeyID, challenge, o
		}},
		{"tampered nonce", func(d *fakeattest.Device) ([]byte, []byte, []byte) {
			o, _ := ca.Attest(d, challenge, fakeattest.Options{WrongNonce: true})
			return d.KeyID, challenge, o
		}},
		{"development key on production-only server", func(d *fakeattest.Device) ([]byte, []byte, []byte) {
			o, _ := ca.Attest(d, challenge, fakeattest.Options{Development: true})
			return d.KeyID, challenge, o
		}},
		{"expired certificate", func(d *fakeattest.Device) ([]byte, []byte, []byte) {
			o, _ := ca.Attest(d, challenge, fakeattest.Options{NotAfter: time.Now().Add(-time.Minute)})
			return d.KeyID, challenge, o
		}},
		{"not cbor", func(d *fakeattest.Device) ([]byte, []byte, []byte) {
			return d.KeyID, challenge, []byte("{\"fmt\":\"apple-appattest\"}")
		}},
	}
	for _, c := range cases {
		d, _ := fakeattest.NewDevice(appID)
		keyID, ch, obj := c.build(d)
		if _, err := v.VerifyAttestation(keyID, ch, obj); !errors.Is(err, appattest.ErrInvalid) {
			t.Errorf("%s: want ErrInvalid, got %v", c.name, err)
		}
	}
}

func TestDevelopmentKeysWhenAllowed(t *testing.T) {
	ca, v := setup(t)
	v.AllowDevelopment = true
	d, _ := fakeattest.NewDevice(appID)
	obj, _ := ca.Attest(d, []byte("c"), fakeattest.Options{Development: true})
	key, err := v.VerifyAttestation(d.KeyID, []byte("c"), obj)
	if err != nil || key.Environment != appattest.EnvironmentDevelopment {
		t.Fatalf("development key: %v %v", key, err)
	}
}
