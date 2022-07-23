#!/bin/sh

set -oue pipefail

export FLATPAK_ID="${FLATPAK_ID:-org.standardnotes.standardnotes}"
export TMPDIR="${XDG_RUNTIME_DIR}/app/${FLATPAK_ID}"

# Wayland support can be optionally enabled like so:
# flatpak override --user --env=USE_WAYLAND=1 org.standardnotes.standardnotes
declare -i USE_WAYLAND="${USE_WAYLAND:-1}"
declare -i EXIT_CODE=0

if [[ "${USE_WAYLAND}" -eq 1 && "${XDG_SESSION_TYPE}" == "wayland" ]]; then
    zypak-wrapper /app/standardnotes/standard-notes --enable-features=UseOzonePlatform,WaylandWindowDecorations --ozone-platform=wayland $@ || EXIT_CODE=$?
    # Fall back to x11 if failed to launch under Wayland. Otherwise, exit normally
    [[ "${EXIT_CODE}" -ne 133 ]] && exit "${EXIT_CODE}"
fi

zypak-wrapper /app/standardnotes/standard-notes $@
