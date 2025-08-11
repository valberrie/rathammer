# This script is untested
sudo pacman -S zig libepoxy freetype2 sdl3 zenity
git clone https://github.com/nmalthouse/rathammer.git
cd rathammer
git submodule update --init --recursive
zig build -Doptimize=ReleaseSafe


echo "Binaries should be in zig-out/bin"
