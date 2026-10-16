#!/bin/bash
# GitHub Repository Mirroring Backup Script
#
# Mirrors every non-fork repository owned by $GITHUB_ENTITY (user or org), plus
# forks whose upstream owner is in $FORK_INCLUDE_OWNERS, and stores each mirror
# as a zip archive in a timestamped backup directory, one subdirectory per
# owner (forks are filed under their upstream owner).
# Exits non-zero if any repository could not be backed up.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load configuration
ENV_FILE="$SCRIPT_DIR/.env"
if [ ! -f "$ENV_FILE" ]; then
    echo "Error: $ENV_FILE not found. Copy .env.sample to .env and fill it in." >&2
    exit 1
fi
# shellcheck source=.env.sample
source "$ENV_FILE"

: "${GITHUB_ENTITY:?GITHUB_ENTITY is not set in .env}"
: "${GITHUB_TOKEN:?GITHUB_TOKEN is not set in .env}"
GITHUB_API="${GITHUB_API:-https://api.github.com}"
BACKUP_ROOT="${BACKUP_ROOT:-$SCRIPT_DIR}"

# Return error if a required tool is not installed
for TOOL in curl jq git zip base64; do
    if ! command -v "$TOOL" &> /dev/null; then
        echo "Error: '$TOOL' is not installed." >&2
        exit 1
    fi
done

# Backups contain private repositories; keep them readable by the owner only.
umask 077

# Call the GitHub API. The token is fed to curl on stdin as a config file so it
# never appears in the process list.
github_api() {
    printf 'header = "Authorization: Bearer %s"\n' "$GITHUB_TOKEN" | \
        curl -fsS --retry 3 -K - \
            -H "Accept: application/vnd.github+json" \
            -H "X-GitHub-Api-Version: 2022-11-28" \
            "$1"
}

# Authenticate git through environment-supplied config instead of embedding the
# token in the clone URL. This keeps it out of the process list and out of the
# mirror's config file (and therefore out of the zip archives).
GIT_BASIC_AUTH="$(printf 'x-access-token:%s' "$GITHUB_TOKEN" | base64 | tr -d '\n')"
export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0="http.https://github.com/.extraheader"
export GIT_CONFIG_VALUE_0="Authorization: Basic $GIT_BASIC_AUTH"
# Fail instead of hanging on a credential prompt.
export GIT_TERMINAL_PROMPT=0

echo "Fetching repository list for entity: $GITHUB_ENTITY"

