import datetime as dt
import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
import claude_sessions
import usage

# Usage of one real Test Desk request (Claude Code 2.1.288, 2026-10-12), numbers only. The transcript
# writes one line per content block, each repeating the request's usage; an early streamed block can
# carry a partial output count (6 here, 217 final), as 52 requests did on the Mac that week.
REAL = {'input_tokens': 2, 'cache_creation_input_tokens': 33489, 'cache_read_input_tokens': 38793,
        'output_tokens': 217, 'cache_creation': {'ephemeral_1h_input_tokens': 33489, 'ephemeral_5m_input_tokens': 0}}


def prompt(time, text='next pass', position=True, **extra):
    event = {'type': 'user', 'timestamp': time, 'promptId': 'p-' + time, 'cwd': '/w/spoken-margins-native',
             'entrypoint': 'claude-desktop', 'message': {'role': 'user', 'content': text}}
    if position:
        event['turnPosition'] = {'promptIndex': 1, 'turnIndex': 1}
    event.update(extra)
    return event


def reply(time, request, values=None, stop='end_turn', content=None, model='claude-opus-5-5', **extra):
    event = {'type': 'assistant', 'timestamp': time, 'requestId': request, 'entrypoint': 'claude-desktop',
             'message': {'id': 'msg-' + request, 'model': model, 'stop_reason': stop,
                         'content': content or [{'type': 'text', 'text': 'done'}],
                         'usage': dict(REAL) if values is None else values}}
    event.update(extra)
    return event


def tool_call(time, request, call, command):
    return reply(time, request, stop='tool_use',
                 content=[{'type': 'tool_use', 'id': call, 'name': 'Bash', 'input': {'command': command}}])


def tool_output(time, call, text):
    return {'type': 'user', 'timestamp': time, 'promptId': 'same-turn',
            'message': {'content': [{'type': 'tool_result', 'tool_use_id': call, 'content': text}]}}


class ClaudeSessionTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.projects = Path(self.tmp.name)

    def session(self, events, name='s1', folder='-w-spoken-margins-native', subagents=None):
        path = self.projects / folder / f'{name}.jsonl'
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(''.join(json.dumps(e) + '\n' for e in events))
        for agent, agent_events in (subagents or {}).items():
            sub = path.parent / name / 'subagents' / f'{agent}.jsonl'
            sub.parent.mkdir(parents=True, exist_ok=True)
            sub.write_text(''.join(json.dumps(e) + '\n' for e in agent_events))
        return path

    def turns(self, **kwargs):
        return [row for row in claude_sessions.collect(self.projects, **kwargs) if row['kind'] == 'turn']

    def test_repeated_blocks_and_streamed_partials_count_once(self):
        partial = dict(REAL, output_tokens=6)
        self.session([prompt('2026-10-12T00:41:10Z'),
                      reply('2026-10-12T00:41:16Z', 'r1', partial, stop=None),
                      reply('2026-10-12T00:41:17Z', 'r1'),
                      reply('2026-10-12T00:41:17Z', 'r1', partial)])
        [row] = self.turns()
        self.assertEqual(row['requests'], 1)
        # As in usage.read_usage: input is all three input counts; cached input is the cache read.
        self.assertEqual(row['input_tokens'], 2 + 33489 + 38793)
        self.assertEqual(row['cached_input_tokens'], 38793)
        self.assertEqual(row['output_tokens'], 217)
        self.assertEqual(row['raw_usage']['cache_creation_1h_input_tokens'], 33489)
        self.assertTrue(row['usage_complete'])

    def test_subagent_requests_join_the_turn_their_time_falls_in(self):
        self.session([prompt('2026-10-12T01:00:00Z'), reply('2026-10-12T01:00:05Z', 'm1'),
                      prompt('2026-10-12T02:00:00Z'), reply('2026-10-12T02:00:05Z', 'm2')],
                     subagents={'agent-a': [reply('2026-10-12T01:30:00Z', 'a1'),
                                            reply('2026-10-12T02:30:00Z', 'a2'),
                                            reply('2026-10-12T02:31:00Z', 'a3')]})
        first, second = self.turns()
        self.assertEqual((first['requests'], first['subagent_requests']), (2, 1))
        self.assertEqual((second['requests'], second['subagent_requests']), (3, 2))

    def test_turns_follow_turn_position_and_fall_back_for_old_transcripts(self):
        self.session([prompt('2026-10-12T01:00:00Z'), reply('2026-10-12T01:00:01Z', 'm1'),
                      # Skill text and a compaction summary belong to the running turn.
                      prompt('2026-10-12T01:00:02Z', 'Base directory for this skill', position=False),
                      prompt('2026-10-12T01:00:03Z', 'continued', position=True, isCompactSummary=True),
                      prompt('2026-10-12T01:30:00Z', '<loop wake>', isMeta=True),
                      reply('2026-10-12T01:30:01Z', 'm2')])
        old = [{'type': 'user', 'timestamp': '2026-10-12T03:00:00Z', 'message': {'content': 'hi'}},
               reply('2026-10-12T03:00:01Z', 'o1'),
               {'type': 'user', 'timestamp': '2026-10-12T03:00:02Z', 'isMeta': True, 'message': {'content': 'x'}},
               {'type': 'user', 'timestamp': '2026-10-12T03:01:00Z', 'message': {'content': 'again'}},
               reply('2026-10-12T03:01:01Z', 'o2')]
        self.session(old, name='s2')
        counts = {}
        for row in self.turns():
            counts[row['session_id']] = counts.get(row['session_id'], 0) + 1
        self.assertEqual(counts, {'s1': 2, 's2': 2})

    def test_jobs_come_from_the_scheduled_tag_the_folder_or_the_entrypoint(self):
        self.session([prompt('2026-10-12T01:00:00Z', '<scheduled-task name="sm-mac-tick" file="x">'),
                      reply('2026-10-12T01:00:01Z', 't1')], name='tick')
        # The finisher's cwd moved after it opened; the transcript folder still names it.
        self.session([prompt('2026-10-12T01:00:00Z'), reply('2026-10-12T01:00:01Z', 'f1')], name='fin',
                     folder='-w-spoken-margins-native-finisher')
        self.session([prompt('2026-10-12T01:00:00Z', entrypoint='sdk-cli'),
                      reply('2026-10-12T01:00:01Z', 'h1')], name='head', folder='-tmp')
        self.session([prompt('2026-10-12T01:00:00Z'), reply('2026-10-12T01:00:01Z', 'o1')], name='other')
        jobs = {row['session_id']: row['job'] for row in self.turns()}
        self.assertEqual(jobs, {'tick': 'scheduled:sm-mac-tick', 'fin': 'finisher',
                                'head': 'headless', 'other': 'desktop-other'})

    def test_a_session_a_wrapper_already_counted_is_skipped(self):
        self.session([prompt('2026-10-12T01:00:00Z', entrypoint='sdk-cli'), reply('2026-10-12T01:00:01Z', 'h1')],
                     name='abc', folder='-tmp')
        ledger = self.projects / 'usage.jsonl'
        transcript = self.projects / 'result.jsonl'
        transcript.write_text(json.dumps({'type': 'result', 'session_id': 'abc', 'is_error': False,
                                          'usage': REAL}) + '\n')
        ledger.write_text(json.dumps(dict(usage.read_usage(transcript), run_id='w1')) + '\n')
        self.assertEqual(claude_sessions.collect(self.projects, wrapped=claude_sessions.wrapper_sessions(ledger)), [])
        self.assertEqual(len(self.turns()), 1)

    def test_failed_interrupted_unfinished_and_compacted_turns_are_incomplete(self):
        self.session([
            prompt('2026-10-12T01:00:00Z'), tool_call('2026-10-12T01:00:01Z', 'a', 'c1', 'ls'),
            prompt('2026-10-12T01:10:00Z'),  # the turn before ended on a tool call and was followed: complete
            reply('2026-10-12T01:10:01Z', 'b'),
            {'type': 'assistant', 'timestamp': '2026-10-12T01:10:02Z', 'isApiErrorMessage': True,
             'message': {'id': 'syn', 'model': '<synthetic>', 'content': [{'type': 'text', 'text': 'API Error: 529'}],
                         'usage': {'input_tokens': 0, 'output_tokens': 0}}},
            prompt('2026-10-12T01:20:00Z'), reply('2026-10-12T01:20:01Z', 'c', stop='tool_use'),
            {'type': 'user', 'timestamp': '2026-10-12T01:20:02Z',
             'message': {'content': [{'type': 'text', 'text': '[Request interrupted by user for tool use]'}]}},
            prompt('2026-10-12T01:30:00Z'), reply('2026-10-12T01:30:01Z', 'd'),
            {'type': 'system', 'subtype': 'compact_boundary', 'timestamp': '2026-10-12T01:30:02Z'},
            reply('2026-10-12T01:30:03Z', 'e'),
            prompt('2026-10-12T01:40:00Z'), tool_call('2026-10-12T01:40:01Z', 'f', 'c2', 'sleep 1'),
        ])
        rows = self.turns()
        self.assertEqual([r['outcome']['kind'] for r in rows],
                         ['completed', 'failed', 'interrupted', 'completed', 'unfinished'])
        self.assertEqual([r['usage_complete'] for r in rows], [True, False, False, False, False])
        self.assertEqual(rows[1]['requests'], 1)  # the synthetic error message is not an API request
        self.assertIn('compaction', rows[3]['usage_missing_reason'])

    def test_only_what_gh_printed_when_posting_is_an_outcome_link(self):
        url = 'https://github.com/o/r/pull/12#issuecomment-5'
        self.session([prompt('2026-10-12T01:00:00Z'),
                      tool_call('2026-10-12T01:00:01Z', 'a', 'c1', 'gh pr comment 12 --body-file x.md'),
                      tool_output('2026-10-12T01:00:02Z', 'c1', url + '\n'),
                      tool_call('2026-10-12T01:00:03Z', 'b', 'c2', 'gh issue view 40'),
                      tool_output('2026-10-12T01:00:04Z', 'c2', 'see https://github.com/o/r/issues/40'),
                      reply('2026-10-12T01:00:05Z', 'c')])
        [row] = self.turns()
        self.assertEqual(row['outcome_links'], [url])
        self.assertEqual(row['targets'], [{'pr': 12}])
        self.assertIsNone(row['attribution_missing_reason'])

    def test_a_bad_file_is_reported_and_the_rest_still_collected(self):
        self.session([prompt('2026-10-12T01:00:00Z'), reply('2026-10-12T01:00:01Z', 'a')], name='good')
        bad = self.session([prompt('2026-10-12T01:00:00Z')], name='bad')
        with bad.open('a') as handle:
            handle.write('{not json\n')
        errors = []
        rows = [r for r in claude_sessions.collect(self.projects, errors=errors) if r['kind'] == 'turn']
        self.assertEqual(sorted(r['session_id'] for r in rows), ['bad', 'good'])
        self.assertEqual(len(errors), 1)
        self.assertIn('unreadable line', errors[0])

    def test_since_keeps_later_turns_and_their_session_check(self):
        self.session([prompt('2026-10-04T23:00:00Z'), reply('2026-10-04T23:00:01Z', 'a'),
                      prompt('2026-10-05T01:00:00Z'), reply('2026-10-05T01:00:01Z', 'b')])
        rows = claude_sessions.collect(self.projects, since=dt.datetime(2026, 10, 5, tzinfo=dt.timezone.utc))
        self.assertEqual([(r['kind'], r.get('turn')) for r in rows], [('turn', 1), ('session-check', None)])

    def test_store_replaces_a_turn_that_was_still_running(self):
        ledger = self.projects / 'out' / 'claude-usage.jsonl'
        self.session([prompt('2026-10-12T01:00:00Z'), tool_call('2026-10-12T01:00:01Z', 'a', 'c1', 'ls')])
        claude_sessions.store(ledger, claude_sessions.collect(self.projects))
        path = self.session([prompt('2026-10-12T01:00:00Z'), tool_call('2026-10-12T01:00:01Z', 'a', 'c1', 'ls'),
                             reply('2026-10-12T01:00:05Z', 'b')])
        self.assertTrue(path.exists())
        claude_sessions.store(ledger, claude_sessions.collect(self.projects))
        rows = [json.loads(line) for line in ledger.read_text().splitlines()]
        turn = [r for r in rows if r['kind'] == 'turn']
        self.assertEqual(len(rows), 2)
        self.assertEqual((turn[0]['requests'], turn[0]['outcome']['kind']), (2, 'completed'))

    def test_coverage_compares_only_final_client_totals(self):
        cost = {'type': 'cost-state', 'modelUsage': {'claude-opus-5-5[1m]': {
            'inputTokens': 10, 'cacheCreationInputTokens': 33489, 'cacheReadInputTokens': 38793, 'outputTokens': 217}}}
        self.session([prompt('2026-10-12T01:00:00Z'), reply('2026-10-12T01:00:01Z', 'a'), cost], name='final')
        self.session([prompt('2026-10-12T01:00:00Z'), cost, reply('2026-10-12T01:00:01Z', 'b')], name='stale')
        result = claude_sessions.coverage(claude_sessions.collect(self.projects))
        written = 2 + 33489 + 38793 + 217
        self.assertEqual((result['sessions'], result['sessions_compared']), (2, 1))
        self.assertEqual((result['transcript_tokens'], result['client_reported_tokens']), (written, written + 8))
        self.assertEqual(result['transcript_share'], round(written / (written + 8), 4))
        self.assertEqual(result['client_only_models'], [])


if __name__ == '__main__':
    unittest.main()
