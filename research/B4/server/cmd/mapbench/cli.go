//go:build mapbench

package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"sync"
	"time"

	"spokenmargins.dev/bridge/internal/maps"
)

// The server's prices for Claude Haiku 5.5, dollars per million tokens.
var serverPrices = maps.Prices{InputPerMTok: 0.10, OutputPerMTok: 0.50}

// Call is one model call as the bench records it. No prompt or answer text.
type Call struct {
	Purpose      string  `json:"purpose"`
	Effort       string  `json:"effort"`
	InputTokens  int64   `json:"inputTokens"`
	OutputTokens int64   `json:"outputTokens"`
	Thinking     int64   `json:"thinkingTokens"`
	MicroUSD     int64   `json:"microUSD"`
	PlanUSD      float64 `json:"planListUSD"`
	Ms           int64   `json:"ms"`
	OK           bool    `json:"ok"`
}

// Spend keeps the bench under its budget, at the server's prices.
type Spend struct {
	mu       sync.Mutex
	budget   int64
	spent    int64
	reserved int64
}

var errBudget = errors.New("budget would be passed")

func (s *Spend) reserve(estimate int64) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.spent+s.reserved+estimate > s.budget {
		return errBudget
	}
	s.reserved += estimate
	return nil
}

func (s *Spend) settle(estimate, actual int64) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.reserved -= estimate
	s.spent += actual
}

func (s *Spend) Spent() int64 {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.spent
}

// CLI calls Claude Haiku 5.5 through the Claude Code CLI on the owner's plan
// (no API key on this Mac). The request's system prompt replaces Claude
// Code's, tools are off and the answer comes back through --json-schema, so
// the model sees the server's prompt plus about 800 tokens of CLI wrapping.
type CLI struct {
	Path    string
	Token   string
	Model   string
	Effort  string
	Dir     string // an empty working directory
	Spend   *Spend
	Slots   chan struct{}
	Purpose string

	mu    sync.Mutex
	Calls []Call
}

func (c *CLI) Generator() string { return "bench/" + c.Model }

// Generate satisfies maps.Provider, so the server's own worker can run on it.
func (c *CLI) Generate(ctx context.Context, req maps.Request) (maps.Response, error) {
	text, call, err := c.Call(ctx, req.System, req.Prompt, req.Schema, c.Purpose)
	if err != nil {
		return maps.Response{}, err
	}
	return maps.Response{Text: text, InputTokens: call.InputTokens, OutputTokens: call.OutputTokens, Complete: call.OK}, nil
}

func (c *CLI) WithPurpose(p string) *CLI {
	return &CLI{Path: c.Path, Token: c.Token, Model: c.Model, Effort: c.Effort, Dir: c.Dir, Spend: c.Spend, Slots: c.Slots, Purpose: p}
}

func (c *CLI) WithEffort(e string) *CLI {
	d := c.WithPurpose(c.Purpose)
	d.Effort = e
	return d
}

// Call runs one prompt and returns the structured answer as JSON text.
func (c *CLI) Call(ctx context.Context, system, prompt string, schema map[string]any, purpose string) (string, Call, error) {
	// A high guess: three bytes a token in, 4,000 tokens out.
	// Wait for a slot first: a call queued for a slot must not hold budget.
	c.Slots <- struct{}{}
	defer func() { <-c.Slots }()
	estimate := serverPrices.Cost(int64(len(system)+len(prompt))/3+1500, 4000)
	if err := c.Spend.reserve(estimate); err != nil {
		return "", Call{}, err
	}
	actual := int64(0)
	defer func() { c.Spend.settle(estimate, actual) }()

	schemaJSON, err := json.Marshal(schema)
	if err != nil {
		return "", Call{}, err
	}
	args := []string{"-p", "-", "--output-format", "json", "--model", c.Model, "--effort", c.Effort,
		"--system-prompt", system, "--exclude-dynamic-system-prompt-sections",
		"--tools", "", "--strict-mcp-config", "--setting-sources", "", "--no-session-persistence",
		"--max-budget-usd", "1", "--json-schema", string(schemaJSON)}
	started := time.Now()
	cmd := exec.CommandContext(ctx, c.Path, args...)
	cmd.Dir = c.Dir
	cmd.Stdin = strings.NewReader(prompt)
	cmd.Env = append(os.Environ(), "CLAUDE_CODE_OAUTH_TOKEN="+c.Token)
	var out, errOut bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &errOut
	runErr := cmd.Run()
	call := Call{Purpose: purpose, Effort: c.Effort, Ms: time.Since(started).Milliseconds()}
	var r struct {
		IsError          bool            `json:"is_error"`
		StructuredOutput json.RawMessage `json:"structured_output"`
		TotalCostUSD     float64         `json:"total_cost_usd"`
		Usage            struct {
			InputTokens         int64 `json:"input_tokens"`
			CacheCreation       int64 `json:"cache_creation_input_tokens"`
			CacheRead           int64 `json:"cache_read_input_tokens"`
			OutputTokens        int64 `json:"output_tokens"`
			OutputTokensDetails struct {
				Thinking int64 `json:"thinking_tokens"`
			} `json:"output_tokens_details"`
		} `json:"usage"`
	}
	if err := json.Unmarshal(out.Bytes(), &r); err != nil {
		c.record(call)
		msg := strings.TrimSpace(errOut.String())
		if len(msg) > 200 {
			msg = msg[:200]
		}
		return "", call, fmt.Errorf("cli: %v: %s", runErr, msg)
	}
	call.InputTokens = r.Usage.InputTokens + r.Usage.CacheCreation + r.Usage.CacheRead
	call.OutputTokens = r.Usage.OutputTokens
	call.Thinking = r.Usage.OutputTokensDetails.Thinking
	call.MicroUSD = serverPrices.Cost(call.InputTokens, call.OutputTokens)
	call.PlanUSD = r.TotalCostUSD
	call.OK = !r.IsError && len(r.StructuredOutput) > 0 && string(r.StructuredOutput) != "null"
	actual = call.MicroUSD
	c.record(call)
	if !call.OK {
		return "", call, nil
	}
	return string(r.StructuredOutput), call, nil
}

func (c *CLI) record(call Call) {
	c.mu.Lock()
	c.Calls = append(c.Calls, call)
	c.mu.Unlock()
}

func (c *CLI) Taken() []Call {
	c.mu.Lock()
	defer c.mu.Unlock()
	return append([]Call(nil), c.Calls...)
}

func keychainToken() (string, error) {
	out, err := exec.Command("security", "find-generic-password", "-s", "claude-code-oauth", "-w").Output()
	if err != nil {
		return "", fmt.Errorf("no Claude token in the Keychain (claude-code-oauth): %w", err)
	}
	return strings.TrimSpace(string(out)), nil
}
