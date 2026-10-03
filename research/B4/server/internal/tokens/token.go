package tokens

import (
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
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

// KeyID is token_key_id: SHA-256 of the public key's PKIX (SPKI) DER.
func KeyID(pk *rsa.PublicKey) ([keyIDLen]byte, error) {
	der, err := x509.MarshalPKIXPublicKey(pk)
	if err != nil {
		return [keyIDLen]byte{}, err
	}
	return sha256.Sum256(der), nil
}
