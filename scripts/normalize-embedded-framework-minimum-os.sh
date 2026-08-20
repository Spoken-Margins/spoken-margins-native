#!/bin/sh
set -eu

framework_path=${1:?framework path is required}
deployment_target=${2:?deployment target is required}
framework_info_plist="$framework_path/Info.plist"

if [ ! -f "$framework_info_plist" ]; then
    exit 0
fi

/usr/libexec/PlistBuddy -c "Set :MinimumOSVersion $deployment_target" "$framework_info_plist"

# Xcode signs binary-package frameworks when it copies them into the app. This
# phase intentionally changes the copied framework afterward, so the framework
# must be signed again before Xcode seals the containing app. A desktop
# codesign verification can otherwise report the app as valid even though an
# iOS device rejects the modified nested framework during installation.
if [ "${CODE_SIGNING_ALLOWED:-NO}" = "YES" ]; then
    signing_identity=${EXPANDED_CODE_SIGN_IDENTITY:-${CODE_SIGN_IDENTITY:-}}
    if [ -z "$signing_identity" ]; then
        echo "error: Cannot re-sign $framework_path without a code-signing identity." >&2
        exit 1
    fi

    /usr/bin/codesign \
        --force \
        --sign "$signing_identity" \
        --timestamp=none \
        --preserve-metadata=identifier,entitlements,flags \
        --generate-entitlement-der \
        "$framework_path"

    /usr/bin/codesign --verify --strict --verbose=2 "$framework_path"
fi
