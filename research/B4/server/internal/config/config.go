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
	// owner switches it on, because Default leaves it out. Tokens gates
	// anonymous token issuance (#737), off by default for the same reason.
	// MapUploadToken, when on, makes map uploads carry an anonymous token
	// (#743). It is a switch of its own, not a field on maps, so an app that
	// knows nothing of it reads it as off and nothing else changes. Relay
	// gates the web app's feed and page relay (#2985), off by default.
	ServiceLinks          = "links"
	ServiceAttest         = "attest"
	ServiceBridge         = "bridge"
	ServiceMaps           = "maps"
	ServiceTokens         = "tokens"
	ServiceMapUploadToken = "mapUploadToken"
	ServiceRelay          = "relay"
)

// KnownServices are the switches the owner can flip.
var KnownServices = []string{ServiceLinks, ServiceAttest, ServiceBridge, ServiceMaps, ServiceTokens, ServiceMapUploadToken, ServiceRelay}

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
		Services: map[string]Service{ServiceAttest: {Enabled: true}, ServiceBridge: {Enabled: true}, ServiceLinks: {Enabled: false}},
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

// KeepMinimumBuild leaves a service's minimumBuild as it is.
const KeepMinimumBuild = -1

// Set flips one service and bumps the serial, writing atomically. Any
// minimumBuild the service already has is kept.
func Set(path, service string, enabled bool) (Document, error) {
	return SetWithMinimumBuild(path, service, enabled, KeepMinimumBuild)
}

// SetWithMinimumBuild is Set that also sets the service's minimumBuild, so
// one command (and one serial bump) can switch a feature on for new builds
// only. KeepMinimumBuild leaves it unchanged and 0 removes it. Any other
// negative number is refused: the app treats it as a malformed document
// and switches every feature off.
func SetWithMinimumBuild(path, service string, enabled bool, minimumBuild int) (Document, error) {
	if minimumBuild < KeepMinimumBuild {
		return Document{}, fmt.Errorf("config: minimumBuild %d must be 0 or more", minimumBuild)
	}
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
	if minimumBuild != KeepMinimumBuild {
		svc.MinimumBuild = minimumBuild
	}
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
		if m := d.Services[n].MinimumBuild; m > 0 {
			state += fmt.Sprintf("(build>=%d)", m)
		}
		out += fmt.Sprintf(" %s=%s", n, state)
	}
	return out
}
