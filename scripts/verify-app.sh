#!/bin/bash
#
# Verifies a built XDeck Pinos.app against the project's distribution contract.
#
# Usage: scripts/verify-app.sh <path-to-"XDeck Pinos.app"> <Debug|Release>
#
# Fails closed: any unmet requirement, unreadable value or missing tool exits non-zero.
# Uses only tools that ship with macOS and Xcode (PlistBuddy, plutil, lipo, vtool, codesign).
# Written for the macOS system bash (3.2).

set -euo pipefail

EXPECTED_APP_NAME="XDeck Pinos.app"
EXPECTED_BUNDLE_ID="io.github.syscat64.XDeckPinos"
EXPECTED_SHORT_VERSION="1.0.0"
EXPECTED_BUILD_VERSION="1"
EXPECTED_MIN_MACOS="12.0"
# The app must be exactly these architectures, in any order.
EXPECTED_ARCHS="arm64 x86_64"
HARDENED_RUNTIME_FLAG=$((0x10000))

fail() {
  echo "VERIFY FAILED: $*" >&2
  exit 1
}

info() {
  printf '  %-30s %s\n' "$1" "$2"
}

usage() {
  echo "usage: $0 <path-to-\"$EXPECTED_APP_NAME\"> <Debug|Release>" >&2
  exit 2
}

[ $# -eq 2 ] || usage
APP="${1%/}"
CONFIGURATION="$2"
case "$CONFIGURATION" in
  Debug | Release) ;;
  *) usage ;;
esac

# Canonical form of a dotted version: "12" -> "12.0", "12.0.0" -> "12.0", "12.1.0" -> "12.1".
normalize_version() {
  local v="$1"
  case "$v" in
    *.*) ;;
    *) v="$v.0" ;;
  esac
  while [ "${v%.0}" != "$v" ] && [ "${v#*.*.}" != "$v" ]; do
    v="${v%.0}"
  done
  echo "$v"
}

plist_value() { # <plist> <key>
  /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null || true
}

# Sorted, space-separated architecture list of a Mach-O file.
archs_of() { # <file>
  lipo -archs "$1" | tr ' ' '\n' | sort | tr '\n' ' ' | sed 's/ $//'
}

# Minimum macOS of one architecture slice, from its load commands.
min_macos_of() { # <file> <arch>
  local out platform minos
  out="$(xcrun vtool -arch "$2" -show-build "$1")" || fail "vtool failed for $1 ($2)"
  platform="$(awk '$1 == "platform" { print $2; exit }' <<<"$out")"
  minos="$(awk '$1 == "minos" { print $2; exit }' <<<"$out")"
  if [ -z "$minos" ]; then
    # Older LC_VERSION_MIN_MACOSX command.
    platform="MACOS"
    minos="$(awk '$1 == "version" { print $2; exit }' <<<"$out")"
  fi
  [ "$platform" = "MACOS" ] || fail "$1 ($2) platform is '$platform', expected MACOS"
  [ -n "$minos" ] || fail "could not read the minimum macOS of $1 ($2)"
  echo "$minos"
}

require_exact_min_macos() { # <label> <raw version>
  local norm
  norm="$(normalize_version "$2")"
  [ "$norm" = "$EXPECTED_MIN_MACOS" ] \
    || fail "$1 minimum macOS is '$2', expected exactly $EXPECTED_MIN_MACOS"
}

# Signature facts of one code object, from codesign's own diagnostic output.
require_adhoc_no_runtime() { # <code path> <label>
  local diag flags_hex flags_value
  diag="$(codesign -dvv "$1" 2>&1)" || fail "codesign could not read the signature of $2"
  grep -q '^Signature=adhoc$' <<<"$diag" || fail "$2 is not ad-hoc signed"
  if grep -q '^Authority=' <<<"$diag"; then
    fail "$2 has a signing authority chain (not ad-hoc)"
  fi
  flags_hex="$(awk '/^CodeDirectory / { if (match($0, /flags=0x[0-9a-fA-F]+/)) { print substr($0, RSTART + 6, RLENGTH - 6); exit } }' <<<"$diag")"
  [ -n "$flags_hex" ] || fail "could not read code signature flags of $2"
  flags_value=$((flags_hex))
  if [ $((flags_value & HARDENED_RUNTIME_FLAG)) -ne 0 ]; then
    fail "$2 has the Hardened Runtime flag set ($flags_hex)"
  fi
}

