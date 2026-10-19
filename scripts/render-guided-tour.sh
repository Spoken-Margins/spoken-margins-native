#!/bin/zsh
# Re-renders the guided tour clip with the bundled Kitten voice (#2051) and prints what the manifest needs.
# Usage: scripts/render-guided-tour.sh [output.m4a]   (default: Site/onboarding/v1/guided-tour-v2.m4a)
set -euo pipefail
root=${0:A:h:h}
out=${1:-$root/Site/onboarding/v1/guided-tour-v2.m4a}
swift run -c release --package-path "$root/Packages/SessionKit" tour-render \
    --kitten "$root/App/SpokenMarginsApp/Resources/Kitten" \
    --text "$root/Site/onboarding/v1/guided-tour.txt" \
    --out "$out"
afinfo "$out" | grep -E "estimated duration|Data format"
echo "audioChecksumSHA256: $(shasum -a 256 "$out" | cut -d' ' -f1)"
