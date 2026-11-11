# macOS SVG Markdown preview E2E

This driver opens the production BaoCode window with an isolated workspace and data directory. It copies the issue 858 fixture into the workspace, embeds it as a local Markdown image, opens the Markdown through the workbench, and uses the Preview/Markdown switch via the existing desktop pointer driver. A second local SVG contains CSS `@import` and image URLs aimed at a loopback HTTP server. The server counts only the probe endpoints; it does not intercept other traffic.

From the repository root, with a complete Xcode installation:

```sh
flutter build macos --debug --target tool/e2e/svg_preview_app.dart
svg_out="$(mktemp -d /private/tmp/baocode-svg-e2e.XXXXXX)"
BAOCODE_DATA_DIR="$svg_out/data" \
BAOCODE_E2E_OUT="$svg_out" \
BAOCODE_E2E_SVG="$PWD/test/fixtures/svg/issue_858.svg" \
  build/macos/Build/Products/Debug/BaoCode.app/Contents/MacOS/BaoCode
```

The app uses English and closes the unrelated chat panel. It does not initiate a model request. It saves `issue_858.png`, `safe.png`, and `result.json` in the output directory; failures also attempt `failure.png`. It checks screenshot pixels inside the rendered SVG for the original white button and blue button, and the safe sample's blue rectangle and white background. Probe requests, Flutter errors, missing images, failed pixel checks and timeouts fail the run. Keep the output directory to inspect the screenshots and JSON. A fresh output directory is recommended for each run.
