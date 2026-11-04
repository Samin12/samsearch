#!/bin/zsh
# Builds Quick Ask into Nanolight's extensions folder. Nanolight supplies @raycast/api and React.
set -euo pipefail
cd "${0:A:h}"
OUT="$HOME/Library/Application Support/Nanolight/extensions/samin-quick-ask"
ESBUILD=("$HOME/Library/Application Support/Nanolight/extensions/.cache/node_modules/esbuild/bin/esbuild")
[[ -x "${ESBUILD[1]}" ]] || ESBUILD=(npx --yes esbuild)

mkdir -p "$OUT/commands" "$OUT/assets"
for cmd in ask new-thread; do
  "${ESBUILD[@]}" "src/$cmd.tsx" --bundle --platform=node --target=node20 --format=cjs --jsx=automatic \
    --external:@raycast/api --external:react --external:react/jsx-runtime \
    --outfile="$OUT/commands/$cmd.js" --log-level=warning
done
python3 -I -c 'import json,sys; p=json.load(open("package.json")); [p.pop(k,None) for k in ("scripts","devDependencies")]; json.dump(p,open(sys.argv[1],"w"),indent=2)' "$OUT/package.json"
cp assets/icon.png "$OUT/assets/icon.png"
echo "Built into $OUT"
