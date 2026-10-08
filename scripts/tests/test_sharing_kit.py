import copy
import hashlib
import json
from pathlib import Path
import re
import sys
import tempfile
import unittest
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import sharing_kit as kit_tool  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
PACKET_PLAN_SWIFT = ROOT / 'Packages/SessionKit/Sources/CoopPacket/PacketBuilder.swift'
SHARING_MODELS_SWIFT = ROOT / 'Packages/SessionKit/Sources/SessionKit/SharingModels.swift'


def swift_lets(path, header, indent):
    """The stored properties of one Swift struct, name -> type, read from the source so a plan can't drift from it."""
    text = Path(path).read_text(encoding='utf-8')
    start = re.search(header, text)
    assert start, header
    props = {}
    for line in text[start.end():].splitlines():
        if re.match(r'^' + ' ' * (indent - 4) + r'\}', line):
            break
        found = re.match(r'^' + ' ' * indent + r'(?:public )?let (\w+): ([^=\n]+)', line)
        if found:
            props[found.group(1)] = found.group(2).strip()
    return props


def mutated(change):
    kit = copy.deepcopy(kit_tool.load_kit())
    change(kit)
    return kit


def packet_of(kit, file):
    return next(p for p in kit['packets'] if p['file'] == file)


class KitFileTests(unittest.TestCase):
    def test_the_committed_kit_and_procedure_pass_lint(self):
        self.assertEqual(kit_tool.lint(), [])

    def test_the_kit_covers_the_failure_modes_the_issue_names(self):
        kit = kit_tool.load_kit()
        packets = {p['file']: p for p in kit['packets']}
        # An item he already has, a source he does not have, a different episode sharing the intro, a wrong cut.
        self.assertEqual(packets['kit-1-episode-a']['item'], 'episode-a')
        self.assertTrue(kit['items']['episode-a']['listenerMayAdd'])
        self.assertNotIn('listenerMayAdd', kit['items']['episode-b'])
        self.assertEqual(packets['kit-2-episode-b']['item'], 'episode-b')
        self.assertTrue(packets['kit-3-wrong-cut']['wrongCut'])
        self.assertEqual(packets['kit-3-wrong-cut']['item'], 'episode-a')
        self.assertEqual(packets['kit-3-wrong-cut']['evidenceFrom'], 'episode-b')
        self.assertEqual(kit['items']['article-w']['kind'], 'article')
        for key in ('episode-a', 'episode-b'):
            self.assertGreater(kit['items'][key]['audio']['sharedIntroSeconds'], 0)

    def test_every_public_link_is_https_and_open_to_anyone(self):
        kit = kit_tool.load_kit()
        for key, item in kit['items'].items():
            links = [item['source']['page'], item['identity']['canonicalURL']]
            links += [item['audio']['url']] if item['kind'] == 'podcast' else []
            for link in links:
                self.assertTrue(link.startswith('https://'), (key, link))
                self.assertTrue(kit_tool.is_shareable_link(link), (key, link))
            self.assertTrue(item['source']['license'])


