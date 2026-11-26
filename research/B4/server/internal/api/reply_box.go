package api

import (
	"encoding/base64"
	"log"
	"net/http"
	"strings"
	"time"

	"spokenmargins.dev/bridge/internal/clubs"
	"spokenmargins.dev/bridge/internal/links"
	"spokenmargins.dev/bridge/internal/weborigin"
)

// Reply boxes (#4675, docs/design/reply-mailbox.md). The sender's phone makes a reply box with each share
// link: the link upload carries the box in four headers, and the server makes the box (internal/clubs,
// reply.go) and stores the link's sealed reply part beside its packet. A friend's browser fetches the part
// from GET /l/<id>/reply, opens it with the link's key, and posts a sealed answer to the box with the
// post proof. The sender's phone lists and fetches answers with the read proof, which never leaves it,
// and can close the box with that proof.
//
// Every club route for a box of kind reply answers to the replies switch instead of clubs (boxOn), so
// reply boxes work with clubs off and club creation, which takes no credential, stays closed.
//
// CORS: only the post route of a reply box, and its preflight, answer CORS, and only to an exact
// -link-origins origin. The headers are set before any check, so a browser can read every error the post
// answers (404, 409, 410, 413, 429, 503). Ordinary clubs and every other club route answer no CORS.
const (
	HeaderReplyID       = "X-SM-Reply-Id"
	HeaderReplyReadHash = "X-SM-Reply-Read-Hash"
	HeaderReplyPostHash = "X-SM-Reply-Post-Hash"
	HeaderReplyPart     = "X-SM-Reply-Part"
)

// replyRequest is a link upload's reply box, read from its headers.
type replyRequest struct {
	id, readHash, postHash string
	part                   []byte
}

// replyHeaders reads the four reply-box headers. It answers ok only when all four are present, each once,
// and well formed; anything else (some missing, one malformed) is no box, and the link is still made.
func replyHeaders(r *http.Request) (replyRequest, bool) {
	one := func(name string) (string, bool) {
		v := r.Header.Values(name)
		if len(v) != 1 {
			return "", false
		}
		return v[0], true
	}
	id, okID := one(HeaderReplyID)
	readHash, okRead := one(HeaderReplyReadHash)
	postHash, okPost := one(HeaderReplyPostHash)
	encoded, okPart := one(HeaderReplyPart)
	if !okID || !okRead || !okPost || !okPart {
		return replyRequest{}, false
	}
	if !clubs.ValidID(id) || !clubs.ValidHash(readHash) || !clubs.ValidHash(postHash) || readHash == postHash {
		return replyRequest{}, false
	}
	if base64.StdEncoding.DecodedLen(len(encoded)) > links.MaxReplyBytes+3 {
		return replyRequest{}, false
	}
	part, err := base64.StdEncoding.Strict().DecodeString(encoded)
	if err != nil || len(part) > links.MaxReplyBytes || !links.Sealed(part, links.PartReply) {
		return replyRequest{}, false
	}
	return replyRequest{id: id, readHash: readHash, postHash: postHash, part: part}, true
}

// hasReplyHeaders is true when the upload carries any of the four headers.
func hasReplyHeaders(r *http.Request) bool {
	for _, name := range []string{HeaderReplyID, HeaderReplyReadHash, HeaderReplyPostHash, HeaderReplyPart} {
		if len(r.Header.Values(name)) > 0 {
			return true
		}
	}
	return false
}

// makeReplyBox makes the reply box the upload asked for, for the link that was just made and bound, and
// stores the link's sealed reply part. It reports whether both are in place. If the part cannot be stored,
// the box is removed again, so a box exists only with a link that hands out its post proof. Nothing it
// logs names the link, the box or a proof.
func (s *Server) makeReplyBox(r *http.Request, linkID string, expires, now time.Time) bool {
	if !hasReplyHeaders(r) || !s.repliesUp() {
		return false
	}
	box, ok := replyHeaders(r)
	if !ok {
		return false
	}
	if err := s.Clubs.CreateReply(box.id, box.readHash, box.postHash, linkID, expires, now); err != nil {
		log.Print("replies: reply box not made")
		return false
	}
	if err := s.Links.PutReply(linkID, box.part, now); err != nil {
		log.Print("replies: reply part not stored, reply box removed")
		if err := s.Clubs.DiscardReply(box.id, linkID, now); err != nil {
			log.Print("replies: half-made reply box could not be removed")
		}
		return false
	}
	return true
}

