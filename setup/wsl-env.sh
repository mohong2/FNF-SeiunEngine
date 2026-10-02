# SeiunEngine WSL environment - Haxe 4.3.7 (minimum 4.3.0) + Neko 2.3.0
# (official binaries in ~/haxe and ~/neko, no GitHub needed)
# The binaries live in ~/haxe and ~/neko (extracted from the official tarballs).
# Usage: source ~/wsl-env.sh   (or put it in ~/.bashrc for new terminals)
export PATH="$HOME/haxe:$HOME/neko:$PATH"
export LD_LIBRARY_PATH="$HOME/neko:$LD_LIBRARY_PATH"
