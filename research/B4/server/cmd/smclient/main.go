// smclient is a test client that does what the app will do, using a fake
// Apple CA (see smserver make-test-ca). It keeps its install key in a file
// so repeated runs are the same install, which is how the demo shows a
// block taking effect.
//
//	smclient -base http://127.0.0.1:8795 -ca DIR -device FILE
package main

import (
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"errors"
	"flag"
	"fmt"
	"os"

	"spokenmargins.dev/bridge/internal/api"
	"spokenmargins.dev/bridge/internal/appattest/fakeattest"
	"spokenmargins.dev/bridge/internal/client"
	"spokenmargins.dev/bridge/internal/store"
)

type savedDevice struct {
	Key     string `json:"key"`
	Counter uint32 `json:"counter"`
}

func loadOrCreate(path, appID string) (*fakeattest.Device, bool, error) {
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		d, err := fakeattest.NewDevice(appID)
		return d, true, err
	}
	if err != nil {
		return nil, false, err
	}
	var s savedDevice
	if err := json.Unmarshal(data, &s); err != nil {
		return nil, false, err
	}
	b, _ := pem.Decode([]byte(s.Key))
	if b == nil {
		return nil, false, errors.New("device file has no key")
	}
	k, err := x509.ParseECPrivateKey(b.Bytes)
	if err != nil {
		return nil, false, err
	}
	d := &fakeattest.Device{AppID: appID, Key: k, KeyID: fakeattest.KeyIDFor(&k.PublicKey), Counter: s.Counter}
	return d, false, nil
}

func save(path string, d *fakeattest.Device) error {
	der, err := x509.MarshalECPrivateKey(d.Key)
	if err != nil {
		return err
	}
	data, _ := json.Marshal(savedDevice{
		Key:     string(pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: der})),
		Counter: d.Counter,
	})
	return os.WriteFile(path, data, 0o600)
}

func main() {
	base := flag.String("base", "http://127.0.0.1:8795", "server base URL")
	caDir := flag.String("ca", "", "directory from smserver make-test-ca")
	devicePath := flag.String("device", "device.json", "file holding this test install's key")
	appID := flag.String("app-id", "J8SWC6J3VY.com.spokenmargins.native", "TeamID.bundleID")
	dev := flag.Bool("development", false, "attest as a development-environment key")
	flag.Parse()

	ca, err := fakeattest.LoadCA(*caDir)
	check(err)
	d, isNew, err := loadOrCreate(*devicePath, *appID)
	check(err)
	c := &client.Client{Base: *base, CA: ca, Device: d, Development: *dev}

	show := func(step string, r client.Response, err error) client.Response {
		check(err)
		fmt.Printf("%-24s %s\n", step, r)
		return r
	}
	ping := func() client.Response {
		r, err := c.Attested("/api/v1/ping", []byte("{}"))
		return show("POST ping (attested)", r, err)
	}
	register := func() {
		r, err := c.Register()
		show("POST attest/register", r, err)
	}
	r, err := c.Get("/api/v1/health")
	show("GET health", r, err)
	r, err = c.Get(api.PathConfig)
	show("GET config", r, err)
	if isNew {
		register()
	}
	if ping().Code() == "unknown_key" {
		// The server lost or purged our record: attest a fresh key, as the app will.
		c.Device, err = fakeattest.NewDevice(*appID)
		check(err)
		register()
		ping()
	}
	check(save(*devicePath, c.Device))
	fmt.Printf("install tag: %s\n", store.Tag(c.Device.KeyID))
}

func check(err error) {
	if err != nil {
		fmt.Fprintln(os.Stderr, "smclient:", err)
		os.Exit(1)
	}
}
