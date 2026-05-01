#!/usr/bin/env bash
set -Eeuo pipefail

PUBLIC_REPOSITORY="${PUBLIC_REPOSITORY:-HalfSweet/claude-buddy}"
PUBLIC_HEAD="${PUBLIC_HEAD:-HEAD}"

ORIGIN_REPOSITORY="${ORIGIN_REPOSITORY:-HalfSweet/claude-desktop-buddy-sifli}"
ORIGIN_BRANCH="${ORIGIN_BRANCH:-main}"
ORIGIN_REPO_URL="${ORIGIN_REPO_URL:-https://github.com/${ORIGIN_REPOSITORY}.git}"

SYNC_STATE_REF="${SYNC_STATE_REF:-refs/heads/sync/open-source-main}"
SYNC_COMMITTER_NAME="${SYNC_COMMITTER_NAME:-open-source-reverse-sync[bot]}"
SYNC_COMMITTER_EMAIL="${SYNC_COMMITTER_EMAIL:-open-source-reverse-sync[bot]@users.noreply.github.com}"

FILTERED_PATHSPECS=(
  "."
  ":(exclude)AGENTS.md"
  ":(exclude)Claude.md"
  ":(exclude).vscode"
  ":(exclude).vscode/**"
  ":(exclude).codex"
  ":(exclude).codex/**"
  ":(exclude).claude"
  ":(exclude).claude/**"
  ":(exclude)prd"
  ":(exclude)prd/**"
  ":(exclude).github/workflows/open-source-sync.yml"
  ":(exclude).github/scripts/open-source-sync.sh"
  ":(exclude).github/workflows/ssh-debug.yml"
  ":(exclude).github/workflows/open-source-reverse-sync.yml"
  ":(exclude).github/scripts/open-source-reverse-sync.sh"
)

public_head="$(git rev-parse --verify "${PUBLIC_HEAD}^{commit}")"
sync_base="$(git ls-remote "$ORIGIN_REPO_URL" "$SYNC_STATE_REF" | awk '{print $1}')"
if [[ -z "$sync_base" ]]; then
  echo "Missing ${SYNC_STATE_REF} in ${ORIGIN_REPOSITORY}; push open-source/main there once before running reverse sync." >&2
  exit 1
fi

if [[ "$sync_base" == "$public_head" ]]; then
  echo "Open source sync state is already at ${public_head}."
  exit 0
fi

origin_dir="$(mktemp -d)"
patch_file="$(mktemp)"
message_file="$(mktemp)"
trap 'rm -rf "$origin_dir"; rm -f "$patch_file" "$message_file"' EXIT

git clone --quiet --branch "$ORIGIN_BRANCH" "$ORIGIN_REPO_URL" "$origin_dir"
(
  cd "$origin_dir"
  git config user.name "$SYNC_COMMITTER_NAME"
  git config user.email "$SYNC_COMMITTER_EMAIL"
)

processed=0
while IFS= read -r source_commit; do
  [[ -n "$source_commit" ]] || continue
  parent="$(git show -s --format=%P "$source_commit" | awk '{print $1}')"

  if [[ -n "$parent" ]]; then
    git diff --binary --full-index "$parent" "$source_commit" -- "${FILTERED_PATHSPECS[@]}" > "$patch_file"
  else
    git diff-tree --binary --full-index --root -p "$source_commit" -- "${FILTERED_PATHSPECS[@]}" > "$patch_file"
  fi

  if [[ ! -s "$patch_file" ]]; then
    echo "Skipping ${source_commit}: no origin changes after filtering."
    continue
  fi

  author_name="$(git show -s --format=%an "$source_commit")"
  author_email="$(git show -s --format=%ae "$source_commit")"
  author_date="$(git show -s --format=%aI "$source_commit")"

  git log -1 --format=%B "$source_commit" > "$message_file"
  {
    echo
    echo "Open-Source-Commit: ${source_commit}"
    echo "Open-Source-Repository: ${PUBLIC_REPOSITORY}"
    echo "Open-Source-Base: ${sync_base}"
    echo "Open-Source-Head: ${public_head}"
  } >> "$message_file"

  (
    cd "$origin_dir"
    git apply --index --3way "$patch_file"
    if ! git diff --cached --quiet; then
      env \
        GIT_AUTHOR_NAME="$author_name" \
        GIT_AUTHOR_EMAIL="$author_email" \
        GIT_AUTHOR_DATE="$author_date" \
        git commit -F "$message_file"
    fi
  )

  processed=$((processed + 1))
  : > "$patch_file"
  : > "$message_file"
done < <(git rev-list --reverse --first-parent "${sync_base}..${public_head}")

(
  cd "$origin_dir"
  git push origin "HEAD:refs/heads/${ORIGIN_BRANCH}"
)
git push "$ORIGIN_REPO_URL" "${public_head}:${SYNC_STATE_REF}"

echo "Processed ${processed} public commit(s), ending at ${public_head}."
