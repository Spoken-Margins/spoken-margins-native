#!/bin/sh
set -eu

framework_info_plist=${1:?framework Info.plist path is required}
deployment_target=${2:?deployment target is required}

if [ ! -f "$framework_info_plist" ]; then
    exit 0
fi

/usr/libexec/PlistBuddy -c "Set :MinimumOSVersion $deployment_target" "$framework_info_plist"
