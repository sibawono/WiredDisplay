#!/bin/bash
# Publishes local main to GitHub as one scrubbed commit (AGENTS.md, publishing procedure):
# main minus docs/evidence, scanned for personal identifiers, authored by the noreply identity.
# usage: scripts/publish-public.sh "commit message" [--yes]
set -euo pipefail
cd "$(dirname "$0")/.."
MESSAGE="${1:?usage: scripts/publish-public.sh \"commit message\" [--yes]}"
CONFIRM="${2:-}"

HANDOVER=docs/evidence/LOCAL-HANDOVER.md
RX="$(grep -A1 'Identifier scan list' "$HANDOVER" | sed -n 's/.*`\(.*\)`.*/\1/p' | head -1)"
[ -n "$RX" ] || { echo "no identifier list found in $HANDOVER" >&2; exit 1; }
# Words that contain an identifier without being one: the public noreply handle, Indonesian "memanggil".
ALLOWED='sibawono|memanggil'

MAIN_AT_START="$(git rev-parse main)" PUBLIC_AT_START="$(git rev-parse public)"
INDEX_DIR="$(mktemp -d)"
trap 'rm -rf "$INDEX_DIR"' EXIT
INDEX="$INDEX_DIR/index"
GIT_INDEX_FILE="$INDEX" git read-tree main
GIT_INDEX_FILE="$INDEX" git rm -r -q --cached --ignore-unmatch docs/evidence
TREE="$(GIT_INDEX_FILE="$INDEX" git write-tree)"

HITS="$(git grep -n -I -i -E "$RX" "$TREE" -- . \
  | RX="$RX" ALLOWED="$ALLOWED" perl -ne 'my $l = $_; $l =~ s/$ENV{ALLOWED}//gi; print if $l =~ /$ENV{RX}/i' || true)"
# Binary files (images) are checked byte for byte.
BINARY_HITS="$(git grep -l -i -a -E "$RX" "$TREE" -- '*.png' '*.jpg' '*.icns' || true)"
if [ -n "$HITS$BINARY_HITS" ]; then
  echo "Personal identifiers in the public tree; nothing was published:" >&2
  printf '%s\n%s\n' "$HITS" "$BINARY_HITS" | sed '/^$/d' >&2
  exit 1
fi

if [ "$(git rev-parse 'public^{tree}')" = "$TREE" ]; then
  echo "GitHub already has this tree ($TREE); nothing to publish."
  exit 0
fi
echo "Public tree $TREE, scan clean. Changes since the last publish:"
git --no-pager diff --stat public "$TREE"
if [ "$CONFIRM" != "--yes" ]; then
  read -r -p "Push this to github main? [y/N] " answer
  [ "$answer" = "y" ] || { echo "Not published."; exit 1; }
fi

# main or the public ref may have moved while the prompt waited (another publish): start again then.
MAIN_NOW="$(git rev-parse main)" PUBLIC_NOW="$(git rev-parse public)"
if [ "$MAIN_NOW" != "$MAIN_AT_START" ] || [ "$PUBLIC_NOW" != "$PUBLIC_AT_START" ]; then
  echo "main or public changed while waiting; nothing was published. Run the script again." >&2
  exit 1
fi

export GIT_AUTHOR_NAME=sibawono GIT_AUTHOR_EMAIL=341369459+sibawono@users.noreply.github.com
export GIT_COMMITTER_NAME=sibawono GIT_COMMITTER_EMAIL=341369459+sibawono@users.noreply.github.com
COMMIT="$(git commit-tree "$TREE" -p public -m "$MESSAGE")"
# The local ref moves only once GitHub accepted the commit.
git push github "$COMMIT:refs/heads/main"
git update-ref refs/heads/public "$COMMIT"
echo "Published $COMMIT (tree $TREE)."
