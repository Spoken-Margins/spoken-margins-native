//go:build mapbench

package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"

	"spokenmargins.dev/bridge/internal/maps"
)

// Episode is one manifest row from the cache. Only these identifiers and
// derived numbers reach the repo; transcript text stays in the cache.
type Episode struct {
	Slug             string  `json:"slug"`
	Podcast          string  `json:"podcast"`
	FeedURL          string  `json:"feedUrl"`
	EpisodeGUID      string  `json:"episodeGuid"`
	EpisodeTitle     string  `json:"episodeTitle"`
	DurationSec      float64 `json:"durationSec"`
	ChaptersURL      string  `json:"chaptersUrl"`
	TranscriptURL    string  `json:"transcriptUrl"`
	TranscriptFormat string  `json:"transcriptFormat"`
}

type cue struct {
	startMs, endMs int64
	speaker        string
	text           string
}

// Segments are built the way a phone's would look: cues joined until a
// sentence ends after at least minSegMs, or maxSegMs passes, or the speaker
// changes. Published cues are a few seconds long, and a two-hour episode
// would pass the server's 3,000-segment limit without this.
const (
	minSegMs = 15000
	maxSegMs = 30000
)

func loadEpisode(cache string, e Episode) (maps.Transcript, []int64, error) {
	dir := filepath.Join(cache, e.Slug)
	chapters, err := loadChapters(filepath.Join(dir, "chapters.json"))
	if err != nil {
		return maps.Transcript{}, nil, err
	}
	matches, _ := filepath.Glob(filepath.Join(dir, "transcript.*"))
	if len(matches) == 0 {
		return maps.Transcript{}, nil, fmt.Errorf("%s: no transcript", e.Slug)
	}
	data, err := os.ReadFile(matches[0])
	if err != nil {
		return maps.Transcript{}, nil, err
	}
	var cues []cue
	switch strings.ToLower(filepath.Ext(matches[0])) {
	case ".json":
		cues, err = parseJSONTranscript(data)
	default:
		cues, err = parseTimedText(string(data))
	}
	if err != nil {
		return maps.Transcript{}, nil, fmt.Errorf("%s: %w", e.Slug, err)
	}
	if len(cues) == 0 {
		return maps.Transcript{}, nil, fmt.Errorf("%s: transcript has no cues", e.Slug)
	}
	t := maps.Transcript{
		Schema:     maps.TranscriptSchema,
		EpisodeKey: episodeKey(e.Slug),
		Segments:   joinCues(cues),
	}
	t.Language = guessLanguage(t.Segments)
	t.DurationMs = int64(e.DurationSec * 1000)
	if last := cues[len(cues)-1].endMs; last > t.DurationMs {
		t.DurationMs = last
	}
	return t, chapters, nil
}

func loadChapters(path string) ([]int64, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var c struct {
		Chapters []struct {
			StartSec float64 `json:"startSec"`
		} `json:"chapters"`
	}
	if err := json.Unmarshal(data, &c); err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	var starts []int64
	for _, ch := range c.Chapters {
		starts = append(starts, int64(ch.StartSec*1000))
	}
	sort.Slice(starts, func(i, j int) bool { return starts[i] < starts[j] })
	return starts, nil
}

var (
	timingLine = regexp.MustCompile(`(\d{1,2}:)?(\d{1,2}):(\d{2})[.,](\d{1,3})\s*-->\s*(\d{1,2}:)?(\d{1,2}):(\d{2})[.,](\d{1,3})`)
	voiceTag   = regexp.MustCompile(`<v(?:\.[^ >]*)?\s+([^>]*)>`)
	anyTag     = regexp.MustCompile(`<[^>]*>`)
)

