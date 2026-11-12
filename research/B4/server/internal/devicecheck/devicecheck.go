// Package devicecheck talks to Apple's DeviceCheck server API: two bits per physical device, kept by
// Apple, that survive an app reinstall (#1728). The server never sees or stores a device identifier;
// the app hands it a short-lived device token and Apple reads or writes the bits behind it.
//
// Nothing here knows about strikes. The caller says "read the bits" or "write these bits", and
// package api decides when (only once the ladder has been used, and only when the app has sent a token
// because the server asked for one).
//
// A token is passed straight through and never kept, logged or put in an error.
package devicecheck

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"sync"
	"time"
)

const (
	// ProductionURL serves devices running an App Store or TestFlight build.
	ProductionURL = "https://api.devicecheck.apple.com"
	// DevelopmentURL serves devices running a build signed for development.
	DevelopmentURL = "https://api.development.devicecheck.apple.com"

	pathQuery  = "/v1/query_two_bits"
	pathUpdate = "/v1/update_two_bits"

	// A provider token is good for an hour at Apple; making one more than every twenty minutes is
	// refused there, so one is reused for that long.
	jwtLife = 20 * time.Minute

	maxReply = 4 << 10
)

var (
	// ErrBadToken: Apple did not accept the device token (a malformed, made-up or expired one). The
	// caller should treat the request as not having carried a token.
	ErrBadToken = errors.New("devicecheck: device token refused")
	// ErrUnavailable: Apple could not answer, or the server's own key was refused. Nothing is known
	// about the device; the caller decides whether to fail open.
	ErrUnavailable = errors.New("devicecheck: unavailable")
)

// Bits is the two bits Apple keeps for a device and this developer.
type Bits struct{ Bit0, Bit1 bool }

// Value is the bits as a number from 0 to 3, bit 0 the low one.
func (b Bits) Value() uint8 {
	var v uint8
	if b.Bit0 {
		v |= 1
	}
	if b.Bit1 {
		v |= 2
	}
	return v
}

// BitsOf is the inverse of Value; only the low two bits are read.
func BitsOf(v uint8) Bits { return Bits{Bit0: v&1 != 0, Bit1: v&2 != 0} }

// Client signs requests with the developer's DeviceCheck key (a .p8 from the developer account).
type Client struct {
	TeamID string
	KeyID  string
	Key    *ecdsa.PrivateKey
	// BaseURL is ProductionURL when empty. Tests point it at a fake.
	BaseURL string
	// HTTP is a client with a ten second timeout when nil.
	HTTP *http.Client
	Now  func() time.Time

	mu    sync.Mutex
	jwt   string
	jwtAt time.Time
}

// ParseKeyPEM reads the .p8 file Apple gives out (a PKCS#8 EC private key).
func ParseKeyPEM(data []byte) (*ecdsa.PrivateKey, error) {
	block, _ := pem.Decode(data)
	if block == nil {
		return nil, errors.New("devicecheck: key is not PEM")
	}
	k, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return nil, errors.New("devicecheck: key is not PKCS#8")
	}
	ec, ok := k.(*ecdsa.PrivateKey)
	if !ok || ec.Curve.Params().BitSize != 256 {
		return nil, errors.New("devicecheck: key is not a P-256 key")
	}
	return ec, nil
}

func (c *Client) now() time.Time {
	if c.Now != nil {
		return c.Now()
	}
	return time.Now()
}

func (c *Client) base() string {
	if c.BaseURL != "" {
		return strings.TrimRight(c.BaseURL, "/")
	}
	return ProductionURL
}

func (c *Client) http() *http.Client {
	if c.HTTP != nil {
		return c.HTTP
	}
	return &http.Client{Timeout: 10 * time.Second}
}

func b64(b []byte) string { return base64.RawURLEncoding.EncodeToString(b) }

