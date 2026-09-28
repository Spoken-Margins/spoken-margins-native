// Package manifest defines the bridge manifest (seam I3) and the gate every
// manifest passes before the server publishes it.
//
// The manifest is one document, identical for every install. Each source
// carries its latest item links and titles and a fetch recipe. A recipe is
// data in a closed vocabulary (App Store Review Guideline 2.5.2): the app
// interprets it with code it already ships, and nothing in it is evaluated
// as a script, expression or template. The server never includes article
// bodies; the phone fetches each article from the publisher itself.
//
// The gate here is strict (unknown fields are an error) so nothing is
// published by accident. The app's decoder is lenient (it ignores unknown
// fields) so old builds keep working as the format grows.
package manifest

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"
	"unicode"
)

const (
	Schema        = "spokenmargins.bridge-manifest"
	Version       = 1
	RecipeVersion = 1

	MaxBytes          = 4 << 20
	MaxSources        = 5000
	MaxItemsPerSource = 50
	MaxSelectors      = 10
	MaxSelectorLength = 200
	MaxTitleLength    = 300
	MaxURLLength      = 2048
)

type Manifest struct {
	Schema      string   `json:"schema"`
	Version     int      `json:"version"`
	GeneratedAt string   `json:"generatedAt"`
	Sources     []Source `json:"sources"`
}

type Source struct {
	ID        string `json:"id"`
	Title     string `json:"title"`
	Homepage  string `json:"homepage"`
	Match     Match  `json:"match"`
	Status    string `json:"status"`
	CheckedAt string `json:"checkedAt"`
	// UpdatedAt changes when the item list changes: the per-source change
	// marker the app compares before diffing items.
	UpdatedAt string `json:"updatedAt"`
	Items     []Item `json:"items"`
	Recipe    Recipe `json:"recipe"`
}

// Match lets the phone decide locally whether a shared link belongs to a
// bridged source, so checking "can I follow this?" asks the server nothing.
type Match struct {
	Hosts        []string `json:"hosts"`
	PathPrefixes []string `json:"pathPrefixes,omitempty"`
}

// Item is a link and its metadata. There is deliberately no field that
// could hold article text.
type Item struct {
	URL         string `json:"url"`
	Title       string `json:"title"`
	PublishedAt string `json:"publishedAt,omitempty"`
	FirstSeenAt string `json:"firstSeenAt"`
}

type Recipe struct {
	Version int `json:"version"`
	// Extract is "readable" (the app's bundled readability extractor) or
	// "selectors" (the lists below, applied with querySelectorAll).
	Extract   string     `json:"extract"`
	Content   []string   `json:"content,omitempty"`
	Remove    []string   `json:"remove,omitempty"`
	Title     string     `json:"title,omitempty"`
	Published *Attribute `json:"published,omitempty"`
}

type Attribute struct {
	Selector  string `json:"selector"`
	Attribute string `json:"attribute,omitempty"`
}

var (
	idPattern        = regexp.MustCompile(`^[a-z0-9][a-z0-9-]{1,62}$`)
	hostPattern      = regexp.MustCompile(`^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$`)
	attributePattern = regexp.MustCompile(`^[a-z][a-z0-9-]{0,40}$`)
	// Our own domains can never be a source's host: a phone following that
	// source would then fetch from us, telling us who follows it.
	ownDomains = []string{"proximitytoprogress.com", "spokenmargins.com", "spokenmargins.app"}
	// Characters and fragments no CSS selector needs but an injection would.
	selectorForbidden = []string{"{", "}", ";", "<", "`", "\\", "/*", "*/", "url(", "expression(", "javascript:", "@import"}
)

// Problems collects every reason a manifest is refused.
type Problems []string

func (p Problems) Error() string { return "manifest refused:\n  " + strings.Join(p, "\n  ") }

func (p *Problems) add(format string, a ...any) { *p = append(*p, fmt.Sprintf(format, a...)) }

// Validate parses data strictly and applies every publish rule.
func Validate(data []byte) (*Manifest, error) {
	if len(data) > MaxBytes {
		return nil, Problems{fmt.Sprintf("manifest is %d bytes, limit %d", len(data), MaxBytes)}
	}
	var m Manifest
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&m); err != nil {
		return nil, Problems{"not a v1 manifest: " + err.Error()}
	}
	if dec.More() {
		return nil, Problems{"trailing data after manifest"}
	}
	var p Problems
	if m.Schema != Schema || m.Version != Version {
		p.add("schema %q version %d, want %q version %d", m.Schema, m.Version, Schema, Version)
	}
	checkTime(&p, "generatedAt", m.GeneratedAt, true)
	if len(m.Sources) > MaxSources {
		p.add("%d sources, limit %d", len(m.Sources), MaxSources)
	}
	seen := map[string]bool{}
	for i, s := range m.Sources {
		where := fmt.Sprintf("sources[%d] (%s)", i, s.ID)
		if !idPattern.MatchString(s.ID) {
			p.add("%s: id must be a lowercase slug", where)
		}
		if seen[s.ID] {
			p.add("%s: duplicate id", where)
		}
		seen[s.ID] = true
		checkText(&p, where+".title", s.Title, true)
		hosts := map[string]bool{}
		if len(s.Match.Hosts) == 0 || len(s.Match.Hosts) > 10 {
			p.add("%s: match.hosts needs 1 to 10 hosts", where)
		}
		for _, h := range s.Match.Hosts {
			if !hostPattern.MatchString(h) || net.ParseIP(h) != nil {
				p.add("%s: match host %q is not a lowercase DNS name", where, h)
			}
			for _, own := range ownDomains {
				if h == own || strings.HasSuffix(h, "."+own) {
					p.add("%s: match host %q is a Spoken Margins domain", where, h)
				}
			}
			hosts[h] = true
		}
		if len(s.Match.PathPrefixes) > 10 {
			p.add("%s: more than 10 path prefixes", where)
		}
		for _, pp := range s.Match.PathPrefixes {
			if !strings.HasPrefix(pp, "/") || len(pp) > 200 || strings.ContainsAny(pp, "?#*") {
				p.add("%s: path prefix %q must start with / and hold no query, fragment or wildcard", where, pp)
			}
		}
		checkURL(&p, where+".homepage", s.Homepage, hosts)
		switch s.Status {
		case "active", "paused", "retired":
		default:
			p.add("%s: status %q", where, s.Status)
		}
		checkTime(&p, where+".checkedAt", s.CheckedAt, true)
		checkTime(&p, where+".updatedAt", s.UpdatedAt, true)
		if len(s.Items) > MaxItemsPerSource {
			p.add("%s: %d items, limit %d", where, len(s.Items), MaxItemsPerSource)
		}
		for j, it := range s.Items {
			iw := fmt.Sprintf("%s.items[%d]", where, j)
			checkURL(&p, iw+".url", it.URL, hosts)
			checkText(&p, iw+".title", it.Title, true)
			checkTime(&p, iw+".publishedAt", it.PublishedAt, false)
			checkTime(&p, iw+".firstSeenAt", it.FirstSeenAt, true)
		}
		checkRecipe(&p, where+".recipe", s.Recipe)
	}
	if len(p) > 0 {
		return nil, p
	}
	return &m, nil
}

