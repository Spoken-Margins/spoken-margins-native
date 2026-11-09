"""scripts/system_callback_isolation.py: main-actor closures handed to off-main system callbacks (#3513).

Each case is one neighbouring shape of the class and says whether it is a row. The tree check is the guard; the
pre-fix shapes of the Watch reply (#2964) and the remote-command handlers (#3513) are rows here, so the check
fails if either comes back.
"""
import sys
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
import system_callback_isolation as sci  # noqa: E402


TREE = None


def tree_rows():
    global TREE
    if TREE is None:
        TREE = sci.scan(sci.tree_sources())
    return TREE


def rows(source):
    return [(api, problem) for _, _, api, problem in sci.scan([('App/X/Sources/X.swift', source)])]


class SystemCallbackIsolationTests(unittest.TestCase):
    def test_the_tree_has_no_unallowed_row(self):
        bad = sci.unallowed(tree_rows())
        self.assertEqual(bad, [], '\n'.join(f'{p}:{n}: {a}: {m}' for p, n, a, m in bad))

    def test_every_allowance_still_names_a_row(self):
        seen = {(path, api) for path, _, api, _ in tree_rows()}
        self.assertEqual(sorted(set(sci.ALLOWED) - seen), [], 'a stale ALLOWED entry: remove it')

    def test_the_watch_reply_before_its_fix_is_a_row(self):
        before = ('WCSession.default.sendMessage(wrapped.dictionary, replyHandler: { [weak self] dictionary in\n'
                  '    Task { @MainActor in self?.apply(dictionary) }\n'
                  '}, errorHandler: nil)\n')
        self.assertEqual(rows(before), [('WCSession.sendMessage', 'the replyHandler closure is not `@Sendable`')])
        self.assertEqual(rows(before.replace('{ [weak self]', '{ @Sendable [weak self]')), [])

    def test_the_remote_command_handlers_before_their_fix_are_rows(self):
        before = ('let target = remoteCommand.addTarget { [weak self] _ in\n'
                  '    Task { @MainActor [weak self] in self?.run() }\n'
                  '    return .success\n'
                  '}\n')
        self.assertEqual(len(rows(before)), 1)
        self.assertEqual(rows(before.replace('{ [weak self] _ in', '{ @Sendable [weak self] _ in')), [])
        self.assertEqual(len(rows('remote.addTarget(handler: { _ in .success })')), 1)
        self.assertEqual(rows('remote.addTarget(handler: { @Sendable _ in .success })'), [])

    def test_a_handler_that_is_not_a_literal_is_a_row(self):
        self.assertEqual(rows('let t = command.addTarget(handler: handler)'),
                         [('MPRemoteCommand.addTarget(handler:)', '`handler:` is not a closure literal, so its isolation is unseen')])

    def test_neighbours_that_are_not_the_class(self):
        self.assertEqual(rows('button.addTarget(self, action: #selector(close), for: .touchUpInside)'), [])
        self.assertEqual(rows('session.sendMessage(message, replyHandler: nil, errorHandler: nil)'), [])
        self.assertEqual(rows('// remote.addTarget { _ in .success }\nlet s = "x.sendMessage(m) { e in }"'), [])
        self.assertEqual(rows('/* MPMediaItemArtwork(boundsSize: s) { _ in image } */'), [])
        self.assertEqual(rows('let a = #"he said "x.addTarget { _ in .success }" "#'), [])
        self.assertEqual(rows('let a = """\n  x.addTarget { _ in .success }\n  """'), [])
        self.assertEqual(len(rows('let a = #"\\"#; remote.addTarget { _ in .success }')), 1)

    def test_an_allowance_covers_only_its_count(self):
        path, api = next(iter(sci.ALLOWED))
        count = sci.ALLOWED[(path, api)][0]
        same = [(path, n, api, 'x') for n in range(count)]
        self.assertEqual(sci.unallowed(same), [])
        self.assertEqual(len(sci.unallowed(same + [(path, 999, api, 'x')])), count + 1)

    def test_background_task_launch_handler_off_main(self):
        call = 'BGTaskScheduler.shared.register(forTaskWithIdentifier: id, using: nil) { task in self.run(task) }'
        self.assertEqual(len(rows(call)), 1)
        self.assertEqual(rows(call.replace('using: nil', 'using: .main')), [])
        self.assertEqual(rows(call.replace('{ task in', '{ @Sendable task in')), [])

    def test_record_permission_callback(self):
        self.assertEqual(len(rows('AVAudioApplication.requestRecordPermission { granted in self.granted = granted }')), 1)
        self.assertEqual(rows('AVAudioApplication.requestRecordPermission { @Sendable granted in c.resume(returning: granted) }'), [])
        self.assertEqual(rows('let ok = await AVAudioApplication.requestRecordPermission()'), [])

    def test_both_closures_of_send_message_are_checked(self):
        found = rows('session.sendMessage(m, replyHandler: { @Sendable r in }) { error in print(error) }')
        self.assertEqual(found, [('WCSession.sendMessage', 'the trailing closure is not `@Sendable`')])
        self.assertEqual(len(rows('s.sendMessageData(d, replyHandler: { r in }, errorHandler: { e in })')), 2)

    def test_artwork_request_handler(self):
        self.assertEqual(len(rows('let a = MPMediaItemArtwork(boundsSize: size) { _ in image }')), 1)
        self.assertEqual(rows('let a = MPMediaItemArtwork(boundsSize: size) { @Sendable _ in image }'), [])

    def test_an_off_main_notification_publisher_needs_a_hop(self):
        sink = ('NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)\n'
                '    .sink { [weak self] _ in self?.record() }\n')
        self.assertEqual([a for a, _ in rows(sink)], ['NotificationCenter.publisher'])
        hopped = sink.replace('\n    .sink', '\n    .receive(on: DispatchQueue.main)\n    .sink')
        self.assertEqual(rows(hopped), [])
        self.assertEqual(rows('.onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)) { _ in x() }'),
                         [('NotificationCenter.publisher', 'posted off the main thread: add `.receive(on:)`')])
        swift_name = 'NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification).sink { _ in }'
        self.assertEqual(len(rows(swift_name)), 1)
        main_posted = 'NotificationCenter.default.publisher(for: UIApplication.willTerminateNotification).sink { _ in }'
        self.assertEqual(rows(main_posted), [])

    def test_an_off_main_observer_into_assume_isolated(self):
        trap = ('center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { n in\n'
                '    MainActor.assumeIsolated { self.handle(n) }\n'
                '}\n')
        self.assertEqual([a for a, _ in rows(trap)], ['NotificationCenter.addObserver'])
        self.assertEqual(rows(trap.replace('queue: nil', 'queue: .main')), [])
        self.assertEqual(rows(trap.replace('MainActor.assumeIsolated { self.handle(n) }', 'Task { @MainActor in }')), [])
        selector = 'center.addObserver(self, selector: #selector(route), name: AVAudioSession.routeChangeNotification, object: nil)'
        self.assertEqual([a for a, _ in rows(selector)], ['NotificationCenter.addObserver'])


if __name__ == '__main__':
    unittest.main()
