package maps

import (
	"strings"
	"unicode"
)

// These follow the phone's ListeningMapSummaryValidator (the title word limit,
// and the rule that a capitalised name in a summary must appear in the
// source), so a community map meets nearly the same standard as one made on
// the device. The source is the scene's own text: stage 2 shows the model
// nothing else, so a name from anywhere else is a guess.
//
// One difference: in a language that capitalises every noun, a capital
// doesn't mark a name, so only acronyms and words with a capital inside
// them ("YouTube", "McKinsey") are checked. In German the plain rule
// refused 151 of 159 bench scenes, nearly all for role nouns like "Gast"
// and "Sprecher"; this one passes 158 to 159 (#2075).
const MaxTitleWords = 8

var nameAbbreviations = map[string]bool{
	"mr": true, "mrs": true, "ms": true, "dr": true, "prof": true, "st": true,
	"sen": true, "rep": true, "gov": true, "gen": true, "jr": true, "sr": true,
}

// capitalisesNouns reports whether lang, a BCP 47 tag, writes every noun
// with a capital: German and the languages written like it (Swiss German,
// Luxembourgish, Bavarian).
func capitalisesNouns(lang string) bool {
	primary, _, _ := strings.Cut(strings.ToLower(lang), "-")
	switch primary {
	case "de", "gsw", "lb", "bar":
		return true
	}
	return false
}

// capitalisedNames returns capitalised tokens of two or more letters that
// don't start a sentence, with a possessive "'s" removed. A name made of
// several capitalised parts ("McDonald-Smith") yields each part. With
// nounsCapitalised set, for a language that capitalises nouns, it keeps only the
// parts a common noun can't be: acronyms and words with an inner capital.
func capitalisedNames(text string, nounsCapitalised bool) []string {
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
			if r := []rune(part); len(r) >= 2 && unicode.IsUpper(r[0]) &&
				(!nounsCapitalised || isAcronym(part) || hasInnerCapital(part)) {
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
// "artificial intelligence"), or in the singular ("LLMs" and "LLM"). lang is
// the transcript's language; see capitalisesNouns.
func ungroundedName(summary, source, lang string) string {
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
	for _, name := range capitalisedNames(summary, capitalisesNouns(lang)) {
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

// hasInnerCapital reports whether a word has a capital after a lowercase
// letter ("YouTube", "McKinsey"), which a German common noun never does.
func hasInnerCapital(word string) bool {
	r := []rune(word)
	for i := 1; i < len(r); i++ {
		if unicode.IsUpper(r[i]) && unicode.IsLower(r[i-1]) {
			return true
		}
	}
	return false
}
