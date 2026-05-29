#!/usr/bin/env bash
# gh-watch.sh <tag> — wait for the GitHub Actions release chain for <tag>,
# print the outcome, fire a macOS notification.
#
# Run it BACKGROUNDED from a Claude Code Bash call (run_in_background: true):
# the harness re-invokes the agent with this script's output when the chain
# settles. No hooks, no temp files, no settings.json.
#
# Chain (per PROVENANCE.md): release.yml | publish-pgck-web.yml -> update-latest-md.yml.
# A release is "in" only when update-latest-md.yml has rewritten LATEST.md.
# SHA-keyed so parallel pushes of different tags never cross.
#
#   scripts/gh-watch.sh v0.2.2
#   scripts/gh-watch.sh pgck-web/v0.2.6
#   scripts/gh-watch.sh            # most recent local tag (git describe)

set -euo pipefail

tag="${1:-$(git describe --tags --abbrev=0 2>/dev/null || true)}"
[ -z "$tag" ] && { echo "Usage: $0 <tag>" >&2; exit 2; }

notify() {
  command -v osascript >/dev/null 2>&1 || return 0
  osascript -e "display notification \"$2\" with title \"pgCK release\" sound name \"$1\"" 2>/dev/null || true
}
trap 'echo "✗ Release FAILED: $tag"; notify Sosumi "$tag chain failed"' ERR

case "$tag" in
  pgck-web/v*) wf="publish-pgck-web.yml" ;;
  v*)          wf="release.yml" ;;
  *) echo "Unknown tag pattern: $tag" >&2; exit 2 ;;
esac

echo "▶ Watching release chain for $tag ($wf -> update-latest-md.yml)"
sha=$(git rev-list -n1 "$tag" 2>/dev/null || true)
[ -z "$sha" ] && { echo "Cannot resolve $tag SHA (pushed yet?)" >&2; exit 2; }
echo "  SHA ${sha:0:12}"

find_run() {
  local workflow="$1" run=""
  for _ in $(seq 1 10); do
    run=$(gh run list --workflow="$workflow" --limit 20 --json databaseId,headSha \
      --jq ".[] | select(.headSha == \"$sha\") | .databaseId" | head -1)
    [ -n "$run" ] && { echo "$run"; return 0; }
    sleep 3
  done
  return 1
}

initial=$(find_run "$wf") || { echo "✗ no $wf run for $sha after 30s"; exit 1; }
echo "  initial run $initial"
gh run watch "$initial" --exit-status

chain=$(find_run update-latest-md.yml) || { echo "✗ update-latest-md run for $sha not seen after 30s"; exit 1; }
echo "  chain run $chain"
gh run watch "$chain" --exit-status

echo "✓ Release in: $tag"
sed -n '1,20p' LATEST.md
notify Glass "$tag chain landed"
