//go:build mapbench

// Command mapbench measures how community listening maps find scene breaks
// (#2075), against publisher chapters as the answer key. It compares:
//
//	A  the server's worker as it runs today (prompt, checks, repairs)
//	B  code only: a topic-shift and pause score, top K by episode length
//	C  code plus Haiku: Haiku picks K of B's candidates, then writes each
//	   scene's title and summary in its own call
//
// Run from research/B4/server:
//
//	go run -tags mapbench ./cmd/mapbench -approaches B
//	go run -tags mapbench ./cmd/mapbench -approaches A,B,C -budget 3
//
// Transcripts are read from the cache (-cache) and never written to the
// repo. Model-written titles and summaries go to the cache too; only
// numbers and identifiers go to -out.
package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	"spokenmargins.dev/bridge/internal/maps"
)

func episodeKey(slug string) string {
	sum := sha256.Sum256([]byte("mapbench:" + slug))
	return hex.EncodeToString(sum[:])
}

// BResult is one variant of approach B at one scene length.
type BResult struct {
	Variant         string  `json:"variant"`
	MinutesPerScene float64 `json:"minutesPerScene"`
	K               int     `json:"k"`
	Breaks          []int64 `json:"breaksMs"`
	At30            Match   `json:"at30s"`
	At60            Match   `json:"at60s"`
}

// EpisodeResult holds everything measured on one episode.
type EpisodeResult struct {
	Slug        string             `json:"slug"`
	Podcast     string             `json:"podcast"`
	FeedURL     string             `json:"feedUrl"`
	EpisodeGUID string             `json:"episodeGuid"`
	Language    string             `json:"language"`
	Minutes     float64            `json:"minutes"`
	Segments    int                `json:"segments"`
	Chapters    []int64            `json:"chapterStartsMs"`
	Uniform     map[string]BResult `json:"uniform"`
	B           []BResult          `json:"b"`
	A           *AResult           `json:"a,omitempty"`
	AAt30       *Match             `json:"aAt30s,omitempty"`
	AAt60       *Match             `json:"aAt60s,omitempty"`
	C           map[string]*CEval  `json:"c,omitempty"`
}

type CEval struct {
	CResult
	At30 Match `json:"at30s"`
	At60 Match `json:"at60s"`
}

var minutesGrid = []float64{3, 4, 5, 6, 7, 8}

