#!/bin/zsh
# Fetches the Stem Splitter's model, Meta's HTDemucs (MIT licence), into Ongaku/StemModel,
# where the build bundles it with the app. It's 84 MB, so it isn't kept in git.
#
#   Scripts/fetch-stem-model.sh

set -euo pipefail
root=${0:A:h:h}
destination="$root/Ongaku/StemModel/htdemucs.th"
url="https://dl.fbaipublicfiles.com/demucs/hybrid_transformer/955717e8-8726e21a.th"
expected="8726e21a993978c7ba086d3872e7608d7d5bfca646ca4aca459ffda844faa8b4"

mkdir -p "${destination:h}"
if [[ -f "$destination" ]] && [[ "$(shasum -a 256 "$destination" | cut -d' ' -f1)" == "$expected" ]]; then
  echo "The model is already in place."
  exit 0
fi
curl -fL --progress-bar -o "$destination.partial" "$url"
actual=$(shasum -a 256 "$destination.partial" | cut -d' ' -f1)
if [[ "$actual" != "$expected" ]]; then
  rm -f "$destination.partial"
  echo "The download doesn't match the expected checksum." >&2
  exit 1
fi
mv "$destination.partial" "$destination"
echo "Fetched $destination"
