// Package appattest verifies Apple App Attest attestations and assertions,
// following "Validating apps that connect to your server" (Apple Developer
// Documentation). The attestation proves a key lives in a genuine device's
// Secure Enclave and belongs to our app; assertions prove later requests come
// from that key. Nothing here identifies a person: the key is generated per
// install and Apple does not tell us which device made it.
package appattest

import (
	"bytes"
	"crypto/ecdh"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/sha256"
	"crypto/x509"
	_ "embed"
	"encoding/asn1"
	"encoding/binary"
	"encoding/pem"
	"errors"
	"fmt"
	"math/big"
	"time"

	"spokenmargins.dev/bridge/internal/cbor"
)

//go:embed apple_app_attestation_root_ca.pem
var appleRootPEM []byte

// AppleRootPEM is Apple's App Attestation Root CA, downloaded from
// https://www.apple.com/certificateauthority/Apple_App_Attestation_Root_CA.pem
// (SHA-256 fingerprint 1C:B9:82:3B:A2:8B:A6:AD:2D:33:A0:06:94:1D:E2:AE:
// 4F:51:3E:F1:D4:E8:31:B9:F7:E0:FA:7B:62:42:C9:32, valid until 2045).
func AppleRootPEM() []byte { return append([]byte(nil), appleRootPEM...) }

// NonceExtensionOID carries SHA256(authData || clientDataHash) in the
// credential certificate.
var NonceExtensionOID = asn1.ObjectIdentifier{1, 2, 840, 113635, 100, 8, 2}

// AAGUIDs Apple uses to mark which App Attest environment issued a key.
var (
	AAGUIDDevelopment = []byte("appattestdevelop")
	AAGUIDProduction  = append([]byte("appattest"), make([]byte, 7)...)
)

const (
	EnvironmentDevelopment = "development"
	EnvironmentProduction  = "production"
)

var (
	ErrInvalid = errors.New("appattest: invalid")
)

func invalid(format string, a ...any) error {
	return fmt.Errorf("%w: %s", ErrInvalid, fmt.Sprintf(format, a...))
}

// Verifier checks attestation objects for one app.
type Verifier struct {
	Roots *x509.CertPool
	// AppID is "<TeamID>.<bundle identifier>".
	AppID string
	// AllowDevelopment accepts keys from the App Attest development
	// environment (debug builds). Production keys are always accepted.
	AllowDevelopment bool
	Now              func() time.Time
}

// PoolFromPEM builds a certificate pool from PEM data.
func PoolFromPEM(data []byte) (*x509.CertPool, error) {
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(data) {
		return nil, errors.New("appattest: no certificates in PEM data")
	}
	return pool, nil
}

// Key is what the server keeps after a successful attestation.
type Key struct {
	KeyID       []byte
	PublicKey   *ecdsa.PublicKey
	Environment string
}

type authData struct {
	rpIDHash []byte
	flags    byte
	counter  uint32
	aaguid   []byte
	credID   []byte
}

func parseAuthData(b []byte, withCredential bool) (authData, error) {
	var a authData
	if len(b) < 37 {
		return a, invalid("authenticator data too short")
	}
	a.rpIDHash, a.flags, a.counter = b[:32], b[32], binary.BigEndian.Uint32(b[33:37])
	if !withCredential {
		return a, nil
	}
	if len(b) < 55 {
		return a, invalid("attested credential data missing")
	}
	a.aaguid = b[37:53]
	n := int(binary.BigEndian.Uint16(b[53:55]))
	if len(b) < 55+n {
		return a, invalid("credential id truncated")
	}
	a.credID = b[55 : 55+n]
	return a, nil
}

func (v *Verifier) now() time.Time {
	if v.Now != nil {
		return v.Now()
	}
	return time.Now()
}

func asMap(x any) (map[any]any, bool) { m, ok := x.(map[any]any); return m, ok }