// getLinkReply is GET /l/{id}/reply: the link's sealed reply part, byte for byte, under the link's CORS. A
// link with no part answers 404, and so does every link while the replies switch is off, so the page
// shows today's way to send a file. An expired or removed link answers as /packet does.
func (s *Server) getLinkReply(w http.ResponseWriter, r *http.Request) {
	linkHeaders(w)
	if !s.linksOn(w) {
		return
	}
	data, err := s.Links.Reply(r.PathValue("id"), s.Now())
	if err != nil {
		linkFailure(w, err)
		return
	}
	if !s.repliesUp() {
		fail(w, http.StatusNotFound, "not_found")
		return
	}
	w.Header().Set("Content-Type", "application/octet-stream")
	w.Write(data)
}

// closeReplyBox is POST /api/v1/clubs/{id}/close with the read proof: the reply box takes no more answers.
// Its sender can still list, fetch and report what is in it until it ends. Only a reply box can be closed;
// a post proof, a stranger and a club all get 404. A box that is already closed or has ended counts as
// closed. Counted with club writes in the per-network hour.
func (s *Server) closeReplyBox(w http.ResponseWriter, r *http.Request) {
	clubHeaders(w)
	id := r.PathValue("id")
	if _, ok := s.boxOn(w, id); !ok {
		return
	}
	now := s.Now()
	if !s.clubWindow.hit(s.clientKey(r), now, s.clubWritesPerHour()) {
		fail(w, http.StatusTooManyRequests, "rate_limited")
		return
	}
	if err := s.Clubs.Close(id, clubProof(r), now); err != nil {
		clubFailure(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]bool{"closed": true})
}

// replyCORS sets the CORS headers on a reply box's post answer, for an exact -link-origins origin. Never
// credentials. With no origins listed it changes nothing.
func (s *Server) replyCORS(w http.ResponseWriter, r *http.Request) {
	if len(s.LinkOrigins) == 0 {
		return
	}
	h := w.Header()
	h.Add("Vary", "Origin")
	if origin := r.Header.Get("Origin"); weborigin.Allowed(s.LinkOrigins, origin) {
		h.Set("Access-Control-Allow-Origin", origin)
	}
}

// replyAllowedHeaders are the request headers a browser may send with an answer.
var replyAllowedHeaders = map[string]bool{"authorization": true, "content-type": true}

// replyPreflight answers OPTIONS on a box's post route. It allows POST with Authorization and Content-Type,
// for a listed origin and a reply box only; an ordinary club, an unknown id, another origin, another
// method or another header is refused with no CORS headers, so the browser blocks the post.
func (s *Server) replyPreflight(w http.ResponseWriter, r *http.Request) {
	h := w.Header()
	h.Add("Vary", "Origin")
	h.Add("Vary", "Access-Control-Request-Method")
	h.Add("Vary", "Access-Control-Request-Headers")
	h.Set("Cache-Control", "no-store")
	origin := r.Header.Get("Origin")
	ok := weborigin.Allowed(s.LinkOrigins, origin) && r.Header.Get("Access-Control-Request-Method") == http.MethodPost
	for _, field := range strings.Split(r.Header.Get("Access-Control-Request-Headers"), ",") {
		if name := strings.ToLower(strings.TrimSpace(field)); name != "" && !replyAllowedHeaders[name] {
			ok = false
		}
	}
	if !ok || !s.box(r.PathValue("id")).Reply {
		fail(w, http.StatusForbidden, "origin_refused")
		return
	}
	h.Set("Access-Control-Allow-Origin", origin)
	h.Set("Access-Control-Allow-Methods", http.MethodPost)
	h.Set("Access-Control-Allow-Headers", "Authorization, Content-Type")
	h.Set("Access-Control-Max-Age", linkCORSMaxAge)
	w.WriteHeader(http.StatusNoContent)
}
