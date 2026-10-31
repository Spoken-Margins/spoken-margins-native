// Package relay fetches one public feed or web page for the web app, which a
// browser can't read directly when the publisher sends no CORS header
// (#2985). It keeps nothing.
//
// Rules this file enforces, not just documents:
//   - Nothing is logged here, and the URL is never written anywhere. The
//     request log names the route only (api.logRoute), never the query.
//   - No cache past the request, no cookie jar, and no header from the
//     listener's request reaches the publisher: the outgoing request carries
//     only a fixed User-Agent and Accept. Only the content type comes back.
//   - SSRF: http and https only, ports 80 and 443 only, and every address a
//     name resolves to must be public. The dialer resolves the name itself,
//     checks every answer, and connects to the address it checked, so a
//     second DNS answer can't swap in a private one (DNS rebinding). The
//     socket's Control hook checks the address again just before connect.
//     Every redirect hop goes through the same dialer, and there are at most
//     five.
//   - Abuse: 10 s for the whole fetch, 5 MB of body, feed and HTML content
//     types only, and a cap on fetches in flight. The per-client hourly
//     limit is the API's (api.relayWindow).
package relay

import (
	"context"
	"errors"
	"fmt"
	"io"
	"mime"
	"net"
	"net/http"
	"net/netip"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

const (
	DefaultTimeout       = 10 * time.Second
	DefaultMaxBytes      = 5 << 20
	DefaultMaxRedirects  = 5
	DefaultMaxConcurrent = 4
	// MaxURLLength bounds the query parameter before anything parses it.
	MaxURLLength = 2048

	// UserAgent is sent on every fetch. A request that arrives with it is
	// the relay calling itself, and Admit refuses it.
	UserAgent = "SpokenMarginsRelay/1 (+https://github.com/Spoken-Margins/spoken-margins-native)"
	accept    = "application/rss+xml, application/atom+xml, application/feed+json, application/xml;q=0.9, text/xml;q=0.9, text/html;q=0.8, application/xhtml+xml;q=0.8"
)

// allowedTypes are the media types the relay passes back: feeds and pages.
// JSON in general is left out on purpose, so the relay can't be pointed at
// arbitrary APIs; JSON Feed has its own type.
var allowedTypes = map[string]bool{
	"application/rss+xml":   true,
	"application/atom+xml":  true,
	"application/feed+json": true,
	"application/xml":       true,
	"text/xml":              true,
	"text/html":             true,
	"application/xhtml+xml": true,
}

// Error is a refusal with the HTTP status and the fixed code the API
// answers with. It never carries the URL.
type Error struct {
	Status int
	Code   string
}

func (e *Error) Error() string { return fmt.Sprintf("relay: %s (%d)", e.Code, e.Status) }

var (
	ErrBadURL           = &Error{http.StatusBadRequest, "bad_url"}
	ErrPortRefused      = &Error{http.StatusForbidden, "port_refused"}
	ErrAddressRefused   = &Error{http.StatusForbidden, "address_refused"}
	ErrOriginRefused    = &Error{http.StatusForbidden, "origin_refused"}
	ErrLoopRefused      = &Error{http.StatusForbidden, "loop_refused"}
	ErrTooManyRedirects = &Error{http.StatusBadGateway, "too_many_redirects"}
	ErrTypeRefused      = &Error{http.StatusBadGateway, "type_refused"}
	ErrTooLarge         = &Error{http.StatusBadGateway, "too_large"}
	ErrUpstreamStatus   = &Error{http.StatusBadGateway, "upstream_status"}
	ErrUpstream         = &Error{http.StatusBadGateway, "upstream_unreachable"}
	ErrTimeout          = &Error{http.StatusGatewayTimeout, "timeout"}
	ErrBusy             = &Error{http.StatusServiceUnavailable, "busy"}
)

// Relay is safe for concurrent use. The zero value with Origins set uses the
// defaults above; the other fields exist for tests and are left alone in
// production.
type Relay struct {
	// Origins are the web app origins that may read relayed responses
	// (Access-Control-Allow-Origin). A request with any other Origin header
	// is refused before anything is fetched.
	Origins []string

	Timeout       time.Duration
	MaxBytes      int64
	MaxRedirects  int
	MaxConcurrent int

	// Ports overrides the allowed ports (80 and 443). Tests only.
	Ports []int
	// Allowed overrides PublicAddr. Tests only, to reach an httptest server
	// on loopback; production never sets it.
	Allowed func(netip.Addr) bool
	// Lookup overrides DNS resolution. Tests only.
	Lookup func(ctx context.Context, host string) ([]netip.Addr, error)

	once   sync.Once
	client *http.Client
	slots  chan struct{}
}

func (r *Relay) init() {
	r.once.Do(func() {
		if r.Timeout == 0 {
			r.Timeout = DefaultTimeout
		}
		if r.MaxBytes == 0 {
			r.MaxBytes = DefaultMaxBytes
		}
		if r.MaxRedirects == 0 {
			r.MaxRedirects = DefaultMaxRedirects
		}
		if r.MaxConcurrent == 0 {
			r.MaxConcurrent = DefaultMaxConcurrent
		}
		if r.Allowed == nil {
			r.Allowed = PublicAddr
		}
		if r.Lookup == nil {
			r.Lookup = func(ctx context.Context, host string) ([]netip.Addr, error) {
				return net.DefaultResolver.LookupNetIP(ctx, "ip", host)
			}
		}
		r.slots = make(chan struct{}, r.MaxConcurrent)
		transport := &http.Transport{
			// Never an environment proxy: it would dial for us, past the checks.
			Proxy:               nil,
			DialContext:         r.dial,
			ForceAttemptHTTP2:   true,
			TLSHandshakeTimeout: r.Timeout,
			// A fresh, checked connection for every hop; nothing is pooled
			// between listeners' fetches.
			DisableKeepAlives:      true,
			MaxResponseHeaderBytes: 64 << 10,
		}
		r.client = &http.Client{
			Transport: transport,
			Timeout:   r.Timeout,
			// No Jar: cookies set by one hop are not sent to the next.
			CheckRedirect: func(req *http.Request, via []*http.Request) error {
				if len(via) > r.MaxRedirects {
					return ErrTooManyRedirects
				}
				if _, err := r.checkURL(req.URL); err != nil {
					return err
				}
				// Go sets Referer to the previous hop's URL (except on an
				// https→http hop). That URL may hold a private feed's token,
				// so the next host never sees it. With no Jar and fixed
				// request headers, this leaves the hop carrying only what
				// the first request did.
				req.Header.Del("Referer")
				return nil
			},
		}
	})
}

// ValidOrigin reports whether s is a browser origin the relay may be
// configured with: https://host[:port], or http on localhost for a dev
// server. No path, query, credentials or wildcard.
func ValidOrigin(s string) bool {
	u, err := url.Parse(s)
	if err != nil || u.User != nil || u.Path != "" || u.RawQuery != "" || u.Fragment != "" || u.Hostname() == "" || strings.Contains(s, "*") {
		return false
	}
	if u.Scheme+"://"+u.Host != s {
		return false
	}
	switch u.Scheme {
	case "https":
		return true
	case "http":
		return u.Hostname() == "localhost" || u.Hostname() == "127.0.0.1"
	}
	return false
}

// AllowedOrigin reports whether a browser origin may read relayed responses.
// A missing Origin is never allowed.
func (r *Relay) AllowedOrigin(origin string) bool {
	if origin == "" {
		return false
	}
	for _, o := range r.Origins {
		if o == origin {
			return true
		}
	}
	return false
}

func (r *Relay) portAllowed(port int) bool {
	if r.Ports == nil {
		return port == 80 || port == 443
	}
	for _, p := range r.Ports {
		if p == port {
			return true
		}
	}
	return false
}

// Parse checks a URL from the query before any network use: scheme, no
// credentials, port, and the host's spelling. An IP literal is checked
// against the address rules here; a name is checked when it is dialed.
func (r *Relay) Parse(raw string) (*url.URL, error) {
	r.init()
	if raw == "" || len(raw) > MaxURLLength {
		return nil, ErrBadURL
	}
	u, err := url.Parse(raw)
	if err != nil {
		return nil, ErrBadURL
	}
	return r.checkURL(u)
}

func (r *Relay) checkURL(u *url.URL) (*url.URL, error) {
	if u.Scheme != "http" && u.Scheme != "https" {
		return nil, ErrBadURL
	}
	if u.User != nil || u.Opaque != "" || u.Hostname() == "" {
		return nil, ErrBadURL
	}
	port := 80
	if u.Scheme == "https" {
		port = 443
	}
	if p := u.Port(); p != "" {
		n, err := strconv.Atoi(p)
		if err != nil || n <= 0 || n > 65535 {
			return nil, ErrBadURL
		}
		port = n
	}
	if !r.portAllowed(port) {
		return nil, ErrPortRefused
	}
	host := u.Hostname()
	if ip, err := netip.ParseAddr(host); err == nil {
		if ip.Zone() != "" || !r.Allowed(ip.Unmap()) {
			return nil, ErrAddressRefused
		}
		return u, nil
	}
	if numericLooking(host) {
		// 2130706433, 0x7f000001, 127.1, 0177.0.0.1: some resolvers read
		// these as IP addresses. A real host name never ends in a number,
		// so refuse them rather than guess how a resolver will read them.
		return nil, ErrBadURL
	}
	return u, nil
}

// numericLooking reports whether a host that isn't a canonical IP literal
// would still be read as an address by inet_aton-style parsers: its last
// label is all digits, or any label is hex (0x…).
func numericLooking(host string) bool {
	host = strings.TrimSuffix(host, ".")
	labels := strings.Split(host, ".")
	last := labels[len(labels)-1]
	if last == "" {
		return true
	}
	allDigits := true
	for _, c := range last {
		if c < '0' || c > '9' {
			allDigits = false
			break
		}
	}
	if allDigits {
		return true
	}
	for _, l := range labels {
		if len(l) > 2 && (l[:2] == "0x" || l[:2] == "0X") {
			if _, err := strconv.ParseUint(l[2:], 16, 64); err == nil {
				return true
			}
		}
	}
	return false
}

// refusedPrefixes are special-purpose ranges netip's predicates don't cover:
// shared address space (often a VPN such as Tailscale on the server),
// benchmarking, reserved, documentation, and IPv6 ranges that embed an IPv4
// address and could reach a private one through a translator. The source is
// IANA's two special-purpose address registries: every block not marked
// globally reachable, and the deprecated ones. A feed or page never lives in
// any of them, so the few anycast services inside 2001::/23 are refused too.
var refusedPrefixes = func() []netip.Prefix {
	var out []netip.Prefix
	for _, s := range []string{
		"0.0.0.0/8",       // "this network"
		"100.64.0.0/10",   // shared address space, carrier NAT, Tailscale
		"192.0.0.0/24",    // IETF protocol assignments
		"192.0.2.0/24",    // documentation
		"192.88.99.0/24",  // 6to4 relay anycast (deprecated)
		"198.18.0.0/15",   // benchmarking
		"198.51.100.0/24", // documentation
		"203.0.113.0/24",  // documentation
		"240.0.0.0/4",     // reserved, and 255.255.255.255
		"::/96",           // IPv4-compatible (deprecated)
		"::ffff:0:0:0/96", // SIIT, IPv4-translated
		"64:ff9b::/96",    // NAT64
		"64:ff9b:1::/48",  // local NAT64
		"100::/64",        // discard
		"100:0:0:1::/64",  // dummy prefix
		"2001::/23",       // IETF protocol assignments: Teredo, benchmarking, ORCHID, ORCHIDv2, drone remote ID
		"2001:db8::/32",   // documentation
		"2002::/16",       // 6to4
		"3fff::/20",       // documentation
		"5f00::/16",       // segment routing (SRv6) SIDs
		"fec0::/10",       // site-local (deprecated)
	} {
		out = append(out, netip.MustParsePrefix(s))
	}
	return out
}()

// PublicAddr reports whether the relay may connect to an address: not
// unspecified, loopback, private, link-local, multicast or special-purpose,
// for IPv4 and IPv6. IPv4-mapped IPv6 addresses are judged as IPv4.
func PublicAddr(a netip.Addr) bool {
	a = a.Unmap()
	if !a.IsValid() || a.Zone() != "" ||
		a.IsUnspecified() || a.IsLoopback() || a.IsPrivate() ||
		a.IsLinkLocalUnicast() || a.IsLinkLocalMulticast() ||
		a.IsInterfaceLocalMulticast() || a.IsMulticast() {
		return false
	}
	for _, p := range refusedPrefixes {
		if p.Contains(a) {
			return false
		}
	}
	return a.IsGlobalUnicast()
}

// dial resolves, checks every answer, and connects to a checked address.
func (r *Relay) dial(ctx context.Context, network, addr string) (net.Conn, error) {
	host, portStr, err := net.SplitHostPort(addr)
	if err != nil {
		return nil, ErrBadURL
	}
	port, err := strconv.Atoi(portStr)
	if err != nil || !r.portAllowed(port) {
		return nil, ErrPortRefused
	}
	var addrs []netip.Addr
	if ip, err := netip.ParseAddr(host); err == nil {
		addrs = []netip.Addr{ip}
	} else {
		if addrs, err = r.Lookup(ctx, host); err != nil || len(addrs) == 0 {
			return nil, ErrUpstream
		}
	}
	// Refuse the name if any answer is private, so a mixed answer can't be
	// used to reach the private one on a retry.
	for i, a := range addrs {
		addrs[i] = a.Unmap()
		if a.Zone() != "" || !r.Allowed(addrs[i]) {
			return nil, ErrAddressRefused
		}
	}
	d := &net.Dialer{
		Control: func(_, address string, _ syscall.RawConn) error {
			ap, err := netip.ParseAddrPort(address)
			if err != nil || !r.Allowed(ap.Addr().Unmap()) || !r.portAllowed(int(ap.Port())) {
				return ErrAddressRefused
			}
			return nil
		},
	}
	var lastErr error = ErrUpstream
	for _, a := range addrs {
		conn, err := d.DialContext(ctx, "tcp", netip.AddrPortFrom(a, uint16(port)).String())
		if err == nil {
			return conn, nil
		}
		lastErr = err
	}
	return nil, lastErr
}

// Result is a relayed response: the upstream content type and body, and the
// address the body came from after any redirects.
type Result struct {
	ContentType string
	Body        []byte
	// FinalURL is where the last redirect landed: the requested URL when
	// there was none. The web app resolves a feed's relative links against
	// it, and checks that a Substack page is the post the listener tapped
	// (#2979). Every hop was checked by the rules above.
	FinalURL string
}

// FinalURLHeader carries Result.FinalURL to the web app. It is listed in
// Access-Control-Expose-Headers, so a cross-origin fetch() can read it.
const FinalURLHeader = "X-Final-URL"

// Fetch gets one URL under every rule above. Errors are always *Error.
func (r *Relay) Fetch(ctx context.Context, raw string) (*Result, error) {
	r.init()
	u, err := r.Parse(raw)
	if err != nil {
		return nil, err
	}
	select {
	case r.slots <- struct{}{}:
		defer func() { <-r.slots }()
	default:
		return nil, ErrBusy
	}
	ctx, cancel := context.WithTimeout(ctx, r.Timeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u.String(), nil)
	if err != nil {
		return nil, ErrBadURL
	}
	req.Header.Set("User-Agent", UserAgent)
	req.Header.Set("Accept", accept)
	resp, err := r.client.Do(req)
	if err != nil {
		return nil, classify(ctx, err)
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode > 299 {
		return nil, ErrUpstreamStatus
	}
	media, params, err := mime.ParseMediaType(resp.Header.Get("Content-Type"))
	if err != nil || !allowedTypes[media] {
		return nil, ErrTypeRefused
	}
	if resp.ContentLength > r.MaxBytes {
		return nil, ErrTooLarge
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, r.MaxBytes+1))
	if err != nil {
		return nil, classify(ctx, err)
	}
	if int64(len(body)) > r.MaxBytes {
		return nil, ErrTooLarge
	}
	contentType := media
	if cs := params["charset"]; cs != "" {
		contentType = mime.FormatMediaType(media, map[string]string{"charset": cs})
	}
	final := u.String()
	if resp.Request != nil && resp.Request.URL != nil {
		final = resp.Request.URL.String()
	}
	return &Result{ContentType: contentType, Body: body, FinalURL: final}, nil
}

func classify(ctx context.Context, err error) error {
	var re *Error
	if errors.As(err, &re) {
		return re
	}
	var ne net.Error
	if errors.Is(err, context.DeadlineExceeded) || ctx.Err() != nil || (errors.As(err, &ne) && ne.Timeout()) {
		return ErrTimeout
	}
	return ErrUpstream
}

// Admit sets the response headers every relay answer carries and refuses a
// caller that may not use the relay, before anything is fetched or counted:
// a request with no Origin, or one not listed. A browser always sends
// Origin on a cross-origin fetch(), and sends none for a cross-site <img>
// or <script> (a no-cors request), so such a page can't make visitors'
// browsers drive the relay. A same-origin GET sends no Origin either, so
// the web app must be served from a listed origin other than this host.
// It reports whether the request may go on; when it can't, the answer has
// been written.
func (r *Relay) Admit(w http.ResponseWriter, req *http.Request) bool {
	h := w.Header()
	h.Set("Cache-Control", "no-store")
	h.Set("Referrer-Policy", "no-referrer")
	h.Set("X-Content-Type-Options", "nosniff")
	// The body is a publisher's page served from our origin. A sandbox with
	// no sources means opening it directly runs nothing and reads nothing
	// on the share-link host; fetch() from the web app is unaffected.
	h.Set("Content-Security-Policy", "sandbox; default-src 'none'")
	listed := r.CORS(w, req)
	// The server's own public address passes PublicAddr, so ?url= can name
	// this relay under any host name or address. Its User-Agent gives the
	// nested request away, and redirect hops carry it too.
	if req.Header.Get("User-Agent") == UserAgent {
		writeError(w, ErrLoopRefused)
		return false
	}
	if !listed {
		writeError(w, ErrOriginRefused)
		return false
	}
	return true
}

// CORS sets the headers that let a listed web app read this answer, whatever
// it turns out to be: Vary: Origin always, and Access-Control-Allow-Origin only
// for a listed origin. Call it before any answer is written. Without it a
// browser hides an error's status and body, so the web app can't tell
// "switched off" or "busy" from "unreachable" (#3018). It reports whether the
// origin is listed.
func (r *Relay) CORS(w http.ResponseWriter, req *http.Request) bool {
	h := w.Header()
	h.Set("Vary", "Origin")
	origin := req.Header.Get("Origin")
	if !r.AllowedOrigin(origin) {
		return false
	}
	h.Set("Access-Control-Allow-Origin", origin)
	return true
}

// ServeHTTP answers GET ?url=… with the relayed body, or {"error": code}.
// The API wraps it with the on switch and the per-client limit, and calls
// Admit before the limit; calling it again here is harmless.
func (r *Relay) ServeHTTP(w http.ResponseWriter, req *http.Request) {
	r.init()
	if !r.Admit(w, req) {
		return
	}
	h := w.Header()
	res, err := r.Fetch(req.Context(), req.URL.Query().Get("url"))
	if err != nil {
		var re *Error
		if !errors.As(err, &re) {
			re = ErrUpstream
		}
		writeError(w, re)
		return
	}
	h.Set("Content-Type", res.ContentType)
	h.Set("Content-Disposition", "attachment")
	h.Set(FinalURLHeader, res.FinalURL)
	h.Set("Access-Control-Expose-Headers", FinalURLHeader)
	h.Set("Content-Length", strconv.Itoa(len(res.Body)))
	w.WriteHeader(http.StatusOK)
	w.Write(res.Body)
}

func writeError(w http.ResponseWriter, e *Error) {
	w.Header().Set("Content-Type", "application/json")
	if e.Status == http.StatusServiceUnavailable {
		w.Header().Set("Retry-After", "60")
	}
	w.WriteHeader(e.Status)
	fmt.Fprintf(w, "{\"error\":%q}\n", e.Code)
}