class KitRuleTests(unittest.TestCase):
    def problems(self, change):
        return kit_tool.validate_kit(mutated(change))

    def assertProblem(self, problems, fragment):
        self.assertTrue(any(fragment in p for p in problems), f'{fragment!r} not in {problems}')

    def test_a_sender_that_could_pass_for_a_person_is_refused(self):
        problems = self.problems(lambda k: packet_of(k, 'kit-1-episode-a').update(sender='Ada Jensen'))
        self.assertProblem(problems, 'synthetic')

    def test_a_private_looking_link_is_refused(self):
        def change(kit):
            identity = kit['items']['episode-a']['identity']
            identity['enclosureURL'] = 'https://example.com/ep.mp3?token=abc'
            kit['items']['episode-a']['audio']['url'] = identity['enclosureURL']
        self.assertProblem(self.problems(change), 'looks private')

    def test_a_non_https_canonical_link_is_refused(self):
        def change(kit):
            kit['items']['article-w']['identity']['canonicalURL'] = 'http://www.archives.gov/x'
        self.assertProblem(self.problems(change), 'canonicalURL must be https')

    def test_a_margin_too_near_the_start_has_no_before_fingerprint(self):
        def change(kit):
            packet_of(kit, 'kit-2-episode-b')['margins'][0]['atMs'] = 2000
        self.assertProblem(self.problems(change), 'no sound for the "before" fingerprint')

    def test_a_margin_too_near_the_end_has_no_after_fingerprint(self):
        def change(kit):
            packet_of(kit, 'kit-2-episode-b')['margins'][2]['atMs'] = 313000
        self.assertProblem(self.problems(change), 'too near the end')

    def test_a_margin_past_the_end_of_the_item_is_refused(self):
        def change(kit):
            packet_of(kit, 'kit-1-episode-a')['margins'][0]['atMs'] = 9_999_000
        self.assertProblem(self.problems(change), 'beyond the end')

    def test_evidence_from_another_episode_must_be_marked_wrong_cut(self):
        def change(kit):
            del packet_of(kit, 'kit-3-wrong-cut')['wrongCut']
        self.assertProblem(self.problems(change), 'wrongCut')

    def test_a_wrong_cut_packet_must_leave_most_fingerprints_clear_of_the_intro(self):
        def change(kit):
            for margin in packet_of(kit, 'kit-3-wrong-cut')['margins']:
                margin['atMs'] = 4000 + 1000 * int(margin['id'][1:])
        self.assertProblem(self.problems(change), 'could match the shared intro')

    def test_a_wrong_cut_packet_needs_an_intro_margin(self):
        def change(kit):
            for margin in packet_of(kit, 'kit-3-wrong-cut')['margins']:
                margin['atMs'] += 60000
        self.assertProblem(self.problems(change), 'put one Margin in the shared intro')

    def test_a_wrong_cut_needs_two_episodes_that_share_an_intro(self):
        def change(kit):
            kit['items']['episode-b']['audio']['sharedIntroSeconds'] = 0
        self.assertProblem(self.problems(change), 'share an intro')

    def test_an_article_margin_quotes_words_once(self):
        def change(kit):
            margins = packet_of(kit, 'kit-4-article')['margins']
            margins[1]['quote'] = margins[0]['quote']
        self.assertProblem(self.problems(change), 'each quote is used once')

    def test_an_article_margin_has_no_time(self):
        def change(kit):
            packet_of(kit, 'kit-4-article')['margins'][0]['atMs'] = 1000
        self.assertProblem(self.problems(change), 'no atMs')

    def test_a_packet_with_no_voice_at_all_is_refused(self):
        def change(kit):
            for margin in packet_of(kit, 'kit-1-episode-a')['margins']:
                margin['spoken'] = False
        self.assertProblem(self.problems(change), 'at least one Margin is spoken')

    def test_duplicate_margin_ids_and_file_names_are_refused(self):
        def change(kit):
            packet_of(kit, 'kit-1-episode-a')['margins'][1]['id'] = 'a1'
            packet_of(kit, 'kit-2-episode-b')['file'] = 'kit-1-episode-a'
        problems = self.problems(change)
        self.assertProblem(problems, 'Margin ids are unique')
        self.assertProblem(problems, 'file names are unique')

    def test_a_pinned_hash_must_be_a_sha256(self):
        def change(kit):
            kit['items']['episode-a']['audio']['sha256'] = 'abc'
        self.assertProblem(self.problems(change), 'sha256')

    def test_more_margins_than_a_packet_holds_are_refused(self):
        def change(kit):
            packet = packet_of(kit, 'kit-1-episode-a')
            packet['margins'] = [{'id': f'm{i}', 'atMs': 10000 + i * 1000, 'text': 'x'} for i in range(51)]
        self.assertProblem(self.problems(change), 'holds 1 to 50')


