package maps

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"testing"
)

// The two-stage worker (#2075): code finds candidate breaks, the model picks
// among them, and each scene is written by a call of its own.

// twoTopics is 20 one-minute segments: lighthouses, then from segment 12 on
// bread, so the one real break is at 12 minutes.
func twoTopics() Transcript {
	tr := testTranscript()
	for i := range tr.Segments {
		if i < 12 {
			tr.Segments[i].Text = fmt.Sprintf("Lighthouse keepers trimmed lamp wicks, polished lenses and logged storms on the rocky coast, entry %d.", i)
		} else {
			tr.Segments[i].Text = fmt.Sprintf("Bakers knead sourdough, proof loaves overnight and bake crusty bread in stone ovens, batch %d.", i)
		}
	}
	return tr
}

func TestScoreBreaksFindsTheTopicShift(t *testing.T) {
	tr := twoTopics()
	cands := scoreBreaks(tr)
	if len(cands) != len(tr.Segments)-1 {
		t.Fatalf("%d candidates for %d segments", len(cands), len(tr.Segments))
	}
	best := cands[0]
	for _, c := range cands {
		if c.score < 0 || c.score > 1 {
			t.Fatalf("score %v out of 0..1", c.score)
		}
		if c.score > best.score {
			best = c
		}
	}
	// Smoothing over two neighbours each side blurs a shift by up to a
	// segment, here a minute.
	if abs64(best.atMs-12*60000) > 60000 {
		t.Fatalf("best candidate %+v, want within a minute of 12:00", best)
	}
	for _, c := range cands {
		if abs64(c.atMs-12*60000) > 3*60000 && c.score >= best.score {
			t.Fatalf("candidate %+v far from the shift scores as high as %+v", c, best)
		}
	}
	// One segment has no place to break.
	if got := scoreBreaks(Transcript{Segments: tr.Segments[:1]}); got != nil {
		t.Fatalf("one segment: %v", got)
	}
}

func TestSpreadKeepsBreaksApartAndOffTheEnds(t *testing.T) {
	cands := []candidate{
		{seg: 1, atMs: 10000, score: 1},     // too near the start
		{seg: 2, atMs: 100000, score: 0.9},  // taken
		{seg: 3, atMs: 120000, score: 0.8},  // too near the one taken
		{seg: 4, atMs: 300000, score: 0.5},  // taken
		{seg: 5, atMs: 590000, score: 0.95}, // too near the end
		{seg: 6, atMs: 400000, score: 0.1},  // taken last
	}
	got := spread(cands, 3, 60000, 600000)
	var segs []int
	for _, c := range got {
		segs = append(segs, c.seg)
	}
	if fmt.Sprint(segs) != "[2 4 6]" {
		t.Fatalf("spread = %v, want [2 4 6] in time order", segs)
	}
	if got := spread(cands, 1, 60000, 600000); len(got) != 1 || got[0].seg != 2 {
		t.Fatalf("spread of 1 = %+v", got)
	}
}

func TestPickRequestOffersThreeTimesTheBreaks(t *testing.T) {
	tr := testTranscript()
	plan := planBreaks(tr)
	if plan.k != 4 || len(plan.offered) != 9 {
		t.Fatalf("k %d, %d offered; want 4 and 9", plan.k, len(plan.offered))
	}
	req := buildPickRequest(tr, plan)
	if !strings.Contains(req.Prompt, "Choose exactly 3 candidates") || !strings.Contains(req.Prompt, "c9 at 0:09:00 (segment s9)") ||
		!strings.Contains(req.Prompt, "[s19 0:19:00]") {
		t.Fatalf("pick prompt:\n%s", req.Prompt)
	}
	enum := req.Schema["properties"].(map[string]any)["breaks"].(map[string]any)["items"].(map[string]any)["enum"].([]string)
	if len(enum) != 9 || enum[0] != "c1" || enum[8] != "c9" {
		t.Fatalf("enum %v", enum)
	}
	// A three-minute episode has two places to break, so three scenes.
	short := Transcript{DurationMs: 180000, Segments: tr.Segments[:3]}
	short.Segments[2].EndMs = 180000
	if p := planBreaks(short); p.k != 3 || len(p.offered) != 2 {
		t.Fatalf("short: k %d, %d offered", p.k, len(p.offered))
	}
	// Two minutes has one, too few for a map.
	short = Transcript{DurationMs: 120000, Segments: tr.Segments[:2]}
	if p := planBreaks(short); len(p.offered) >= MinScenes-1 {
		t.Fatalf("two minutes: %d offered", len(p.offered))
	}
}

