//go:build mapbench

package maps

// Hooks for the offline scene-break bench (cmd/mapbench, #2075). They only
// re-export what the worker already uses, so the bench judges answers with
// the server's own checks. The build tag keeps them out of smserver.

// BenchSystemPrompt is the system prompt the worker sends.
const BenchSystemPrompt = systemPrompt

// BenchBuildRequest is the request the worker builds for a transcript.
func BenchBuildRequest(t Transcript) Request { return buildRequest(t) }

// BenchRepairs is what checkAnswer fixed rather than refused.
type BenchRepairs = Repairs

// BenchCheckAnswer runs the worker's answer check, repairs included.
func BenchCheckAnswer(t Transcript, text string) ([]Scene, Repairs, error) {
	return checkAnswer(t, text)
}

// BenchUngroundedName is the name-grounding check: the first capitalised
// name in text that source never says, or "".
func BenchUngroundedName(text, source string) string { return ungroundedName(text, source) }

// BenchWords is the check's word splitter.
func BenchWords(text string) []string { return words(text) }
