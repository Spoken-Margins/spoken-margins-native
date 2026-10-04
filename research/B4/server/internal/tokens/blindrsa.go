// Package tokens issues and redeems anonymous tokens (DESIGN.md §3, §11).
// An attested install asks for a few blind-signed tokens; later it spends
// one on a request that carries no install identity. The server signs
// without seeing the token, so it can't link the spend to the issuance.
//
// The signature scheme is RSABSSA-SHA384-PSS-Deterministic from RFC 9474,
// the variant Privacy Pass token type 2 uses (RFC 9578). It is written here
// on the standard library (DESIGN.md §8) and checked byte for byte against
// the RFC's published test vectors.
package tokens

import (
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha512"
	"crypto/subtle"
	"errors"
	"io"
	"math/big"
)

// saltLen is RFC 9474's sLen for the SHA-384 PSS variants.
const saltLen = sha512.Size384

var (
	ErrMessageTooLong   = errors.New("tokens: message too long for the key")
	ErrInvalidInput     = errors.New("tokens: blinded message is not a value below the modulus")
	ErrSigningFailure   = errors.New("tokens: signature did not verify against the public key")
	ErrInvalidSignature = errors.New("tokens: invalid signature")
)

var one = big.NewInt(1)

func modulusLen(pk *rsa.PublicKey) int { return (pk.N.BitLen() + 7) / 8 }

// encodePSS is EMSA-PSS-ENCODE (RFC 8017 §9.1.1) with SHA-384 and MGF1-SHA-384.
func encodePSS(msg []byte, emBits int, salt []byte) ([]byte, error) {
	hLen := sha512.Size384
	emLen := (emBits + 7) / 8
	if emLen < hLen+len(salt)+2 {
		return nil, ErrMessageTooLong
	}
	mHash := sha512.Sum384(msg)
	h := sha512.New384()
	h.Write(make([]byte, 8))
	h.Write(mHash[:])
	h.Write(salt)
	H := h.Sum(nil)

	db := make([]byte, emLen-hLen-1)
	db[len(db)-len(salt)-1] = 0x01
	copy(db[len(db)-len(salt):], salt)
	mask := mgf1SHA384(H, len(db))
	for i := range db {
		db[i] ^= mask[i]
	}
	db[0] &= 0xff >> (8*emLen - emBits)

	em := make([]byte, 0, emLen)
	em = append(em, db...)
	em = append(em, H...)
	return append(em, 0xbc), nil
}

func mgf1SHA384(seed []byte, length int) []byte {
	out := make([]byte, 0, length+sha512.Size384)
	for counter := uint32(0); len(out) < length; counter++ {
		h := sha512.New384()
		h.Write(seed)
		h.Write([]byte{byte(counter >> 24), byte(counter >> 16), byte(counter >> 8), byte(counter)})
		out = h.Sum(out)
	}
	return out[:length]
}

func intToBytes(x *big.Int, n int) []byte { return x.FillBytes(make([]byte, n)) }

// randomUnit returns r uniform in [1, n) with an inverse mod n.
func randomUnit(random io.Reader, n *big.Int) (r, inv *big.Int, err error) {
	for {
		r, err = rand.Int(random, n)
		if err != nil {
			return nil, nil, err
		}
		if r.Sign() == 0 {
			continue
		}
		if inv = new(big.Int).ModInverse(r, n); inv != nil {
			return r, inv, nil
		}
	}
}

// BlindSign is RFC 9474 §4.3: the server's half. blinded must be exactly the
// modulus length and below the modulus.
//
// math/big is not constant-time, so the private-key operation is itself
// blinded with a fresh random value (RFC 9474 §7.1). The result is checked
// against the public key before it leaves, so a fault can't leak a bad
// signature.
func BlindSign(random io.Reader, sk *rsa.PrivateKey, blinded []byte) ([]byte, error) {
	n := sk.N
	k := modulusLen(&sk.PublicKey)
	if len(blinded) != k {
		return nil, ErrInvalidInput
	}
	m := new(big.Int).SetBytes(blinded)
	if m.Cmp(n) >= 0 {
		return nil, ErrInvalidInput
	}
	e := big.NewInt(int64(sk.E))
	r, rInv, err := randomUnit(random, n)
	if err != nil {
		return nil, err
	}
	c := new(big.Int).Exp(r, e, n)
	c.Mul(c, m).Mod(c, n)
	s := new(big.Int).Exp(c, sk.D, n)
	s.Mul(s, rInv).Mod(s, n)

	if check := new(big.Int).Exp(s, e, n); check.Cmp(m) != 0 {
		return nil, ErrSigningFailure
	}
	return intToBytes(s, k), nil
}

// Verify is RSASSA-PSS-VERIFY with SHA-384 and a 48-byte salt (RFC 9474 §4.5).
func Verify(pk *rsa.PublicKey, msg, sig []byte) error {
	h := sha512.Sum384(msg)
	if err := rsa.VerifyPSS(pk, crypto.SHA384, h[:], sig, &rsa.PSSOptions{SaltLength: saltLen, Hash: crypto.SHA384}); err != nil {
		return ErrInvalidSignature
	}
	return nil
}

// Blind is RFC 9474 §4.2, the client's first step. The app does this in
// Swift; the Go copy serves the tests and smclient.
func Blind(random io.Reader, pk *rsa.PublicKey, msg []byte) (blinded []byte, inv *big.Int, err error) {
	salt := make([]byte, saltLen)
	if _, err := io.ReadFull(random, salt); err != nil {
		return nil, nil, err
	}
	r, inv, err := randomUnit(random, pk.N)
	if err != nil {
		return nil, nil, err
	}
	blinded, err = blindWith(pk, msg, salt, r)
	return blinded, inv, err
}

func blindWith(pk *rsa.PublicKey, msg, salt []byte, r *big.Int) ([]byte, error) {
	em, err := encodePSS(msg, pk.N.BitLen()-1, salt)
	if err != nil {
		return nil, err
	}
	m := new(big.Int).SetBytes(em)
	if new(big.Int).GCD(nil, nil, m, pk.N).Cmp(one) != 0 {
		return nil, ErrInvalidInput
	}
	x := new(big.Int).Exp(r, big.NewInt(int64(pk.E)), pk.N)
	z := x.Mul(x, m).Mod(x, pk.N)
	return intToBytes(z, modulusLen(pk)), nil
}

// Finalize is RFC 9474 §4.4, the client's last step: unblind and verify.
func Finalize(pk *rsa.PublicKey, msg, blindSig []byte, inv *big.Int) ([]byte, error) {
	k := modulusLen(pk)
	if len(blindSig) != k {
		return nil, ErrInvalidSignature
	}
	z := new(big.Int).SetBytes(blindSig)
	s := z.Mul(z, inv).Mod(z, pk.N)
	sig := intToBytes(s, k)
	if err := Verify(pk, msg, sig); err != nil {
		return nil, err
	}
	return sig, nil
}

// equal compares fixed-size values without an early exit.
func equal(a, b []byte) bool { return subtle.ConstantTimeCompare(a, b) == 1 }
