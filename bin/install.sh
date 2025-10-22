#!/usr/bin/env bash
# https://sharats.me/posts/shell-script-best-practices/

set -o errexit
set -o nounset
set -o pipefail
if [[ "${TRACE-0}" == "1" ]]; then
    set -o xtrace
fi

if [[ "${1-}" =~ ^-*h(elp)?$ ]]; then
    echo 'Usage: ./install.sh'
    exit
fi

DIR=$(dirname "$0")
pushd "$DIR/.." &>/dev/null

swift build -c release

cp .build/release/web-to-markdown /usr/local/bin/

echo "$(ls /usr/local/bin/web-to-markdown)"

popd &>/dev/null
