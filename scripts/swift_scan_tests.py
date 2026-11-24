#!/usr/bin/env python3
"""The Python tests that read the app's Swift sources and the files beside them (#5220).

A PR that added a button the mini-player keep-out forbids, a tap frame under 44 pt or a share glyph could pass its own
checks and fail only in the merge queue: #5157 on 2026-11-23 (`test_mini_player_keep_out`, `test_outer_tap_frame`,
`test_share_export_glyphs`). Since #5281 every PR runs all runner tests, these included. This list is what to run
locally for a change under App/ or Packages/ (about a minute), and the lane's readers scope (verify-tests.py
RUNNER_TEST_READERS) runs it on an App-only diff.

  python3 scripts/swift_scan_tests.py          run the scans (do this for any change under App/ or Packages/)
  python3 scripts/swift_scan_tests.py --list   print the modules

A new test that reads App/ or Packages/ joins SCANS with one line. `test_swift_scan_tests.py` finds every test module
that names a path under App/ or Packages/, itself or through a scripts/ module it loads, and fails unless the module
is in SCANS or in NOT_SCANS with a reason.

How the list was made (2026-11-24): each such module was run on this tree and on a copy with App/ and Packages/
removed. The ones that failed only in the copy read the tree (a few also read Info.plist or docs that name Swift
files); six guards that pass on an empty tree (container identifiers, outer tap frame, negative sleeps, ordered
store requests, repeat triggers, failed recorder start) were added by reading them. Together they ran in 25 to 60 s in one
process (a cloud box, a hosted runner).
"""
import re
import sys
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent
TESTS = SCRIPTS / 'tests'
# A module may read the app's tree when it names an App/ or Packages/ path: a Swift file, or a file beside the Swift
# code such as App/SpokenMarginsApp/Info.plist, which an app PR changes just the same.
TREE_PATH = re.compile(r'''["'](?:App|Packages)(?:/[^"'\n]*)?["']''')
LOADED = re.compile(r'''^\s*(?:import|from)\s+([A-Za-z_]\w*)|["']([\w-]+)\.py["']''', re.M)

SCANS = (
    'test_accent_color_wiring', 'test_adaptive_stack_fit', 'test_app_test_negative_sleeps', 'test_app_test_poll_loops',
    'test_article_entry_followups', 'test_baseline_build_34', 'test_beat_kindle_job_table', 'test_building_md',
    'test_camera_wording', 'test_container_identifiers', 'test_dark_toolbar_background_visible', 'test_designated_agent_links',
    'test_dock_dynamic_type', 'test_dynamic_type_add_and_browse', 'test_dynamic_type_clock_and_titles', 'test_dynamic_type_following_rows',
    'test_dynamic_type_library_rows', 'test_dynamic_type_live_activity', 'test_filled_button_contrast', 'test_filled_button_labels',
    'test_following_row_more_menu', 'test_friend_path_words', 'test_hosted_app_paths', 'test_import_navigation_gate',
    'test_increase_contrast_wiring', 'test_interjection_writes', 'test_item_screen_nested_lazy_stacks', 'test_listener_error_text_guard',
    'test_listener_tap_opens_off_main', 'test_listener_words', 'test_live_activity_colors', 'test_main_thread_labels',
    'test_map_text_gate', 'test_microphone_wording', 'test_mini_player_keep_out', 'test_opml_import_done_closes_host',
    'test_ordered_store_requests', 'test_outer_tap_frame', 'test_overview_docs', 'test_package_resolved',
    'test_package_watch', 'test_phone_build_gate', 'test_playback_clock_followers', 'test_podcast_anchor_benchmark',
    'test_public_source_check_callers', 'test_recorder_failed_start', 'test_reduce_motion', 'test_release_gate',
    'test_repeat_trigger_scan', 'test_resume_owners', 'test_retired_names', 'test_row_accessibility_actions',
    'test_screen_change_cue', 'test_screen_title_heading', 'test_search_field_keyboard', 'test_segmented_picker_guard',
    'test_selected_checkmarks_hidden', 'test_selected_trait', 'test_server_contact_consent', 'test_sessionkit_test_inputs',
    'test_share_cleanup_words', 'test_share_export_glyphs', 'test_share_link_policy_pages', 'test_share_review_card_words',
    'test_sharing_kit', 'test_shipped_compat_filter', 'test_siri_phrases', 'test_smallest_type_guard',
    'test_system_callback_isolation', 'test_tap_target_styles', 'test_task_cost_map', 'test_test_clock_ceilings',
    'test_third_party_notices', 'test_tracked_presentations', 'test_type3_lookup_gate', 'test_ui_test_guided_tour_fetch',
    'test_ui_test_hooks_debug_only', 'test_ui_test_scroll_view_lookups', 'test_voiceover_label_nits',
    # This list's own guard, so a PR that adds a test reading App/ learns on its own check that it must list it.
    'test_swift_scan_tests',
)

