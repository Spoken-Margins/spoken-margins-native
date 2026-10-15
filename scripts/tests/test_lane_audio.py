import ctypes
import io
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
import lane_audio  # noqa: E402


def device(identifier, uid, name, transport, input=False, output=False):
    return {'id': identifier, 'uid': uid, 'name': name, 'transport': transport, 'input': input, 'output': output}


AIRPODS_IN = device(112, 'pods:input', 'AirPods', 'blue', input=True)
AIRPODS_OUT = device(106, 'pods:output', 'AirPods', 'blue', output=True)
IPHONE_MIC = device(104, 'iphone-mic', 'iPhone Microphone', 'ccwd', input=True)
MAC_MIC = device(99, 'BuiltInMicrophoneDevice', 'MacBook Pro Microphone', 'bltn', input=True)
MAC_SPEAKERS = device(92, 'BuiltInSpeakerDevice', 'MacBook Pro Speakers', 'bltn', output=True)
USB_OUT = device(70, 'usb-dac', 'USB DAC', 'usb ', output=True)
TEAMS = device(52, 'teams', 'Microsoft Teams Audio', 'virt', input=True, output=True)


class FakeAudio:
    """The Mac's audio devices: a device list and the three default-device slots."""

    def __init__(self, devices, **defaults):
        self.listed = list(devices)
        self.defaults = {'input': 112, 'output': 106, 'system': 106}
        self.defaults.update(defaults)
        self.sets = []
        self.fail_on = None

    def devices(self):
        return list(self.listed)

    def default(self, kind):
        return self.defaults[kind]

    def set_default(self, kind, identifier):
        if self.fail_on == kind:
            raise OSError('refused')
        self.sets.append((kind, identifier))
        self.defaults[kind] = identifier


class LaneAudioTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        patch = mock.patch.dict(os.environ, {'SM_LANE_STATE_DIR': self.temporary.name})
        patch.start()
        self.addCleanup(patch.stop)
        os.environ.pop('SM_LANE_SIMCTL', None)  # a fake simctl switches pinning off; these tests use a fake backend
        os.environ.pop('SM_LANE_AUDIO', None)
        grace = mock.patch.object(lane_audio, 'BOOT_GRACE', 0)  # tests make `booted` the only truth, except where noted
        grace.start()
        self.addCleanup(grace.stop)
        self.out = io.StringIO()
        self.mac = FakeAudio([AIRPODS_IN, AIRPODS_OUT, IPHONE_MIC, MAC_MIC, MAC_SPEAKERS, USB_OUT, TEAMS])
        self.booted = set()
        booted = mock.patch('lane_sim.booted_udids', side_effect=lambda **kw: set(self.booted))
        booted.start()
        self.addCleanup(booted.stop)

    def pin(self, udid='SIM-A', lid_closed=False):
        self.booted.add(udid)
        return lane_audio.pin(udid, backend=self.mac, out=self.out, lid_closed=lambda: lid_closed)

    def settle(self, drop=None):
        return lane_audio.settle(backend=self.mac, out=self.out, booted=lambda: set(self.booted), drop=drop)

    def test_wireless_defaults_move_to_the_built_in_devices_and_come_back(self):
        changed = self.pin()
        self.assertEqual(self.mac.defaults, {'input': 99, 'output': 92, 'system': 92})
        self.assertEqual(len(changed), 3)
        self.assertEqual(self.settle(), [])  # the simulator is still booted: nothing comes back yet
        self.assertEqual(self.mac.defaults, {'input': 99, 'output': 92, 'system': 92})
        self.booted.clear()
        self.settle()
        self.assertEqual(self.mac.defaults, {'input': 112, 'output': 106, 'system': 106})
        self.assertFalse(lane_audio._state_path().exists())

    def test_a_simulator_still_booting_keeps_its_pin_when_another_one_shuts_down(self):
        self.pin('SIM-A')
        with mock.patch.object(lane_audio, 'BOOT_GRACE', 1200.0):
            self.pin('SIM-B')  # B is pinned but simctl does not list it as booted yet
            self.booted.discard('SIM-B')
            self.booted.discard('SIM-A')
            self.settle(drop='SIM-A')  # A shut down
            self.assertEqual(self.mac.defaults, {'input': 99, 'output': 92, 'system': 92})
            self.settle(drop='SIM-B')  # B failed to boot
        self.assertEqual(self.mac.defaults, {'input': 112, 'output': 106, 'system': 106})

    def test_the_continuity_iphone_microphone_counts_as_wireless(self):
        self.mac.defaults['input'] = 104
        self.pin()
        self.assertEqual(self.mac.defaults['input'], 99)

    def test_wireless_defaults_arriving_after_boot_are_pinned_on_the_next_tick(self):
        self.mac.listed = [MAC_MIC, MAC_SPEAKERS, USB_OUT, TEAMS]
        self.mac.defaults = {'input': 99, 'output': 92, 'system': 92}
        self.assertEqual(self.pin(), [])
        self.assertIn('SIM-A', lane_audio._read_state().get('holders', {}))
        self.mac.listed.extend([AIRPODS_IN, AIRPODS_OUT])
        self.mac.defaults = {'input': 112, 'output': 106, 'system': 106}
        changed = lane_audio.pin('SIM-A', backend=self.mac, out=self.out,
                                 lid_closed=lambda: False, refresh=True)
        self.assertEqual(len(changed), 3)
        self.assertEqual(self.mac.defaults, {'input': 99, 'output': 92, 'system': 92})
        self.booted.clear()
        self.settle()
        # These AirPods arrived during the run; restoring them would select a device the run never began on.
        self.assertEqual(self.mac.defaults, {'input': 99, 'output': 92, 'system': 92})

    def refresh_after_airpods_reclaim(self, clock):
        self.mac.defaults = {'input': 112, 'output': 106, 'system': 106}  # the AirPods take the Mac back
        with mock.patch('time.time', return_value=clock):
            return lane_audio.pin('SIM-A', backend=self.mac, out=self.out, lid_closed=lambda: False, refresh=True)

    def test_a_device_that_keeps_reclaiming_the_defaults_is_not_fought_every_second(self):
        # 2026-10-15: pinning undid every reclaim on each 1 s tick, so the output flipped AirPods <-> speakers
        # all through a run and kept tugging the AirPods between the iPhone and the Mac.
        with mock.patch('time.time', return_value=1000.0):
            self.pin()
        switched = [len(self.refresh_after_airpods_reclaim(1001.0 + tick)) for tick in range(lane_audio.REPIN_LIMIT)]
        self.assertEqual(switched, [3] * lane_audio.REPIN_LIMIT)
        stood_down = self.refresh_after_airpods_reclaim(1010.0)
        self.assertEqual(stood_down, [])
        self.assertEqual(self.mac.defaults, {'input': 112, 'output': 106, 'system': 106})  # the Mac's choice stands
        self.assertIn('not fighting it', self.out.getvalue())
        sets = len(self.mac.sets)
        self.assertEqual(self.refresh_after_airpods_reclaim(1100.0), [])  # still standing down
        self.assertEqual(len(self.mac.sets), sets)
        after = 1010.0 + lane_audio.REPIN_YIELD + 1
        self.assertEqual(len(self.refresh_after_airpods_reclaim(after)), 3)  # the yield is over: pinned again
        # The AirPods were never pinned away from at boot, so settle must not resurrect them as a restore target.
        self.booted.clear()
        self.settle()

    def test_reclaims_spread_over_time_are_still_pinned(self):
        with mock.patch('time.time', return_value=1000.0):
            self.pin()
        gap = lane_audio.REPIN_WINDOW / lane_audio.REPIN_LIMIT + 1
        for tick in range(lane_audio.REPIN_LIMIT * 3):
            self.assertEqual(len(self.refresh_after_airpods_reclaim(1001.0 + tick * gap)), 3)
        self.assertNotIn('not fighting it', self.out.getvalue())

    def test_a_fresh_boot_starts_the_count_again(self):
        with mock.patch('time.time', return_value=1000.0):
            self.pin()
        for tick in range(lane_audio.REPIN_LIMIT + 1):
            self.refresh_after_airpods_reclaim(1001.0 + tick)
        self.assertGreater(lane_audio._read_state().get('yield_until', 0), 0)
        self.mac.defaults = {'input': 112, 'output': 106, 'system': 106}
        with mock.patch('time.time', return_value=1020.0):
            self.pin('SIM-B')
        self.assertEqual(self.mac.defaults, {'input': 99, 'output': 92, 'system': 92})
        self.assertNotIn('yield_until', lane_audio._read_state())

    def test_refresh_preserves_original_defaults_and_manual_wired_choices(self):
        self.pin()
        self.mac.defaults.update(input=IPHONE_MIC['id'], output=USB_OUT['id'], system=AIRPODS_OUT['id'])
        lane_audio.pin('SIM-A', backend=self.mac, out=self.out, lid_closed=lambda: False, refresh=True)
        self.assertEqual(self.mac.defaults, {'input': 99, 'output': 70, 'system': 92})
        self.booted.clear()
        self.settle()
        self.assertEqual(self.mac.defaults, {'input': 112, 'output': 70, 'system': 106})

    def test_unchanged_refresh_does_not_enumerate_devices_or_check_the_lid(self):
        self.pin()
        with mock.patch.object(self.mac, 'devices', side_effect=AssertionError('enumerated devices')), \
                mock.patch.object(lane_audio, 'settle', side_effect=AssertionError('queried simulators')):
            self.assertEqual(lane_audio.pin('SIM-A', backend=self.mac, out=self.out,
                                           lid_closed=lambda: self.fail('checked lid'), refresh=True), [])
        self.assertNotIn('skipped', self.out.getvalue())

    def test_unchanged_defaults_after_a_closed_lid_refresh_do_not_repeat_discovery(self):
        self.pin()
        self.mac.defaults['output'] = USB_OUT['id']  # speakers disappeared when the lid closed
        lid = mock.Mock(return_value=True)
        lane_audio.pin('SIM-A', backend=self.mac, out=self.out, lid_closed=lid, refresh=True)
        message = self.out.getvalue()
        self.assertEqual(lane_audio.pin('SIM-A', backend=self.mac, out=self.out,
                                       lid_closed=lid, refresh=True), [])
        self.assertEqual(lid.call_count, 1)
        self.assertEqual(self.out.getvalue(), message)
        self.assertEqual(lane_audio._read_state()['observed'], self.mac.defaults)
        self.booted.clear()
        self.settle()
        self.assertEqual(self.mac.defaults, {'input': 112, 'output': 70, 'system': 106})

    def test_refresh_does_not_recreate_a_released_holder(self):
        self.pin('SIM-A')
        self.pin('SIM-B')
        self.booted.discard('SIM-A')
        self.settle(drop='SIM-A')
        self.mac.defaults['output'] = AIRPODS_OUT['id']
        self.assertEqual(lane_audio.pin('SIM-A', backend=self.mac, out=self.out,
                                       lid_closed=lambda: False, refresh=True), [])
        self.assertEqual(self.mac.defaults['output'], AIRPODS_OUT['id'])
        self.assertEqual(list(lane_audio._read_state()['holders']), ['SIM-B'])

    def test_built_in_wired_and_virtual_defaults_are_left_alone(self):
        for current in (MAC_SPEAKERS, USB_OUT, TEAMS):
            with self.subTest(current=current['name']):
                self.mac.defaults.update(output=current['id'], system=current['id'], input=MAC_MIC['id'])
                self.mac.sets.clear()
                self.assertEqual(self.pin(), [])
                self.assertEqual(self.mac.sets, [])
                self.assertIn('SIM-A', lane_audio._read_state()['holders'])
                self.assertFalse(lane_audio._read_state().get('saved'))

    def test_nothing_changes_without_a_built_in_device_to_move_to(self):
        self.mac.listed = [AIRPODS_IN, AIRPODS_OUT]
        self.assertEqual(self.pin(), [])
        self.assertEqual(self.mac.sets, [])

    def test_a_closed_lid_without_a_display_leaves_the_defaults_alone(self):
        self.assertEqual(self.pin(lid_closed=True), [])
        self.assertEqual(self.mac.defaults, {'input': 112, 'output': 106, 'system': 106})
        self.assertIn('built-in speakers are off', self.out.getvalue())

    def test_a_second_simulator_keeps_the_original_devices_and_the_last_one_out_restores(self):
        self.pin('SIM-A')
        self.pin('SIM-B')  # the defaults are already built-in; the saved AirPods must survive
        self.booted.discard('SIM-A')
        self.settle()
        self.assertEqual(self.mac.defaults['output'], 92)  # SIM-B still plays
        self.booted.discard('SIM-B')
        self.settle()
        self.assertEqual(self.mac.defaults, {'input': 112, 'output': 106, 'system': 106})

    def test_a_default_chosen_by_hand_during_the_run_is_not_overridden(self):
        self.pin()
        self.mac.defaults['output'] = USB_OUT['id']
        self.booted.clear()
        self.settle()
        self.assertEqual(self.mac.defaults, {'input': 112, 'output': 70, 'system': 106})

    def test_a_device_that_left_the_mac_is_not_restored(self):
        self.pin()
        self.mac.listed = [d for d in self.mac.listed if d['uid'] not in ('pods:input', 'pods:output')]
        self.booted.clear()
        self.settle()
        self.assertEqual(self.mac.defaults, {'input': 99, 'output': 92, 'system': 92})
        self.assertFalse(lane_audio._state_path().exists())

    def test_the_next_boot_puts_right_a_run_that_died_without_settling(self):
        self.pin('SIM-A')
        self.booted.clear()  # SIM-A is gone, but nobody called settle
        self.pin('SIM-B')
        self.assertEqual(self.mac.defaults, {'input': 99, 'output': 92, 'system': 92})
        self.assertEqual(list(lane_audio._read_state()['holders']), ['SIM-B'])
        self.booted.clear()
        self.settle()
        self.assertEqual(self.mac.defaults, {'input': 112, 'output': 106, 'system': 106})

    def test_settle_does_nothing_when_it_cannot_tell_what_is_booted(self):
        self.pin()
        self.assertTrue(lane_audio._state_path().exists())

        def broken():
            raise OSError('simctl failed')
        self.assertEqual(lane_audio.settle(backend=self.mac, out=self.out, booted=broken), [])
        self.assertEqual(self.mac.defaults['output'], 92)
        self.assertTrue(lane_audio._state_path().exists())

    def test_a_refused_change_is_skipped_and_never_raises(self):
        self.mac.fail_on = 'output'
        changed = self.pin()
        self.assertEqual(self.mac.defaults['input'], 99)
        self.assertEqual(self.mac.defaults['output'], 106)
        self.assertEqual(len(changed), 2)
        self.assertIn('could not pin the output device', self.out.getvalue())

    def test_a_backend_that_cannot_load_never_fails_the_run(self):
        class Broken:
            def devices(self):
                raise OSError('no CoreAudio')
        self.assertEqual(lane_audio.pin('SIM-A', backend=Broken(), out=self.out, lid_closed=lambda: False), [])
        self.assertIn('pinning skipped', self.out.getvalue())

    def test_a_fake_simctl_or_the_off_switch_never_touches_the_real_devices(self):
        for name in ('SM_LANE_SIMCTL', 'SM_LANE_AUDIO'):
            with self.subTest(name=name), mock.patch.dict(os.environ, {name: 'off' if name == 'SM_LANE_AUDIO' else '/x'}), \
                    mock.patch.object(lane_audio, 'CoreAudio', side_effect=AssertionError('touched CoreAudio')):
                self.assertEqual(lane_audio.pin('SIM-A', out=self.out), [])
                self.assertEqual(lane_audio.settle(out=self.out), [])

    def test_the_closed_lid_check_reads_the_lid_and_the_displays(self):
        closed = '  |   "AppleClamshellState" = Yes\n'
        internal = '          Connection Type: Internal\n'
        external = internal + '          Connection Type: DisplayPort\n'
        replies = {'ioreg': closed, 'system_profiler': internal}
        read = lambda command: replies[Path(command[0]).name]  # noqa: E731
        self.assertTrue(lane_audio.speakers_off(read))
        replies['system_profiler'] = external
        self.assertFalse(lane_audio.speakers_off(read))
        replies['ioreg'] = '  |   "AppleClamshellState" = No\n'
        self.assertFalse(lane_audio.speakers_off(read))

        def broken(command):
            raise OSError('no ioreg')
        self.assertFalse(lane_audio.speakers_off(broken))