echo "Verifying $APP ($CONFIGURATION)"

# ---- Identity ---------------------------------------------------------------
[ -d "$APP" ] || fail "app path does not exist or is not a directory: $APP"
[ "$(basename "$APP")" = "$EXPECTED_APP_NAME" ] \
  || fail "app bundle is named '$(basename "$APP")', expected '$EXPECTED_APP_NAME'"
PLIST="$APP/Contents/Info.plist"
[ -f "$PLIST" ] || fail "Info.plist not found: $PLIST"

BUNDLE_ID="$(plist_value "$PLIST" CFBundleIdentifier)"
SHORT_VERSION="$(plist_value "$PLIST" CFBundleShortVersionString)"
BUILD_VERSION="$(plist_value "$PLIST" CFBundleVersion)"
PLIST_MIN_MACOS="$(plist_value "$PLIST" LSMinimumSystemVersion)"
EXEC_NAME="$(plist_value "$PLIST" CFBundleExecutable)"

[ "$BUNDLE_ID" = "$EXPECTED_BUNDLE_ID" ] || fail "CFBundleIdentifier is '$BUNDLE_ID', expected '$EXPECTED_BUNDLE_ID'"
[ "$SHORT_VERSION" = "$EXPECTED_SHORT_VERSION" ] || fail "CFBundleShortVersionString is '$SHORT_VERSION', expected '$EXPECTED_SHORT_VERSION'"
[ "$BUILD_VERSION" = "$EXPECTED_BUILD_VERSION" ] || fail "CFBundleVersion is '$BUILD_VERSION', expected '$EXPECTED_BUILD_VERSION'"
[ -n "$PLIST_MIN_MACOS" ] || fail "LSMinimumSystemVersion is missing from Info.plist"
require_exact_min_macos "Info.plist LSMinimumSystemVersion" "$PLIST_MIN_MACOS"
[ -n "$EXEC_NAME" ] || fail "CFBundleExecutable is missing from Info.plist"
EXEC="$APP/Contents/MacOS/$EXEC_NAME"
[ -f "$EXEC" ] || fail "executable not found: $EXEC"

info "bundle identifier" "$BUNDLE_ID"
info "version (build)" "$SHORT_VERSION ($BUILD_VERSION)"
info "executable" "$EXEC_NAME"
info "minimum macOS (Info.plist)" "$PLIST_MIN_MACOS"

# ---- Architectures and minimum macOS of the executable -----------------------
EXEC_ARCHS="$(archs_of "$EXEC")"
[ "$EXEC_ARCHS" = "$EXPECTED_ARCHS" ] || fail "executable architectures are '$EXEC_ARCHS', expected exactly '$EXPECTED_ARCHS'"
info "architectures" "$EXEC_ARCHS"

for ARCH in x86_64 arm64; do
  MINOS="$(min_macos_of "$EXEC" "$ARCH")"
  require_exact_min_macos "$ARCH executable" "$MINOS"
  info "minimum macOS ($ARCH)" "$MINOS"
done

