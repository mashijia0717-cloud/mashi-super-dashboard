#!/bin/bash
# Command Line Tools 6.4: load Testing explicitly and keep AppKit's event loop alive.
set -euo pipefail
cd "$(dirname "$0")/.."
developer_dir="$(xcode-select -p)"
if [ -d "$developer_dir/Platforms/MacOSX.platform" ]; then
    frameworks="$developer_dir/Platforms/MacOSX.platform/Developer/Library/Frameworks"
    interop="$developer_dir/Platforms/MacOSX.platform/Developer/usr/lib"
    plugin="$developer_dir/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
else
    frameworks="$developer_dir/Library/Developer/Frameworks"
    interop="$developer_dir/Library/Developer/usr/lib"
    plugin="$developer_dir/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
fi
swift build --build-tests -Xswiftc -load-plugin-library -Xswiftc "$plugin"
bin_dir="$(swift build --show-bin-path)"
mkdir -p "$bin_dir/PackageFrameworks"
ln -sfn "$frameworks/Testing.framework" "$bin_dir/PackageFrameworks/Testing.framework"
ln -sfn "$interop/lib_TestingInterop.dylib" "$bin_dir/PackageFrameworks/lib_TestingInterop.dylib"
swiftc -parse-as-library -F "$frameworks" \
    -Xlinker -rpath -Xlinker "$frameworks" \
    -Xlinker -rpath -Xlinker "$interop" \
    Scripts/AppKitTestRunner.swift -o "$bin_dir/AppKitTestRunner"
"$bin_dir/AppKitTestRunner" "$bin_dir/CPAQuotaBarTests.xctest/Contents/MacOS/CPAQuotaBarTests" "$@"
