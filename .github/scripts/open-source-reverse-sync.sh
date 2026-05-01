#!/usr/bin/env bash
set -Eeuo pipefail

PUBLIC_REPOSITORY="${PUBLIC_REPOSITORY:-HalfSweet/claude-buddy}"
PUBLIC_BRANCH="${PUBLIC_BRANCH:-main}"
PUBLIC_BASE_COMMIT="${PUBLIC_BASE_COMMIT:-72ddd2f7e558d3f75e7686b65924f8b66d332ac3}"
PUBLIC_HEAD="${PUBLIC_HEAD:-HEAD}"

ORIGIN_REPOSITORY="${ORIGIN_REPOSITORY:-HalfSweet/claude-desktop-buddy-sifli}"
ORIGIN_BRANCH="${ORIGIN_BRANCH:-main}"
ORIGIN_REPO_URL="${ORIGIN_REPO_URL:-${ORIGIN_REPO_HTTPS_URL:-https://github.com/${ORIGIN_REPOSITORY}.git}}"

SYNC_STATE_REF="${SYNC_STATE_REF:-refs/sync/open-source-main}"
SYNC_COMMITTER_NAME="${SYNC_COMMITTER_NAME:-open-source-reverse-sync[bot]}"
SYNC_COMMITTER_EMAIL="${SYNC_COMMITTER_EMAIL:-open-source-reverse-sync[bot]@users.noreply.github.com}"
DRY_RUN="${DRY_RUN:-false}"

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

usage() {
  cat <<'USAGE'
Usage: open-source-reverse-sync.sh <sync>

Commands:
  sync  Replay new public main commits onto origin/main, then advance the sync ref.
USAGE
}

die() {
  echo "error: $*" >&2
  exit 1
}

is_true() {
  case "${1:-}" in
    1|true|TRUE|yes|YES)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

resolve_public_commit() {
  local rev="$1"

  git rev-parse --verify "${rev}^{commit}"
}

remote_sync_base() {
  local remote_sha

  remote_sha="$(git ls-remote "$ORIGIN_REPO_URL" "$SYNC_STATE_REF" | awk '{print $1}')"
  if [[ -n "$remote_sha" ]]; then
    printf '%s\n' "$remote_sha"
    return
  fi

  printf '%s\n' "$PUBLIC_BASE_COMMIT"
}

ensure_public_commit_exists() {
  local commit="$1"
  local label="$2"

  git cat-file -e "${commit}^{commit}" 2>/dev/null ||
    die "cannot find ${label} commit ${commit} in the public checkout"
}

commit_parent_for_patch() {
  local commit="$1"
  local parents

  parents="$(git show -s --format=%P "$commit")"
  if [[ -z "$parents" ]]; then
    return
  fi

  printf '%s\n' "${parents%% *}"
}

write_filtered_patch() {
  local commit="$1"
  local patch_file="$2"
  local parent

  parent="$(commit_parent_for_patch "$commit")"
  if [[ -z "$parent" ]]; then
    git diff-tree --binary --full-index --root -p "$commit" -- "${FILTERED_PATHSPECS[@]}" > "$patch_file"
    return
  fi

  git diff --binary --full-index "$parent" "$commit" -- "${FILTERED_PATHSPECS[@]}" > "$patch_file"
}

write_origin_message() {
  local source_commit="$1"
  local sync_base="$2"
  local sync_head="$3"
  local message_file="$4"

  git log -1 --format=%B "$source_commit" > "$message_file"
  {
    echo
    echo "Open-Source-Commit: ${source_commit}"
    echo "Open-Source-Repository: ${PUBLIC_REPOSITORY}"
    echo "Open-Source-Base: ${sync_base}"
    echo "Open-Source-Head: ${sync_head}"
  } >> "$message_file"
}

