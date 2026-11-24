#!/bin/bash
set -euo pipefail

project_root=$(cd "$(dirname "$0")/.." && pwd -P)
app_name='Super Dashboard'
version='3.0.6'
bundle_name='CPAQuotaBar_CPAQuotaBar.bundle'
configuration=release
output_dir="$project_root/dist"
binary=''
resource_bundle=''
helpers_dir=''
skip_build=0
make_zip=0
stage=''

usage() {
    cat <<'USAGE'
Usage: Scripts/package-app.sh [options]
  -o, --output-dir DIR       Output directory (default: project/dist)
  --binary FILE             Use an existing CPAQuotaBar; implies --skip-build
  --skip-build              Use the existing Xcode build product without rebuilding
  --configuration NAME      release (default) or debug
  --resource-bundle DIR     Matching CPAQuotaBar_CPAQuotaBar.bundle
                            (default: next to the selected binary)
  --helpers-dir DIR         Reuse all four already rebuilt, relocatable helpers
                            (default: compile Helpers/ into temporary staging)
  --zip                     Also create Super Dashboard-3.0.6.zip
  -h, --help                Show this help

Requires macOS and an arm64 application binary with an app-aware resource
accessor (SwiftPM's Xcode build system). Building the app requires Xcode;
compiling only helpers requires Xcode/Command Line Tools.
Never installs or launches the application/helpers.
Existing output is not overwritten; choose a fresh directory for another run.
USAGE
}

die() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

need_value() {
    [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || die "$1 requires a value"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -o|--output-dir) need_value "$@"; output_dir="$2"; shift 2 ;;
        --binary) need_value "$@"; binary="$2"; skip_build=1; shift 2 ;;
        --skip-build) skip_build=1; shift ;;
        --configuration) need_value "$@"; configuration="$2"; shift 2 ;;
        --resource-bundle) need_value "$@"; resource_bundle="$2"; shift 2 ;;
        --helpers-dir) need_value "$@"; helpers_dir="$2"; shift 2 ;;
        --zip) make_zip=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown argument: $1 (see --help)" ;;
    esac
done

[[ $(uname -s) == Darwin ]] || die 'Packaging requires macOS'
case "$configuration" in release|debug) ;; *) die 'Configuration must be release or debug' ;; esac
[[ ! -e "$output_dir/$app_name.app" && ! -L "$output_dir/$app_name.app" ]] || die "Output already exists: $output_dir/$app_name.app"
if [[ "$make_zip" == 1 ]]; then
    [[ ! -e "$output_dir/$app_name-$version.zip" && ! -L "$output_dir/$app_name-$version.zip" ]] || die 'Output ZIP already exists'
fi

if [[ "$skip_build" == 0 ]]; then
    /usr/bin/xcrun swift build --build-system xcode --arch arm64 --package-path "$project_root" --configuration "$configuration" --product CPAQuotaBar
fi
if [[ -z "$binary" ]]; then
    bin_dir=$(/usr/bin/xcrun swift build --build-system xcode --arch arm64 --package-path "$project_root" --configuration "$configuration" --show-bin-path)
    binary="$bin_dir/CPAQuotaBar"
fi
[[ -f "$binary" && -x "$binary" ]] || die "Missing executable: $binary; build it first or pass --binary"
binary=$(cd "$(dirname "$binary")" && printf '%s/%s' "$(pwd -P)" "$(basename "$binary")")
[[ $(/usr/bin/lipo -archs "$binary") == arm64 ]] || die 'The bundled display helpers currently support an arm64 application only'
[[ $(/usr/bin/file -b "$binary") == *'Mach-O 64-bit executable'* ]] || die 'The application must be a Mach-O executable'
if /usr/bin/grep -aF 'could not load resource bundle: from' "$binary" >/dev/null; then
    die 'This SwiftPM executable only searches the app root/build directory for resources. Rebuild with --build-system xcode before packaging; an app-root resource bundle cannot be signed.'