// authToken is the ES256 JWT Apple wants in the Authorization header, reused for twenty minutes.
func (c *Client) authToken() (string, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	now := c.now()
	if c.jwt != "" && now.Sub(c.jwtAt) < jwtLife && !now.Before(c.jwtAt) {
		return c.jwt, nil
	}
	if c.Key == nil || c.TeamID == "" || c.KeyID == "" {
		return "", fmt.Errorf("%w: no key configured", ErrUnavailable)
	}
	head, _ := json.Marshal(map[string]string{"alg": "ES256", "kid": c.KeyID})
	claims, _ := json.Marshal(map[string]any{"iss": c.TeamID, "iat": now.Unix()})
	signing := b64(head) + "." + b64(claims)
	sum := sha256.Sum256([]byte(signing))
	r, s, err := ecdsa.Sign(rand.Reader, c.Key, sum[:])
	if err != nil {
		return "", fmt.Errorf("%w: %v", ErrUnavailable, err)
	}
	sig := make([]byte, 64)
	r.FillBytes(sig[:32])
	s.FillBytes(sig[32:])
	c.jwt, c.jwtAt = signing+"."+b64(sig), now
	return c.jwt, nil
}

func transactionID() string {
	raw := make([]byte, 16)
	rand.Read(raw)
	h := hex.EncodeToString(raw)
	return h[0:8] + "-" + h[8:12] + "-" + h[12:16] + "-" + h[16:20] + "-" + h[20:]
}

func (c *Client) post(ctx context.Context, path string, payload map[string]any) (int, []byte, error) {
	auth, err := c.authToken()
	if err != nil {
		return 0, nil, err
	}
	payload["transaction_id"] = transactionID()
	payload["timestamp"] = c.now().UnixMilli()
	data, _ := json.Marshal(payload)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.base()+path, bytes.NewReader(data))
	if err != nil {
		return 0, nil, fmt.Errorf("%w: request", ErrUnavailable)
	}
	req.Header.Set("Authorization", "Bearer "+auth)
	req.Header.Set("Content-Type", "application/json")
	resp, err := c.http().Do(req)
	if err != nil {
		// The error text of a transport failure can quote the URL; the token is in the body, never there.
		return 0, nil, fmt.Errorf("%w: no answer", ErrUnavailable)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, maxReply))
	return resp.StatusCode, body, nil
}

// classify turns a refusing status into the error the caller acts on.
func classify(status int) error {
	switch {
	case status == http.StatusBadRequest:
		return ErrBadToken
	case status == http.StatusUnauthorized || status == http.StatusForbidden:
		// Our own key or team id is wrong: the device did nothing.
		return fmt.Errorf("%w: Apple refused the server's key (%d)", ErrUnavailable, status)
	default:
		return fmt.Errorf("%w: status %d", ErrUnavailable, status)
	}
}

// Query reads the device's bits. A device whose bits were never set reads as 00 ("Failed to find bit
// state" in a plain-text 200 reply, which is Apple's way of saying so).
func (c *Client) Query(ctx context.Context, deviceToken string) (Bits, error) {
	status, body, err := c.post(ctx, pathQuery, map[string]any{"device_token": deviceToken})
	if err != nil {
		return Bits{}, err
	}
	if status != http.StatusOK {
		return Bits{}, classify(status)
	}
	var out struct {
		Bit0 *bool `json:"bit0"`
		Bit1 *bool `json:"bit1"`
	}
	if json.Unmarshal(body, &out) == nil && out.Bit0 != nil && out.Bit1 != nil {
		return Bits{Bit0: *out.Bit0, Bit1: *out.Bit1}, nil
	}
	if bytes.Contains(bytes.ToLower(body), []byte("failed to find bit state")) {
		return Bits{}, nil
	}
	return Bits{}, fmt.Errorf("%w: unreadable reply", ErrUnavailable)
}

// Update sets both bits.
func (c *Client) Update(ctx context.Context, deviceToken string, b Bits) error {
	status, _, err := c.post(ctx, pathUpdate, map[string]any{"device_token": deviceToken, "bit0": b.Bit0, "bit1": b.Bit1})
	if err != nil {
		return err
	}
	if status != http.StatusOK {
		return classify(status)
	}
	return nil
}