func TestCheckPick(t *testing.T) {
	plan := breakPlan{k: 4, offered: []candidate{
		{seg: 3, atMs: 3, score: 0.2}, {seg: 6, atMs: 6, score: 0.9}, {seg: 9, atMs: 9, score: 0.5},
		{seg: 12, atMs: 12, score: 0.7}, {seg: 15, atMs: 15, score: 0.1},
	}}
	answer := func(ids ...string) Response {
		data, _ := json.Marshal(map[string][]string{"breaks": ids})
		return Response{Text: string(data), Complete: true}
	}
	segsOf := func(cs []candidate) string {
		var s []int
		for _, c := range cs {
			s = append(s, c.seg)
		}
		return fmt.Sprint(s)
	}
	for _, c := range []struct {
		name string
		resp Response
		want string // segments, or the reason it can't be used
	}{
		{"exactly k-1, out of order", answer("c4", "c1", "c2"), "[3 6 12]"},
		{"repeats dropped", answer("c2", "c2", "c5"), "[6 15]"},
		{"unknown ids dropped", answer("c2", "c99", "x", "c3"), "[6 9]"},
		{"too many keeps the best scores", answer("c1", "c2", "c3", "c4", "c5"), "[6 9 12]"},
		{"one break", answer("c2"), "1 usable breaks"},
		{"only unknown ids", answer("c6", "c0"), "0 usable breaks"},
		{"none", answer(), "0 usable breaks"},
		{"not JSON", Response{Text: "c1, c2", Complete: true}, "not the expected JSON"},
		{"cut off", Response{Text: answer("c1", "c2", "c3").Text}, "cut off or declined"},
	} {
		got, why := checkPick(plan, c.resp)
		if why == "" {
			why = segsOf(got)
		}
		if why != c.want {
			t.Errorf("%s: %s, want %s", c.name, why, c.want)
		}
	}
}

func TestUnusablePickFallsBackToCodeBreaks(t *testing.T) {
	api := newFakeAPI(t)
	api.pick = func([]string, int) string { return `{"breaks":["c1"]}` }
	svc, _, logs := newService(t, api, 10)
	tr := twoTopics()
	svc.Submit(tr)
	svc.ProcessWaiting(context.Background())
	if api.callCount() != goodCalls || !svc.Store.HasMap(testKey) {
		t.Fatalf("calls %d, map %v", api.callCount(), svc.Store.HasMap(testKey))
	}
	if !containsAny(*logs, "break pick unusable (1 usable breaks); using code's breaks") {
		t.Fatalf("logs %v", *logs)
	}
	var m Map
	data, _ := svc.Store.MapBytes(testKey)
	json.Unmarshal(data, &m)
	// Code's best break, at the topic shift, is one of the scene starts.
	found := false
	for _, sc := range m.Scenes {
		found = found || abs64(sc.StartMs-12*60000) <= 60000
	}
	if len(m.Scenes) != 4 || !found {
		t.Fatalf("scenes %+v", m.Scenes)
	}
}