fi
if [[ -z "$resource_bundle" ]]; then resource_bundle="$(dirname "$binary")/$bundle_name"; fi
[[ -d "$resource_bundle" ]] || die "Missing matching resource bundle: $resource_bundle"
resource_bundle=$(cd "$resource_bundle" && pwd -P)
resource_payload="$resource_bundle"
if [[ -d "$resource_bundle/Contents/Resources" ]]; then resource_payload="$resource_bundle/Contents/Resources"; fi
for resource in MaShiDashboard.icns AppIcon.png 9ROUTER_LICENSE.txt libimobiledevice/COPYING libimobiledevice/NOTICE.md; do
    [[ -f "$resource_payload/$resource" ]] || die "Resource bundle is incomplete: $resource"
done
for tool in idevice_id ideviceinfo comptest; do
    [[ -x "$resource_payload/libimobiledevice/bin/$tool" ]] || die "Missing mobile-device tool: $tool"
done
for library in libimobiledevice-1.0.6.dylib libimobiledevice-glue-1.0.0.dylib libusbmuxd-2.0.6.dylib libplist-2.0.4.dylib libssl.3.dylib libcrypto.3.dylib; do
    [[ -f "$resource_payload/libimobiledevice/lib/$library" ]] || die "Missing mobile-device library: $library"
done
if [[ -n "$helpers_dir" ]]; then
    [[ -d "$helpers_dir" ]] || die "Missing helpers directory: $helpers_dir"
    helpers_dir=$(cd "$helpers_dir" && pwd -P)
fi

