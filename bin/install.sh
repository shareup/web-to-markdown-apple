#!/usr/bin/env bash
# https://sharats.me/posts/shell-script-best-practices/

set -o errexit
set -o nounset
set -o pipefail
if [[ "${TRACE-0}" == "1" ]]; then
    set -o xtrace
fi

if [[ "${1-}" =~ ^-*h(elp)?$ ]]; then
    cat <<'EOF'
Usage: ./install.sh

Builds web-to-markdown in release mode and copies the binary into a
directory on PATH. Picks the first writable destination from:
  1. $INSTALL_DIR (override)
  2. $(brew --prefix)/bin (if Homebrew is installed)
  3. /opt/homebrew/bin (Apple Silicon Homebrew default)
  4. /usr/local/bin (Intel Homebrew / classic default; usually requires sudo)

If none are writable, runs with sudo or fails with a clear error.
EOF
    exit
fi

DIR=$(dirname "$0")
pushd "$DIR/.." &>/dev/null

swift build -c release

# Build the candidate list in priority order.
candidates=()

if [[ -n "${INSTALL_DIR-}" ]]; then
    candidates+=("$INSTALL_DIR")
fi

if command -v brew >/dev/null 2>&1; then
    brew_prefix="$(brew --prefix 2>/dev/null || true)"
    if [[ -n "$brew_prefix" ]]; then
        candidates+=("$brew_prefix/bin")
    fi
fi

candidates+=("/opt/homebrew/bin" "/usr/local/bin")

# Deduplicate while preserving order.
seen=""
unique_candidates=()
for c in "${candidates[@]}"; do
    if [[ ":$seen:" != *":$c:"* ]]; then
        unique_candidates+=("$c")
        seen="$seen:$c"
    fi
done

# Pick the first existing & writable candidate.
dest=""
for candidate in "${unique_candidates[@]}"; do
    if [[ -d "$candidate" ]] && [[ -w "$candidate" ]]; then
        dest="$candidate"
        break
    fi
done

if [[ -z "$dest" ]]; then
    echo "Error: no writable directory found among:" >&2
    printf '  - %s\n' "${unique_candidates[@]}" >&2
    echo "" >&2
    echo "Re-run with sudo, or set INSTALL_DIR=<path> to a writable directory." >&2
    exit 1
fi

cp .build/release/web-to-markdown "$dest/"

echo "Installed: $dest/web-to-markdown"

popd &>/dev/null
