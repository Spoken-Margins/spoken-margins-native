package tokens

import (
	"crypto/rsa"
	"io"
	"math/big"
)

// Pending is the phone's side of one token: made before issuance, finished
// with the server's blind signature. The app does this in Swift; this copy
// serves the tests and smclient, and documents the exact bytes.
type Pending struct {
	pk      *rsa.PublicKey
	token   Token
	inv     *big.Int
	Blinded []byte
}

// NewPending picks a fresh nonce, binds the token to purpose and the key,
// and blinds it.
func NewPending(random io.Reader, pk *rsa.PublicKey, purpose string) (*Pending, error) {
	id, err := KeyID(pk)
	if err != nil {
		return nil, err
	}
	p := &Pending{pk: pk}
	if _, err := io.ReadFull(random, p.token.Nonce[:]); err != nil {
		return nil, err
	}
	p.token.ChallengeDigest = ChallengeDigest(purpose)
	p.token.KeyID = id
	if p.Blinded, p.inv, err = Blind(random, pk, p.token.Input()); err != nil {
		return nil, err
	}
	return p, nil
}

// Finish unblinds the server's signature, checks it, and returns the token
// to spend.
func (p *Pending) Finish(blindSig []byte) ([]byte, error) {
	sig, err := Finalize(p.pk, p.token.Input(), blindSig, p.inv)
	if err != nil {
		return nil, err
	}
	t := p.token
	t.Authenticator = sig
	return t.Marshal(), nil
}