class ShareableLinkTests(unittest.TestCase):
    """Cases from SessionKit's ShareableLinkPolicy: the exporter drops a link that holds an access secret."""

    def test_public_links_are_kept(self):
        for link in (
            'https://hub.hackerpublicradio.org/ccdn.php?filename=/eps/hpr4737/hpr4737.mp3',
            'https://hpr.nyc3.cdn.digitaloceanspaces.com/eps/hpr4737/hpr4737.mp3',
            'https://www.archives.gov/founding-docs/declaration-transcript',
            'https://feeds.simplecast.com/54nAGcIl',
            'https://rss.amperwave.net/0123456789abcdef0123456789abcdef',
        ):
            self.assertTrue(kit_tool.is_shareable_link(link), link)

    def test_links_with_a_secret_or_from_a_paid_host_are_dropped(self):
        for link in (
            'https://example.com/feed?token=abc',
            'https://user:pass@example.com/feed',
            'https://www.patreon.com/rss/show',
            'https://example.com/members/feed.xml',
            'https://example.com/feed/a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8',
            'https://example.com/feed?id=a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8',
            'ftp://example.com/feed',
        ):
            self.assertFalse(kit_tool.is_shareable_link(link), link)


class PlanTests(unittest.TestCase):
    """The plans must decode in coop-packet. Field names are read from its Swift source."""

    @classmethod
    def setUpClass(cls):
        cls.plan_fields = swift_lets(PACKET_PLAN_SWIFT, r'struct PacketPlan: Decodable \{', 4)
        cls.margin_fields = swift_lets(PACKET_PLAN_SWIFT, r'struct Margin: Decodable \{', 8)
        cls.identity_fields = swift_lets(SHARING_MODELS_SWIFT, r'public struct SharedItemIdentity: Codable[^{]*\{', 4)
        cls.item_types = set(re.findall(r'case (\w+)', re.search(
            r'public enum SharedItemType: String[^{]*\{(.*?)\n\}', SHARING_MODELS_SWIFT.read_text(), re.S).group(1)))

    def plans(self):
        kit = kit_tool.load_kit()
        with tempfile.TemporaryDirectory() as work:
            paths = kit_tool.write_plans(kit, work)
            return kit, [(path, json.loads(path.read_text(encoding='utf-8'))) for path in paths]

    def test_the_swift_fields_were_found(self):
        self.assertIn('sender', self.plan_fields)
        self.assertIn('episodeAudio', self.plan_fields)
        self.assertIn('atMs', self.margin_fields)
        self.assertIn('episodeGUID', self.identity_fields)
        self.assertEqual(self.item_types, {'text', 'podcast', 'pdf', 'epub', 'other'})

    def test_plans_use_only_fields_coop_packet_decodes_and_all_it_requires(self):
        kit, plans = self.plans()
        required = {n for n, t in self.plan_fields.items() if not t.endswith('?') and not t.startswith('[')} | {'margins'}
        required_margin = {n for n, t in self.margin_fields.items() if not t.endswith('?')}
        for path, plan in plans:
            self.assertLessEqual(set(plan), set(self.plan_fields), path.name)
            self.assertLessEqual(required, set(plan), path.name)
            for margin in plan['margins']:
                self.assertLessEqual(set(margin), set(self.margin_fields), (path.name, margin['id']))
                self.assertLessEqual(required_margin, set(margin), (path.name, margin['id']))

    def test_every_item_identity_decodes_as_a_shared_item_identity(self):
        kit, plans = self.plans()
        required = {n for n, t in self.identity_fields.items() if not t.endswith('?')}
        for path, plan in plans:
            self.assertLessEqual(set(plan['item']), set(self.identity_fields), path.name)
            self.assertLessEqual(required, set(plan['item']), path.name)
            self.assertIn(plan['item']['itemType'], self.item_types)

    def test_a_margin_is_placed_by_time_or_by_quote_and_never_both(self):
        _, plans = self.plans()
        for path, plan in plans:
            for margin in plan['margins']:
                self.assertEqual(('atMs' in margin) + ('quote' in margin), 1, (path.name, margin['id']))
            self.assertEqual('episodeAudio' in plan, plan['item']['itemType'] == 'podcast', path.name)

    def test_a_wrong_cut_plan_takes_its_fingerprints_from_the_other_episode(self):
        _, plans = self.plans()
        by_name = {path.stem: plan for path, plan in plans}
        self.assertTrue(by_name['kit-1-episode-a']['episodeAudio'].endswith('episode-a.mp3'))
        self.assertTrue(by_name['kit-3-wrong-cut']['episodeAudio'].endswith('episode-b.mp3'))
        self.assertEqual(by_name['kit-3-wrong-cut']['item'], by_name['kit-1-episode-a']['item'])
        self.assertNotEqual(by_name['kit-2-episode-b']['item'], by_name['kit-1-episode-a']['item'])

    def test_audio_paths_resolve_from_the_plan_folder(self):
        kit = kit_tool.load_kit()
        with tempfile.TemporaryDirectory() as work:
            paths = kit_tool.write_plans(kit, work)
            plan = json.loads(paths[0].read_text())
            self.assertEqual((paths[0].parent / plan['episodeAudio']).resolve(), (Path(work) / 'audio' / 'episode-a.mp3').resolve())

    def test_only_text_only_margins_say_spoken_false(self):
        kit, plans = self.plans()
        for path, plan in plans:
            packet = packet_of(kit, path.stem)
            for margin, source in zip(plan['margins'], packet['margins']):
                self.assertEqual(margin.get('spoken'), False if source.get('spoken') is False else None, (path.name, margin['id']))


