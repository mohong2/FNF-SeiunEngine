#!/bin/sh
# SeiunEngine - Linux / WSL dependency setup
# Run from the project root:  ./setup/setup-unix.sh
set -e

# Load Haxe/Neko environment if present (~/wsl-env.sh or project setup/wsl-env.sh)
if [ -f "$HOME/wsl-env.sh" ]; then
	. "$HOME/wsl-env.sh"
elif [ -f "./setup/wsl-env.sh" ]; then
	. "./setup/wsl-env.sh"
fi

if ! command -v haxe >/dev/null 2>&1; then
	echo "ERROR: haxe not found on PATH."
	echo "Install Haxe 4.3.7 or newer and Neko first (see setup/wsl-env.sh), then re-run this script."
	exit 1
fi

echo "=== Haxe version: $(haxe -version 2>&1) ==="

echo "=== Installing system packages (g++, make, VLC, GL/X11 dev headers) ==="
sudo apt-get update
sudo apt-get install -y g++ make git curl unzip \
	zenity \
	libpulse0 \
	libvlc-dev libvlccore-dev \
	libgl1-mesa-dev libglu1-mesa-dev libx11-dev

if [ -d ".haxelib" ] && [ -n "$(ls -A .haxelib 2>/dev/null)" ]; then
	echo "=== .haxelib already exists -> pointing haxelib to it and SKIPPING library install ==="
	echo "    (this keeps any local modifications you made to the libraries)"
	haxelib setup "$(pwd)/.haxelib"
	haxelib fixrepo
else
	echo "=== Configuring haxelib (global ~/haxelib) ==="
	haxelib setup ~/haxelib

	echo "=== Installing Haxe libraries (see hmm.json) ==="
	haxe -cp ./setup -main Main --interp
fi

echo "=== Patching Lime iOS templates (Files-app Documents sharing) ==="
# Resolve the lime library that is actually in use instead of a hardcoded version
# directory (.haxelib/lime/8,0,1 was NOT the active library, so this copy silently
# patched a tree nothing read). NOTE: haxelib 4.x ignores HAXELIB_PATH - it keeps
# its repository path in its own config file - so "haxelib setup" is what matters.
LIME_DIR="$(haxelib libpath lime 2>/dev/null | head -n 1 | tr -d '\r' || true)"
LIME_DIR="${LIME_DIR%/}"
if [ -n "$LIME_DIR" ]; then
	LIME_IOS_TEMPLATE="$LIME_DIR/templates/ios/template"
else
	LIME_IOS_TEMPLATE=""
fi
if [ -f "$LIME_IOS_TEMPLATE/{{app.file}}/{{app.file}}-Info.plist" ]; then
	cp "templates/ios/template/{{app.file}}/{{app.file}}-Info.plist" \
		"$LIME_IOS_TEMPLATE/{{app.file}}/{{app.file}}-Info.plist"
	echo "Lime iOS templates patched OK."
else
	echo "WARNING: Lime iOS template not found - skipped (run after haxelib install lime)."
fi

echo ""
echo "Done! Now build with:"
echo "  haxelib run lime build linux -release"
echo "Output: export/release/linux/bin"
