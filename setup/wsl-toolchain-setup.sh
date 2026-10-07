#!/bin/bash
# One-time WSL toolchain setup: Haxe 4.3.7 (minimum 4.3.0) + Neko 2.3.0 (official tarballs in ~)
# Run after extracting the haxe linux64 tarball (haxe_<timestamp>_<hash>) and neko-2.3.0-linux64
# in your home dir:
#   wsl cp /mnt/o/.../setup/wsl-toolchain-setup.sh ~/wsl-toolchain-setup.sh
#   wsl bash ~/wsl-toolchain-setup.sh
set -e
cd "$HOME"

# The haxe tarball directory name changes with every release (haxe_20220306074705_e5eec31 was
# the 4.2.5 one), so accept any haxe_* directory instead of pinning a single release.
for d in haxe_*; do
	[ -d "$d" ] || continue
	if [ ! -e haxe ]; then
		mv "$d" haxe
	else
		rm -rf "$d"
	fi
done
if [ -d neko-2.3.0-linux64 ]; then
	if [ ! -e neko ]; then
		mv neko-2.3.0-linux64 neko
	else
		rm -rf neko-2.3.0-linux64
	fi
fi

# Install the environment helper into the WSL home dir
if [ -f /mnt/o/FNF-PsychEngine-0.6.3/FNF-PsychEngine-0.6.3/FNF-SeiunEngine/setup/wsl-env.sh ]; then
	cp /mnt/o/FNF-PsychEngine-0.6.3/FNF-PsychEngine-0.6.3/FNF-SeiunEngine/setup/wsl-env.sh "$HOME/wsl-env.sh"
fi
grep -q "wsl-env.sh" "$HOME/.bashrc" 2>/dev/null || echo ". \$HOME/wsl-env.sh" >> "$HOME/.bashrc"

. "$HOME/wsl-env.sh"
echo "haxe:    $(haxe -version 2>&1)"
echo "neko:    $(neko -version 2>&1)"
echo "haxelib: $(haxelib version 2>&1)"