# ---- Every other Mach-O in the bundle (Debug builds add dylibs) --------------
OTHER_MACHO=0
while IFS= read -r -d '' FILE; do
  if [ "$FILE" = "$EXEC" ]; then continue; fi
  FILE_KIND="$(file -b "$FILE")"
  case "$FILE_KIND" in
    *Mach-O*) ;;
    *) continue ;;
  esac
  OTHER_MACHO=$((OTHER_MACHO + 1))
  REL="${FILE#$APP/}"
  [ "$(archs_of "$FILE")" = "$EXPECTED_ARCHS" ] || fail "$REL architectures are '$(archs_of "$FILE")', expected '$EXPECTED_ARCHS'"
  for ARCH in x86_64 arm64; do
    require_exact_min_macos "$REL ($ARCH)" "$(min_macos_of "$FILE" "$ARCH")"
  done
  require_adhoc_no_runtime "$FILE" "$REL"
done < <(find "$APP" -type f -print0)
info "other Mach-O files checked" "$OTHER_MACHO"

# ---- Code signature -----------------------------------------------------------
VERIFY_OUT="$(codesign --verify --deep --strict --verbose=2 "$APP" 2>&1)" \
  || fail "codesign --verify --deep --strict failed: $VERIFY_OUT"
require_adhoc_no_runtime "$APP" "$EXPECTED_APP_NAME"

DIAG="$(codesign -dvv "$APP" 2>&1)"
SIGNED_ID="$(awk -F= '$1 == "Identifier" { print substr($0, index($0, "=") + 1); exit }' <<<"$DIAG")"
[ "$SIGNED_ID" = "$EXPECTED_BUNDLE_ID" ] || fail "code signature identifier is '$SIGNED_ID', expected '$EXPECTED_BUNDLE_ID'"

# codesign prints "TeamIdentifier=not set" when there is none; that is not a Team ID.
TEAM_LINE="$(awk -F= '$1 == "TeamIdentifier" { print substr($0, index($0, "=") + 1); exit }' <<<"$DIAG")"
case "$TEAM_LINE" in
  "" | "not set") TEAM_STATE="none" ;;
  *) fail "app has a signing Team ID: $TEAM_LINE" ;;
esac

info "signature" "ad-hoc, verified (--deep --strict)"
info "Team ID" "$TEAM_STATE"
info "Hardened Runtime" "off"

# ---- Entitlements ---------------------------------------------------------------
ENT_FILE="$(mktemp)"
trap 'rm -f "$ENT_FILE"' EXIT
# With no entitlements codesign prints nothing; treat empty output as "none".
codesign -d --entitlements :- "$APP" >"$ENT_FILE" 2>/dev/null || true

SANDBOX_STATE="absent"
TASK_ALLOW_STATE="absent"
ENT_SUMMARY="none"
if [ -s "$ENT_FILE" ]; then
  plutil -lint "$ENT_FILE" >/dev/null 2>&1 || fail "entitlements output is not a valid plist"
  ENT_SUMMARY="$(plutil -convert json -o - "$ENT_FILE")"
  SANDBOX_VALUE="$(plist_value "$ENT_FILE" com.apple.security.app-sandbox)"
  TASK_ALLOW_VALUE="$(plist_value "$ENT_FILE" com.apple.security.get-task-allow)"
  [ -z "$SANDBOX_VALUE" ] || SANDBOX_STATE="$SANDBOX_VALUE"
  [ -z "$TASK_ALLOW_VALUE" ] || TASK_ALLOW_STATE="$TASK_ALLOW_VALUE"
fi

[ "$SANDBOX_STATE" != "true" ] || fail "App Sandbox entitlement is enabled"
if [ "$CONFIGURATION" = "Release" ] && [ "$TASK_ALLOW_STATE" = "true" ]; then
  fail "Release build has com.apple.security.get-task-allow = true"
fi

info "entitlements" "$ENT_SUMMARY"
info "App Sandbox" "$SANDBOX_STATE (must not be true)"
if [ "$CONFIGURATION" = "Release" ]; then
  info "get-task-allow" "$TASK_ALLOW_STATE (must not be true in Release)"
else
  info "get-task-allow" "$TASK_ALLOW_STATE (allowed in Debug)"
fi

echo "VERIFY OK: $EXPECTED_APP_NAME ($CONFIGURATION) meets the XDeck Pinos build contract"
