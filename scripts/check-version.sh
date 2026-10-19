#!/usr/bin/env bash
# Checks that the app's version (MARKETING_VERSION) is the same everywhere it's written:
# scripts/build-app.sh, project.yml and the app target's two build configurations in
# CybokronDockGroups.xcodeproj/project.pbxproj. When GITHUB_REF_NAME names a version tag (v*, and
# GITHUB_REF_TYPE is "tag" or unset), the tag must be v<version> too. Exits 1 on any mismatch.
#
#   scripts/check-version.sh                         → checks this checkout
#   GITHUB_REF_NAME=v0.6.1 scripts/check-version.sh  → also checks the tag
#   scripts/check-version.sh <root>                  → checks the checkout at <root>
set -euo pipefail

ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
BUILD_SCRIPT="$ROOT/scripts/build-app.sh"
PROJECT_YML="$ROOT/project.yml"
PBXPROJ="$ROOT/CybokronDockGroups.xcodeproj/project.pbxproj"

failures=0
fail() {
  echo "error: $*" >&2
  failures=$((failures + 1))
}

for file in "$BUILD_SCRIPT" "$PROJECT_YML" "$PBXPROJ"; do
  if [[ ! -f "$file" ]]; then
    echo "error: $file not found" >&2
    exit 1
  fi
done

# One value per line; nothing when the setting is missing.
build_versions="$(sed -nE 's/^MARKETING_VERSION="([^"]*)".*/\1/p' "$BUILD_SCRIPT")"
yml_versions="$(sed -nE 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*"?([^"[:space:]]*)"?.*/\1/p' "$PROJECT_YML")"
pbx_versions="$(sed -nE 's/^[[:space:]]*MARKETING_VERSION = "?([^";]*)"?;.*/\1/p' "$PBXPROJ")"

count() { [[ -z "$1" ]] && echo 0 || grep -c '' <<< "$1"; }

if [[ "$(count "$build_versions")" -ne 1 || -z "$build_versions" ]]; then
  echo "error: scripts/build-app.sh must set MARKETING_VERSION=\"<version>\" exactly once" >&2
  exit 1
fi
VERSION="$build_versions"
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$ ]]; then
  fail "scripts/build-app.sh: MARKETING_VERSION \"$VERSION\" isn't a version number"
fi

if [[ "$(count "$yml_versions")" -ne 1 ]]; then
  fail "project.yml: expected one MARKETING_VERSION, found $(count "$yml_versions")"
elif [[ "$yml_versions" != "$VERSION" ]]; then
  fail "project.yml: MARKETING_VERSION is $yml_versions, scripts/build-app.sh has $VERSION"
fi

if [[ "$(count "$pbx_versions")" -ne 2 ]]; then
  fail "project.pbxproj: expected MARKETING_VERSION in 2 build configurations, found $(count "$pbx_versions") (run xcodegen generate)"
fi
while IFS= read -r version; do
  [[ -z "$version" || "$version" == "$VERSION" ]] && continue
  fail "project.pbxproj: MARKETING_VERSION is $version, scripts/build-app.sh has $VERSION (run xcodegen generate)"
done <<< "$pbx_versions"

REF="${GITHUB_REF_NAME:-}"
if [[ -n "$REF" && "${GITHUB_REF_TYPE:-tag}" == "tag" && "$REF" == v* ]]; then
  if [[ "$REF" != "v$VERSION" ]]; then
    fail "tag $REF doesn't match version $VERSION (expected v$VERSION)"
  else
    echo "Tag $REF matches version $VERSION."
  fi
fi

if [[ "$failures" -gt 0 ]]; then
  exit 1
fi
echo "Version $VERSION: scripts/build-app.sh, project.yml and project.pbxproj (2 build configurations) agree."
