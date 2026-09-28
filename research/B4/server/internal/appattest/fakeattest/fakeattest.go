// Package fakeattest plays Apple's part of App Attest for tests and the
// local test client: a root and intermediate CA that issue credential
// certificates in the same shape Apple does, and a device that signs
// assertions. A server only trusts these when it is started with the test
// root instead of Apple's.
package fakeattest

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/asn1"
	"encoding/binary"
	"encoding/pem"
	"errors"
	"math/big"
	"os"
	"path/filepath"
	"time"

	"spokenmargins.dev/bridge/internal/appattest"
	"spokenmargins.dev/bridge/internal/cbor"
)

type CA struct {
	Root     *x509.Certificate
	RootKey  *ecdsa.PrivateKey
	Inter    *x509.Certificate
	InterKey *ecdsa.PrivateKey
}

func serial() *big.Int {
	n, _ := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 62))
	return n
}

func NewCA() (*CA, error) {
	rootKey, err := ecdsa.GenerateKey(elliptic.P384(), rand.Reader)
	if err != nil {
		return nil, err
	}
	now := time.Now()
	rootTmpl := &x509.Certificate{
		SerialNumber:          serial(),
		Subject:               pkix.Name{CommonName: "Spoken Margins TEST App Attestation Root"},
		NotBefore:             now.Add(-time.Hour),
		NotAfter:              now.AddDate(5, 0, 0),
		IsCA:                  true,
		BasicConstraintsValid: true,
		KeyUsage:              x509.KeyUsageCertSign,
	}
	rootDER, err := x509.CreateCertificate(rand.Reader, rootTmpl, rootTmpl, &rootKey.PublicKey, rootKey)
	if err != nil {
		return nil, err
	}
	root, _ := x509.ParseCertificate(rootDER)
	interKey, err := ecdsa.GenerateKey(elliptic.P384(), rand.Reader)
	if err != nil {
		return nil, err
	}
	interTmpl := &x509.Certificate{
		SerialNumber:          serial(),
		Subject:               pkix.Name{CommonName: "Spoken Margins TEST App Attestation CA 1"},
		NotBefore:             now.Add(-time.Hour),
		NotAfter:              now.AddDate(5, 0, 0),
		IsCA:                  true,
		BasicConstraintsValid: true,
		KeyUsage:              x509.KeyUsageCertSign,
	}
	interDER, err := x509.CreateCertificate(rand.Reader, interTmpl, root, &interKey.PublicKey, rootKey)
	if err != nil {
		return nil, err
	}
	inter, _ := x509.ParseCertificate(interDER)
	return &CA{Root: root, RootKey: rootKey, Inter: inter, InterKey: interKey}, nil
}

// RootPEM is what a test server is started with instead of Apple's root.
func (ca *CA) RootPEM() []byte { return appattest.PEMCertificate(ca.Root) }

// Save writes the CA to dir so a separately started client can use it.
func (ca *CA) Save(dir string) error {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	var out []byte
	for _, c := range []*x509.Certificate{ca.Root, ca.Inter} {
		out = append(out, appattest.PEMCertificate(c)...)
	}
	for _, k := range []*ecdsa.PrivateKey{ca.RootKey, ca.InterKey} {
		der, err := x509.MarshalECPrivateKey(k)
		if err != nil {
			return err
		}
		out = append(out, pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: der})...)
	}
	if err := os.WriteFile(filepath.Join(dir, "test-ca.pem"), out, 0o600); err != nil {
		return err
	}
	return os.WriteFile(filepath.Join(dir, "test-root.pem"), ca.RootPEM(), 0o644)
}

func LoadCA(dir string) (*CA, error) {
	data, err := os.ReadFile(filepath.Join(dir, "test-ca.pem"))
	if err != nil {
		return nil, err
	}
	var certs []*x509.Certificate
	var keys []*ecdsa.PrivateKey
	for {
		var b *pem.Block
		b, data = pem.Decode(data)
		if b == nil {
			break
		}
		switch b.Type {
		case "CERTIFICATE":
			c, err := x509.ParseCertificate(b.Bytes)
			if err != nil {
				return nil, err
			}
			certs = append(certs, c)
		case "EC PRIVATE KEY":
			k, err := x509.ParseECPrivateKey(b.Bytes)
			if err != nil {
				return nil, err
			}
			keys = append(keys, k)
		}
	}
	if len(certs) != 2 || len(keys) != 2 {
		return nil, errors.New("fakeattest: test-ca.pem must hold two certificates and two keys")
	}
	return &CA{Root: certs[0], Inter: certs[1], RootKey: keys[0], InterKey: keys[1]}, nil
}

