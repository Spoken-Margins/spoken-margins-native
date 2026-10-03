package tokens

import (
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/asn1"
	"encoding/binary"
	"errors"
)

// TokenType is Privacy Pass's publicly verifiable token type (RFC 9578 §6),
// whose signature is RSABSSA-SHA384-PSS-Deterministic.
const TokenType uint16 = 0x0002

// IssuerName is the TokenChallenge issuer_name every Spoken Margins token names.
const IssuerName = "spokenmargins.proximitytoprogress.com"

const (
	nonceLen  = 32
	digestLen = sha256.Size
	keyIDLen  = sha256.Size
	inputLen  = 2 + nonceLen + digestLen + keyIDLen
)

var ErrMalformed = errors.New("tokens: malformed token")

// Token is RFC 9578's Token structure:
// token_type, nonce, challenge_digest, token_key_id, authenticator.
type Token struct {
	Nonce           [nonceLen]byte
	ChallengeDigest [digestLen]byte
	KeyID           [keyIDLen]byte
	Authenticator   []byte
}

// Input is token_input, the message the issuer blind-signs.
func (t Token) Input() []byte {
	b := make([]byte, 0, inputLen)
	b = binary.BigEndian.AppendUint16(b, TokenType)
	b = append(b, t.Nonce[:]...)
	b = append(b, t.ChallengeDigest[:]...)
	return append(b, t.KeyID[:]...)
}

func (t Token) Marshal() []byte { return append(t.Input(), t.Authenticator...) }

// ParseToken reads a token. The authenticator's length is checked against
// the key at redemption, since it depends on the key's size.
func ParseToken(b []byte) (Token, error) {
	var t Token
	if len(b) <= inputLen || binary.BigEndian.Uint16(b) != TokenType {
		return t, ErrMalformed
	}
	copy(t.Nonce[:], b[2:])
	copy(t.ChallengeDigest[:], b[2+nonceLen:])
	copy(t.KeyID[:], b[2+nonceLen+digestLen:])
	t.Authenticator = append([]byte(nil), b[inputLen:]...)
	return t, nil
}

// ChallengeDigest is SHA-256 of an RFC 9577 TokenChallenge for this issuer,
// with no redemption context and purpose as the origin_info. A token made
// for one purpose (say "maps") can't be spent on another.
func ChallengeDigest(purpose string) [digestLen]byte {
	b := binary.BigEndian.AppendUint16(nil, TokenType)
	b = binary.BigEndian.AppendUint16(b, uint16(len(IssuerName)))
	b = append(b, IssuerName...)
	b = append(b, 0) // redemption_context: empty
	b = binary.BigEndian.AppendUint16(b, uint16(len(purpose)))
	b = append(b, purpose...)
	return sha256.Sum256(b)
}

var (
	oidRSASSAPSS = asn1.ObjectIdentifier{1, 2, 840, 113549, 1, 1, 10}
	oidSHA384    = asn1.ObjectIdentifier{2, 16, 840, 1, 101, 3, 4, 2, 2}
	oidMGF1      = asn1.ObjectIdentifier{1, 2, 840, 113549, 1, 1, 8}
)

type hashAlgorithm struct{ Algorithm asn1.ObjectIdentifier }

type mgfAlgorithm struct {
	Algorithm asn1.ObjectIdentifier
	Hash      hashAlgorithm
}

type pssParams struct {
	Hash       hashAlgorithm `asn1:"explicit,tag:0"`
	MGF        mgfAlgorithm  `asn1:"explicit,tag:1"`
	SaltLength int           `asn1:"explicit,tag:2"`
}

type pssAlgorithm struct {
	Algorithm  asn1.ObjectIdentifier
	Parameters pssParams
}

type subjectPublicKeyInfo struct {
	Algorithm pssAlgorithm
	PublicKey asn1.BitString
}

// SPKI encodes pk as RFC 9578 §6.5 requires: a SubjectPublicKeyInfo whose
// algorithm is id-RSASSA-PSS with SHA-384, MGF1-SHA-384 and a 48-byte salt
// spelled out, not the plain rsaEncryption that x509 writes. Phones and
// other Privacy Pass code hash these exact bytes to get the key id.
func SPKI(pk *rsa.PublicKey) ([]byte, error) {
	key := x509.MarshalPKCS1PublicKey(pk)
	return asn1.Marshal(subjectPublicKeyInfo{
		Algorithm: pssAlgorithm{
			Algorithm: oidRSASSAPSS,
			Parameters: pssParams{
				Hash:       hashAlgorithm{oidSHA384},
				MGF:        mgfAlgorithm{oidMGF1, hashAlgorithm{oidSHA384}},
				SaltLength: saltLen,
			},
		},
		PublicKey: asn1.BitString{Bytes: key, BitLength: 8 * len(key)},
	})
}

// ParseSPKI reads a key encoded by SPKI, refusing any other algorithm or
// parameters, so a phone can't be handed a key for a different scheme.
func ParseSPKI(der []byte) (*rsa.PublicKey, error) {
	var info subjectPublicKeyInfo
	rest, err := asn1.Unmarshal(der, &info)
	if err != nil || len(rest) != 0 {
		return nil, ErrMalformed
	}
	pk, err := x509.ParsePKCS1PublicKey(info.PublicKey.RightAlign())
	if err != nil {
		return nil, ErrMalformed
	}
	// Re-encoding must give the same bytes: that checks every parameter.
	again, err := SPKI(pk)
	if err != nil || string(again) != string(der) {
		return nil, ErrMalformed
	}
	return pk, nil
}

// KeyID is token_key_id: SHA-256 of SPKI(pk) (RFC 9578 §6.5).
func KeyID(pk *rsa.PublicKey) ([keyIDLen]byte, error) {
	der, err := SPKI(pk)
	if err != nil {
		return [keyIDLen]byte{}, err
	}
	return sha256.Sum256(der), nil
}
