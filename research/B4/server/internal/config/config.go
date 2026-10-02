// Package config reads and writes the kill-switch document. It is a static
// JSON file in the public web root, so the app can read it even when the
// service process is down, and the service reads the same file to refuse
// requests for a switched-off feature. One file, one truth.
package config

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"sort"
	"sync"
	"time"

	"spokenmargins.dev/bridge/internal/publicfs"
)

const (
	Schema  = "spokenmargins.server-config"
	Version = 1

	// Attest gates every attested call: challenge, register and any feature
	// endpoint. Bridge gates use of the bridge manifest in the app. Maps
	// gates listening-map uploads and fetches (#551); it is off until the
	// owner switches it on, because Default leaves it out.
	ServiceAttest = "attest"
	ServiceBridge = "bridge"
	ServiceMaps   = "maps"
)

// KnownServices are the switches the owner can flip.
var KnownServices = []string{ServiceAttest, ServiceBridge, ServiceMaps}

type Service struct {
	Enabled bool `json:"enabled"`
	// MinimumBuild switches the feature off for app builds below this
	// number, for when one build misbehaves.
	MinimumBuild int `json:"minimumBuild,omitempty"`
}

type Document struct {
	Schema  string `json:"schema"`
	Version int    `json:"version"`
	// Serial only goes up. The app ignores a document whose serial is lower
	// than the one it has cached, so a stale cache can't switch a feature
	// back on.
	Serial            int64              `json:"serial"`
	CheckAfterSeconds int                `json:"checkAfterSeconds"`
	Services          map[string]Service `json:"services"`
}

func Default() Document {
	return Document{
		Schema: Schema, Version: Version, Serial: 1, CheckAfterSeconds: 6 * 3600,
		Services: map[string]Service{ServiceAttest: {Enabled: true}, ServiceBridge: {Enabled: true}},
	}
}

func Parse(data []byte) (Document, error) {
	var d Document
	if err := json.Unmarshal(data, &d); err != nil {
		return d, err
	}
	if d.Schema != Schema || d.Version != Version {
		return d, fmt.Errorf("config: unexpected schema %q version %d", d.Schema, d.Version)
	}
	return d, nil
}

// Enabled reports whether a service is on. A missing service is off, and so
// is everything if the document can't be read: the server fails closed.
func (d Document) Enabled(service string) bool { return d.Services[service].Enabled }

// Reader caches the document and re-reads it when the file changes.
type Reader struct {
	Path  string
	mu    sync.Mutex
	mtime time.Time
	size  int64
	doc   Document
	err   error
}

func (r *Reader) Current() (Document, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	info, err := os.Stat(r.Path)
	if err != nil {
		return Document{}, err
	}
	if !info.ModTime().Equal(r.mtime) || info.Size() != r.size {
		data, err := os.ReadFile(r.Path)
		if err != nil {
			return Document{}, err
		}
		r.doc, r.err = Parse(data)
		r.mtime, r.size = info.ModTime(), info.Size()
	}
	return r.doc, r.err
}

// Set flips one service and bumps the serial, writing atomically.
func Set(path, service string, enabled bool) (Document, error) {
	known := false
	for _, s := range KnownServices {
		known = known || s == service
	}
	if !known {
		return Document{}, fmt.Errorf("config: unknown service %q (known: %v)", service, KnownServices)
	}
	d := Default()
	if data, err := os.ReadFile(path); err == nil {
		if d, err = Parse(data); err != nil {
			return d, err
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return d, err
	}
	svc := d.Services[service]
	svc.Enabled = enabled
	if d.Services == nil {
		d.Services = map[string]Service{}
	}
	d.Services[service] = svc
	d.Serial++
	return d, Write(path, d)
}

func Write(path string, d Document) error {
	data, err := json.MarshalIndent(d, "", "  ")
	if err != nil {
		return err
	}
	// Caddy serves this file as another user, so it must be 0644 whatever
	// the caller's umask (publicfs).
	return publicfs.WriteFile(path, append(data, '\n'))
}

// Summary is a one-line human description for the CLI.
func (d Document) Summary() string {
	names := make([]string, 0, len(d.Services))
	for n := range d.Services {
		names = append(names, n)
	}
	sort.Strings(names)
	out := fmt.Sprintf("serial %d:", d.Serial)
	for _, n := range names {
		state := "off"
		if d.Services[n].Enabled {
			state = "on"
		}
		out += fmt.Sprintf(" %s=%s", n, state)
	}
	return out
}