func main() {
	home, _ := os.UserHomeDir()
	cache := flag.String("cache", filepath.Join(home, "Library/Caches/spoken-margins-mapbench"), "episode cache (manifest.json, <slug>/)")
	out := flag.String("out", "../eval", "where results.json goes")
	approaches := flag.String("approaches", "B", "comma list of A, B, C")
	budget := flag.Float64("budget", 3, "most dollars to spend on model calls, at the server's prices")
	effortA := flag.String("effort-a", "medium", "effort for A (the server sets none; Haiku 5.5's default is medium)")
	effortsC := flag.String("efforts-c", "medium,low", "comma list of efforts to run C at")
	only := flag.String("only", "", "comma list of slugs to run")
	parallel := flag.Int("parallel", 6, "model calls at once")
	cMinutes := flag.Float64("c-minutes", 0, "minutes per scene for C's K (0: B's best)")
	cVariant := flag.String("c-variant", "", "B variant that offers C's candidates (empty: B's best)")
	offerFactor := flag.Int("offer", 3, "C is offered this many times K candidates")
	claudePath := flag.String("claude", filepath.Join(home, ".local/bin/claude"), "Claude Code CLI")
	explain := flag.String("explain", "", "print the names the check flagged in this generated label (e.g. C-low) and exit")
	flag.Parse()

	data, err := os.ReadFile(filepath.Join(*cache, "manifest.json"))
	if err != nil {
		log.Fatal(err)
	}
	var manifest []Episode
	if err := json.Unmarshal(data, &manifest); err != nil {
		log.Fatal(err)
	}
	want := map[string]bool{}
	for _, s := range strings.Split(*only, ",") {
		if s != "" {
			want[s] = true
		}
	}
	if *explain != "" {
		for _, e := range manifest {
			if len(want) == 0 || want[e.Slug] {
				if err := explainNames(*cache, e, *explain); err != nil {
					log.Printf("%s: %v", e.Slug, err)
				}
			}
		}
		return
	}
	run := map[string]bool{}
	for _, a := range strings.Split(*approaches, ",") {
		run[strings.TrimSpace(strings.ToUpper(a))] = true
	}

	type loaded struct {
		e        Episode
		t        maps.Transcript
		chapters []int64
	}
	var eps []loaded
	for _, e := range manifest {
		if len(want) > 0 && !want[e.Slug] {
			continue
		}
		t, ch, err := loadEpisode(*cache, e)
		if err != nil {
			log.Printf("skip %s: %v", e.Slug, err)
			continue
		}
		eps = append(eps, loaded{e, t, ch})
	}
	log.Printf("%d episodes loaded", len(eps))

	results := make([]*EpisodeResult, len(eps))
	for i, ep := range eps {
		r := &EpisodeResult{Slug: ep.e.Slug, Podcast: ep.e.Podcast, FeedURL: ep.e.FeedURL, EpisodeGUID: ep.e.EpisodeGUID, Language: ep.t.Language,
			Minutes: float64(ep.t.DurationMs) / 60000, Segments: len(ep.t.Segments), Chapters: ep.chapters, Uniform: map[string]BResult{}}
		for _, mins := range minutesGrid {
			k := sceneCount(ep.t.DurationMs, mins)
			u := uniformBreaks(ep.t, k)
			r.Uniform[fmt.Sprint(mins)] = BResult{Variant: "uniform", MinutesPerScene: mins, K: k, Breaks: u, At30: match(u, ep.chapters, 30000), At60: match(u, ep.chapters, 60000)}
		}
		for _, v := range []string{"topic", "pause", "both"} {
			cands := scoreBoundaries(ep.t, variants[v])
			for _, mins := range minutesGrid {
				k := sceneCount(ep.t.DurationMs, mins)
				picked := pick(cands, k-1, minGapFor(ep.t.DurationMs, k), ep.t.DurationMs)
				var br []int64
				for _, c := range picked {
					br = append(br, c.AtMs)
				}
				r.B = append(r.B, BResult{Variant: v, MinutesPerScene: mins, K: k, Breaks: br, At30: match(br, ep.chapters, 30000), At60: match(br, ep.chapters, 60000)})
			}
		}
		results[i] = r
	}
	bestV, bestM := bestB(results)
	log.Printf("B's best: %s at %.0f minutes a scene", bestV, bestM)
	if *cVariant == "" {
		*cVariant = bestV
	}
	if *cMinutes == 0 {
		*cMinutes = bestM
	}

	spend := &Spend{budget: maps.USDToMicro(*budget)}
	if run["A"] || run["C"] {
		token, err := keychainToken()
		if err != nil {
			log.Fatal(err)
		}
		dir, _ := os.MkdirTemp("", "mapbench-cwd-")
		defer os.RemoveAll(dir)
		base := &CLI{Path: *claudePath, Token: token, Model: "claude-haiku-5-5", Dir: dir, Spend: spend, Slots: make(chan struct{}, *parallel)}
		genDir := filepath.Join(*cache, "generated")
		os.MkdirAll(genDir, 0o755)
		ctx := context.Background()
		var wg sync.WaitGroup
		var mu sync.Mutex
		for i, ep := range eps {
			r := results[i]
			if run["A"] {
				wg.Add(1)
				go func() {
					defer wg.Done()
					a, err := runA(ctx, base.WithEffort(*effortA).WithPurpose("A"), ep.t)
					if err != nil {
						log.Printf("A %s: %v", ep.e.Slug, err)
					}
					m30, m60 := match(a.Breaks, ep.chapters, 30000), match(a.Breaks, ep.chapters, 60000)
					mu.Lock()
					r.A, r.AAt30, r.AAt60 = &a, &m30, &m60
					mu.Unlock()
					saveGenerated(genDir, ep.e.Slug, "A", a.Generated)
					log.Printf("A %s: made=%v attempts=%d scenes=%d F1@30=%.2f spent $%.3f", ep.e.Slug, a.Made, a.Attempts, a.Scenes, m30.F1, float64(spend.Spent())/1e6)
				}()
			}
			if run["C"] {
				k := sceneCount(ep.t.DurationMs, *cMinutes)
				cands := scoreBoundaries(ep.t, variants[*cVariant])
				offered := pick(cands, *offerFactor*(k-1), 45000, ep.t.DurationMs)
				for _, effort := range strings.Split(*effortsC, ",") {
					effort := strings.TrimSpace(effort)
					wg.Add(1)
					go func() {
						defer wg.Done()
						c, err := runC(ctx, base.WithEffort(effort).WithPurpose("C"), ep.t, append([]Candidate(nil), offered...), k)
						if err != nil {
							log.Printf("C/%s %s: %v", effort, ep.e.Slug, err)
						}
						ev := &CEval{CResult: c, At30: match(c.Breaks, ep.chapters, 30000), At60: match(c.Breaks, ep.chapters, 60000)}
						mu.Lock()
						if r.C == nil {
							r.C = map[string]*CEval{}
						}
						r.C[effort] = ev
						mu.Unlock()
						saveGenerated(genDir, ep.e.Slug, "C-"+effort, c.Generated)
						log.Printf("C/%s %s: picked=%d/%d pass=%d/%d map=%s F1@30=%.2f spent $%.3f", effort, ep.e.Slug, c.Picked, k-1, c.ScenePass, c.Scenes, c.MapCheck, ev.At30.F1, float64(spend.Spent())/1e6)
					}()
				}
			}
		}
		wg.Wait()
	}
	log.Printf("spent $%.4f at the server's prices", float64(spend.Spent())/1e6)

	os.MkdirAll(*out, 0o755)
	stamp := time.Now().UTC().Format("20060102-1504")
	name := filepath.Join(*out, "results-"+strings.ReplaceAll(*approaches, ",", "")+"-"+stamp+".json")
	body, _ := json.MarshalIndent(map[string]any{
		"run":       map[string]any{"approaches": *approaches, "effortA": *effortA, "effortsC": *effortsC, "cVariant": *cVariant, "cMinutesPerScene": *cMinutes, "offerFactor": *offerFactor, "segmentJoin": fmt.Sprintf("%d-%d s", minSegMs/1000, maxSegMs/1000), "model": "claude-haiku-5-5 via Claude Code CLI", "spentMicroUSD": spend.Spent()},
		"bBest":     map[string]any{"variant": bestV, "minutesPerScene": bestM},
		"episodes":  results,
		"generated": "titles and summaries are in the cache's generated/ folder, not here",
	}, "", "  ")
	if err := os.WriteFile(name, body, 0o644); err != nil {
		log.Fatal(err)
	}
	log.Printf("wrote %s", name)
}

