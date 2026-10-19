package maps

import (
	"math"
	"sort"
	"strings"
)

// Stage 1 of a map: code scores every place a scene could start, and the
// model picks among the best (#2075). Ported from cmd/mapbench's topic-shift
// scorer, the best of the code-only methods the bench tried (F1 0.33 at 30
// seconds against publisher chapters, where an even split scores 0.12).

const (
	// windowMs is how much speech each side of a boundary is compared over.
	windowMs = 120000
	// minutesPerScene sets how many scenes an episode gets: the bench's
	// best scene length against publisher chapters.
	minutesPerScene = 5.0
	// offerFactor times the breaks wanted are offered to the model.
	offerFactor = 3
	// offerGapMs keeps offered breaks, and every break, this far from each
	// other and from the episode's ends.
	offerGapMs = 45000
)

// candidate is a place a scene could start: the start of segment seg.
type candidate struct {
	seg   int
	atMs  int64
	score float64 // 0..1, higher where the words change more
}

// scoreBreaks scores every segment start after the first with a
// TextTiling-style depth score: how deep the dip in word overlap between the
// two minutes before and after it is, compared with the peaks on either
// side. Scores are rank-normalised to 0..1, so they mean the same on every
// episode.
func scoreBreaks(t Transcript) []candidate {
	segs := t.Segments
	n := len(segs)
	if n < 2 {
		return nil
	}
	bags := make([]map[string]float64, n)
	for i, s := range segs {
		bags[i] = bag(s.Text)
	}
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
	depth := make([]float64, n-1)
	for i := 1; i < n; i++ {
		lp := smooth[i]
		for k := i - 1; k >= 1 && smooth[k] >= lp; k-- {
			lp = smooth[k]
		}
		rp := smooth[i]
		for k := i + 1; k < n && smooth[k] >= rp; k++ {
			rp = smooth[k]
		}
		depth[i-1] = (lp - smooth[i]) + (rp - smooth[i])
	}
	ranks := rankNorm(depth)
	cands := make([]candidate, n-1)
	for i := 1; i < n; i++ {
		cands[i-1] = candidate{seg: i, atMs: segs[i].StartMs, score: ranks[i-1]}
	}
	return cands
}

// spread takes up to k of the highest-scoring candidates, best first,
// keeping each at least minGap from the episode's start, its end and every
// one already taken. It returns them in time order.
func spread(cands []candidate, k int, minGap, durationMs int64) []candidate {
	sorted := append([]candidate(nil), cands...)
	sort.SliceStable(sorted, func(a, b int) bool { return sorted[a].score > sorted[b].score })
	var out []candidate
	for _, c := range sorted {
		if len(out) == k {
			break
		}
		if c.atMs < minGap || durationMs-c.atMs < minGap {
			continue
		}
		ok := true
		for _, o := range out {
			if abs64(o.atMs-c.atMs) < minGap {
				ok = false
				break
			}
		}
		if ok {
			out = append(out, c)
		}
	}
	sort.Slice(out, func(a, b int) bool { return out[a].atMs < out[b].atMs })
	return out
}

// sceneCount is how many scenes an episode gets: one per minutesPerScene,
// within MinScenes to MaxScenes.
func sceneCount(durationMs int64) int {
	k := int(math.Round(float64(durationMs) / 60000 / minutesPerScene))
	return max(MinScenes, min(MaxScenes, k))
}

// codeGap is how far apart code's own breaks stay when the model's pick
// can't be used: 40% of an average scene, and at least a minute.
func codeGap(durationMs int64, k int) int64 {
	return max(60000, durationMs/int64(k)*2/5)
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

// bag counts a segment's content words. Like the bench, it keeps only
// a-z, digits and apostrophes, so "für" and "über" split; the scores the
// bench measured depend on exactly this.
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
	for r := range idx {
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