// VerifyAttestation runs Apple's nine validation steps for a new key.
// challenge is the one-time value the server issued; the app passes
// SHA256(challenge) as clientDataHash when it calls attestKey.
func (v *Verifier) VerifyAttestation(keyID, challenge, object []byte) (*Key, error) {
	decoded, err := cbor.Decode(object)
	if err != nil {
		return nil, invalid("attestation is not CBOR: %v", err)
	}
	top, ok := asMap(decoded)
	if !ok {
		return nil, invalid("attestation is not a map")
	}
	if f, _ := top["fmt"].(string); f != "apple-appattest" {
		return nil, invalid("unexpected format %q", f)
	}
	stmt, ok := asMap(top["attStmt"])
	if !ok {
		return nil, invalid("attStmt missing")
	}
	rawAuth, ok := top["authData"].([]byte)
	if !ok {
		return nil, invalid("authData missing")
	}
	x5c, ok := stmt["x5c"].([]any)
	if !ok || len(x5c) < 2 {
		return nil, invalid("x5c must hold the credential and intermediate certificates")
	}
	certs := make([]*x509.Certificate, 0, len(x5c))
	for _, raw := range x5c {
		der, ok := raw.([]byte)
		if !ok {
			return nil, invalid("x5c entry is not bytes")
		}
		c, err := x509.ParseCertificate(der)
		if err != nil {
			return nil, invalid("x5c certificate: %v", err)
		}
		certs = append(certs, c)
	}

	// Step 1: the credential certificate chains to Apple's root.
	intermediates := x509.NewCertPool()
	for _, c := range certs[1:] {
		intermediates.AddCert(c)
	}
	leaf := certs[0]
	if _, err := leaf.Verify(x509.VerifyOptions{
		Roots:         v.Roots,
		Intermediates: intermediates,
		CurrentTime:   v.now(),
		KeyUsages:     []x509.ExtKeyUsage{x509.ExtKeyUsageAny},
	}); err != nil {
		return nil, invalid("certificate chain: %v", err)
	}

	// Steps 2-4: the certificate's nonce binds this authData to our challenge.
	clientDataHash := sha256.Sum256(challenge)
	nonce := sha256.Sum256(append(append([]byte(nil), rawAuth...), clientDataHash[:]...))
	var certNonce []byte
	for _, ext := range leaf.Extensions {
		if ext.Id.Equal(NonceExtensionOID) {
			var seq struct {
				Nonce []byte `asn1:"tag:1,explicit"`
			}
			if rest, err := asn1.Unmarshal(ext.Value, &seq); err != nil || len(rest) != 0 {
				return nil, invalid("nonce extension malformed")
			}
			certNonce = seq.Nonce
		}
	}
	if !bytes.Equal(certNonce, nonce[:]) {
		return nil, invalid("nonce does not match challenge")
	}

	// Step 5: the key identifier is the hash of the certificate's public key.
	pub, ok := leaf.PublicKey.(*ecdsa.PublicKey)
	if !ok || pub.Curve != elliptic.P256() {
		return nil, invalid("credential key is not P-256")
	}
	ecdhPub, err := pub.ECDH()
	if err != nil {
		return nil, invalid("credential key: %v", err)
	}
	pubHash := sha256.Sum256(ecdhPub.Bytes())
	if !bytes.Equal(pubHash[:], keyID) {
		return nil, invalid("key id does not match credential certificate")
	}

	// Steps 6-9: authenticator data names our app, a fresh key, the
	// environment, and the same key id.
	ad, err := parseAuthData(rawAuth, true)
	if err != nil {
		return nil, err
	}
	appHash := sha256.Sum256([]byte(v.AppID))
	if !bytes.Equal(ad.rpIDHash, appHash[:]) {
		return nil, invalid("attestation is for a different app")
	}
	if ad.counter != 0 {
		return nil, invalid("counter must be zero for a new key")
	}
	env := ""
	switch {
	case bytes.Equal(ad.aaguid, AAGUIDProduction):
		env = EnvironmentProduction
	case bytes.Equal(ad.aaguid, AAGUIDDevelopment) && v.AllowDevelopment:
		env = EnvironmentDevelopment
	default:
		return nil, invalid("environment not accepted")
	}
	if !bytes.Equal(ad.credID, keyID) {
		return nil, invalid("credential id does not match key id")
	}
	return &Key{KeyID: append([]byte(nil), keyID...), PublicKey: pub, Environment: env}, nil
}

// VerifyAssertion checks one request signed by an attested key and returns
// the assertion's counter, which must exceed the last one stored.
func VerifyAssertion(appID string, pub *ecdsa.PublicKey, lastCounter uint32, clientData, object []byte) (uint32, error) {
	decoded, err := cbor.Decode(object)
	if err != nil {
		return 0, invalid("assertion is not CBOR: %v", err)
	}
	m, ok := asMap(decoded)
	if !ok {
		return 0, invalid("assertion is not a map")
	}
	sig, ok1 := m["signature"].([]byte)
	rawAuth, ok2 := m["authenticatorData"].([]byte)
	if !ok1 || !ok2 {
		return 0, invalid("assertion fields missing")
	}
	clientDataHash := sha256.Sum256(clientData)
	nonce := sha256.Sum256(append(append([]byte(nil), rawAuth...), clientDataHash[:]...))
	digest := sha256.Sum256(nonce[:])
	if !ecdsa.VerifyASN1(pub, digest[:], sig) {
		return 0, invalid("signature does not verify")
	}
	ad, err := parseAuthData(rawAuth, false)
	if err != nil {
		return 0, err
	}
	appHash := sha256.Sum256([]byte(appID))
	if !bytes.Equal(ad.rpIDHash, appHash[:]) {
		return 0, invalid("assertion is for a different app")
	}
	if ad.counter <= lastCounter {
		return 0, invalid("counter did not increase (replay)")
	}
	return ad.counter, nil
}

// MarshalPublicKey returns the uncompressed point for storage.
func MarshalPublicKey(pub *ecdsa.PublicKey) ([]byte, error) {
	k, err := pub.ECDH()
	if err != nil {
		return nil, err
	}
	return k.Bytes(), nil
}

// ParsePublicKey reverses MarshalPublicKey.
func ParsePublicKey(b []byte) (*ecdsa.PublicKey, error) {
	// ecdh validates that the point is on the curve.
	if _, err := ecdh.P256().NewPublicKey(b); err != nil {
		return nil, err
	}
	return &ecdsa.PublicKey{
		Curve: elliptic.P256(),
		X:     new(big.Int).SetBytes(b[1:33]),
		Y:     new(big.Int).SetBytes(b[33:65]),
	}, nil
}

// PEMCertificate is a small helper for writing test roots.
func PEMCertificate(c *x509.Certificate) []byte {
	return pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: c.Raw})
}
