// Package maps makes community listening maps (#551). An opted-in phone
// uploads one episode's transcript; a worker asks an AI provider for a map of
// the episode's scenes, checks the answer, keeps the map and deletes the
// transcript. Anyone can then fetch the map for that episode.
//
// Rules this package enforces, not just documents:
//   - A transcript is never served and never written to disk. It waits in
//     memory for the worker and is dropped as soon as its map is made or
//     dropped; the hourly sweep drops any older than TranscriptMaxAge, and a
//     restart drops them all.
//   - The first upload for an episode wins; later ones cause no new work.
//   - Spending stops at a hard monthly cap kept in a ledger on disk.
//   - Neither the episode key nor the API key is ever logged.
package maps

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
)

const (
	TranscriptSchema = "spokenmargins.episode-transcript.v1"
	MapSchema        = "spokenmargins.episode-map.v1"

	MaxTranscriptBytes = 2 << 20
	MaxSegments        = 3000
	// MaxPromptBytes bounds the text the model reads (each segment's text, id
	// and the timestamp line around it). Claude Haiku 5.5 bills a prompt over
	// 100,000 tokens at five times the price, which the ledger's flat prices
	// would undercount. At 2 bytes a token, the worst case, 180,000 bytes is
	// 90,000 tokens; ordinary English is about 3 bytes a token, so this holds
	// roughly 3 hours of speech, less in languages that need more tokens.
	MaxPromptBytes = 180000
	// MaxDurationMs bounds durationMs so the scene arithmetic can't overflow
	// and a typo can't claim a week-long episode.
	MaxDurationMs = 48 * 3600 * 1000
)

// promptLineOverhead stands for the "[id h:mm:ss] " and newline that
// buildRequest adds around each segment's text.
const promptLineOverhead = 14

var (
	keyPattern       = regexp.MustCompile(`^[0-9a-f]{64}$`)
	segmentIDPattern = regexp.MustCompile(`^[A-Za-z0-9._:-]{1,64}$`)
	languagePattern  = regexp.MustCompile(`^[A-Za-z0-9-]{1,35}$`)
)

// ValidKey reports whether key is an episode key: 64 lowercase hex characters.
func ValidKey(key string) bool { return keyPattern.MatchString(key) }

type Segment struct {
	ID      string `json:"id"`
	StartMs int64  `json:"startMs"`
	EndMs   int64  `json:"endMs"`
	Text    string `json:"text"`
}

// Transcript is what a phone uploads. Unknown fields are ignored, so a newer
// app can add some without being refused.
type Transcript struct {
	Schema     string    `json:"schema"`
	EpisodeKey string    `json:"episodeKey"`
	DurationMs int64     `json:"durationMs"`
	Language   string    `json:"language"`
	Segments   []Segment `json:"segments"`
}

// ErrInvalid wraps every reason ParseTranscript refuses an upload.
var ErrInvalid = errors.New("maps: invalid transcript")

func invalid(format string, args ...any) error {
	return fmt.Errorf("%w: %s", ErrInvalid, fmt.Sprintf(format, args...))
}

// ParseTranscript decodes and checks an upload. The caller bounds the body to
// MaxTranscriptBytes before calling it.
func ParseTranscript(data []byte) (Transcript, error) {
	var t Transcript
	if len(data) > MaxTranscriptBytes {
		return t, invalid("over %d bytes", MaxTranscriptBytes)
	}
	dec := json.NewDecoder(bytes.NewReader(data))
	if err := dec.Decode(&t); err != nil {
		return t, invalid("not JSON")
	}
	if dec.More() {
		return t, invalid("trailing data")
	}
	if t.Schema != TranscriptSchema {
		return t, invalid("schema")
	}
	if !ValidKey(t.EpisodeKey) {
		return t, invalid("episodeKey")
	}
	if t.DurationMs <= 0 || t.DurationMs > MaxDurationMs {
		return t, invalid("durationMs")
	}
	if !languagePattern.MatchString(t.Language) {
		return t, invalid("language")
	}
	if len(t.Segments) == 0 || len(t.Segments) > MaxSegments {
		return t, invalid("segment count")
	}
	seen := make(map[string]bool, len(t.Segments))
	promptBytes := 0
	for i, s := range t.Segments {
		promptBytes += len(s.Text) + len(s.ID) + promptLineOverhead
		if promptBytes > MaxPromptBytes {
			return t, invalid("too long to map")
		}
		if !segmentIDPattern.MatchString(s.ID) || seen[s.ID] {
			return t, invalid("segment %d id", i)
		}
		seen[s.ID] = true
		if s.StartMs < 0 || s.EndMs < s.StartMs || s.EndMs > MaxDurationMs {
			return t, invalid("segment %d times", i)
		}
		if i > 0 && s.StartMs <= t.Segments[i-1].StartMs {
			return t, invalid("segment %d starts out of order", i)
		}
	}
	return t, nil
}

// Scene is one stretch of the episode in a map.
type Scene struct {
	StartMs int64  `json:"startMs"`
	EndMs   int64  `json:"endMs"`
	Title   string `json:"title"`
	Summary string `json:"summary"`
}

// Map is the only thing kept and served.
type Map struct {
	Schema     string  `json:"schema"`
	EpisodeKey string  `json:"episodeKey"`
	DurationMs int64   `json:"durationMs"`
	Generator  string  `json:"generator"`
	CreatedAt  string  `json:"createdAt"`
	Scenes     []Scene `json:"scenes"`
}
