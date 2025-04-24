#!/bin/sh

set -oue pipefail

export FLATPAK_ID="${FLATPAK_ID:-org.standardnotes.standardnotes}"
export TMPDIR="${XDG_RUNTIME_DIR}/app/${FLATPAK_ID}"

zypak-wrapper /app/standardnotes/standard-notes --gtk-version=4 --enable-wayland-ime $@
