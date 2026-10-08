#!/bin/sh
# Manual trial only. Uses Xcode Cloud's existing checkout credentials and tools.
set -eu

if [ "${CI_XCODE_CLOUD:-}" != "TRUE" ]; then
    echo "Xcode Cloud trial preparation: no local actions."
    exit 0
fi

: "${CI_PRIMARY_REPOSITORY_PATH:?Xcode Cloud repository path is required}"
: "${SM_CLOUD_TRIAL_COMMIT:?Set the reviewed trial commit SHA in the workflow}"
case "${CI_START_CONDITION:-}" in
    manual|manual_rebuild) ;;
    *) echo "error: This trial allows only manual starts." >&2; exit 1 ;;
esac

cd "$CI_PRIMARY_REPOSITORY_PATH"
trial_actual_commit=$(git rev-parse HEAD)
if [ "$trial_actual_commit" != "$SM_CLOUD_TRIAL_COMMIT" ]; then
    echo "error: Checkout does not match the reviewed trial commit." >&2
    exit 1
fi
echo "Cloud trial checkout: $trial_actual_commit"

# Git LFS is pre-installed by Xcode Cloud. No tool or credential installation.
git lfs version
git lfs pull --include='App/SpokenMarginsApp/Resources/Supertonic/onnx/*.onnx' --exclude=''
python3 scripts/validate-supertonic-assets.py

# SessionKit is in this checkout. Let Xcode Cloud resolve the committed pins;
# never generate a project, update packages, or invoke the local Mac lane here.
test -f Packages/SessionKit/Package.swift
test -f SpokenMarginsNative.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
