"""Refresh device UI and complete release after the bounded pull repair."""
import json
import runpy
h=runpy.run_path('artifacts/reviews/second-edition/run-remaining-checks.py',run_name='helpers')
v=h['verification']

def shutdown_if_booted(udid):
    devices=json.loads(v.capture(['xcrun','simctl','list','devices','available','--json']))['devices']
    device=next(d for group in devices.values() for d in group if d['udid']==udid)
    if device['state']=='Booted': h['command'](['xcrun','simctl','shutdown',udid])

def small_with_pull(run):
    device=h['SMALL']
    run.manifest['destination']={'udid':device,'name':'iPhone SE (3rd generation)','os':'18.6'}
    derived=h['ROOT']/'.build/verification/SpokenMarginsReleaseTests'
    base=['xcodebuild','-configuration','Debug','-project','SpokenMarginsNative.xcodeproj','-scheme','SpokenMarginsReleaseTests','-testPlan','Release','-destination','id='+device,'-derivedDataPath',str(derived)]
    cases={'SpokenMarginsAppUITests/Gate1FlowUITests/'+name for name in ['testLibraryCompactRowStaysDense','testPlaybackPrimaryActionsRemainVisibleWithLongTitleAndAccessibilityText','testWrittenMarginSaveSearchStarAndDiscardPreserveTheSource','testBuild23LayoutRegressionsRemainOperableAtAccessibilityType','testPlaybackPullsIntoTimelineAndReflectionControlsClearTheMiniPlayerAndKeyboard']}
    run.command('build-for-testing',base+['build-for-testing'],timeout=900)
    run.command('bundle-contracts',[h['sys'].executable,'scripts/verify-bundle.py',str(derived/'Build/Products/Debug-iphonesimulator/SpokenMarginsApp.app')])
    run.command('simulator-boot',['xcrun','simctl','boot',device],timeout=60)
    run.command('simulator-ready',['xcrun','simctl','bootstatus',device,'-b'],timeout=180)
    run.command('xcode-tests',base+['test-without-building','-parallel-testing-enabled','NO','-test-timeouts-enabled','YES','-resultBundlePath',str(run.output/'tests.xcresult')]+['-only-testing:'+x for x in sorted(cases)],timeout=900,expected=cases,tests=True)

shutdown_if_booted(h['PHONE'])
shutdown_if_booted(h['SMALL'])
h['named_plan']('fast',h['PHONE'])
h['named_plan']('ui',h['IPAD'])
shutdown_if_booted(h['IPAD'])
shutdown_if_booted(h['SMALL'])
h['evidence_run']('ui-small-ios18','Five small-phone iOS 18 routes including content pull',small_with_pull)
shutdown_if_booted(h['SMALL'])
h['named_plan']('release',h['PHONE'])
h['evidence_run']('generic-builds','Generic simulator and device builds',h['generic_builds'])
print('Final device matrix, release and generic builds passed.',flush=True)
