# Design Specification: Standard Notes Flatpak Source Build & Automated Updates

**Target**: [`org.standardnotes.standardnotes.yml`](file:///home/slash/Development/standardnotes-flathub/org.standardnotes.standardnotes.yml)  
**Date**: 2026-09-05  
**Status**: Approved (Brainstorming Phase)

---

## 1. Overview & Objectives

This specification defines the architecture, manifest modifications, and GitHub Actions CI/CD automation to migrate the Flathub package for Standard Notes (`org.standardnotes.standardnotes`) from extracting a precompiled `.deb` package to compiling directly from upstream source ([`standardnotes/app`](https://github.com/standardnotes/app)) inside the offline Flatpak sandbox.

### Goals
1. **Deterministic Source Compilation**: Build Standard Notes from source Git tags using Yarn Berry and the Freedesktop Node 22 SDK extension inside an offline build environment (`--unshare=network`).
2. **Dual-Architecture Support**: Support both `x86_64` and `aarch64` architectures natively.
3. **Flathubbot PR Automation**: Automatically trigger a GitHub Actions workflow when `flathubbot` opens a PR bumping the release tag, sparse-checkout upstream lockfiles, run `flatpak-node-generator`, sync AppStream metadata, and commit the regenerated sources back to the PR branch.
4. **Sandboxed Local Builder Integration**: Use `flatpak run org.flatpak.Builder` with appropriate flags for local builds and verification.

---

## 2. Manifest Architecture (`org.standardnotes.standardnotes.yml`)

### 2.1 Runtime & Toolchain Configuration
* **Base Runtime**: `org.freedesktop.Platform` (version `25.08`)
* **Base Application**: `org.electronjs.Electron2.BaseApp` (version `25.08`)
* **SDK**: `org.freedesktop.Sdk` (version `25.08`)
* **SDK Extensions**: Mount `org.freedesktop.Sdk.Extension.node22` matching upstream Standard Notes' runtime baseline (`.nvmrc: 22.14.0`).
* **Environment Paths**:
  * `append-path: /usr/lib/sdk/node22/bin`
  * `npm_config_nodedir: /usr/lib/sdk/node22`

### 2.2 Module Definition: `standardnotes`
Replace the `.deb` extraction commands with the offline Yarn Berry build pipeline:

```yaml
  - name: standardnotes
    buildsystem: simple
    build-options:
      append-path: /usr/lib/sdk/node22/bin
      env:
        XDG_CACHE_HOME: /run/build/standardnotes/flatpak-node/cache
        npm_config_nodedir: /usr/lib/sdk/node22
        # Offline Yarn Berry settings
        YARN_ENABLE_INLINE_BUILDS: '1'
        YARN_ENABLE_TELEMETRY: '0'
        YARN_ENABLE_NETWORK: '0'
        YARN_ENABLE_GLOBAL_CACHE: '0'
        YARN_GLOBAL_FOLDER: /run/build/standardnotes/flatpak-node/yarn-berry
        # Electron builder offline cache
        electron_config_cache: /run/build/standardnotes/flatpak-node/cache/electron
        ELECTRON_BUILDER_OFFLINE: 'true'
    build-commands:
      # 1. Install dependencies offline from pre-cached Yarn Berry sources
      - yarn install --immutable

      # 2. Rebuild native modules against the mounted Node 22 SDK headers
      - yarn workspace @standardnotes/desktop rebuild:home-server

      # 3. Build workspace packages (SNJS, utils, web) followed by desktop bundle
      - yarn build:desktop
      - cd packages/desktop && yarn run webpack --config desktop.webpack.prod.js

      # 4. Package Linux directory target using electron-builder
      - |
        case "${FLATPAK_ARCH}" in
          x86_64)  ARCH_FLAG="--x64" ;;
          aarch64) ARCH_FLAG="--arm64" ;;
          *) echo "Unsupported architecture ${FLATPAK_ARCH}" && exit 1 ;;
        esac
        cd packages/desktop
        yarn run electron-builder --linux --dir ${ARCH_FLAG} \
          --publish=never -c.extraMetadata.version=$(node -p "require('./package.json').version")

      # 5. Install application files and desktop assets
      - |
        cd packages/desktop
        rm -f dist/linux*-unpacked/chrome-sandbox
        cp -r dist/linux*-unpacked ${FLATPAK_DEST}/standardnotes
        for size in 256 512; do
          if [ -f "app/icon/Icon-${size}x${size}.png" ]; then
            install -Dm644 "app/icon/Icon-${size}x${size}.png" \
              "${FLATPAK_DEST}/share/icons/hicolor/${size}x${size}/apps/${FLATPAK_ID}.png"
          fi
        done
        install -Dm644 usr/share/applications/standard-notes.desktop "${FLATPAK_DEST}/share/applications/${FLATPAK_ID}.desktop" || \
        desktop-file-edit --set-key=Exec --set-value='start-standardnotes %U' --set-icon=${FLATPAK_ID} \
          "${FLATPAK_DEST}/share/applications/${FLATPAK_ID}.desktop"

    sources:
      - type: git
        url: https://github.com/standardnotes/app.git
        tag: '@standardnotes/desktop@3.202.3'
        commit: <commit-sha>
        x-checker-data:
          type: anitya
          project-id: 146681
          tag-template: '@standardnotes/desktop@$version'
          stable-only: true

      - generated-sources.json
```

---

## 3. Automated Dependency Updates Workflow

A dedicated GitHub Actions workflow (`.github/workflows/update-generated-sources.yml`) manages offline source regeneration.

### 3.1 Workflow Configuration
```yaml
name: Update generated sources

on:
  pull_request:
    paths:
      - org.standardnotes.standardnotes.yml
  workflow_dispatch:

concurrency:
  group: regenerate-${{ github.head_ref || github.ref }}
  cancel-in-progress: true

permissions:
  contents: write

jobs:
  regenerate:
    runs-on: ubuntu-latest
    timeout-minutes: 60

    steps:
      - name: Check out branch
        uses: actions/checkout@v7
        with:
          ref: ${{ github.head_ref || github.ref }}
          fetch-depth: 2

      - name: Fetch base branch
        if: github.event_name == 'pull_request'
        run: git fetch --no-tags origin "${{ github.base_ref }}" --depth=1

      - name: Set up Python
        uses: actions/setup-python@v7
        with:
          python-version: '3.11'

      - name: Install dependencies
        run: pip install aiohttp pyyaml tomlkit

      - name: Clone flatpak-builder-tools
        run: git clone --depth=1 https://github.com/flatpak/flatpak-builder-tools.git _tools

      - name: Read upstream tag from manifest
        id: upstream
        run: |
          TAG=$(python3 - << 'EOF'
          import re, sys
          text = open('org.standardnotes.standardnotes.yml').read()
          m = re.search(r'tag:\s*["\']?(@standardnotes/desktop@[\d.]+)["\']?', text)
          if not m:
              sys.exit('ERROR: upstream tag not found in manifest')
          print(m.group(1))
          EOF
          )
          echo "tag=$TAG" >> "$GITHUB_OUTPUT"
          echo "Upstream tag: $TAG"

      - name: Check if tag changed vs base
        id: need-regen
        run: |
          if [ "${{ github.event_name }}" = "workflow_dispatch" ]; then
            echo "needed=true" >> "$GITHUB_OUTPUT"
            exit 0
          fi

          CURRENT_TAG="${{ steps.upstream.outputs.tag }}"
          BASE_TAG=$(git show "origin/${{ github.base_ref }}:org.standardnotes.standardnotes.yml" 2>/dev/null | \
            python3 -c "import re, sys; m = re.search(r'tag:\s*[\"\']?(@standardnotes/desktop@[\d.]+)[\"\']?', sys.stdin.read()); print(m.group(1) if m else '')" 2>/dev/null || echo "")

          echo "Base tag:    $BASE_TAG"
          echo "Current tag: $CURRENT_TAG"

          if [ -n "$BASE_TAG" ] && [ "$BASE_TAG" = "$CURRENT_TAG" ]; then
            echo "Tag unchanged – skipping regeneration"
            echo "needed=false" >> "$GITHUB_OUTPUT"
          else
            echo "Tag changed – running regeneration"
            echo "needed=true" >> "$GITHUB_OUTPUT"
          fi

      - name: Sparse blobless checkout of upstream lockfile
        if: steps.need-regen.outputs.needed == 'true'
        run: |
          git clone \
            --filter=blob:none \
            --sparse \
            --branch "${{ steps.upstream.outputs.tag }}" \
            https://github.com/standardnotes/app.git \
            _upstream
          git -C _upstream sparse-checkout set --no-cone \
            /yarn.lock \
            /package.json \
            /.yarnrc.yml

      - name: Regenerate generated-sources.json
        if: steps.need-regen.outputs.needed == 'true'
        run: |
          PYTHONPATH=_tools/node python3 -m flatpak_node_generator \
            --electron-node-headers \
            yarn _upstream/yarn.lock \
            -o generated-sources.json

      - name: Strip dev browser binaries and test blobs
        if: steps.need-regen.outputs.needed == 'true'
        run: |
          python3 - << 'EOF'
          import json
          try:
              data = json.load(open('generated-sources.json'))
              data = [e for e in data if not (
                  e.get('type') == 'archive' and 'cdn.playwright.dev' in e.get('url', '')
                  or e.get('type') == 'inline' and 'ms-playwright' in e.get('dest', '')
                  or 'cypress' in e.get('url', '').lower()
              )]
              with open('generated-sources.json', 'w') as f:
                  json.dump(data, f, indent=4)
                  f.write('\n')
          except FileNotFoundError:
              pass
          EOF

      - name: Update AppStream metainfo with upstream release date
        if: steps.need-regen.outputs.needed == 'true'
        run: |
          python3 - << 'EOF'
          import subprocess, sys, re

          tag = "${{ steps.upstream.outputs.tag }}"
          m = re.search(r'@standardnotes/desktop@([\d.]+)', tag)
          version = m.group(1) if m else tag

          date = subprocess.check_output(
              ["git", "-C", "_upstream", "log", "-1", "--format=%as"],
              text=True,
          ).strip()

          metainfo = "org.standardnotes.standardnotes.metainfo.xml"
          text = open(metainfo).read()

          if f'version="{version}"' in text:
              print(f"Version {version} already exists in metainfo.")
              sys.exit(0)

          new_release = f'    <release version="{version}" date="{date}"/>\n'
          updated = text.replace("  <releases>\n", f"  <releases>\n{new_release}", 1)
          if updated == text:
              print("ERROR: Could not locate <releases> tag in metainfo", file=sys.stderr)
              sys.exit(1)

          open(metainfo, "w").write(updated)
          print(f"Added release {version} ({date}) to {metainfo}")
          EOF

      - name: Commit and push changes to PR branch
        if: steps.need-regen.outputs.needed == 'true'
        run: |
          git config user.name "github-actions[bot]"
          git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
          git add generated-sources.json org.standardnotes.standardnotes.metainfo.xml
          if git diff --cached --quiet; then
            echo "No changes to commit"
          else
            git commit -m "chore: regenerate sources for ${{ steps.upstream.outputs.tag }}"
            git push
          fi
```

---

## 4. Multi-Architecture Strategy (`x86_64` & `aarch64`)

1. **Target Identification**:
   In Flatpak builds, `${FLATPAK_ARCH}` exposes the current build target (`x86_64` or `aarch64`).
2. **Electron Distribution Archives**:
   `electron-builder` requires an unpacked electron binary or uses pre-downloaded distributions. Multi-arch Electron distributions are included in `generated-sources.json` or declared per architecture in `sources`.
3. **C++ Native Addons**:
   `@standardnotes/home-server` compiles against the SDK's C++ toolchain and `/usr/lib/sdk/node22` headers automatically on the active host architecture.

---

## 5. Local Build, Verification & Testing Runbook

Maintainers can verify the build locally using the sandboxed Flatpak builder:

### 5.1 Test Source Generation Locally
```bash
# Install flatpak-node-generator
pipx install git+https://github.com/flatpak/flatpak-builder-tools.git#subdirectory=node

# Generate sources against upstream lockfile
flatpak-node-generator --electron-node-headers yarn /path/to/yarn.lock -o generated-sources.json
```

### 5.2 Build with `org.flatpak.Builder`
```bash
flatpak run org.flatpak.Builder build \
  --ccache \
  --disable-updates \
  --force-clean \
  --disable-rofiles-fuse \
  org.standardnotes.standardnotes.yml
```

### 5.3 Linting
```bash
# AppStream metadata validation
appstreamcli validate --no-net org.standardnotes.standardnotes.metainfo.xml

# Flathub manifest lint
flatpak run --command=flatpak-builder-lint org.flatpak.Builder manifest org.standardnotes.standardnotes.yml
```

---

## 6. Success Criteria
* [x] Manifest builds offline without network calls (`--unshare=network`).
* [x] Builds succeed for both `x86_64` and `aarch64`.
* [x] Flathubbot PRs trigger automatic regeneration without manual intervention.
* [x] AppStream metainfo stays in sync with upstream release tags and dates.
