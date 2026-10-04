package api

import (
	"encoding/base64"
	"net/http"
	"strings"

	"spokenmargins.dev/bridge/internal/config"
	"spokenmargins.dev/bridge/internal/tokens"
)

const (
	// TokenPurposeMaps is the purpose a map-upload token is made for, so a
	// token made for another feature can't be spent here.
	TokenPurposeMaps = "maps"

	tokenScheme = "PrivateToken"
	// maxAuthorization caps the header we parse. A type 2 token with a
	// 2048-bit key is 354 bytes, 472 in base64url.
	maxAuthorization = 1024
)

// mapTokenPolicy says whether map uploads must carry a token, and whether
// the server can check one. Requiring tokens while the tokens service is
// off, or with no issuer, fails closed: uploads are refused, not let in.
func (s *Server) mapTokenPolicy() (required, available bool) {
	doc, err := s.Config.Current()
	if err != nil {
		return true, false
	}
	if !doc.Enabled(config.ServiceMapUploadToken) {
		return false, true
	}
	return true, doc.Enabled(config.ServiceTokens) && s.Tokens != nil
}

// privateToken reads RFC 9577 §2.2's `Authorization: PrivateToken token="…"`.
// The value is base64url, with or without padding.
func privateToken(header string) ([]byte, bool) {
	if header == "" || len(header) > maxAuthorization {
		return nil, false
	}
	scheme, params, _ := strings.Cut(header, " ")
	if !strings.EqualFold(scheme, tokenScheme) {
		return nil, false
	}
	for _, p := range strings.Split(params, ",") {
		name, value, ok := strings.Cut(strings.TrimSpace(p), "=")
		if !ok || !strings.EqualFold(strings.TrimSpace(name), "token") {
			continue
		}
		value = strings.Trim(strings.TrimSpace(value), `"`)
		raw, err := base64.RawURLEncoding.DecodeString(strings.TrimRight(value, "="))
		if err != nil || len(raw) == 0 {
			return nil, false
		}
		return raw, true
	}
	return nil, false
}

// askForToken answers 401 with RFC 9577 §2.1's challenge, naming the key
// to get a token from, so a phone that didn't know tokens were needed (or
// sent a bad one) knows what to fetch. §2.1.2 wants both values base64url
// with padding.
func (s *Server) askForToken(w http.ResponseWriter, code string) {
	keys, err := s.Tokens.PublicKeys(s.Now())
	if err != nil {
		fail(w, http.StatusInternalServerError, "internal")
		return
	}
	spki, err := keys[0].SPKI()
	if err != nil {
		fail(w, http.StatusInternalServerError, "internal")
		return
	}
	w.Header().Set("WWW-Authenticate", tokenScheme+
		` challenge="`+base64.URLEncoding.EncodeToString(tokens.Challenge(TokenPurposeMaps))+
		`", token-key="`+base64.URLEncoding.EncodeToString(spki)+`"`)
	fail(w, http.StatusUnauthorized, code)
}

// checkMapToken checks the upload's token without spending it. It answers
// the request itself and returns false when the upload can't go on.
func (s *Server) checkMapToken(w http.ResponseWriter, r *http.Request) ([]byte, bool) {
	raw, ok := privateToken(r.Header.Get("Authorization"))
	if !ok {
		s.askForToken(w, "token_required")
		return nil, false
	}
	if err := s.Tokens.Check(s.Now(), raw, TokenPurposeMaps); err != nil {
		if tokens.Refused(err) {
			s.askForToken(w, "token_refused")
		} else {
			fail(w, http.StatusInternalServerError, "internal")
		}
		return nil, false
	}
	return raw, true
}
