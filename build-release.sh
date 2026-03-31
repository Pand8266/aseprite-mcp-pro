#!/bin/bash
# Sync extension from private repo to public repo
set -e

PRIVATE_REPO="../aseprite_mcp_pro"
PUBLIC_EXT="./extension"

echo "Syncing extension from private repo..."

# Clean and copy extension
rm -rf "${PUBLIC_EXT}"
cp -r "${PRIVATE_REPO}/mcp/extension" "${PUBLIC_EXT}"

# Copy changelog
cp "${PRIVATE_REPO}/CHANGELOG.md" ./CHANGELOG.md

echo "Extension synced."
echo "Files ready for commit and push."