class ProcedureTests(unittest.TestCase):
    def setUp(self):
        self.kit = kit_tool.load_kit()
        self.text = kit_tool.PROCEDURE_FILE.read_text(encoding='utf-8')

    def test_it_names_every_packet_sender_count_and_what_each_margin_says(self):
        self.assertEqual(kit_tool.procedure_problems(self.kit, self.text), [])
        self.assertIn('Voice files: 3', self.text)

    def test_it_never_tells_the_listener_to_remove_the_app_or_reset_anything(self):
        for word in ('reinstall', 'reset', 'erase', 'delete the app', 'offload'):
            problems = kit_tool.procedure_problems(self.kit, self.text + f'\nNow {word}.\n')
            self.assertTrue(any(word in p for p in problems), word)

    def test_a_dropped_packet_or_link_is_caught(self):
        self.assertTrue(kit_tool.procedure_problems(self.kit, self.text.replace('kit-3-wrong-cut.spokenmargins', 'x')))
        self.assertTrue(kit_tool.procedure_problems(self.kit, self.text.replace('4 shared Margins', 'some Margins')))
        self.assertTrue(kit_tool.procedure_problems(self.kit, self.text.replace(
            self.kit['items']['episode-a']['audio']['url'], 'https://example.com/x.mp3')))
        self.assertTrue(kit_tool.procedure_problems(
            self.kit, self.text.replace('#536', 'the streamed bug').replace('/issues/536', '/issues/1')))

    def test_every_step_says_what_the_listener_should_see_or_hear(self):
        steps = re.split(r'\n## (?=\d\. )', self.text)[1:]
        self.assertEqual(len(steps), 8)
        for step in steps[:-1]:
            self.assertRegex(step, r'You should (see|hear)', step.splitlines()[0])