// minGapFor keeps picked breaks at least 40% of an average scene apart.
func minGapFor(durationMs int64, k int) int64 {
	return max(60000, durationMs/int64(k)*2/5)
}

// bestB is the variant and scene length with the highest mean F1 at 30 s.
func bestB(results []*EpisodeResult) (string, float64) {
	sum := map[string]float64{}
	for _, r := range results {
		for _, b := range r.B {
			sum[fmt.Sprintf("%s|%v", b.Variant, b.MinutesPerScene)] += b.At30.F1
		}
	}
	keys := make([]string, 0, len(sum))
	for k := range sum {
		keys = append(keys, k)
	}
	sort.Slice(keys, func(a, b int) bool {
		return sum[keys[a]] > sum[keys[b]] || sum[keys[a]] == sum[keys[b]] && keys[a] < keys[b]
	})
	if len(keys) == 0 {
		return "both", 6
	}
	v, m, _ := strings.Cut(keys[0], "|")
	var mins float64
	fmt.Sscan(m, &mins)
	return v, mins
}

func saveGenerated(dir, slug, label string, g []GenScene) {
	if len(g) == 0 {
		return
	}
	body, _ := json.MarshalIndent(g, "", "  ")
	os.WriteFile(filepath.Join(dir, slug+"."+label+".json"), body, 0o644)
}
