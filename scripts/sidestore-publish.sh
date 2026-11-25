#!/bin/bash
# Publishes a GitHub release's IPA to SideStore Connect (https://connect.sidestore.io).
#
# The IPA stays on GitHub: SideStore Connect gets the release asset's download
# URL and size (externalDownloadUrl), not an upload. Called by
# .github/workflows/sidestore.yml; can also run locally (see docs/SIDESTORE.md).
#
# usage: scripts/sidestore-publish.sh <tag>          e.g. v0.5.2
# env:
#   SIDESTORE_ACCESS_TOKEN  personal access token from SideStore Connect (required unless DRY_RUN=1)
#   GITHUB_REPOSITORY       owner/name of the public repo (default sibawono/WiredDisplay)
#   SIDESTORE_BUNDLE_ID     app bundle ID on SideStore Connect (default dev.wireddisplay.client)
#   SIDESTORE_LANG          language code for the version description (default en)
#   SIDESTORE_PUBLISH       true: make the version live at once; anything else: leave it unpublished
#   SIDESTORE_URL           instance (default https://connect.sidestore.io)
#   DRY_RUN=1               print the request instead of sending it
set -euo pipefail

TAG="${1:?usage: $0 <tag>, e.g. v0.5.2}"
REPO="${GITHUB_REPOSITORY:-sibawono/WiredDisplay}"
BUNDLE_ID="${SIDESTORE_BUNDLE_ID:-dev.wireddisplay.client}"
LANG_CODE="${SIDESTORE_LANG:-en}"
INSTANCE="${SIDESTORE_URL:-https://connect.sidestore.io}"
PUBLISH=false
[ "${SIDESTORE_PUBLISH:-}" = "true" ] && PUBLISH=true

# The tag and the bundle ID go into a URL path: accept only plain values.
[[ "$TAG" =~ ^v?[0-9]+(\.[0-9]+){1,3}$ ]] || { echo "error: tag '$TAG' is not a version tag like v0.5.2" >&2; exit 1; }
[[ "$BUNDLE_ID" =~ ^[A-Za-z0-9.-]+$ ]] || { echo "error: bad bundle ID '$BUNDLE_ID'" >&2; exit 1; }
[[ "$LANG_CODE" =~ ^[a-z]{2}(-[A-Za-z]+)?$ ]] || { echo "error: bad language code '$LANG_CODE'" >&2; exit 1; }
VERSION="${TAG#v}"

RELEASE="$(gh release view "$TAG" --repo "$REPO" --json isDraft,isPrerelease,body,assets)"
if [ "$(jq -r .isDraft <<<"$RELEASE")" = "true" ]; then
  echo "error: $TAG is a draft release; its asset URL is not public" >&2; exit 1
fi
if [ "$(jq -r .isPrerelease <<<"$RELEASE")" = "true" ]; then
  echo "skip: $TAG is a pre-release; only stable releases go to SideStore" >&2; exit 0
fi

# Exactly one IPA, and it must be this version's.
IPAS="$(jq -c '[.assets[] | select(.name | endswith(".ipa"))]' <<<"$RELEASE")"
[ "$(jq length <<<"$IPAS")" = 1 ] || { echo "error: $TAG must have exactly one .ipa asset" >&2; exit 1; }
NAME="$(jq -r '.[0].name' <<<"$IPAS")"
[ "$NAME" = "WiredDisplay-$VERSION.ipa" ] || { echo "error: asset '$NAME' does not match version $VERSION" >&2; exit 1; }
SIZE="$(jq -r '.[0].size' <<<"$IPAS")"
URL="https://github.com/$REPO/releases/download/$TAG/$NAME"

# The download URL must answer publicly with the same size SideStore will be told.
REMOTE_SIZE="$(curl -sSfL -o /dev/null -w '%{size_download}' "$URL")"
[ "$REMOTE_SIZE" = "$SIZE" ] || { echo "error: $URL returned $REMOTE_SIZE bytes, the release says $SIZE" >&2; exit 1; }

# The release notes without their "## Downloads" section (a table of the Mac and
# iPad files, which means nothing inside SideStore).
NOTES="$(jq -r '.body // ""' <<<"$RELEASE" | tr -d '\r' \
  | awk '/^## /{skip = ($0 ~ /^## Downloads/)} !skip' | sed '/./,$!d')"
[ -n "$NOTES" ] || NOTES="WiredDisplay $VERSION"

# The fields go inside a top-level "data" object: with the fields at the top
# level the API answers HTTP 400 "No data provided" (first run, 2026-11-25).
# The API page lists only the fields, not this wrapper.
BODY="$(jq -n --arg lang "$LANG_CODE" --arg notes "$NOTES" --arg url "$URL" \
  --argjson size "$SIZE" --argjson publish "$PUBLISH" '{data: {
    allowCreateNewVersion: true,
    versionDescription: {($lang): $notes},
    externalDownloadUrl: $url,
    downloadFileSize: $size,
    publish: $publish
  }}')"
ENDPOINT="$INSTANCE/api/webhook/apps/$BUNDLE_ID/version/$VERSION"

if [ "${DRY_RUN:-}" = "1" ]; then
  echo "POST $ENDPOINT"
  jq '.data.versionDescription[] |= (.[0:200] + "…")' <<<"$BODY"
  exit 0
fi

: "${SIDESTORE_ACCESS_TOKEN:?SIDESTORE_ACCESS_TOKEN is not set (see docs/SIDESTORE.md)}"
OUT="$(mktemp)"; trap 'rm -f "$OUT"' EXIT
CODE="$(curl -sS -o "$OUT" -w '%{http_code}' -X POST "$ENDPOINT" \
  -H "Authorization: Bearer $SIDESTORE_ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  --data-binary @- <<<"$BODY")"
if [[ "$CODE" != 2* ]]; then
  echo "error: SideStore Connect answered HTTP $CODE:" >&2
  head -c 2000 "$OUT" >&2; echo >&2
  exit 1
fi
head -c 1000 "$OUT"; echo
echo "SideStore Connect: $BUNDLE_ID $VERSION -> $URL ($SIZE bytes), published=$PUBLISH (HTTP $CODE)"
