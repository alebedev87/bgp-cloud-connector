#!/usr/bin/env bash

# Sync the version from the VERSION file into:
#   - Containerfile.bgp-cloud-connector
#   - Containerfile.bgp-cloud-connector-bundle

set -e

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

version_file="${repo_root}/VERSION"

containerfiles=(
    "${repo_root}/Containerfile.bgp-cloud-connector"
    "${repo_root}/Containerfile.bgp-cloud-connector-bundle"
)

if [ ! -f "$version_file" ]; then
    echo "Error: VERSION file not found at $version_file" >&2
    exit 1
fi

version=$(tr -d '\n' < "$version_file")
echo "Target VERSION: $version"

any_updated=false

for containerfile in "${containerfiles[@]}"; do
    if [ ! -f "$containerfile" ]; then
        echo "Error: Containerfile not found at $containerfile" >&2
        exit 1
    fi

    current_version=$(grep -oP 'version="\K[^"]+' "$containerfile" | head -1)
    current_release=$(grep -oP 'release="\K[^"]+' "$containerfile" | head -1)

    if [ -z "$current_version" ]; then
        echo "Error: No version label found in $containerfile" >&2
        exit 1
    fi

    if [ "$current_version" = "$version" ] && { [ -z "$current_release" ] || [ "$current_release" = "$version" ]; }; then
        echo "[OK] $(basename "$containerfile"): already in sync ($version)"
    else
        echo "[UPDATE] $(basename "$containerfile"): updating to $version"
        sed -i "s/version=\"[^\"]*\"/version=\"$version\"/" "$containerfile"
        sed -i "s/release=\"[^\"]*\"/release=\"$version\"/" "$containerfile"
        any_updated=true
    fi
done

if [ "$any_updated" = true ]; then
    echo ""
    echo "Updated Containerfiles with VERSION=$version"

    if command -v git &> /dev/null; then
        echo ""
        echo "Changes made:"
        git diff --stat "${containerfiles[@]}"
    fi
else
    echo ""
    echo "All Containerfiles already in sync with VERSION=$version"
fi