func TestMapScenesFollowThePick(t *testing.T) {
	api := newFakeAPI(t)
	api.pick = func([]string, int) string { return `{"breaks":["c7","c2","c4"]}` }
	svc, _, _ := newService(t, api, 10)
	svc.Submit(testTranscript())
	svc.ProcessWaiting(context.Background())
	var m Map
	data, _ := svc.Store.MapBytes(testKey)
	json.Unmarshal(data, &m)
	want := [][2]int64{{0, 2}, {2, 4}, {4, 7}, {7, 20}}
	if len(m.Scenes) != len(want) {
		t.Fatalf("scenes %+v", m.Scenes)
	}
	for i, w := range want {
		if m.Scenes[i].StartMs != w[0]*60000 || m.Scenes[i].EndMs != w[1]*60000 {
			t.Fatalf("scene %d = %+v, want %v minutes", i, m.Scenes[i], w)
		}
	}
	// Each scene call saw only its own scene's text.
	third := api.prompt(3)
	if !strings.Contains(third, "Scene 3 of 4, from 0:04:00 to 0:07:00") ||
		!strings.Contains(third, "keeper number 4 ") || !strings.Contains(third, "keeper number 6 ") ||
		strings.Contains(third, "keeper number 3 ") || strings.Contains(third, "keeper number 7 ") {
		t.Fatalf("scene 3 prompt:\n%s", third)
	}
}

func TestSceneRetryNamesTheBrokenRule(t *testing.T) {
	long := sceneJSON("One two three four five six seven eight nine", "Margaret Thatcher visits the keepers.")
	api := newFakeAPI(t, long, goodScene)
	svc, _, logs := newService(t, api, 10)
	svc.Submit(testTranscript())
	svc.ProcessWaiting(context.Background())
	if api.callCount() != goodCalls+1 || !svc.Store.HasMap(testKey) {
		t.Fatalf("calls %d, map %v", api.callCount(), svc.Store.HasMap(testKey))
	}
	first, retry := api.prompt(1), api.prompt(2)
	if !strings.HasPrefix(retry, first) || strings.Contains(first, "previous") {
		t.Fatal("the retry changed the scene part of the prompt, or the first try had a note")
	}
	if note := retry[len(first):]; note != "\n"+sceneRetryHints["title length"]+"\n" {
		t.Fatalf("retry note %q", note)
	}
	// Only the failing scene was retried: scene 2's prompt has no note.
	if strings.Contains(api.prompt(3), "previous") || !strings.Contains(api.prompt(3), "Scene 2 of 4") {
		t.Fatalf("scene 2 prompt:\n%s", api.prompt(3))
	}
	if !containsAny(*logs, "scene 1 attempt 1: title length") {
		t.Fatalf("logs %v", *logs)
	}
	for _, l := range *logs {
		if strings.Contains(l, "Thatcher") || strings.Contains(l, "seven eight") || strings.Contains(l, testKey) {
			t.Fatalf("log leaks text: %q", l)
		}
	}
}