def build_packet(path, kit, packet, mutate=None):
    """A packet shaped like the ones coop-packet writes, for testing the reader without Swift."""
    item = kit['items'][packet['item']]
    identity = item['identity']
    podcast = item['kind'] == 'podcast'
    files, assets, interjections = {}, [], []
    for margin in packet['margins']:
        spoken = margin.get('spoken', True)
        representation = {
            'id': f"representation-{margin['id']}",
            'kind': 'original_audio_and_text' if spoken else 'text_only',
            'approvedTranscript': margin['text'],
            'provenance': 'sender_approved_original' if spoken else 'sender_approved_text_only',
        }
        if spoken:
            voice = f"assets/audio/{margin['id']}.m4a"
            files[voice] = b'm4a:' + margin['id'].encode()
            assets.append({'id': f"voice-{margin['id']}", 'role': 'original_voice', 'path': voice, 'mimeType': 'audio/mp4',
                           'durationMs': 6000, 'provenance': 'sender_approved_original'})
            representation['assetId'] = f"voice-{margin['id']}"
        if podcast:
            anchor = {'anchorType': 'media', 'mediaTimeMs': margin['atMs'], 'machineEvidenceAssetIds': []}
            for side in ('pre', 'post'):
                evidence = f"assets/evidence/{margin['id']}-{side}.shazamsignature"
                files[evidence] = f"sig:{margin['id']}:{side}".encode()
                assets.append({'id': f"{margin['id']}-{side}", 'role': 'acoustic_signature', 'path': evidence,
                               'mimeType': 'application/vnd.apple.shazam.signature', 'durationMs': 11000,
                               'anchorOffsetMs': 11500 if side == 'pre' else -500, 'provenance': 'test'})
                anchor['machineEvidenceAssetIds'].append(f"{margin['id']}-{side}")
        else:
            anchor = {'anchorType': 'text', 'exactText': margin['quote'], 'machineEvidenceAssetIds': []}
        interjections.append({'packageScopedId': margin['id'], 'createdAt': kit['createdAt'], 'anchor': anchor,
                              'defaultRepresentationId': representation['id'], 'representations': [representation]})
    layer = {'id': 'commentary-layer', 'schemaVersion': 'spoken-margins.commentary-layer.v1', 'interjections': interjections}
    files['artifacts/commentary-layer.json'] = json.dumps(layer).encode()
    source = {'sourceType': 'podcast' if podcast else 'article', 'canonicalURL': identity['canonicalURL'], 'title': identity['title']}
    for field in ('episodeGUID', 'enclosureURL', 'durationMs', 'publisher', 'showTitle', 'publishedAt', 'languageCode'):
        if field in identity:
            source[field] = identity[field]
    for descriptor in assets:
        data = files[descriptor['path']]
        descriptor.update(byteCount=len(data), sha256=hashlib.sha256(data).hexdigest())
    layer_bytes = files['artifacts/commentary-layer.json']
    manifest = {
        'schemaVersion': 'spoken-margins.package.v1', 'packageId': 'package-test', 'createdAt': kit['createdAt'],
        'contentDigest': '0' * 64, 'senderDisplayLabel': packet['sender'], 'suggestedRevealMode': 'companion',
        'source': source, 'requiredCapabilities': ['spoken-margins.commentary-layer.v1'],
        'artifacts': [{'id': 'commentary-layer', 'kind': 'commentary_layer', 'schemaVersion': 'spoken-margins.commentary-layer.v1',
                       'path': 'artifacts/commentary-layer.json', 'required': True, 'byteCount': len(layer_bytes),
                       'sha256': hashlib.sha256(layer_bytes).hexdigest()}],
        'assets': assets,
        'redactions': {name: True for name in (
            'rawAudioOmitted', 'rawTranscriptOmitted', 'fullSourceTextOmitted', 'sourceAudioOmitted',
            'diagnosticsOmitted', 'filesystemPathsOmitted', 'unrelatedTurnsOmitted', 'privateRepresentationsOmitted')},
    }
    if mutate:
        mutate(manifest, layer, files)
        files['artifacts/commentary-layer.json'] = json.dumps(layer).encode()
    with zipfile.ZipFile(path, 'w') as archive:
        archive.writestr('manifest.json', json.dumps(manifest))
        archive.writestr('preview.md', '# preview\n')
        for name, data in files.items():
            archive.writestr(name, data)


