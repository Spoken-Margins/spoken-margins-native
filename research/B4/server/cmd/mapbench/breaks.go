//go:build mapbench

package main

import (
	"math"
	"sort"
	"strings"

	"spokenmargins.dev/bridge/internal/maps"
)

// Candidate is a possible scene break: the start of segment Seg.
type Candidate struct {
	ID     string  `json:"id"`
	Seg    int     `json:"seg"`
	AtMs   int64   `json:"atMs"`
	Score  float64 `json:"score"`
	Topic  float64 `json:"topic"`
	Pause  float64 `json:"pause"`
	PauseS float64 `json:"pauseSec"`
}

// windowMs is how much speech each side of a boundary is compared over.
const windowMs = 120000

// Score weights for the "both" variant; "topic" and "pause" use one each.
var variants = map[string][2]float64{
	"topic": {1, 0},
	"pause": {0, 1},
	"both":  {1, 0.5},
}

// scoreBoundaries scores every segment start after the first: a
// TextTiling-style depth score for the dip in word overlap between the two
// minutes before and after it, and the silence before it. Both are
// rank-normalised to 0..1 so the weights mean the same on every episode.
func scoreBoundaries(t maps.Transcript, weights [2]float64) []Candidate {
	segs := t.Segments
	bags := make([]map[string]float64, len(segs))
	for i, s := range segs {
		bags[i] = bag(s.Text)
	}
	n := len(segs)
	sims := make([]float64, n)
	lo, hi := 0, 0
	for i := 1; i < n; i++ {
		at := segs[i].StartMs
		for lo < i && segs[lo].StartMs < at-windowMs {
			lo++
		}
		if hi < i {
			hi = i
		}
		for hi < n && segs[hi].StartMs < at+windowMs {
			hi++
		}
		left, right := map[string]float64{}, map[string]float64{}
		for k := lo; k < i; k++ {
			addBag(left, bags[k])
		}
		for k := i; k < hi; k++ {
			addBag(right, bags[k])
		}
		sims[i] = cosine(left, right)
	}
	// Smooth over two neighbours each side, as TextTiling does.
	smooth := make([]float64, n)
	for i := 1; i < n; i++ {
		sum, c := 0.0, 0.0
		for k := i - 2; k <= i+2; k++ {
			if k >= 1 && k < n {
				sum += sims[k]
				c++
			}
		}
		smooth[i] = sum / c
	}
	depth := make([]float64, n)
	for i := 1; i < n; i++ {
		lp := smooth[i]
		for k := i - 1; k >= 1 && smooth[k] >= lp; k-- {
			lp = smooth[k]
		}
		rp := smooth[i]
		for k := i + 1; k < n && smooth[k] >= rp; k++ {
			rp = smooth[k]
		}
		depth[i] = (lp - smooth[i]) + (rp - smooth[i])
	}
	pause := make([]float64, n)
	for i := 1; i < n; i++ {
		gap := float64(segs[i].StartMs-segs[i-1].EndMs) / 1000
		pause[i] = math.Max(0, math.Min(gap, 5))
	}
	topicR, pauseR := rankNorm(depth[1:]), rankNorm(pause[1:])
	cands := make([]Candidate, 0, n-1)
	for i := 1; i < n; i++ {
		c := Candidate{Seg: i, AtMs: segs[i].StartMs, Topic: topicR[i-1], Pause: pauseR[i-1], PauseS: pause[i]}
		c.Score = weights[0]*c.Topic + weights[1]*c.Pause
		cands = append(cands, c)
	}
	return cands
}

// pick takes the k highest-scoring candidates, best first, keeping each at
// least minGap from the episode's start, its end and every one already
// taken. It returns them in time order.
func pick(cands []Candidate, k int, minGap, durationMs int64) []Candidate {
	sorted := append([]Candidate(nil), cands...)
	sort.SliceStable(sorted, func(a, b int) bool { return sorted[a].Score > sorted[b].Score })
	var out []Candidate
	for _, c := range sorted {
		if len(out) == k {
			break
		}
		if c.AtMs < minGap || durationMs-c.AtMs < minGap {
			continue
		}
		ok := true
		for _, o := range out {
			if abs64(o.AtMs-c.AtMs) < minGap {
				ok = false
				break
			}
		}
		if ok {
			out = append(out, c)
		}
	}
	sort.Slice(out, func(a, b int) bool { return out[a].AtMs < out[b].AtMs })
	return out
}

// sceneCount is K for an episode: one scene per minutesPerScene, within the
// server's 3 to 40.
func sceneCount(durationMs int64, minutesPerScene float64) int {
	k := int(math.Round(float64(durationMs) / 60000 / minutesPerScene))
	return max(maps.MinScenes, min(maps.MaxScenes, k))
}