func TestSceneFailingTwiceIsFoldedIntoItsNeighbour(t *testing.T) {
	quote := strings.Join(words(testTranscript().Segments[1].Text)[0:10], " ")
	copied := sceneJSON("Keepers and storms", quote)
	// Scenes start at 0, 5, 7 and 9 minutes.
	run := func(t *testing.T, scenes ...string) (*Service, *[]string, Map) {
		api := newFakeAPI(t, scenes...)
		api.pick = func([]string, int) string { return `{"breaks":["c5","c7","c9"]}` }
		svc, _, logs := newService(t, api, 10)
		svc.Submit(testTranscript())
		svc.ProcessWaiting(context.Background())
		var m Map
		if data, err := svc.Store.MapBytes(testKey); err == nil {
			json.Unmarshal(data, &m)
		}
		return svc, logs, m
	}
	// Scene 2 (5 to 7 minutes) fails twice: scene 1 runs on to 7.
	_, logs, m := run(t, goodScene, copied, copied, goodScene)
	if len(m.Scenes) != 3 || m.Scenes[0].EndMs != 7*60000 || m.Scenes[1].StartMs != 7*60000 {
		t.Fatalf("scenes %+v", m.Scenes)
	}
	if !containsAny(*logs, "folded 1 scenes into a neighbour") {
		t.Fatalf("logs %v", *logs)
	}
	// The first scene failing gives its time to the next one.
	_, _, m = run(t, copied, copied, goodScene)
	if len(m.Scenes) != 3 || m.Scenes[0].StartMs != 0 || m.Scenes[0].EndMs != 7*60000 {
		t.Fatalf("scenes %+v", m.Scenes)
	}
	// Two failing scenes leave two, fewer than MinScenes: no map.
	svc, logs, _ := run(t, copied, copied, copied, copied, goodScene)
	if svc.Store.HasMap(testKey) || svc.Store.HasTranscript(testKey) || !containsAny(*logs, "2 scenes passed") {
		t.Fatalf("map %v, logs %v", svc.Store.HasMap(testKey), *logs)
	}
	// A summary naming someone the scene doesn't, twice, gets its title.
	named := sceneJSON("Keepers and storms", "Margaret Thatcher describes the work of the station keepers in detail.")
	_, logs, m = run(t, named, named, goodScene)
	if len(m.Scenes) != 4 || m.Scenes[0].Summary != "Keepers and storms" || !containsAny(*logs, "replaced 1 summaries with their title") {
		t.Fatalf("scenes %+v, logs %v", m.Scenes, *logs)
	}
}

func TestCheckScene(t *testing.T) {
	tr := testTranscript()
	d := sceneDraft{text: sceneText(tr, 7, 10)}
	grams := copyRuns(tr)
	ok := func(text string) Response { return Response{Text: text, Complete: true} }
	line := func(n int) string { return strings.TrimSpace(strings.Repeat("word ", n)) }
	quote := func(seg, n int) string { return strings.Join(words(tr.Segments[seg].Text)[2:2+n], " ") }
	for _, c := range []struct {
		name string
		resp Response
		want string
	}{
		{"good", ok(goodScene), ""},
		{"cut off", Response{Text: goodScene}, "cut off"},
		{"not JSON", ok(`{"title":`), "no answer"},
		{"empty", ok(sceneJSON(" ", "")), "no answer"},
		{"no title", ok(sceneJSON("", "A summary.")), "title length"},
		{"eight-word title", ok(sceneJSON(line(8), "A summary.")), ""},
		{"nine-word title", ok(sceneJSON(line(9), "A summary.")), "title length"},
		{"81-character title", ok(sceneJSON(strings.Repeat("t", 81), "A summary.")), "title length"},
		{"25-word summary", ok(sceneJSON("Title", line(25))), ""},
		{"26-word summary", ok(sceneJSON("Title", line(26))), "summary length"},
		{"301-character summary", ok(sceneJSON("Title", strings.Repeat("s", 301))), "summary length"},
		{"name from another scene", ok(sceneJSON("Title", "The host thanks Margaret for the tip.")), "ungrounded name"},
		{"seven copied words", ok(sceneJSON("Title", quote(8, 7))), ""},
		{"eight copied words", ok(sceneJSON("Title", quote(8, 8))), "copied words"},
		{"copied from another scene", ok(sceneJSON("Title", quote(1, 8))), "copied words"},
		{"copied in the title", ok(sceneJSON(quote(8, 8), "A summary.")), "copied words"},
	} {
		if got := checkScene("en", &d, c.resp, grams); got != c.want {
			t.Errorf("%s: %q, want %q", c.name, got, c.want)
		}
		if c.want != "" && sceneRetryHints[c.want] == "" {
			t.Errorf("%s: rule %q has no retry hint", c.name, c.want)
		}
	}
}

