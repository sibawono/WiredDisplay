#!/bin/bash
# Publishes a GitHub release's IPA to SideStore Connect (https://connect.sidestore.io).
#
# The release's IPA is downloaded from GitHub and uploaded to SideStore Connect,
# which hosts the copy it serves. Called by
# .github/workflows/sidestore.yml; can also run locally (see docs/SIDESTORE.md).
#
# usage: scripts/sidestore-publish.sh <tag>          e.g. v0.5.2
# env:
#   SIDESTORE_ACCESS_TOKEN  personal access token from SideStore Connect (required unless DRY_RUN=1)
#   GITHUB_REPOSITORY       owner/name of the public repo (default sibawono/WiredDisplay)
#   SIDESTORE_BUNDLE_ID     app bundle ID on SideStore Connect (default dev.wireddisplay.client)
#   SIDESTORE_LANG          language code for the version description (default en)
#   SIDESTORE_CHANNEL       release channel: stable (default), beta or nightly
#   SIDESTORE_PUBLISH       true: make the version live at once; anything else: leave it unpublished
#   SIDESTORE_URL           instance (default https://connect.sidestore.io)
#   DRY_RUN=1               print the request instead of sending it
set -euo pipefail

TAG="${1:?usage: $0 <tag>, e.g. v0.5.2}"
REPO="${GITHUB_REPOSITORY:-sibawono/WiredDisplay}"
BUNDLE_ID="${SIDESTORE_BUNDLE_ID:-dev.wireddisplay.client}"
LANG_CODE="${SIDESTORE_LANG:-en}"
CHANNEL="${SIDESTORE_CHANNEL:-stable}"
INSTANCE="${SIDESTORE_URL:-https://connect.sidestore.io}"
PUBLISH=false
[ "${SIDESTORE_PUBLISH:-}" = "true" ] && PUBLISH=true

# The tag and the bundle ID go into a URL path: accept only plain values.
[[ "$TAG" =~ ^v?[0-9]+(\.[0-9]+){1,3}$ ]] || { echo "error: tag '$TAG' is not a version tag like v0.5.2" >&2; exit 1; }
[[ "$BUNDLE_ID" =~ ^[A-Za-z0-9.-]+$ ]] || { echo "error: bad bundle ID '$BUNDLE_ID'" >&2; exit 1; }
[[ "$CHANNEL" =~ ^(stable|beta|nightly)$ ]] || { echo "error: bad release channel '$CHANNEL'" >&2; exit 1; }
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

ENDPOINT="$INSTANCE/api/webhook/apps/$BUNDLE_ID/version/$VERSION"

if [ "${DRY_RUN:-}" = "1" ]; then
  echo "POST $ENDPOINT (multipart: file=$NAME, releaseChannel=$CHANNEL, publish=$PUBLISH)"
  echo "versionDescription.$LANG_CODE:"; printf '%s\n' "$NOTES" | head -c 300; echo "…"
  exit 0
fi

: "${SIDESTORE_ACCESS_TOKEN:?SIDESTORE_ACCESS_TOKEN is not set (see docs/SIDESTORE.md)}"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
OUT="$WORK/answer"
gh release download "$TAG" --repo "$REPO" --pattern "$NAME" --dir "$WORK"
[ "$(wc -c <"$WORK/$NAME" | tr -d ' ')" = "$SIZE" ] || { echo "error: downloaded $NAME has the wrong size" >&2; exit 1; }
DESC="$(jq -c --arg lang "$LANG_CODE" --arg notes "$NOTES" -n '{($lang): $notes}')"

# What the server accepts (found by trying, 2026-11-25; the API page differs):
# multipart/form-data with the IPA as "file" and "releaseChannel" required.
# JSON bodies, with or without a "data" wrapper, get 400 "No data provided",
# and externalDownloadUrl is not enough without "file". versionDescription must
# be a mapping; it is sent as a JSON part, and dropped if the server refuses it
# (the notes can then be pasted in the dashboard).
upload() {
  local desc=()
  [ "$1" = with-notes ] && desc=(-F "versionDescription=$DESC;type=application/json")
  curl -sS -o "$OUT" -w '%{http_code}' -X POST "$ENDPOINT" \
    -H "Authorization: Bearer $SIDESTORE_ACCESS_TOKEN" \
    -F "file=@$WORK/$NAME;type=application/octet-stream" \
    --form-string "releaseChannel=$CHANNEL" \
    --form-string "allowCreateNewVersion=true" \
    --form-string "publish=$PUBLISH" \
    "${desc[@]}"
}
MODE=with-notes
CODE="$(upload "$MODE")"
if [ "$CODE" = 400 ] && grep -q "versionDescription" "$OUT"; then
  echo "note: the server refused the release notes ($(tr -d '\n' <"$OUT" | head -c 300)); sending without them"
  MODE=without-notes
  CODE="$(upload "$MODE")"
fi
if [[ "$CODE" != 2* ]]; then
  echo "error: SideStore Connect answered HTTP $CODE:" >&2
  head -c 2000 "$OUT" >&2; echo >&2
  exit 1
fi
head -c 1000 "$OUT"; echo
echo "SideStore Connect: $BUNDLE_ID $VERSION ($CHANNEL), $NAME uploaded ($SIZE bytes), notes $MODE, published=$PUBLISH (HTTP $CODE)"