// uniformBreaks is the floor any method must beat: k scenes of equal length,
// snapped to the nearest segment start.
func uniformBreaks(t maps.Transcript, k int) []int64 {
	var out []int64
	for i := 1; i < k; i++ {
		target := t.DurationMs * int64(i) / int64(k)
		best := t.Segments[0].StartMs
		for _, s := range t.Segments {
			if abs64(s.StartMs-target) < abs64(best-target) {
				best = s.StartMs
			}
		}
		out = append(out, best)
	}
	return out
}

var stopwords = func() map[string]bool {
	m := map[string]bool{}
	for _, w := range strings.Fields(`the and that this with you for are was but not have they what like just yeah
	its it's about there from your all can one more would know think really because when been their them then
	which some out get got going were well right also very things thing kind sort something lot people we're
	that's don't i'm you're there's they're it’s don’t i’m you’re that’s okay mean say said even much how who
	other into could make actually any these those here where why our will being had has did does doing want
	way time now yes over only see too back maybe still good little gonna wanna into than through same pretty
	der die das und ist ich nicht ein eine einen einem einer sie wir ihr mit auf auch sich den dem des von für
	aber noch nur wie was wenn man dann also schon mal hat haben sind war wird werden kann können muss dass
	das ja nein doch halt eben genau oder weil sehr mehr hier jetzt immer bei aus nach zum zur über unter so
	diese dieser dieses denn da ganz gut wieder einfach eigentlich irgendwie natürlich gibt gerade sozusagen`) {
		m[w] = true
	}
	return m
}()

func bag(text string) map[string]float64 {
	b := map[string]float64{}
	for _, w := range strings.FieldsFunc(strings.ToLower(text), func(r rune) bool {
		return !(r >= 'a' && r <= 'z' || r >= '0' && r <= '9' || r == '\'' || r == '’')
	}) {
		w = strings.Trim(w, "'’")
		if len(w) < 3 || stopwords[w] {
			continue
		}
		if len(w) > 4 && strings.HasSuffix(w, "s") && !strings.HasSuffix(w, "ss") {
			w = w[:len(w)-1]
		}
		b[w]++
	}
	return b
}

func addBag(dst, src map[string]float64) {
	for w, c := range src {
		dst[w] += c
	}
}

func cosine(a, b map[string]float64) float64 {
	var dot, na, nb float64
	for w, x := range a {
		na += x * x
		dot += x * b[w]
	}
	for _, y := range b {
		nb += y * y
	}
	if na == 0 || nb == 0 {
		return 0
	}
	return dot / math.Sqrt(na*nb)
}

// rankNorm maps values to their rank in 0..1, ties sharing the lower rank.
func rankNorm(v []float64) []float64 {
	idx := make([]int, len(v))
	for i := range idx {
		idx[i] = i
	}
	sort.SliceStable(idx, func(a, b int) bool { return v[idx[a]] < v[idx[b]] })
	out := make([]float64, len(v))
	if len(v) < 2 {
		return out
	}
	for r := 0; r < len(idx); r++ {
		rank := r
		for rank > 0 && v[idx[rank-1]] == v[idx[r]] {
			rank--
		}
		out[idx[r]] = float64(rank) / float64(len(v)-1)
	}
	return out
}

func abs64(x int64) int64 {
	if x < 0 {
		return -x
	}
	return x
}

// Match scores predicted breaks against chapter starts. Breaks within
// ignoreMs of the start are dropped on both sides (the break at 0 is free).
// Each chapter start is matched to at most one prediction, nearest first.
type Match struct {
	Predicted int     `json:"predicted"`
	Reference int     `json:"reference"`
	Hits      int     `json:"hits"`
	Precision float64 `json:"precision"`
	Recall    float64 `json:"recall"`
	F1        float64 `json:"f1"`
}

const ignoreMs = 15000

func match(pred, ref []int64, tolMs int64) Match {
	p, r := drop0(pred), drop0(ref)
	type pair struct {
		i, j int
		d    int64
	}
	var pairs []pair
	for i, x := range p {
		for j, y := range r {
			if d := abs64(x - y); d <= tolMs {
				pairs = append(pairs, pair{i, j, d})
			}
		}
	}
	sort.Slice(pairs, func(a, b int) bool { return pairs[a].d < pairs[b].d })
	usedP, usedR := map[int]bool{}, map[int]bool{}
	hits := 0
	for _, pr := range pairs {
		if !usedP[pr.i] && !usedR[pr.j] {
			usedP[pr.i], usedR[pr.j] = true, true
			hits++
		}
	}
	m := Match{Predicted: len(p), Reference: len(r), Hits: hits}
	if len(p) > 0 {
		m.Precision = float64(hits) / float64(len(p))
	}
	if len(r) > 0 {
		m.Recall = float64(hits) / float64(len(r))
	}
	if m.Precision+m.Recall > 0 {
		m.F1 = 2 * m.Precision * m.Recall / (m.Precision + m.Recall)
	}
	return m
}

func drop0(v []int64) []int64 {
	var out []int64
	for _, x := range v {
		if x >= ignoreMs {
			out = append(out, x)
		}
	}
	return out
}
