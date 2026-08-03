#!/bin/bash

set -euo pipefail

product_framework="${BUILT_PRODUCTS_DIR}/onnxruntime.framework"
product_binary="${product_framework}/onnxruntime"
embedded_framework="${TARGET_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}/onnxruntime.framework"
app_binary="${TARGET_BUILD_DIR}/${EXECUTABLE_PATH}"
stamp_file="${SCRIPT_OUTPUT_FILE_0:-}"

if [[ ! -d "${embedded_framework}" ]]; then
    if [[ -n "${stamp_file}" ]]; then
        /usr/bin/touch "${stamp_file}"
    fi
    exit 0
fi

if [[ ! -f "${product_binary}" ]]; then
    echo "error: Refusing to remove embedded ONNX Runtime without its package build product." >&2
    exit 1
fi

if ! /usr/bin/file "${product_binary}" | /usr/bin/grep -q "ar archive"; then
    echo "error: Refusing to remove embedded ONNX Runtime because the package product is not static." >&2
    exit 1
fi

if [[ ! -f "${app_binary}" ]]; then
    echo "error: Refusing to inspect ONNX Runtime linkage because the app executable is missing." >&2
    exit 1
fi

if /usr/bin/otool -L "${app_binary}" | /usr/bin/grep -Fq "@rpath/onnxruntime.framework/onnxruntime"; then
    echo "error: Refusing to remove embedded ONNX Runtime because the app dynamically links it." >&2
    exit 1
fi

# ONNX Runtime's code is already statically linked into the app. Xcode 26 can
# additionally synthesize and embed a redundant framework bundle, which App
# Store Connect rejects because its deployment metadata does not match the
# synthesized executable. The exact bundle is safe to remove after the guards
# above prove it is not a runtime dependency.
/bin/rm -rf "${embedded_framework}"
if [[ -n "${stamp_file}" ]]; then
    /usr/bin/touch "${stamp_file}"
fi
echo "Removed redundant embedded static ONNX Runtime framework."