// Device is one app install's Secure Enclave key.
type Device struct {
	AppID   string
	KeyID   []byte
	Key     *ecdsa.PrivateKey
	Counter uint32
}

func NewDevice(appID string) (*Device, error) {
	k, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, err
	}
	pub, _ := appattest.MarshalPublicKey(&k.PublicKey)
	id := sha256.Sum256(pub)
	return &Device{AppID: appID, KeyID: id[:], Key: k}, nil
}

// Options lets tests produce deliberately wrong attestations.
type Options struct {
	Development  bool
	AppID        string // overrides the device's app id in authData
	Counter      uint32
	WrongNonce   bool
	CredentialID []byte
	NotAfter     time.Time
}

// Attest returns an attestation object as DCAppAttestService.attestKey would,
// with clientDataHash = SHA256(challenge).
func (ca *CA) Attest(d *Device, challenge []byte, o Options) ([]byte, error) {
	appID := d.AppID
	if o.AppID != "" {
		appID = o.AppID
	}
	credID := d.KeyID
	if o.CredentialID != nil {
		credID = o.CredentialID
	}
	aaguid := appattest.AAGUIDProduction
	if o.Development {
		aaguid = appattest.AAGUIDDevelopment
	}
	rp := sha256.Sum256([]byte(appID))
	ad := append([]byte(nil), rp[:]...)
	ad = append(ad, 0x40) // attested credential data present
	ad = binary.BigEndian.AppendUint32(ad, o.Counter)
	ad = append(ad, aaguid...)
	ad = binary.BigEndian.AppendUint16(ad, uint16(len(credID)))
	ad = append(ad, credID...)
	pub, _ := appattest.MarshalPublicKey(&d.Key.PublicKey)
	cose, err := cbor.Encode(cbor.Map{
		{Key: 1, Value: 2}, {Key: 3, Value: -7}, {Key: -1, Value: 1},
		{Key: -2, Value: pub[1:33]}, {Key: -3, Value: pub[33:65]},
	})
	if err != nil {
		return nil, err
	}
	ad = append(ad, cose...)

	cdh := sha256.Sum256(challenge)
	nonce := sha256.Sum256(append(append([]byte(nil), ad...), cdh[:]...))
	if o.WrongNonce {
		nonce[0] ^= 0xff
	}
	ext, err := asn1.Marshal(struct {
		Nonce []byte `asn1:"tag:1,explicit"`
	}{nonce[:]})
	if err != nil {
		return nil, err
	}
	notAfter := time.Now().AddDate(0, 0, 90)
	if !o.NotAfter.IsZero() {
		notAfter = o.NotAfter
	}
	leafTmpl := &x509.Certificate{
		SerialNumber:    serial(),
		Subject:         pkix.Name{CommonName: "test credential"},
		NotBefore:       time.Now().Add(-time.Hour),
		NotAfter:        notAfter,
		KeyUsage:        x509.KeyUsageDigitalSignature,
		ExtraExtensions: []pkix.Extension{{Id: appattest.NonceExtensionOID, Value: ext}},
	}
	leafDER, err := x509.CreateCertificate(rand.Reader, leafTmpl, ca.Inter, &d.Key.PublicKey, ca.InterKey)
	if err != nil {
		return nil, err
	}
	return cbor.Encode(cbor.Map{
		{Key: "fmt", Value: "apple-appattest"},
		{Key: "attStmt", Value: cbor.Map{
			{Key: "x5c", Value: []any{leafDER, ca.Inter.Raw}},
			{Key: "receipt", Value: []byte("test receipt")},
		}},
		{Key: "authData", Value: ad},
	})
}

// Assert signs clientData as DCAppAttestService.generateAssertion would,
// advancing the device's counter.
func (d *Device) Assert(clientData []byte) ([]byte, error) {
	d.Counter++
	rp := sha256.Sum256([]byte(d.AppID))
	ad := append(append([]byte(nil), rp[:]...), 0x00)
	ad = binary.BigEndian.AppendUint32(ad, d.Counter)
	cdh := sha256.Sum256(clientData)
	nonce := sha256.Sum256(append(append([]byte(nil), ad...), cdh[:]...))
	digest := sha256.Sum256(nonce[:])
	sig, err := ecdsa.SignASN1(rand.Reader, d.Key, digest[:])
	if err != nil {
		return nil, err
	}
	return cbor.Encode(cbor.Map{
		{Key: "signature", Value: sig},
		{Key: "authenticatorData", Value: ad},
	})
}
