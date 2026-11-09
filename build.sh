#!/bin/sh
# Builds the standalone index.html (open directly in a browser or host on GitHub Pages) from src/app.html.
set -e
cd "$(dirname "$0")"
{ printf '<!doctype html>\n<html lang="en">\n<head>\n<meta charset="utf-8">\n<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">\n<style>:root{padding-top:env(safe-area-inset-top,0px);padding-bottom:env(safe-area-inset-bottom,0px)}body{margin:0}[hidden]{display:none!important}</style>\n</head>\n<body>\n'; cat src/app.html; printf '\n</body>\n</html>\n'; } > index.html
