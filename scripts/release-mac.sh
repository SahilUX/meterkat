#!/usr/bin/env bash
# Build the checked-out release tag with existing keychain credentials and upload it.
set -euo pipefail
[[ $# == 1 && $1 == v* ]] || { echo "usage: $0 vX.Y.Z" >&2; exit 2; }
cd "$(dirname "$0")/.."
tag=$1
[[ $(git rev-parse HEAD) == $(git rev-parse "$tag^{commit}") ]] || {
    echo "Check out $tag before building its release." >&2; exit 1;
}
[[ -z $(git status --porcelain --untracked-files=no) ]] || {
    echo "Commit or discard tracked changes before building." >&2; exit 1;
}
gh release view "$tag" --repo SahilUX/meterkat >/dev/null
Mac/build.sh --notarize
gh release upload "$tag" build/mac/Meterkat.dmg --repo SahilUX/meterkat
