#!/bin/zsh
# Build a Developer ID signed, notarized, and stapled GitHub Release archive.
# This script never uploads an artifact to GitHub.
set -euo pipefail

task_root="${0:A:h:h}"
cd "$task_root"

fail() {
    print -u2 -- "Qbar release: $*"
    exit 1
}

[[ -n "${QBAR_SIGNING_IDENTITY:-}" ]] || fail "Set QBAR_SIGNING_IDENTITY to the full Developer ID Application identity."
[[ "$QBAR_SIGNING_IDENTITY" == "Developer ID Application: "* ]] || fail "QBAR_SIGNING_IDENTITY must be a Developer ID Application identity."
[[ -n "${QBAR_TEAM_ID:-}" ]] || fail "Set QBAR_TEAM_ID to the certificate's Apple team ID."
[[ "$QBAR_TEAM_ID" =~ '^[A-Z0-9]{10}$' ]] || fail "QBAR_TEAM_ID must be a 10-character Apple team ID."
[[ -n "${QBAR_NOTARY_PROFILE:-}" ]] || fail "Set QBAR_NOTARY_PROFILE to a notarytool Keychain profile."

for command_name in xcodegen xcodebuild xcrun codesign ditto security spctl shasum; do
    command -v "$command_name" >/dev/null 2>&1 || fail "Required command is unavailable: $command_name"
done

if ! /usr/bin/security find-identity -v -p codesigning | /usr/bin/grep -Fq -- "\"$QBAR_SIGNING_IDENTITY\""; then
    fail "The requested valid Developer ID Application identity is not installed in the Keychain."
fi

[[ -z "$(/usr/bin/git status --porcelain --untracked-files=normal)" ]] || fail "Commit or remove local changes before producing a release."

stage=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/qbar-release.XXXXXXXX") || fail "Could not create a temporary release directory."
cleanup() {
    [[ -n "${stage:-}" && -d "$stage" ]] && /bin/rm -rf -- "$stage"
}
trap cleanup EXIT

# Keep the release isolated from the user's installed Qbar and local build output.
xcodegen generate
xcodebuild \
    -project Qbar.xcodeproj \
    -scheme Qbar \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$stage/DerivedData" \
    'ONLY_ACTIVE_ARCH=NO' \
    'CODE_SIGN_STYLE=Manual' \
    "DEVELOPMENT_TEAM=$QBAR_TEAM_ID" \
    "CODE_SIGN_IDENTITY=$QBAR_SIGNING_IDENTITY" \
    'CODE_SIGNING_ALLOWED=YES' \
    build

[[ -z "$(/usr/bin/git status --porcelain --untracked-files=normal)" ]] || fail "The build changed tracked or untracked source files; commit the generated changes and retry."

built_app="$stage/DerivedData/Build/Products/Release/Qbar.app"
[[ -d "$built_app" ]] || fail "The Release build did not produce Qbar.app."
app="$stage/Qbar.app"
/usr/bin/ditto "$built_app" "$app"

info_plist="$app/Contents/Info.plist"
[[ -f "$info_plist" ]] || fail "The app has no Info.plist."
bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info_plist")
[[ "$bundle_id" == 'studio.qbar.mac' ]] || fail "Unexpected bundle ID: $bundle_id"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info_plist")
print -r -- "$version" | /usr/bin/grep -Eq '^[0-9]+(\.[0-9]+){1,2}$' || fail "Invalid release version: $version"

/usr/bin/lipo -verify_arch arm64 x86_64 "$app/Contents/MacOS/Qbar" >/dev/null || fail "The app is not a universal arm64/x86_64 build."
/usr/bin/codesign --verify --strict --deep --verbose=2 "$app" || fail "Code signature validation failed."
/usr/bin/codesign -dv --verbose=4 "$app" > "$stage/signature.txt" 2>&1 || fail "Could not inspect the code signature."
/usr/bin/grep -Fxq -- "Authority=$QBAR_SIGNING_IDENTITY" "$stage/signature.txt" || fail "The app is not signed by the requested Developer ID Application identity."
/usr/bin/grep -Fxq -- "TeamIdentifier=$QBAR_TEAM_ID" "$stage/signature.txt" || fail "The app has the wrong Team ID."
/usr/bin/grep -Eq '^CodeDirectory .*flags=.*\(runtime\)' "$stage/signature.txt" || fail "Hardened Runtime is not enabled."
/usr/bin/grep -q '^Timestamp=' "$stage/signature.txt" || fail "The Developer ID signature has no secure timestamp."