mkdir -p "$output_dir"
output_dir=$(cd "$output_dir" && pwd -P)
stage=$(mktemp -d "$output_dir/.package-app.XXXXXX")
cleanup() {
    if [[ -n "$stage" && -d "$stage" ]]; then rm -rf "$stage"; fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
app="$stage/$app_name.app"
macos="$app/Contents/MacOS"
resources="$app/Contents/Resources"
mkdir -p "$macos" "$resources/Licenses"
/usr/bin/ditto "$binary" "$macos/CPAQuotaBar"
/usr/bin/ditto "$resource_bundle" "$resources/$bundle_name"
/usr/bin/ditto "$resource_payload/MaShiDashboard.icns" "$resources/MaShiDashboard.icns"
/usr/bin/ditto "$project_root/THIRD_PARTY_NOTICES.md" "$resources/THIRD_PARTY_NOTICES.md"
/usr/bin/ditto "$project_root/Helpers/m1ddc-vendor/LICENSE" "$resources/Licenses/m1ddc-MIT.txt"
/usr/bin/ditto "$project_root/Helpers/Licenses" "$resources/Licenses"

if [[ -z "$helpers_dir" ]]; then
    printf 'Compiling display helpers (isolated module cache; no SwiftPM)...\n'
    helpers_dir="$stage/helpers"
    module_cache="$stage/module-cache"
    mkdir -p "$helpers_dir" "$module_cache"
    sdk=$(/usr/bin/xcrun --sdk macosx --show-sdk-path)
    helper_sources="$project_root/Helpers"
    /usr/bin/xcrun --sdk macosx clang -arch arm64 -isysroot "$sdk" -mmacosx-version-min=14.0 -O2 -fmodules \
        -fmodules-cache-path="$module_cache" -I "$helper_sources/m1ddc-vendor/headers" \
        "$helper_sources/DDCControl.m" "$helper_sources/m1ddc-vendor/sources/ioregistry.m" \
        -framework Foundation -framework IOKit -framework ApplicationServices -framework CoreDisplay \
        -o "$helpers_dir/DDCControl"
    /usr/bin/xcrun --sdk macosx swiftc -O -sdk "$sdk" -target arm64-apple-macosx14.0 \
        -module-cache-path "$module_cache" -I "$helper_sources/DisplayTopology" "$helper_sources/DisplayManager.swift" -o "$helpers_dir/DisplayManager"
    /usr/bin/xcrun --sdk macosx clang -arch arm64 -isysroot "$sdk" -mmacosx-version-min=14.0 -O2 -fmodules -fobjc-arc \
        -fmodules-cache-path="$module_cache" "$helper_sources/ScreenBlank.m" \
        -framework Cocoa -framework ApplicationServices -framework Carbon -framework IOKit -o "$helpers_dir/ScreenBlank"
    /usr/bin/xcrun --sdk macosx clang -arch arm64 -isysroot "$sdk" -mmacosx-version-min=14.0 -O2 \
        "$helper_sources/builtin_brightness.c" -F "$sdk/System/Library/PrivateFrameworks" \
        -framework ApplicationServices -framework CoreGraphics -framework DisplayServices -o "$helpers_dir/builtin_brightness"
fi

for helper in DDCControl DisplayManager ScreenBlank builtin_brightness; do
    [[ -x "$helpers_dir/$helper" ]] || die "Missing executable helper: $helper"
    [[ $(/usr/bin/file -b "$helpers_dir/$helper") == *'Mach-O'*'executable'* ]] || die "Helper is not a Mach-O executable: $helper"
    if /usr/bin/grep -aE '/Applications/显示器控制台[.]app|Library/Scripts/builtin_brightness' "$helpers_dir/$helper" >/dev/null; then
        die "$helper still references the legacy installation; rebuild it from Helpers/"
    fi
    /usr/bin/ditto "$helpers_dir/$helper" "$macos/$helper"
done
chmod 755 "$macos/CPAQuotaBar" "$macos/DDCControl" "$macos/DisplayManager" "$macos/ScreenBlank" "$macos/builtin_brightness"

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.local.CPAQuotaBar</string>
    <key>CFBundleExecutable</key><string>CPAQuotaBar</string>
    <key>CFBundleName</key><string>Super Dashboard</string>
    <key>CFBundleDisplayName</key><string>Super Dashboard</string>
    <key>CFBundleShortVersionString</key><string>$version</string>
    <key>CFBundleVersion</key><string>$version</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
    <key>CFBundleIconFile</key><string>MaShiDashboard.icns</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSLocalNetworkUsageDescription</key><string>读取同一网络中已配对 Apple 设备的电量和连接状态。</string>
</dict>
</plist>
PLIST
/usr/bin/plutil -lint "$app/Contents/Info.plist"
/usr/bin/xattr -cr "$app"

signed_count=0
while IFS= read -r -d '' nested; do
    if [[ $(/usr/bin/file -b "$nested") == *'Mach-O'* ]]; then
        /usr/bin/lipo -verify_arch arm64 "$nested"
        external_dependencies=$(/usr/bin/otool -L "$nested" | /usr/bin/awk '/^\t\// { sub(/^[\t ]+/, ""); sub(/ \(compatibility.*$/, ""); if ($0 !~ /^\/System\/Library\// && $0 !~ /^\/usr\/lib\//) print }')
        [[ -z "$external_dependencies" ]] || die "Non-system absolute dependency in $nested: $external_dependencies"
        while IFS= read -r runtime_path; do
            case "$runtime_path" in
                /Applications/Xcode*.app/Contents/Developer/*|/Library/Developer/CommandLineTools/*)
                    /usr/bin/install_name_tool -delete_rpath "$runtime_path" "$nested"
                    ;;
            esac
        done < <(/usr/bin/otool -l "$nested" | /usr/bin/awk '/cmd LC_RPATH/ { getline; getline; sub(/^[ \t]*path /, ""); sub(/ \(offset [0-9]+\)$/, ""); print }')
        if [[ "$nested" != "$macos/CPAQuotaBar" ]]; then
            /usr/bin/codesign --force --sign - --timestamp=none "$nested"
            /usr/bin/codesign --verify --strict "$nested"
        fi
        signed_count=$((signed_count + 1))
    fi
done < <(/usr/bin/find "$app/Contents" -type f -print0)
if [[ -f "$resources/$bundle_name/Contents/Info.plist" || -f "$resources/$bundle_name/Info.plist" ]]; then
    /usr/bin/codesign --force --sign - --timestamp=none "$resources/$bundle_name"
fi
/usr/bin/codesign --force --sign - --timestamp=none "$app"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$app"

if [[ "$make_zip" == 1 ]]; then
    /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app" "$stage/$app_name-$version.zip"
fi
mv "$app" "$output_dir/$app_name.app"
printf 'Verified %s Mach-O files; packaged: %s\n' "$signed_count" "$output_dir/$app_name.app"
if [[ "$make_zip" == 1 ]]; then
    mv "$stage/$app_name-$version.zip" "$output_dir/$app_name-$version.zip"
    /usr/bin/shasum -a 256 "$output_dir/$app_name-$version.zip"
fi
