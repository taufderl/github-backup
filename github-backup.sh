#!/bin/bash
# GitHub Repository Mirroring Backup Script

# Load secrets
source ./secrets.sh

# Return error if 'jq' is not installed
if ! command -v jq &> /dev/null
then
    echo "Error: 'jq' is not installed. Please install it to parse the GitHub API response."
    exit 1
fi

echo "Fetching repository list for entity: $GITHUB_ENTITY"

REPO_LIST=$(curl -s -H "Authorization: token $GITHUB_TOKEN" \
    "https://api.github.com/user/repos?per_page=100" | \
    jq -r '.[] | select(.fork == false) | .name')

if [ -z "$REPO_LIST" ]; then
    echo "Error: Could not retrieve repository list. Check GITHUB_ENTITY, GITHUB_TOKEN, and network connectivity."
    exit 1
fi

BACKUP_DIR="$(date +%Y%m%d_%H%M)_backups"
mkdir -p "$BACKUP_DIR"
echo "Created backup directory: $BACKUP_DIR"

echo "Found $(echo "$REPO_LIST" | wc -w) repositories."
for REPO_NAME in $REPO_LIST; do
    echo "[$REPO_NAME] Processing repository..."

    # Construct the full source and destination URLs
    SOURCE_URL="https://$GITHUB_ENTITY:$GITHUB_TOKEN@github.com/$GITHUB_ENTITY/$REPO_NAME.git"
    REPO_DIR="$REPO_NAME.git"

    echo "[$REPO_NAME] Cloning as a mirror..."
    git clone -q --mirror "$SOURCE_URL" "$REPO_DIR"

    if [ $? -ne 0 ]; then
        echo "[$REPO_NAME] Error cloning $REPO_NAME. Skipping this repository."
        continue
    fi

    echo "[$REPO_NAME] Creating backup archive."
    zip -q -r "$BACKUP_DIR/$REPO_DIR.zip" "$REPO_DIR"

    # TODO: Push repository to a backup git server

    echo "[$REPO_NAME] Removing mirror directory."
    rm -rf "$REPO_DIR"
done

echo "Successfully completed backup process!"
exit 0
