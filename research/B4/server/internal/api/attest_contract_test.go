package api_test

import (
	"bytes"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"reflect"
	"strconv"
	"testing"
	"time"

	"spokenmargins.dev/bridge/internal/api"
	"spokenmargins.dev/bridge/internal/appattest/fakeattest"
)

// The contract between the app's attested requests and this middleware (#4134, Done when 5). The Swift tests talk
// to hand-written fakes, which can agree with the app and disagree with the server. Here each side checks itself
// against the same committed files in Contracts/fixtures/share-link-attest/:
//
//   - requests/: what the app sends, written by the Swift test (ShareLinkAttestContractTests). This test recomputes
//     the hash of the bytes the app signed and drives the real attested middleware with the app's own headers.
//   - responses/: what this middleware answers, written here and read by the Swift test through the app's mapping.
//
// Files are rewritten only when SM_REGENERATE_ATTEST_FIXTURES=1 is set, so a normal run never writes to the tree.

const attestContractDir = "../../../../../Contracts/fixtures/share-link-attest"

type recordedRequest struct {
	Method           string            `json:"method"`
	Path             string            `json:"path"`
	Time             int64             `json:"time"`
	BodyBase64       string            `json:"bodyBase64"`
	Headers          map[string]string `json:"headers"`
	AssertionHeader  string            `json:"assertionHeader"`
	ClientDataSHA256 string            `json:"clientDataSHA256"`
}

type recordedResponse struct {
	Status int            `json:"status"`
	Body   map[string]any `json:"body"`
}

func TestTheAppsAttestedRequestPassesTheRealMiddleware(t *testing.T) {
	data, err := os.ReadFile(filepath.Join(attestContractDir, "requests", "sender-check.json"))
	if err != nil {
		t.Fatal(err)
	}
	var fx recordedRequest
	if err := json.Unmarshal(data, &fx); err != nil {
		t.Fatal(err)
	}
	body, err := base64.StdEncoding.DecodeString(fx.BodyBase64)
	if err != nil {
		t.Fatal(err)
	}

	// The bytes the app signed are the bytes this server verifies.
	sum := sha256.Sum256(api.ClientData(fx.Method, fx.Path, fx.Time, body))
	if got := hex.EncodeToString(sum[:]); got != fx.ClientDataSHA256 {
		t.Fatalf("ClientData hash %s, the app signed %s", got, fx.ClientDataSHA256)
	}
	if fx.Path != api.PathLinkSender || fx.Method != http.MethodPost {
		t.Fatalf("the app's sender check is %s %s, the server serves POST %s", fx.Method, fx.Path, api.PathLinkSender)
	}
	if fx.AssertionHeader != api.HeaderAssertion {
		t.Fatalf("the app sends its assertion in %q, the server reads %q", fx.AssertionHeader, api.HeaderAssertion)
	}
	for _, name := range []string{api.HeaderKeyID, api.HeaderTime} {
		if _, ok := fx.Headers[name]; !ok {
			t.Fatalf("the app sends no %s header: %v", name, fx.Headers)
		}
	}
	if fx.Headers[api.HeaderTime] != strconv.FormatInt(fx.Time, 10) {
		t.Fatalf("the time header %q is not the signed time %d", fx.Headers[api.HeaderTime], fx.Time)
	}

	// The real middleware, with the server's clock at the app's recorded time. The install registered first, at the
	// real time, because a fake device's certificate is only valid from now.
	r := newSenderRig(t)
	r.now = time.Unix(fx.Time, 0).UTC()

	// send posts the app's request with the app's own headers. The key id and assertion are the fake device's, since
	// the app's placeholder assertion is not a signature; signedAt is the time the device signs over.
	send := func(d *fakeattest.Device, header int64, signedAt int64, signedPath string, withAssertion bool) recordedResponse {
		t.Helper()
		req, err := http.NewRequest(fx.Method, r.http.URL+fx.Path, bytes.NewReader(body))
		if err != nil {
			t.Fatal(err)
		}
		for name, value := range fx.Headers {
			req.Header.Set(name, value)
		}
		req.Header.Set(api.HeaderKeyID, base64.StdEncoding.EncodeToString(d.KeyID))
		req.Header.Set(api.HeaderTime, strconv.FormatInt(header, 10))
		if withAssertion {
			assertion, err := d.Assert(api.ClientData(fx.Method, signedPath, signedAt, body))
			if err != nil {
				t.Fatal(err)
			}
			req.Header.Set(fx.AssertionHeader, base64.StdEncoding.EncodeToString(assertion))
		}
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		raw, _ := io.ReadAll(resp.Body)
		out := recordedResponse{Status: resp.StatusCode}
		if err := json.Unmarshal(raw, &out.Body); err != nil {
			t.Fatalf("non-JSON answer %d %q", resp.StatusCode, raw)
		}
		return out
	}

	stranger, err := fakeattest.NewDevice(appID)
	if err != nil {
		t.Fatal(err)
	}
	cases := []struct {
		name string
		got  recordedResponse
	}{
		{"ok", send(r.c.Device, fx.Time, fx.Time, fx.Path, true)},
		{"clock_skew", send(r.c.Device, fx.Time-600, fx.Time-600, fx.Path, true)},
		{"unknown_key", send(stranger, fx.Time, fx.Time, fx.Path, true)},
		{"invalid_assertion", send(r.c.Device, fx.Time, fx.Time, "/api/v1/ping", true)},
		{"missing_assertion", send(r.c.Device, fx.Time, fx.Time, fx.Path, false)},
	}
	regenerate := os.Getenv("SM_REGENERATE_ATTEST_FIXTURES") == "1"
	for _, c := range cases {
		got := c.got
		if c.name == "ok" {
			// The permit and its expiry are random per run.
			if got.Status != 200 || got.Body["sharingAllowed"] != true || got.Body["permit"] == nil {
				t.Fatalf("ok: %+v", got)
			}
			got.Body["permit"] = "<permit>"
			if _, ok := got.Body["permitExpiresAt"]; ok {
				got.Body["permitExpiresAt"] = "<permitExpiresAt>"
			}
		}
		file := filepath.Join(attestContractDir, "responses", c.name+".json")
		if regenerate {
			var out bytes.Buffer
			enc := json.NewEncoder(&out)
			enc.SetEscapeHTML(false)
			enc.SetIndent("", "  ")
			if err := enc.Encode(got); err != nil {
				t.Fatal(err)
			}
			if err := os.MkdirAll(filepath.Dir(file), 0o755); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(file, out.Bytes(), 0o644); err != nil {
				t.Fatal(err)
			}
		}
		data, err := os.ReadFile(file)
		if err != nil {
			t.Fatal(err)
		}
		var want recordedResponse
		if err := json.Unmarshal(data, &want); err != nil {
			t.Fatal(err)
		}
		// Round-trip what we got through JSON so numbers compare as the file's do.
		roundTrip, _ := json.Marshal(got)
		var gotNormal recordedResponse
		json.Unmarshal(roundTrip, &gotNormal)
		if !reflect.DeepEqual(gotNormal, want) {
			t.Errorf("%s: the middleware answered %+v, the app's mapping is tested against %+v (SM_REGENERATE_ATTEST_FIXTURES=1 rewrites it)", c.name, gotNormal, want)
		}
	}
}
