import runpy
h=runpy.run_path('artifacts/reviews/second-edition/run-remaining-checks.py',run_name='helpers')
def body(run):
    run.manifest['destination']={'udid':h['SMALL'],'name':'iPhone SE (3rd generation)','os':'18.6'}
    base=['xcodebuild','-configuration','Debug','-project','SpokenMarginsNative.xcodeproj','-scheme','SpokenMarginsReleaseTests','-testPlan','Release','-destination','id='+h['SMALL'],'-derivedDataPath',str(h['ROOT']/'.build/verification/SpokenMarginsReleaseTests')]
    cases={'SpokenMarginsAppUITests/Gate1FlowUITests/'+name for name in ['testPlaybackPullsIntoTimelineAndReflectionControlsClearTheMiniPlayerAndKeyboard']}
    run.command('build-for-testing',base+['build-for-testing'],timeout=900)
    run.command('xcode-tests',base+['test-without-building','-parallel-testing-enabled','NO','-test-timeouts-enabled','YES','-resultBundlePath',str(run.output/'tests.xcresult')]+['-only-testing:'+x for x in sorted(cases)],timeout=500,expected=cases,tests=True)
h['evidence_run']('small-return-repair','Release UI: ordinary back-button tap after reflection',body)