# /user/repos is paginated; keep requesting pages until a short page comes back.
# It also lists repositories of other owners (collaborations, orgs), so filter
# by owner and keep the API-provided clone URL rather than building one.
REPO_LIST=""
FORK_LIST=""
PER_PAGE=100
PAGE=1
while :; do
    if ! RESPONSE=$(github_api "$GITHUB_API/user/repos?per_page=$PER_PAGE&page=$PAGE"); then
        echo "Error: Could not retrieve repository list (page $PAGE). Check GITHUB_TOKEN and network connectivity." >&2
        exit 1
    fi
    if ! PAGE_COUNT=$(jq -er 'if type == "array" then length else error("unexpected API response") end' <<< "$RESPONSE"); then
        echo "Error: Unexpected API response on page $PAGE." >&2
        exit 1
    fi
    PAGE_REPOS=$(jq -r --arg owner "$GITHUB_ENTITY" \
        '.[] | select(.fork == false and (.owner.login | ascii_downcase) == ($owner | ascii_downcase))
             | "\(.name)\t\(.clone_url)\t\(.owner.login)"' <<< "$RESPONSE")
    if [ -n "$PAGE_REPOS" ]; then
        REPO_LIST+="$PAGE_REPOS"$'\n'
    fi
    PAGE_FORKS=$(jq -r --arg owner "$GITHUB_ENTITY" \
        '.[] | select(.fork == true and (.owner.login | ascii_downcase) == ($owner | ascii_downcase))
             | "\(.name)\t\(.clone_url)\t\(.url)"' <<< "$RESPONSE")
    if [ -n "$PAGE_FORKS" ]; then
        FORK_LIST+="$PAGE_FORKS"$'\n'
    fi
    if [ "$PAGE_COUNT" -lt "$PER_PAGE" ]; then
        break
    fi
    PAGE=$((PAGE + 1))
done

FAILED=()

# Forks are skipped unless their upstream owner is listed in FORK_INCLUDE_OWNERS,
# since a fork of a large project (e.g. the Linux kernel) can be gigabytes.
# The repo listing does not include the upstream, so look up each fork's parent.
FORK_INCLUDE_OWNERS="${FORK_INCLUDE_OWNERS:-}"
if [ -n "$FORK_INCLUDE_OWNERS" ] && [ -n "$FORK_LIST" ]; then
    INCLUDE_LC=" $(tr '[:upper:]' '[:lower:]' <<< "$FORK_INCLUDE_OWNERS" | tr -s ' \t,' ' ') "
    while IFS=$'\t' read -r FORK_NAME FORK_CLONE_URL FORK_API_URL; do
        [ -n "$FORK_NAME" ] || continue
        if ! PARENT_OWNER=$(github_api "$FORK_API_URL" | jq -er '.parent.owner.login'); then
            echo "[$FORK_NAME] Error: could not look up fork parent." >&2
            FAILED+=("$FORK_NAME")
            continue
        fi
        PARENT_LC=$(tr '[:upper:]' '[:lower:]' <<< "$PARENT_OWNER")
        if [[ "$INCLUDE_LC" == *" $PARENT_LC "* ]]; then
            echo "[$FORK_NAME] Including fork of $PARENT_OWNER."
            REPO_LIST+="$FORK_NAME"$'\t'"$FORK_CLONE_URL"$'\t'"$PARENT_OWNER"$'\n'
        fi
    done <<< "$FORK_LIST"
fi

if [ -z "$REPO_LIST" ]; then
    echo "Error: No repositories found for '$GITHUB_ENTITY'. Check GITHUB_ENTITY and the token's repository access." >&2
    exit 1
fi

REPO_COUNT=$(printf '%s' "$REPO_LIST" | grep -c .)

BACKUP_DIR="$BACKUP_ROOT/$(date +%Y%m%d_%H%M)_backups"
mkdir -p "$BACKUP_DIR"
echo "Created backup directory: $BACKUP_DIR"

# Clone into a private scratch directory that is always cleaned up, so an
# interrupted run cannot leave mirrors behind that break the next run.
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

echo "Found $REPO_COUNT repositories."
while IFS=$'\t' read -r REPO_NAME CLONE_URL OWNER_DIR; do
    [ -n "$REPO_NAME" ] || continue
    REPO_LABEL="$OWNER_DIR/$REPO_NAME"
    echo "[$REPO_LABEL] Processing repository..."

    # Archives are grouped per owner: own repos under $GITHUB_ENTITY, forks
    # under their upstream owner. Both names come from the API, so reject
    # anything that is not a plain GitHub login/repo name before using them
    # as paths.
    if [[ ! "$OWNER_DIR" =~ ^[A-Za-z0-9-]+$ || ! "$REPO_NAME" =~ ^[A-Za-z0-9._-]+$ || "$REPO_NAME" == "." || "$REPO_NAME" == ".." ]]; then
        echo "[$REPO_LABEL] Error: unexpected owner or repository name. Skipping this repository." >&2
        FAILED+=("$REPO_LABEL")
        continue
    fi

    REPO_DIR="$REPO_NAME.git"
    mkdir -p "$BACKUP_DIR/$OWNER_DIR"
    ARCHIVE="$BACKUP_DIR/$OWNER_DIR/$REPO_DIR.zip"

    echo "[$REPO_LABEL] Cloning as a mirror..."
    if ! git clone -q --mirror "$CLONE_URL" "$WORK_DIR/$REPO_DIR" < /dev/null; then
        echo "[$REPO_LABEL] Error cloning $REPO_LABEL. Skipping this repository." >&2
        FAILED+=("$REPO_LABEL")
        rm -rf "${WORK_DIR:?}/$REPO_DIR"
        continue
    fi

    # Never archive credentials.
    if grep -qF -- "$GITHUB_TOKEN" "$WORK_DIR/$REPO_DIR/config"; then
        echo "[$REPO_LABEL] Error: token found in mirror config. Refusing to archive." >&2
        FAILED+=("$REPO_LABEL")
        rm -rf "${WORK_DIR:?}/$REPO_DIR"
        continue
    fi

    echo "[$REPO_LABEL] Creating backup archive."
    # Write to a temporary name first so a partial zip is never mistaken for a backup.
    if ! (cd "$WORK_DIR" && zip -q -r "$ARCHIVE.partial" "$REPO_DIR" < /dev/null) || \
       ! mv "$ARCHIVE.partial" "$ARCHIVE"; then
        echo "[$REPO_LABEL] Error creating archive. Skipping this repository." >&2
        FAILED+=("$REPO_LABEL")
        rm -f "$ARCHIVE.partial"
        rm -rf "${WORK_DIR:?}/$REPO_DIR"
        continue
    fi

    # TODO: Push repository to a backup git server

    echo "[$REPO_LABEL] Removing mirror directory."
    rm -rf "${WORK_DIR:?}/$REPO_DIR"
done <<< "$REPO_LIST"

if [ "${#FAILED[@]}" -gt 0 ]; then
    echo "Backup finished with ${#FAILED[@]} failed repositories (of $REPO_COUNT selected):" >&2
    printf '  - %s\n' "${FAILED[@]}" >&2
    exit 1
fi

echo "Successfully backed up all $REPO_COUNT repositories!"
exit 0
