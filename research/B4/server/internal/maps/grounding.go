package maps

import (
	"strings"
	"unicode"
)

// These follow the phone's ListeningMapSummaryValidator (the title word limit,
// and the rule that a capitalised name in a summary must appear in the
// source), so a community map meets nearly the same standard as one made on
// the device. The server's source is a little wider: the scene and its two
// neighbours, since the model, not the phone, drew the scene's edges.
const MaxTitleWords = 8

var nameAbbreviations = map[string]bool{
	"mr": true, "mrs": true, "ms": true, "dr": true, "prof": true, "st": true,
	"sen": true, "rep": true, "gov": true, "gen": true, "jr": true, "sr": true,
}

// capitalisedNames returns capitalised tokens of two or more letters that
// don't start a sentence, with a possessive "'s" removed. A name made of
// several capitalised parts ("McDonald-Smith") yields each part.
func capitalisedNames(text string) []string {
	var names []string
	sentenceStart := true
	for _, token := range strings.Fields(text) {
		core := token
		for _, suffix := range []string{"'s", "’s"} {
			core = strings.TrimSuffix(core, suffix)
		}
		core = strings.TrimFunc(core, func(r rune) bool { return !unicode.IsLetter(r) })
		startsSentence := sentenceStart
		last := token[len(token)-1]
		sentenceStart = (last == '.' || last == '!' || last == '?') && !nameAbbreviations[strings.ToLower(core)]
		if startsSentence || len([]rune(core)) < 2 {
			continue
		}
		if first := []rune(core)[0]; !unicode.IsUpper(first) {
			continue
		}
		for _, part := range strings.FieldsFunc(core, func(r rune) bool { return !unicode.IsLetter(r) }) {
			if r := []rune(part); len(r) >= 2 && unicode.IsUpper(r[0]) {
				names = append(names, part)
			}
		}
	}
	return names
}

// maxInitialism is the longest run of source words whose initials an
// all-capital name may spell ("AI" for "artificial intelligence").
const maxInitialism = 6

// ungroundedName returns the first capitalised name in summary that is not a
// word of source, or "". An acronym counts as grounded when source has it in
// dotted form ("AI" and "A.I."), as the initials of words in a row ("AI" and
// "artificial intelligence"), or in the singular ("LLMs" and "LLM").
func ungroundedName(summary, source string) string {
	known := map[string]bool{}
	for _, w := range words(source) {
		known[w] = true
	}
	for _, token := range strings.Fields(source) {
		// "A.I." splits into "a" and "i"; joined, it is "ai".
		known[strings.Join(words(token), "")] = true
	}
	initials := map[string]bool{}
	sourceWords := words(source)
	for i := range sourceWords {
		var b strings.Builder
		for j := i; j < len(sourceWords) && j-i < maxInitialism; j++ {
			b.WriteRune([]rune(sourceWords[j])[0])
			if j > i {
				initials[b.String()] = true
			}
		}
	}
	grounded := func(name string) bool {
		lower := strings.ToLower(name)
		if known[lower] {
			return true
		}
		if !isAcronym(name) {
			return false
		}
		stem := strings.TrimSuffix(lower, "s")
		return initials[lower] || (strings.HasSuffix(name, "s") && (known[stem] || initials[stem]))
	}
	for _, name := range capitalisedNames(summary) {
		if !grounded(name) {
			return name
		}
	}
	return ""
}

// isAcronym reports whether name is all capitals, allowing a plural "s"
// ("NASA", "LLMs").
func isAcronym(name string) bool {
	r := []rune(strings.TrimSuffix(name, "s"))
	if len(r) < 2 {
		return false
	}
	for _, c := range r {
		if !unicode.IsUpper(c) && !unicode.IsDigit(c) {
			return false
		}
	}
	return true
}
