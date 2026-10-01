#!/bin/zsh
# Package a Developer ID signed app exported from Xcode Organizer.
# The source app is never changed; no artifact is uploaded to GitHub.
set -euo pipefail

task_root="${0:A:h:h}"
cd "$task_root"

fail() {
    print -u2 -- "Qbar package: $*"
    exit 1
}

[[ $# -eq 1 ]] || fail "Usage: QBAR_TEAM_ID=CFZ7CJRP9T zsh Scripts/package-notarized.sh /path/to/Qbar.app"
source_app="${1:A}"
[[ -d "$source_app" && -f "$source_app/Contents/Info.plist" ]] || fail "Pass an existing Qbar.app bundle exported by Xcode Organizer."

team_id="${QBAR_TEAM_ID:-CFZ7CJRP9T}"
[[ "$team_id" =~ '^[A-Z0-9]{10}$' ]] || fail "QBAR_TEAM_ID must be a 10-character Apple team ID."

for command_name in codesign ditto lipo plutil shasum spctl xcrun; do
    command -v "$command_name" >/dev/null 2>&1 || fail "Required command is unavailable: $command_name"
done

expected_version=$(/usr/bin/awk '$1 == "MARKETING_VERSION:" { gsub(/"/, "", $2); print $2; exit }' project.yml)
expected_build=$(/usr/bin/awk '$1 == "CURRENT_PROJECT_VERSION:" { gsub(/"/, "", $2); print $2; exit }' project.yml)
[[ -n "$expected_version" && -n "$expected_build" ]] || fail "Could not read the expected version and build from project.yml."

stage=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/qbar-package.XXXXXXXX") || fail "Could not create a temporary package directory."
release_lock=""
cleanup() {
    [[ -z "$release_lock" || ! -d "$release_lock" ]] || /bin/rmdir "$release_lock" 2>/dev/null || true
    [[ -z "${stage:-}" || ! -d "$stage" ]] || /bin/rm -rf -- "$stage"
}
trap cleanup EXIT

app="$stage/Qbar.app"
/usr/bin/ditto "$source_app" "$app" || fail "Could not copy the exported app."
info_plist="$app/Contents/Info.plist"
bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info_plist") || fail "Could not read the bundle ID."
[[ "$bundle_id" == 'studio.qbar.mac' ]] || fail "Unexpected bundle ID: $bundle_id"
executable=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$info_plist") || fail "Could not read the executable name."
[[ "$executable" == 'Qbar' && -f "$app/Contents/MacOS/Qbar" ]] || fail "The exported app has an unexpected executable."
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info_plist") || fail "Could not read the app version."
build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$info_plist") || fail "Could not read the app build."
print -r -- "$version" | /usr/bin/grep -Eq '^[0-9]+(\.[0-9]+){1,2}$' || fail "Invalid app version: $version"
[[ "$version" == "$expected_version" && "$build" == "$expected_build" ]] || fail "App version/build $version ($build) differs from project.yml $expected_version ($expected_build)."

/usr/bin/lipo "$app/Contents/MacOS/Qbar" -verify_arch arm64 x86_64 >/dev/null || fail "The app is not a universal arm64/x86_64 build."
/usr/bin/codesign --verify --strict --deep --verbose=2 "$app" || fail "Code signature validation failed."
/usr/bin/codesign -dv --verbose=4 "$app" > "$stage/signature.txt" 2>&1 || fail "Could not inspect the code signature."
/usr/bin/grep -Eq "^Authority=Developer ID Application: .+ \($team_id\)$" "$stage/signature.txt" || fail "The app is not signed with a Developer ID Application certificate for team $team_id."
/usr/bin/grep -Fxq -- "TeamIdentifier=$team_id" "$stage/signature.txt" || fail "The app has the wrong Team ID."
/usr/bin/grep -Eq '^CodeDirectory .*flags=.*\(runtime\)' "$stage/signature.txt" || fail "Hardened Runtime is not enabled."
/usr/bin/grep -q '^Timestamp=' "$stage/signature.txt" || fail "The signature has no secure timestamp."

/usr/bin/codesign -d --entitlements :- "$app" > "$stage/entitlements.plist" 2>/dev/null || fail "Could not inspect the app entitlements."
if [[ -s "$stage/entitlements.plist" ]]; then
    /usr/bin/plutil -lint "$stage/entitlements.plist" >/dev/null || fail "The signed entitlements are malformed."
    for forbidden_key in com.apple.security.get-task-allow com.apple.security.app-sandbox; do
        if /usr/libexec/PlistBuddy -c "Print :$forbidden_key" "$stage/entitlements.plist" >/dev/null 2>&1; then
            fail "The app contains forbidden entitlement $forbidden_key."
        fi
    done
fi

# Organizer may export an accepted app before attaching its ticket. Staple only
# the temporary copy, then require validation and Gatekeeper acceptance.
if ! xcrun stapler validate "$app" >/dev/null 2>&1; then
    xcrun stapler staple "$app" || fail "Apple has no notarization ticket for this app, or the ticket could not be stapled."
fi
xcrun stapler validate "$app" || fail "The notarization ticket did not validate."
/usr/bin/codesign --verify --strict --deep --verbose=2 "$app" || fail "The stapled app failed code signature validation."
/usr/sbin/spctl --assess --type execute --verbose=4 "$app" || fail "Gatekeeper rejected the stapled app."

archive_name="Qbar-$version-macos-universal.zip"
archive="$stage/$archive_name"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app" "$archive" || fail "Could not create the release archive."
/bin/mkdir "$stage/extracted"
/usr/bin/ditto -x -k "$archive" "$stage/extracted" || fail "Could not extract the release archive."
extracted_app="$stage/extracted/Qbar.app"
[[ -d "$extracted_app" ]] || fail "The archive did not contain Qbar.app."
/usr/bin/codesign --verify --strict --deep --verbose=2 "$extracted_app" || fail "The archived app failed code signature validation."
xcrun stapler validate "$extracted_app" || fail "The archived app lost its notarization ticket."
/usr/sbin/spctl --assess --type execute --verbose=4 "$extracted_app" || fail "Gatekeeper rejected the archived app."
checksum_name="$archive_name.sha256"
(cd "$stage" && /usr/bin/shasum -a 256 "$archive_name" > "$checksum_name") || fail "Could not generate SHA-256."

/bin/mkdir -p dist
lock_path="dist/.qbar-release.lock"
/bin/mkdir "$lock_path" || fail "Another release is finishing, or a stale release lock exists."
release_lock="$lock_path"
[[ ! -e "dist/$archive_name" && ! -e "dist/$checksum_name" ]] || fail "Release files already exist in dist; refusing to overwrite them."
/bin/mv "$archive" "dist/$archive_name" || fail "Could not move the release archive into dist."
if ! /bin/mv "$stage/$checksum_name" "dist/$checksum_name"; then
    /bin/rm -f -- "dist/$archive_name"
    fail "Could not move the checksum into dist; removed the partial release archive."
fi
print -- "Notarized release ready: $task_root/dist/$archive_name"
print -- "SHA-256: $task_root/dist/$checksum_name"
print -- "The exported source app was not changed; no GitHub release was created."
