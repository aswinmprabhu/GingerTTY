Pierre diff assets vendored for offline runtime use.

Source package:
- `@pierre/diffs@1.0.11`

Bundle generation:
```sh
tmpdir="$(mktemp -d /tmp/pierrevendor.XXXXXX)"
cd "$tmpdir"
npm init -y
npm install @pierre/diffs@1.0.11 esbuild
printf "import './node_modules/@pierre/diffs/dist/components/web-components.js';\nexport * from '@pierre/diffs';\n" > entry.mjs
npx esbuild entry.mjs --bundle --format=esm --platform=browser --target=safari17 --outfile=pierre-diffs.bundle.mjs
```