PIPELINE = ('tests the lane, CI, release or repository tools; App/ and Packages/ appear in it only as path inputs '
            'or fixtures, and the merge group runs it with every runner test')
CONTRACTS = ('checks contracts, fixtures or catalog data, not a rule on the Swift code; the portable plan\'s contracts '
             'step validates the tree')
NOT_SCANS = {
    'test_main_t3': PIPELINE,
    'test_check_build29_database': ('checks that Build 29 opens the database, on its own fixtures; it reads only '
                                    'SessionKit\'s Package.resolved, which sends a PR to the Mac checks'),
    'test_sm_build_cache': PIPELINE,
    'test_xcresult_attachments': PIPELINE,
    'test_catalog_packs_contract': CONTRACTS,
    'test_check_gitleaks': PIPELINE,
    'test_check_public_tree': PIPELINE,
    'test_ci_harness': PIPELINE,
    'test_ci_model': PIPELINE,
    'test_ci_step_budgets': PIPELINE,
    'test_codeowners': PIPELINE,
    'test_conflict_report': PIPELINE,
    'test_daily_phone_plan': PIPELINE,
    'test_deploy_check': PIPELINE,
    'test_diagnostics_hangs': PIPELINE,
    'test_fast_portable': PIPELINE,
    'test_fast_split_plans': PIPELINE,
    'test_hosted_package_cache': PIPELINE,
    'test_hot_file_ratchet': PIPELINE,
    'test_hot_file_ratchet_fast_step': PIPELINE,
    'test_lane_audio_window': PIPELINE,
    'test_lane_guard': PIPELINE,
    'test_lane_inherited_holds': PIPELINE,
    'test_lane_ledger': PIPELINE,
    'test_lane_merge_rules': PIPELINE,
    'test_lane_slots': PIPELINE,
    'test_lane_t3': PIPELINE,
    'test_linux_core_tests': PIPELINE,
    'test_mac_checks_scope': PIPELINE,
    'test_main_t3_bisect': PIPELINE,
    'test_main_thread_reads': 'the portable plan runs this guard on the tree as its main-thread-reads step (8 s)',
    'test_merge_policy': PIPELINE,
    'test_ops_checkout': PIPELINE,
    'test_owner_tap_alert': PIPELINE,
    'test_phone_build': PIPELINE,
    'test_plan_timeout': PIPELINE,
    'test_portable_formats': CONTRACTS,
    'test_pr_issue_link': PIPELINE,
    'test_quiz_page': CONTRACTS,
    'test_rank_main_thread_reads': PIPELINE,
    'test_real_use_proof': PIPELINE,
    'test_required_check_dispatch': PIPELINE,
    'test_research_tests': PIPELINE,
    'test_sessionkit_pass': PIPELINE,
    'test_sessionkit_steps': PIPELINE,
    'test_shipped_compat_step': PIPELINE,
    'test_slow_tier': PIPELINE,
    'test_sm_project_sync': PIPELINE,
    'test_sm_status': PIPELINE,
    'test_split_move': PIPELINE,
    'test_starter_catalog': CONTRACTS,
    'test_test_scope': PIPELINE,
    'test_test_trust_own_commits': PIPELINE,
    'test_tools_step': PIPELINE,
    'test_validate_contracts': CONTRACTS,
    'test_verification': PIPELINE,
    'test_verify_inputs': PIPELINE,
    'test_voice_catalog': CONTRACTS,
    'test_web_step_node': PIPELINE,
    'test_xcodebuild_finish': PIPELINE,
}


def names_swift_tree(text):
    return bool(TREE_PATH.search(text))


def swift_tree_readers(scripts=SCRIPTS):
    """{test module: why} for every scripts/tests module that names a path under App/ or Packages/, itself or through a scripts/
    module it imports or loads by file name. This module and its own test are left out: they name it to find it."""
    own = {Path(__file__).stem, 'test_' + Path(__file__).stem}
    guards = {path.stem for path in scripts.glob('*.py')
              if path.stem not in own and names_swift_tree(path.read_text(encoding='utf-8'))}
    found = {}
    for path in sorted((scripts / 'tests').glob('test_*.py')):
        if path.stem in own:
            continue
        text = path.read_text(encoding='utf-8')
        why = ['itself'] if names_swift_tree(text) else []
        loaded = {a or b for a, b in LOADED.findall(text)}
        why += sorted(loaded & guards)
        if why:
            found[path.stem] = why
    return found


def suite():
    sys.path.insert(0, str(TESTS))
    return unittest.defaultTestLoader.loadTestsFromNames(SCANS)


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    if argv == ['--list']:
        print('\n'.join(SCANS))
        return 0
    if argv:
        print(__doc__, file=sys.stderr)
        return 2
    result = unittest.TextTestRunner().run(suite())
    return 0 if result.wasSuccessful() else 1


if __name__ == '__main__':
    sys.exit(main())