// parseTimedText reads SRT and WebVTT: a timing line, then text lines up to
// a blank line. Cue numbers and NOTE blocks are skipped.
func parseTimedText(s string) ([]cue, error) {
	s = strings.ReplaceAll(s, "\r\n", "\n")
	var cues []cue
	var cur *cue
	flush := func() {
		if cur != nil && strings.TrimSpace(cur.text) != "" {
			cur.text = strings.Join(strings.Fields(cur.text), " ")
			cues = append(cues, *cur)
		}
		cur = nil
	}
	for _, line := range strings.Split(s, "\n") {
		if m := timingLine.FindStringSubmatch(line); m != nil {
			flush()
			cur = &cue{startMs: clockMs(m[1], m[2], m[3], m[4]), endMs: clockMs(m[5], m[6], m[7], m[8])}
			continue
		}
		if strings.TrimSpace(line) == "" {
			flush()
			continue
		}
		if cur == nil {
			continue // cue number, WEBVTT header, NOTE
		}
		if v := voiceTag.FindStringSubmatch(line); v != nil {
			cur.speaker = strings.TrimSpace(v[1])
		}
		if sp, rest, ok := strings.Cut(line, ":"); ok && cur.text == "" && len(sp) < 40 && !strings.ContainsAny(sp, ".,?!") && strings.TrimSpace(rest) != "" && sp == strings.TrimSpace(sp) && len(strings.Fields(sp)) <= 3 {
			// "Speaker Name: text", a common SRT convention.
			cur.speaker, line = sp, rest
		}
		cur.text += " " + anyTag.ReplaceAllString(line, "")
	}
	flush()
	if len(cues) == 0 {
		return nil, fmt.Errorf("no timed cues")
	}
	return cues, nil
}

func clockMs(h, m, s, frac string) int64 {
	hh, _ := strconv.Atoi(strings.TrimSuffix(h, ":"))
	mm, _ := strconv.Atoi(m)
	ss, _ := strconv.Atoi(s)
	for len(frac) < 3 {
		frac += "0"
	}
	ms, _ := strconv.Atoi(frac)
	return int64(((hh*60+mm)*60+ss)*1000 + ms)
}

// parseJSONTranscript reads the Podcasting 2.0 JSON transcript format.
func parseJSONTranscript(data []byte) ([]cue, error) {
	var j struct {
		Segments []struct {
			Speaker   string  `json:"speaker"`
			StartTime flexNum `json:"startTime"`
			EndTime   flexNum `json:"endTime"`
			Body      string  `json:"body"`
		} `json:"segments"`
	}
	if err := json.Unmarshal(data, &j); err != nil {
		return nil, err
	}
	var cues []cue
	for _, s := range j.Segments {
		text := strings.Join(strings.Fields(s.Body), " ")
		if text == "" {
			continue
		}
		cues = append(cues, cue{startMs: int64(s.StartTime * 1000), endMs: int64(s.EndTime * 1000), speaker: s.Speaker, text: text})
	}
	sort.SliceStable(cues, func(a, b int) bool { return cues[a].startMs < cues[b].startMs })
	return cues, nil
}

func joinCues(cues []cue) []maps.Segment {
	var segs []maps.Segment
	var cur *maps.Segment
	speaker := ""
	for _, c := range cues {
		if cur != nil {
			long := c.endMs-cur.StartMs > maxSegMs
			sentence := c.startMs-cur.StartMs >= minSegMs && strings.ContainsAny(cur.Text[len(cur.Text)-1:], ".?!")
			if long || sentence || (c.speaker != "" && c.speaker != speaker) {
				segs = append(segs, *cur)
				cur = nil
			}
		}
		if cur == nil {
			start := c.startMs
			if n := len(segs); n > 0 && start <= segs[n-1].StartMs {
				start = segs[n-1].StartMs + 1 // the server needs strictly increasing starts
			}
			// Some publisher cues end before they start, or before the
			// nudged start; the server refuses a segment like that.
			cur = &maps.Segment{ID: fmt.Sprintf("s%d", len(segs)+1), StartMs: start, EndMs: max(c.endMs, start), Text: c.text}
			speaker = c.speaker
			continue
		}
		cur.Text += " " + c.text
		if c.endMs > cur.EndMs {
			cur.EndMs = c.endMs
		}
	}
	if cur != nil {
		segs = append(segs, *cur)
	}
	return segs
}

// guessLanguage tells English from German by their commonest words; the
// bench has only those two.
func guessLanguage(segs []maps.Segment) string {
	en, de := 0, 0
	for _, s := range segs {
		for _, w := range strings.Fields(strings.ToLower(s.Text)) {
			switch w {
			case "the", "and", "is", "of", "that":
				en++
			case "der", "die", "und", "ist", "das", "nicht":
				de++
			}
		}
	}
	if de > en {
		return "de"
	}
	return "en"
}

// flexNum reads a number written either as a JSON number or as a string,
// since some feeds quote their transcript times.
type flexNum float64

func (f *flexNum) UnmarshalJSON(b []byte) error {
	v, err := strconv.ParseFloat(strings.Trim(string(b), `"`), 64)
	*f = flexNum(v)
	return err
}