class CoreAudioTests(unittest.TestCase):
    def test_a_process_without_a_run_loop_receives_changed_defaults(self):
        # Model the HAL notification boundary documented in AudioHardwareDeprecated.h: the main run
        # loop is not pumped by this CLI. NULL rnlp asks HAL to own a notification thread instead.
        audio, core = mock.Mock(), mock.Mock()
        notifications = []

        def set_property(object_id, address, qualifier_size, qualifier, size, value):
            address = ctypes.cast(address, ctypes.POINTER(lane_audio.CoreAudio._Address)).contents
            self.assertEqual((object_id.value, address.selector, address.scope, address.element),
                             (1, lane_audio._code('rnlp'), lane_audio.GLOBAL, 0))
            self.assertEqual((qualifier_size, qualifier, size), (0, None, ctypes.sizeof(ctypes.c_void_p)))
            self.assertIsNone(ctypes.cast(value, ctypes.POINTER(ctypes.c_void_p)).contents.value)
            notifications.append(True)
            return 0

        def get_property(object_id, address, qualifier_size, qualifier, size, value):
            # A changed device is visible only once notification delivery is enabled.
            ctypes.cast(value, ctypes.POINTER(ctypes.c_uint32)).contents.value = 106 if notifications else 92
            return 0

        audio.AudioObjectSetPropertyData.side_effect = set_property
        audio.AudioObjectGetPropertyData.side_effect = get_property
        with mock.patch.object(lane_audio.ctypes.util, 'find_library', side_effect=['audio', 'core']), \
                mock.patch.object(lane_audio.ctypes, 'CDLL', side_effect=[audio, core]):
            backend = lane_audio.CoreAudio()
            self.assertEqual(backend.default('output'), 106)
        audio.AudioObjectSetPropertyData.assert_called_once()

    def test_a_refused_notification_thread_is_reported_instead_of_reading_stale_defaults(self):
        audio, core = mock.Mock(), mock.Mock()
        audio.AudioObjectSetPropertyData.return_value = -1
        with mock.patch.object(lane_audio.ctypes.util, 'find_library', side_effect=['audio', 'core']), \
                mock.patch.object(lane_audio.ctypes, 'CDLL', side_effect=[audio, core]):
            with self.assertRaisesRegex(OSError, 'notification'):
                lane_audio.CoreAudio()


if __name__ == '__main__':
    unittest.main()