func TestCapHoldsMidEpisode(t *testing.T) {
	// The cap leaves room for the pick and two scenes, but not the third:
	// the worker stops there and makes no map. pickFirst starts scenes at
	// 0, 1, 2 and 3 minutes.
	api := newFakeAPI(t)
	svc, _, logs := newService(t, api, 10)
	tr := testTranscript()
	second := sceneDraft{startMs: 60000, endMs: 120000, text: sceneText(tr, 1, 2)}
	svc.CapMicroUSD = 2*23000 + svc.estimate(buildSceneRequest(second, 1, 4))
	svc.Store.PutTranscript(tr, svc.Now())
	svc.ProcessWaiting(context.Background())
	if api.callCount() != 3 || svc.Store.HasMap(testKey) || svc.Store.HasTranscript(testKey) {
		t.Fatalf("calls %d, map %v", api.callCount(), svc.Store.HasMap(testKey))
	}
	if !containsAny(*logs, "monthly cap reached") {
		t.Fatalf("logs %v", *logs)
	}
}

func TestCapitalisesNouns(t *testing.T) {
	for lang, want := range map[string]bool{
		"de": true, "de-DE": true, "de-AT": true, "de-CH": true, "DE": true, "gsw": true, "lb": true, "bar": true,
		"en": false, "en-US": false, "nl": false, "da": false, "": false, "dex": false,
	} {
		if got := capitalisesNouns(lang); got != want {
			t.Errorf("%q: %v, want %v", lang, got, want)
		}
	}
}

// German capitalises every noun, so a capital doesn't mark a name there
// (#2075: the plain rule refused 151 of 159 German bench scenes).
func TestGermanNameCheck(t *testing.T) {
	source := "Heute reden wir über künstliche Intelligenz und die Europäische Union. Später kommt YouTube dran, und die NATO."
	cases := []struct {
		summary string
		want    string
	}{
		// Role and format nouns, the bench's main false alarm.
		{"Der Gast erzählt dem Moderator von seiner Arbeit.", ""},
		{"Die Sprecher diskutieren mit ihrem Gesprächspartner.", ""},
		{"In dieser Runde stellt der Host die neue Folge vor.", ""},
		{"Die Gäste sprechen über Ernährung und Gesundheit im Alltag.", ""},
		// Other common nouns, often compounds.
		{"Das Gespräch dreht sich um Klimaschutz und Energiepolitik.", ""},
		// Acronyms are checked: grounded by initials, by the word, or not at all.
		{"Die KI verändert die Arbeit in der EU.", ""},
		{"Die NATO und ihre Rolle.", ""},
		{"Die CDU stellt ihr Programm vor.", "CDU"},
		{"Was die USA davon halten.", "USA"},
		// Inner capitals mark a brand or name, which a noun never has.
		{"Der Gast spricht über YouTube.", ""},
		{"Eine Studie von McKinsey wird besprochen.", "McKinsey"},
		{"Ein Blick auf DeepMind und seine Modelle.", "DeepMind"},
		// The cost: an ordinary name isn't checked in German. In the
		// bench's German data none of the flagged words was a real name.
		{"Angela Merkel trifft den Gast.", ""},
		{"Der Gast trifft Angela Merkel.", ""},
	}
	for _, c := range cases {
		if got := ungroundedName(c.summary, source, "de"); got != c.want {
			t.Errorf("de %q: got %q, want %q", c.summary, got, c.want)
		}
	}
	for _, lang := range []string{"de-DE", "de-AT", "gsw"} {
		if got := ungroundedName("Die CDU und der Gast.", source, lang); got != "CDU" {
			t.Errorf("%s: got %q, want CDU", lang, got)
		}
		if got := ungroundedName("Die Runde und der Gast.", source, lang); got != "" {
			t.Errorf("%s: got %q, want no name", lang, got)
		}
	}
	// English is unchanged: every capitalised word mid-sentence is checked.
	english := "Today the host talks about lighthouses."
	for summary, want := range map[string]string{
		"The host meets Angela Merkel.":   "Angela",
		"A talk with the Gast.":           "Gast",
		"The host explains why AI helps.": "AI",
		"The host describes lighthouses.": "",
	} {
		if got := ungroundedName(summary, english, "en"); got != want {
			t.Errorf("en %q: got %q, want %q", summary, got, want)
		}
	}
}