// Publish validates data and, only if it passes, replaces the manifest at
// path atomically. Anything that writes the public manifest (the M2 watcher,
// a deploy script, the CLI) must go through here, so the gate can't be
// skipped and a phone never sees a half-written file.
func Publish(path string, data []byte) (*Manifest, error) {
	m, err := Validate(data)
	if err != nil {
		return nil, err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return nil, err
	}
	tmp, err := os.CreateTemp(filepath.Dir(path), ".manifest-*")
	if err != nil {
		return nil, err
	}
	defer os.Remove(tmp.Name())
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		return nil, err
	}
	if err := tmp.Chmod(0o644); err != nil {
		tmp.Close()
		return nil, err
	}
	if err := tmp.Close(); err != nil {
		return nil, err
	}
	return m, os.Rename(tmp.Name(), path)
}

func checkTime(p *Problems, where, v string, required bool) {
	if v == "" {
		if required {
			p.add("%s is required", where)
		}
		return
	}
	if _, err := time.Parse(time.RFC3339, v); err != nil {
		p.add("%s: %q is not RFC 3339", where, v)
	}
}

func checkText(p *Problems, where, v string, required bool) {
	if required && strings.TrimSpace(v) == "" {
		p.add("%s is required", where)
	}
	if len(v) > MaxTitleLength {
		p.add("%s is %d bytes, limit %d", where, len(v), MaxTitleLength)
	}
	for _, r := range v {
		if unicode.IsControl(r) {
			p.add("%s contains a control character", where)
			return
		}
	}
}

// checkURL requires https on one of the source's own hosts, so a manifest
// can never make a phone fetch from somewhere the listener didn't choose.
func checkURL(p *Problems, where, v string, hosts map[string]bool) {
	if len(v) > MaxURLLength {
		p.add("%s is longer than %d bytes", where, MaxURLLength)
		return
	}
	u, err := url.Parse(v)
	if err != nil || u.Scheme != "https" || u.User != nil || u.Port() != "" || !hosts[u.Host] {
		p.add("%s: %q must be https on one of the source's match hosts, without credentials or port", where, v)
	}
}

func checkSelector(p *Problems, where, s string) {
	if s == "" || len(s) > MaxSelectorLength {
		p.add("%s: selector must be 1 to %d bytes", where, MaxSelectorLength)
		return
	}
	lower := strings.ToLower(s)
	for _, f := range selectorForbidden {
		if strings.Contains(lower, f) {
			p.add("%s: selector %q contains %q", where, s, f)
		}
	}
	for _, r := range s {
		if unicode.IsControl(r) {
			p.add("%s: selector contains a control character", where)
			return
		}
	}
}

func checkRecipe(p *Problems, where string, r Recipe) {
	if r.Version != RecipeVersion {
		p.add("%s: version %d, want %d", where, r.Version, RecipeVersion)
	}
	switch r.Extract {
	case "readable":
	case "selectors":
		if len(r.Content) == 0 {
			p.add("%s: extract \"selectors\" needs at least one content selector", where)
		}
	default:
		p.add("%s: extract %q, want \"readable\" or \"selectors\"", where, r.Extract)
	}
	if len(r.Content) > MaxSelectors || len(r.Remove) > MaxSelectors {
		p.add("%s: at most %d selectors per list", where, MaxSelectors)
	}
	for i, s := range r.Content {
		checkSelector(p, fmt.Sprintf("%s.content[%d]", where, i), s)
	}
	for i, s := range r.Remove {
		checkSelector(p, fmt.Sprintf("%s.remove[%d]", where, i), s)
	}
	if r.Title != "" {
		checkSelector(p, where+".title", r.Title)
	}
	if r.Published != nil {
		checkSelector(p, where+".published.selector", r.Published.Selector)
		if r.Published.Attribute != "" && !attributePattern.MatchString(r.Published.Attribute) {
			p.add("%s.published.attribute %q is not an attribute name", where, r.Published.Attribute)
		}
	}
}
