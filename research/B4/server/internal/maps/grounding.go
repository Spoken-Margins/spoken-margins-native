package maps

import (
	"strings"
	"unicode"
)

// These mirror the phone's ListeningMapSummaryValidator (the title word limit,
// and the rule that a capitalised name in a summary must appear in the
// scene's own text), so a community map meets the same standard as one made
// on the device.
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

// ungroundedName returns the first capitalised name in summary that is not a
// word of source, or "".
func ungroundedName(summary, source string) string {
	known := map[string]bool{}
	for _, w := range words(source) {
		known[w] = true
	}
	for _, name := range capitalisedNames(summary) {
		if !known[strings.ToLower(name)] {
			return name
		}
	}
	return ""
}