# A direct-download build must not accidentally inherit development or Store entitlements.
/usr/bin/codesign -d --entitlements :- "$app" > "$stage/entitlements.plist" 2>/dev/null || fail "Could not inspect the app entitlements."
if [[ -s "$stage/entitlements.plist" ]]; then
    /usr/bin/plutil -lint "$stage/entitlements.plist" >/dev/null || fail "The signed entitlements are malformed."
    for forbidden_key in com.apple.security.get-task-allow com.apple.security.app-sandbox; do
        value=$(/usr/libexec/PlistBuddy -c "Print :$forbidden_key" "$stage/entitlements.plist" 2>/dev/null || true)
        [[ "$value" != true ]] || fail "The release contains forbidden entitlement $forbidden_key."
    done
fi

notary_zip="$stage/Qbar-notary.zip"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app" "$notary_zip"
notary_result="$stage/notary-result.plist"
if ! xcrun notarytool submit "$notary_zip" \
    --keychain-profile "$QBAR_NOTARY_PROFILE" \
    --wait --timeout 2h --output-format plist > "$notary_result"; then
    if [[ -s "$notary_result" ]]; then
        /usr/bin/plutil -p "$notary_result" >&2 || true
        failed_id=$(/usr/libexec/PlistBuddy -c 'Print :id' "$notary_result" 2>/dev/null || true)
        [[ -z "$failed_id" ]] || xcrun notarytool log "$failed_id" --keychain-profile "$QBAR_NOTARY_PROFILE" >&2 || true
    fi
    fail "Notarization submission failed; no release archive was produced."
fi
notary_status=$(/usr/libexec/PlistBuddy -c 'Print :status' "$notary_result" 2>/dev/null || true)
if [[ "$notary_status" != 'Accepted' ]]; then
    notary_id=$(/usr/libexec/PlistBuddy -c 'Print :id' "$notary_result" 2>/dev/null || true)
    [[ -z "$notary_id" ]] || xcrun notarytool log "$notary_id" --keychain-profile "$QBAR_NOTARY_PROFILE" >&2 || true
    fail "Apple did not accept the notarization ($notary_status); no release archive was produced."
fi

xcrun stapler staple "$app" || fail "Could not staple the notarization ticket."
xcrun stapler validate "$app" || fail "The stapled ticket did not validate."
/usr/bin/codesign --verify --strict --deep --verbose=2 "$app" || fail "The stapled app failed code signature validation."
/usr/sbin/spctl --assess --type execute --verbose=4 "$app" || fail "Gatekeeper did not accept the stapled app."

archive_name="Qbar-$version-macos-universal.zip"
archive="$stage/$archive_name"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app" "$archive"
/bin/mkdir "$stage/extracted"
/usr/bin/ditto -x -k "$archive" "$stage/extracted"
extracted_app="$stage/extracted/Qbar.app"
[[ -d "$extracted_app" ]] || fail "The final archive did not contain Qbar.app."
/usr/bin/codesign --verify --strict --deep --verbose=2 "$extracted_app" || fail "The archived app failed code signature validation."
xcrun stapler validate "$extracted_app" || fail "The archived app lost its notarization ticket."
/usr/sbin/spctl --assess --type execute --verbose=4 "$extracted_app" || fail "Gatekeeper rejected the archived app."
checksum_name="$archive_name.sha256"
(cd "$stage" && /usr/bin/shasum -a 256 "$archive_name" > "$checksum_name")

/bin/mkdir -p dist
release_lock="dist/.qbar-release.lock"
/bin/mkdir "$release_lock" || fail "Another release is finishing, or a stale release lock exists."
cleanup_output() {
    /bin/rmdir "$release_lock" 2>/dev/null || true
}
trap 'cleanup_output; cleanup' EXIT
[[ ! -e "dist/$archive_name" && ! -e "dist/$checksum_name" ]] || fail "Release files already exist in dist; refusing to overwrite them."
/bin/mv "$archive" "dist/$archive_name" || fail "Could not move the release archive into dist."
if ! /bin/mv "$stage/$checksum_name" "dist/$checksum_name"; then
    /bin/rm -f -- "dist/$archive_name"
    fail "Could not move the checksum into dist; removed the partial release archive."
fi
print -- "Notarized release ready: $task_root/dist/$archive_name"
print -- "SHA-256: $task_root/dist/$checksum_name"
print -- "No GitHub release was created or uploaded."
