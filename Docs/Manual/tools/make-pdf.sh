#!/bin/zsh
# Builds "Docs/Manual/Ongaku Studio Manual.pdf" from the manual's Markdown and images.
# Needs Python 3 and Google Chrome (it prints the page headlessly). Run it from anywhere:
#
#   Docs/Manual/tools/make-pdf.sh

set -euo pipefail
tools=${0:A:h}
manual=${tools:h}
chrome="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
build=$(mktemp -d)
trap 'rm -rf "$build"' EXIT

[[ -x "$chrome" ]] || { echo "Google Chrome isn't installed in /Applications." >&2; exit 1 }

python3 "$tools/build.py" "$build/manual.html"
"$chrome" --headless=new --disable-gpu --no-pdf-header-footer --allow-file-access-from-files \
  --print-to-pdf="$build/manual.pdf" --virtual-time-budget=20000 "file://$build/manual.html" 2>/dev/null
[[ -s "$build/manual.pdf" ]] || { echo "Chrome didn't make the PDF." >&2; exit 1 }
cp "$build/manual.pdf" "$manual/Ongaku Studio Manual.pdf"
echo "Made $manual/Ongaku Studio Manual.pdf"