commit_origin_patch() {
  local origin_dir="$1"
  local source_commit="$2"
  local sync_base="$3"
  local sync_head="$4"
  local patch_file="$5"
  local message_file
  local author_name
  local author_email
  local author_date

  if [[ ! -s "$patch_file" ]]; then
    echo "Skipping ${source_commit}: no origin changes after filtering."
    return
  fi

  message_file="$(mktemp)"
  write_origin_message "$source_commit" "$sync_base" "$sync_head" "$message_file"
  author_name="$(git show -s --format=%an "$source_commit")"
  author_email="$(git show -s --format=%ae "$source_commit")"
  author_date="$(git show -s --format=%aI "$source_commit")"

  (
    cd "$origin_dir"
    if git apply --reverse --check "$patch_file" >/dev/null 2>&1; then
      echo "Skipping ${source_commit}: patch is already represented in origin."
      exit 0
    fi

    git apply --index --3way "$patch_file"

    if git diff --cached --quiet; then
      echo "Skipping ${source_commit}: patch is already represented in origin."
      exit 0
    fi

    env \
      GIT_AUTHOR_NAME="$author_name" \
      GIT_AUTHOR_EMAIL="$author_email" \
      GIT_AUTHOR_DATE="$author_date" \
      git commit -F "$message_file"
  )

  rm -f "$message_file"
}

public_commit_range() {
  local sync_base="$1"
  local sync_head="$2"

  git rev-list --reverse --first-parent "${sync_base}..${sync_head}"
}

push_origin_main_and_state() {
  local origin_dir="$1"
  local sync_head="$2"

  if is_true "$DRY_RUN"; then
    echo "DRY_RUN=true: skipping push to ${ORIGIN_REPOSITORY}/${ORIGIN_BRANCH} and ${SYNC_STATE_REF}."
    return
  fi

  (
    cd "$origin_dir"
    git push origin "HEAD:refs/heads/${ORIGIN_BRANCH}"
  )

  git push "$ORIGIN_REPO_URL" "${sync_head}:${SYNC_STATE_REF}"
}

sync_origin_repo() {
  local sync_base
  local sync_head
  local origin_dir
  local patch_file
  local source_commit
  local applied_count=0

  sync_head="$(resolve_public_commit "$PUBLIC_HEAD")"
  sync_base="$(remote_sync_base)"
  ensure_public_commit_exists "$sync_base" "sync base"
  ensure_public_commit_exists "$sync_head" "sync head"

  if [[ "$sync_base" == "$sync_head" ]]; then
    echo "Open source sync state is already at ${sync_head}."
    return
  fi

  git merge-base --is-ancestor "$sync_base" "$sync_head" ||
    die "sync base ${sync_base} is not an ancestor of public head ${sync_head}"

  origin_dir="$(mktemp -d)"
  patch_file="$(mktemp)"
  trap 'rm -rf "${origin_dir:-}"; rm -f "${patch_file:-}"' EXIT

  git clone --quiet --branch "$ORIGIN_BRANCH" "$ORIGIN_REPO_URL" "$origin_dir"
  (
    cd "$origin_dir"
    git config user.name "$SYNC_COMMITTER_NAME"
    git config user.email "$SYNC_COMMITTER_EMAIL"
  )

  while IFS= read -r source_commit; do
    [[ -n "$source_commit" ]] || continue
    write_filtered_patch "$source_commit" "$patch_file"
    commit_origin_patch "$origin_dir" "$source_commit" "$sync_base" "$sync_head" "$patch_file"
    applied_count=$((applied_count + 1))
    : > "$patch_file"
  done < <(public_commit_range "$sync_base" "$sync_head")

  push_origin_main_and_state "$origin_dir" "$sync_head"
  echo "Processed ${applied_count} public commit(s), ending at ${sync_head}."
}

main() {
  local command="${1:-}"

  case "$command" in
    sync)
      sync_origin_repo
      ;;
    -h|--help|help)
      usage
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
}

main "$@"
