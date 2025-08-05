#!/bin/bash
RATOUT=distrib/rathammer-windows

rm -rf "$RATOUT"
mkdir "$RATOUT"

zig build -Doptimize=ReleaseSafe
cp zig-out/bin/rathammer "$RATOUT"
cp -r ratasset "$RATOUT"
cp  config.vdf "$RATOUT"
cp -r doc "$RATOUT"

mkdir "$RATOUT"/ratgraph
cp -r ratgraph/asset "$RATOUT"/ratgraph

rm "$RATOUT"/ratgraph/asset/fonts/*

LOUT="$RATOUT"

cp libfreetype-6.dll $RATOUT
cp SDL3.dll        $RATOUT
cp libbz2-1.dll $RATOUT
cp libbrotlidec.dll $RATOUT
cp libharfbuzz-0.dll $RATOUT
cp libpng16-16.dll $RATOUT
cp zlib1.dll $RATOUT
cp libbrotlicommon.dll $RATOUT
cp libgcc_s_seh-1.dll $RATOUT
cp libstdc++-6.dll $RATOUT
cp libgraphite2.dll $RATOUT
cp libglib-2.0-0.dll $RATOUT
cp libintl-8.dll $RATOUT
cp libwinpthread-1.dll $RATOUT
cp libiconv-2.dll $RATOUT
cp libpcre2-8-0.dll $RATOUT

cp -r rat_custom "$RATOUT"

cd distrib
zip -r win.zip rathammer-windows
cd ..
