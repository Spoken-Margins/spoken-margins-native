// Package client is a test client that behaves like the app will: fetch
// the public config, attest a key once, then sign each request. The app's
// Swift client (B4 M3) should follow the same sequence; ClientData in
// package api is the exact byte format both sides sign.
package client

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"time"

	"spokenmargins.dev/bridge/internal/api"
	"spokenmargins.dev/bridge/internal/appattest/fakeattest"
)

type Client struct {
	Base        string
	HTTP        *http.Client
	CA          *fakeattest.CA
	Device      *fakeattest.Device
	Development bool
	Now         func() time.Time
}

type Response struct {
	Status int
	Body   map[string]any
}

func (r Response) Code() string {
	if s, ok := r.Body["error"].(string); ok {
		return s
	}
	return ""
}

func (r Response) String() string {
	b, _ := json.Marshal(r.Body)
	return fmt.Sprintf("HTTP %d %s", r.Status, b)
}

func (c *Client) http() *http.Client {
	if c.HTTP != nil {
		return c.HTTP
	}
	return http.DefaultClient
}

func (c *Client) do(req *http.Request) (Response, error) {
	resp, err := c.http().Do(req)
	if err != nil {
		return Response{}, err
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return Response{}, err
	}
	out := Response{Status: resp.StatusCode}
	if len(data) > 0 {
		if err := json.Unmarshal(data, &out.Body); err != nil {
			return out, fmt.Errorf("non-JSON response: %q", data)
		}
	}
	return out, nil
}

func (c *Client) Get(path string) (Response, error) {
	req, err := http.NewRequest(http.MethodGet, c.Base+path, nil)
	if err != nil {
		return Response{}, err
	}
	return c.do(req)
}

func (c *Client) postJSON(path string, v any) (Response, error) {
	body, _ := json.Marshal(v)
	req, err := http.NewRequest(http.MethodPost, c.Base+path, bytes.NewReader(body))
	if err != nil {
		return Response{}, err
	}
	req.Header.Set("Content-Type", "application/json")
	return c.do(req)
}

// Register fetches a challenge and attests the device key.
func (c *Client) Register() (Response, error) {
	ch, err := c.postJSON("/api/v1/attest/challenge", struct{}{})
	if err != nil || ch.Status != http.StatusOK {
		return ch, err
	}
	b64, _ := ch.Body["challenge"].(string)
	challenge, err := base64.StdEncoding.DecodeString(b64)
	if err != nil {
		return ch, err
	}
	att, err := c.CA.Attest(c.Device, challenge, fakeattest.Options{Development: c.Development})
	if err != nil {
		return Response{}, err
	}
	return c.postJSON("/api/v1/attest/register", map[string]string{
		"keyId":       base64.StdEncoding.EncodeToString(c.Device.KeyID),
		"challenge":   b64,
		"attestation": base64.StdEncoding.EncodeToString(att),
	})
}

// Signed builds an attested POST without sending it, so tests can replay it.
func (c *Client) Signed(path string, body []byte) (*http.Request, error) {
	now := time.Now
	if c.Now != nil {
		now = c.Now
	}
	unix := now().Unix()
	assertion, err := c.Device.Assert(api.ClientData(http.MethodPost, path, unix, body))
	if err != nil {
		return nil, err
	}
	req, err := http.NewRequest(http.MethodPost, c.Base+path, bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set(api.HeaderKeyID, base64.StdEncoding.EncodeToString(c.Device.KeyID))
	req.Header.Set(api.HeaderAssertion, base64.StdEncoding.EncodeToString(assertion))
	req.Header.Set(api.HeaderTime, strconv.FormatInt(unix, 10))
	return req, nil
}

func (c *Client) Send(req *http.Request) (Response, error) { return c.do(req) }

// Attested signs and sends one request.
func (c *Client) Attested(path string, body []byte) (Response, error) {
	req, err := c.Signed(path, body)
	if err != nil {
		return Response{}, err
	}
	return c.do(req)
}