@unittest.skipUnless(kit_tool.SCHEMAS.exists(), 'contract schemas are not here')
class PacketLintTests(unittest.TestCase):
    def setUp(self):
        try:
            import jsonschema  # noqa: F401
        except ImportError:
            self.skipTest('jsonschema is not installed')
        self.kit = kit_tool.load_kit()
        self.folder = tempfile.TemporaryDirectory()
        self.addCleanup(self.folder.cleanup)

    def lint(self, file, mutate=None, kit=None):
        kit = kit or self.kit
        packet = packet_of(self.kit, file)
        path = Path(self.folder.name) / kit_tool.packet_file_name(packet)
        build_packet(path, self.kit, packet, mutate)
        return kit_tool.lint_packet(path, kit)

    def assertProblem(self, problems, fragment):
        self.assertTrue(any(fragment in p for p in problems), f'{fragment!r} not in {problems}')

    def test_packets_shaped_like_the_ones_coop_packet_writes_pass(self):
        for packet in self.kit['packets']:
            self.assertEqual(self.lint(packet['file']), [], packet['file'])

    def test_a_packet_that_needs_more_than_build_29_reads_is_refused(self):
        problems = self.lint('kit-1-episode-a', lambda m, l, f: m['requiredCapabilities'].append('spoken-margins.embedded-text-item.v1'))
        self.assertProblem(problems, 'Build 29 cannot read')

    def test_a_changed_file_no_longer_matches_the_manifest(self):
        problems = self.lint('kit-1-episode-a', lambda m, l, f: f.update({'assets/audio/a1.m4a': b'changed'}))
        self.assertProblem(problems, 'does not match its size or hash')

    def test_a_file_the_manifest_does_not_list_is_found(self):
        problems = self.lint('kit-1-episode-a', lambda m, l, f: f.update({'assets/audio/stray.m4a': b'x'}))
        self.assertProblem(problems, 'not in the manifest')

    def test_a_margin_without_fingerprints_is_found(self):
        problems = self.lint('kit-2-episode-b', lambda m, l, f: l['interjections'][0]['anchor'].update(machineEvidenceAssetIds=[]))
        self.assertProblem(problems, 'no acoustic fingerprint')

    def test_a_margin_in_the_wrong_place_is_found(self):
        problems = self.lint('kit-2-episode-b', lambda m, l, f: l['interjections'][1]['anchor'].update(mediaTimeMs=61000))
        self.assertProblem(problems, 'anchored at 61000 ms')

    def test_a_spoken_margin_with_no_voice_is_found(self):
        def change(manifest, layer, files):
            layer['interjections'][0]['representations'][0].pop('assetId')
        self.assertProblem(self.lint('kit-1-episode-a', change), 'needs its voice file')

    def test_a_text_only_margin_that_carries_a_voice_is_found(self):
        def change(manifest, layer, files):
            layer['interjections'][3]['representations'][0]['assetId'] = 'voice-a1'
        self.assertProblem(self.lint('kit-1-episode-a', change), 'carries a voice file')

    def test_a_packet_about_another_item_is_found(self):
        problems = self.lint('kit-1-episode-a', lambda m, l, f: m['source'].update(canonicalURL='https://example.com/other.mp3'))
        self.assertProblem(problems, 'source.canonicalURL')

    def test_a_sender_label_that_changed_is_found(self):
        problems = self.lint('kit-1-episode-a', lambda m, l, f: m.update(senderDisplayLabel='Someone Else'))
        self.assertProblem(problems, 'sender is')

    def test_an_article_margin_anchored_to_other_words_is_found(self):
        problems = self.lint('kit-4-article', lambda m, l, f: l['interjections'][0]['anchor'].update(exactText='other words'))
        self.assertProblem(problems, "anchored to 'other words'")

    def test_extra_or_reordered_margins_are_found(self):
        problems = self.lint('kit-3-wrong-cut', lambda m, l, f: l['interjections'].reverse())
        self.assertProblem(problems, 'not the ones in kit.json')

    def test_a_manifest_that_breaks_the_package_schema_is_found(self):
        problems = self.lint('kit-1-episode-a', lambda m, l, f: m.pop('redactions'))
        self.assertProblem(problems, 'redactions')

    def test_something_that_is_not_a_zip_or_not_in_the_kit_is_found(self):
        stray = Path(self.folder.name) / 'kit-1-episode-a.spokenmargins'
        stray.write_bytes(b'not a zip')
        self.assertProblem(kit_tool.lint_packet(stray, self.kit), 'not a zip')
        other = Path(self.folder.name) / 'other.spokenmargins'
        other.write_bytes(b'x')
        self.assertProblem(kit_tool.lint_packet(other, self.kit), 'not a packet named in kit.json')


