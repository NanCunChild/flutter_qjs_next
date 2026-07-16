#!/usr/bin/env bash
# Mirror doc/wiki/ (source of truth) to the GitHub Wiki repository.
# Usage:
#   bash scripts/sync-wiki.sh
# Env:
#   GH_TOKEN / GITHUB_TOKEN  — token with wiki write access (required for push)
#   GITHUB_REPOSITORY        — owner/repo (CI sets this; else inferred from origin)
#   WIKI_DRY_RUN=1           — prepare clone and copy only, do not push
#   WIKI_DIR                 — override temporary wiki workdir
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${ROOT}/doc/wiki"

if [[ ! -d "${SRC}" ]]; then
  echo "error: missing wiki source: ${SRC}" >&2
  exit 1
fi

if [[ -z "${GITHUB_REPOSITORY:-}" ]]; then
  origin="$(git -C "${ROOT}" remote get-url origin 2>/dev/null || true)"
  # https://github.com/owner/repo.git | git@github.com:owner/repo.git
  if [[ "${origin}" =~ github\.com[:/]([^/]+)/([^/.]+)(\.git)?$ ]]; then
    GITHUB_REPOSITORY="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
  else
    echo "error: set GITHUB_REPOSITORY=owner/repo" >&2
    exit 1
  fi
fi

TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
WIKI_URL_HTTPS="https://github.com/${GITHUB_REPOSITORY}.wiki.git"
WIKI_URL_AUTH=""
if [[ -n "${TOKEN}" ]]; then
  WIKI_URL_AUTH="https://x-access-token:${TOKEN}@github.com/${GITHUB_REPOSITORY}.wiki.git"
fi

WORKDIR="${WIKI_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/flutter-qjs-wiki.XXXXXX")}"
cleanup() {
  if [[ -z "${WIKI_DIR:-}" && -d "${WORKDIR}" ]]; then
    rm -rf "${WORKDIR}"
  fi
}
trap cleanup EXIT

echo "source:  ${SRC}"
echo "repo:    ${GITHUB_REPOSITORY}"
echo "workdir: ${WORKDIR}"

clone_url="${WIKI_URL_AUTH:-${WIKI_URL_HTTPS}}"
if ! git clone --depth 1 "${clone_url}" "${WORKDIR}" 2>/tmp/wiki-clone.err; then
  echo "wiki clone failed (wiki may be empty / not initialized):" >&2
  cat /tmp/wiki-clone.err >&2
  # Empty wiki: create orphan repo so first push initializes it.
  mkdir -p "${WORKDIR}"
  git -C "${WORKDIR}" init
  git -C "${WORKDIR}" remote add origin "${clone_url}"
  # Placeholder so empty clone state is valid; will be replaced below.
  printf '%s\n' "# ${GITHUB_REPOSITORY##*/}" > "${WORKDIR}/Home.md"
  git -C "${WORKDIR}" add Home.md
  git -C "${WORKDIR}" \
    -c user.name="${GIT_AUTHOR_NAME:-github-actions[bot]}" \
    -c user.email="${GIT_AUTHOR_EMAIL:-github-actions[bot]@users.noreply.github.com}" \
    -c commit.gpgsign=false \
    commit -m "Initialize wiki"
fi

# Replace tracked wiki content with doc/wiki mirror (keep .git).
find "${WORKDIR}" -mindepth 1 -maxdepth 1 ! -name '.git' -exec rm -rf {} +

# Copy tree; map doc/wiki/README.md -> Home.md (GitHub Wiki home).
rsync -a --exclude '.git' "${SRC}/" "${WORKDIR}/"
if [[ -f "${WORKDIR}/README.md" ]]; then
  mv -f "${WORKDIR}/README.md" "${WORKDIR}/Home.md"
fi

# Sidebar: optional _Sidebar.md from Home nav is left to wiki authors;
# ensure at least Home exists.
if [[ ! -f "${WORKDIR}/Home.md" ]]; then
  echo "error: Home.md missing after sync" >&2
  exit 1
fi

# Rewrite repo-root relative links used in doc (e.g. ../../CHANGELOG.md).
# Point them at the default branch blob URL.
DEFAULT_BRANCH="${DEFAULT_BRANCH:-main}"
BLOB="https://github.com/${GITHUB_REPOSITORY}/blob/${DEFAULT_BRANCH}"
while IFS= read -r -d '' f; do
  # portable in-place: sed temp
  tmp="${f}.tmp"
  sed -e "s|](../../CHANGELOG.md)|](${BLOB}/CHANGELOG.md)|g" \
      -e "s|](../CHANGELOG.md)|](${BLOB}/CHANGELOG.md)|g" \
      -e "s|](CHANGELOG.md)|](${BLOB}/CHANGELOG.md)|g" \
      "${f}" > "${tmp}"
  mv "${tmp}" "${f}"
done < <(find "${WORKDIR}" -type f -name '*.md' -print0)

git -C "${WORKDIR}" config user.name "${GIT_AUTHOR_NAME:-github-actions[bot]}"
git -C "${WORKDIR}" config user.email \
  "${GIT_AUTHOR_EMAIL:-github-actions[bot]@users.noreply.github.com}"
# Avoid local commit.gpgsign / signing keys interfering with bot commits.
git -C "${WORKDIR}" config commit.gpgsign false

git -C "${WORKDIR}" add -A

if git -C "${WORKDIR}" diff --cached --quiet; then
  echo "wiki already up to date"
  exit 0
fi

git -C "${WORKDIR}" -c commit.gpgsign=false \
  commit -m "docs: sync wiki from doc/wiki ($(date -u +%Y-%m-%dT%H:%MZ))"

if [[ "${WIKI_DRY_RUN:-0}" == "1" ]]; then
  echo "WIKI_DRY_RUN=1: skip push"
  git -C "${WORKDIR}" log -1 --oneline
  exit 0
fi

if [[ -z "${TOKEN}" ]]; then
  echo "error: GH_TOKEN or GITHUB_TOKEN required to push" >&2
  exit 1
fi

# Ensure push URL uses token.
git -C "${WORKDIR}" remote set-url origin "${WIKI_URL_AUTH}"

# Prefer existing remote default branch (wiki is often master).
push_ref="$(git -C "${WORKDIR}" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##' || true)"
if [[ -z "${push_ref}" ]]; then
  push_ref="$(git -C "${WORKDIR}" branch --show-current 2>/dev/null || echo master)"
fi

if ! git -C "${WORKDIR}" push -u origin "HEAD:${push_ref}" 2>/tmp/wiki-push.err; then
  # Fallbacks for first publish / alternate default.
  if ! git -C "${WORKDIR}" push -u origin HEAD:master 2>>/tmp/wiki-push.err \
    && ! git -C "${WORKDIR}" push -u origin HEAD:main 2>>/tmp/wiki-push.err; then
    echo "wiki push failed:" >&2
    cat /tmp/wiki-push.err >&2
    echo >&2
    echo "If the wiki remote does not exist yet:" >&2
    echo "  1) Enable Wikis in the GitHub repo settings" >&2
    echo "  2) Create any page once in the Wiki UI (initializes .wiki.git)" >&2
    echo "  3) Re-run this workflow" >&2
    exit 1
  fi
fi

echo "wiki published: https://github.com/${GITHUB_REPOSITORY}/wiki"
