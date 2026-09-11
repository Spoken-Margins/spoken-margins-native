"""Final two-color binding repair: complete release gate and generic builds."""
import runpy
h=runpy.run_path('artifacts/reviews/second-edition/run-remaining-checks.py',run_name='helpers')
h['command'](['xcrun','simctl','shutdown',h['PHONE']])
h['named_plan']('release',h['PHONE'])
h['evidence_run']('generic-builds','Generic simulator and device builds',h['generic_builds'])
print('Final contrast candidate release and builds passed.',flush=True)
