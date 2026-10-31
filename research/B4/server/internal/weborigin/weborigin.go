// Package weborigin reads the owner's lists of web app origins that may read
// a server response from another origin (CORS). An origin is matched as an
// exact string, the way a browser sends it in the Origin header, so a list
// entry has to be written in that same form or it would never match.
package weborigin

import (
	"fmt"
	"net/url"
	"strings"
)

// Valid reports whether s is an origin a list may hold: https://host[:port],
// or http on localhost for a dev server. It is written as a browser writes
// it: lower case, ASCII (an international name in its xn-- form), and no
// default port, path, query, credentials or wildcard. "null" is refused.
func Valid(s string) bool {
	// Printable ASCII, lower case, no wildcard: checked on the raw string,
	// before url.Parse can normalise anything away.
	if s == "" || s != strings.ToLower(s) || strings.Contains(s, "*") {
		return false
	}
	for _, c := range s {
		if c < 0x21 || c > 0x7e {
			return false
		}
	}
	u, err := url.Parse(s)
	if err != nil || u.User != nil || u.Opaque != "" || u.Path != "" || u.RawQuery != "" || u.ForceQuery || u.Fragment != "" {
		return false
	}
	// Rebuilding it must give back exactly what was written, so nothing
	// was dropped or reinterpreted on the way.
	host, port := u.Hostname(), u.Port()
	if host == "" || u.Scheme+"://"+u.Host != s || strings.HasSuffix(u.Host, ":") {
		return false
	}
	switch u.Scheme {
	case "https":
		return port != "443"
	case "http":
		return (host == "localhost" || host == "127.0.0.1") && port != "80"
	}
	return false
}

// Parse reads a comma-separated list. A bad entry is an error rather than
// skipped, so a typo can't quietly leave a route open to fewer (or other)
// origins than the owner meant. An empty string is an empty list.
func Parse(list string) ([]string, error) {
	if strings.TrimSpace(list) == "" {
		return nil, nil
	}
	var out []string
	for _, o := range strings.Split(list, ",") {
		o = strings.TrimSpace(o)
		if !Valid(o) {
			return nil, fmt.Errorf("%q is not an origin like https://web.example.com", o)
		}
		out = append(out, o)
	}
	return out, nil
}

// Allowed reports whether origin, as the request sent it, is on the list.
// A missing Origin is never allowed.
func Allowed(list []string, origin string) bool {
	if origin == "" {
		return false
	}
	for _, o := range list {
		if o == origin {
			return true
		}
	}
	return false
}