class BuildTests(unittest.TestCase):
    """`build` on a Mac runs real tools. Here every tool is a recording stand-in."""

    def setUp(self):
        self.kit = kit_tool.load_kit()
        self.work = tempfile.TemporaryDirectory()
        self.addCleanup(self.work.cleanup)
        self.calls = []

    def fetch(self, url, destination):
        item = next(i for i in self.kit['items'].values() if i.get('audio', {}).get('url') == url)
        Path(destination).write_bytes(b'audio for ' + item['identity']['title'].encode())

    def pin_fake_audio(self):
        for item in self.kit['items'].values():
            if item['kind'] == 'podcast':
                item['audio']['sha256'] = hashlib.sha256(b'audio for ' + item['identity']['title'].encode()).hexdigest()

    def runner(self, fail_on=None, tamper=None, voices='Samantha en_US\nDaniel en_GB\nKaren en_AU\nMoira en_IE\n'):
        """Stands in for say, swift and coop-packet. `coop-packet build` writes a packet shaped like the real ones."""
        def run(command, **kwargs):
            self.calls.append(command)
            result = lambda out='': type('R', (), {'stdout': out, 'returncode': 0})()  # noqa: E731
            if command[:2] == ['say', '-v']:
                return result(voices)
            if command[:2] == ['swift', 'build'] and '--show-bin-path' in command:
                return result('/bin-path\n')
            if fail_on and fail_on in command:
                raise kit_tool.subprocess.CalledProcessError(2, command)
            if command[:2] == ['/bin-path/coop-packet', 'build']:
                plan = json.loads(Path(command[2]).read_text())
                packet = packet_of(self.kit, plan['fileName'])
                build_packet(Path(command[4]) / kit_tool.packet_file_name(packet), self.kit, packet, tamper)
            return result()
        return run

    def test_it_refuses_to_run_anywhere_but_a_mac(self):
        with self.assertRaisesRegex(kit_tool.KitError, 'needs a Mac'):
            kit_tool.build(self.kit, self.work.name, run=self.runner(), fetch=self.fetch, platform='linux')
        self.assertEqual(self.calls, [])

    def test_it_stops_when_a_voice_is_not_installed(self):
        with self.assertRaisesRegex(kit_tool.KitError, 'Karen'):
            kit_tool.build(self.kit, self.work.name, run=self.runner(voices='Samantha en_US\nDaniel en_GB\nMoira en_IE\n'),
                           fetch=self.fetch, platform='darwin')

    def test_it_stops_when_the_public_audio_is_not_the_pinned_file(self):
        with self.assertRaisesRegex(kit_tool.KitError, 'not the file kit.json pins'):
            kit_tool.build(self.kit, self.work.name, run=self.runner(), fetch=self.fetch, platform='darwin')
        self.assertFalse(any(c[:2] == ['swift', 'build'] for c in self.calls))

    def test_it_builds_each_plan_then_checks_them_all_before_it_lists_hashes(self):
        try:
            import jsonschema  # noqa: F401
        except ImportError:
            self.skipTest('jsonschema is not installed')
        self.pin_fake_audio()
        packets = kit_tool.build(self.kit, self.work.name, run=self.runner(), fetch=self.fetch, platform='darwin')
        verbs = [c[1] if c[0] == '/bin-path/coop-packet' else c[0] for c in self.calls if c[0] != 'say']
        self.assertEqual(verbs, ['swift', 'swift'] + ['build'] * 4 + ['check'])
        check = next(c for c in self.calls if c[:2] == ['/bin-path/coop-packet', 'check'])
        self.assertEqual([Path(p).name for p in check[2:]], [kit_tool.packet_file_name(p) for p in self.kit['packets']])
        listed = (Path(self.work.name) / 'out' / 'SHA256SUMS').read_text().splitlines()
        self.assertEqual(sorted(line.split('  ')[1] for line in listed), sorted(p.name for p in packets))

    def test_a_built_packet_that_disagrees_with_the_kit_stops_the_build(self):
        try:
            import jsonschema  # noqa: F401
        except ImportError:
            self.skipTest('jsonschema is not installed')
        self.pin_fake_audio()

        def moved(manifest, layer, files):
            anchor = layer['interjections'][1]['anchor']
            if 'mediaTimeMs' in anchor:
                anchor['mediaTimeMs'] += 1000

        with self.assertRaisesRegex(kit_tool.KitError, 'disagree with kit.json'):
            kit_tool.build(self.kit, self.work.name, run=self.runner(tamper=moved), fetch=self.fetch, platform='darwin')
        self.assertFalse((Path(self.work.name) / 'out' / 'SHA256SUMS').exists())

    def test_a_failed_coop_packet_check_stops_the_build(self):
        self.pin_fake_audio()
        with self.assertRaises(kit_tool.subprocess.CalledProcessError):
            kit_tool.build(self.kit, self.work.name, run=self.runner(fail_on='check'), fetch=self.fetch, platform='darwin')

    def test_audio_that_matches_its_pin_is_fetched_once(self):
        self.pin_fake_audio()
        kit_tool.fetch_audio(self.kit, Path(self.work.name) / 'audio', self.fetch)
        fetched = []
        kit_tool.fetch_audio(self.kit, Path(self.work.name) / 'audio', lambda url, dest: fetched.append(url))
        self.assertEqual(fetched, [])

    def test_stage_wants_built_packets_and_lists_their_hashes(self):
        with self.assertRaisesRegex(kit_tool.KitError, 'build first'):
            kit_tool.stage(self.work.name, destination=Path(self.work.name) / 'packets')

    def test_hash_list_names_each_packet(self):
        folder = Path(self.work.name)
        (folder / 'b.spokenmargins').write_bytes(b'b')
        (folder / 'a.spokenmargins').write_bytes(b'a')
        lines = kit_tool.hash_list(folder).splitlines()
        self.assertEqual([line.split('  ')[1] for line in lines], ['a.spokenmargins', 'b.spokenmargins'])
        self.assertEqual(lines[0].split('  ')[0], hashlib.sha256(b'a').hexdigest())


class VerifyContentTests(unittest.TestCase):
    def test_the_shared_intro_is_measured_from_the_sound(self):
        rate = 8000
        intro = [((i * 7919) % 20000) - 10000 for i in range(rate * 2)]
        first = intro + [((i * 104729) % 20000) - 10000 for i in range(rate * 2)]
        second = [v + (i % 3) - 1 for i, v in enumerate(intro)] + [((i * 15485863) % 20000) - 10000 for i in range(rate * 2)]
        self.assertEqual(kit_tool.shared_prefix_seconds(first, second), 2.0)
        self.assertEqual(kit_tool.shared_prefix_seconds(first, first[::-1]), 0.0)
        self.assertEqual(kit_tool.shared_prefix_seconds([0] * 8000, [0] * 8000), 0.0)

    def article_only(self):
        kit = kit_tool.load_kit()
        kit['items'] = {'article-w': kit['items']['article-w']}
        kit['packets'] = [packet_of(kit, 'kit-4-article')]
        return kit

    def test_a_quote_that_moved_or_repeated_is_reported(self):
        kit = self.article_only()
        title = kit['items']['article-w']['source']['pageTitle']
        text = ' '.join(m['quote'] for m in kit['packets'][0]['margins'])
        with tempfile.TemporaryDirectory() as work:
            clean = kit_tool.verify_content(kit, work, page_text=lambda url: (title, text), log=lambda *a: None)
            self.assertEqual(clean, [])
            twice = kit_tool.verify_content(kit, work, page_text=lambda url: (title, text + ' ' + text), log=lambda *a: None)
            self.assertEqual(len(twice), 3)
            gone = kit_tool.verify_content(kit, work, page_text=lambda url: ('Moved', 'nothing here'), log=lambda *a: None)
            self.assertEqual(len(gone), 4)

    def test_changed_public_audio_is_reported(self):
        kit = kit_tool.load_kit()
        with tempfile.TemporaryDirectory() as work:
            problems = kit_tool.verify_content(
                kit, work, fetch=lambda url, dest: Path(dest).write_bytes(b'something else'),
                page_text=lambda url: ('', ''), log=lambda *a: None)
        self.assertTrue(any('not the file kit.json pins' in p for p in problems))


@unittest.skipUnless(any(kit_tool.PACKETS_DIR.glob('*.spokenmargins')), 'no packets are staged yet')
class StagedPacketTests(unittest.TestCase):
    """Once the Mac has built and staged the packets, they have to keep matching kit.json."""

    def test_staged_packets_are_exactly_the_kit_and_pass_the_reader(self):
        kit = kit_tool.load_kit()
        names = sorted(p.name for p in kit_tool.PACKETS_DIR.glob('*.spokenmargins'))
        self.assertEqual(names, sorted(kit_tool.packet_file_name(p) for p in kit['packets']))
        for name in names:
            self.assertEqual(kit_tool.lint_packet(kit_tool.PACKETS_DIR / name, kit), [], name)

    def test_the_hash_list_matches_the_files(self):
        listed = (kit_tool.PACKETS_DIR / 'SHA256SUMS').read_text(encoding='utf-8')
        self.assertEqual(listed, kit_tool.hash_list(kit_tool.PACKETS_DIR))


if __name__ == '__main__':
    unittest.main()
