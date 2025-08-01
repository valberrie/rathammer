#!/bin/bash

echo "run this script from the repo directory not distrib/"

RATOUT=distrib/appimagebuild


rm -rf "$RATOUT"
mkdir "$RATOUT"

zig build -Doptimize=ReleaseSafe

cp zig-out/bin/rathammer "$RATOUT"
cp -r ratasset "$RATOUT"
cp  config.vdf "$RATOUT"
cp -r doc "$RATOUT"

#cp -r ratgraph "$RATOUT"
mkdir "$RATOUT"/ratgraph
cp -r ratgraph/asset "$RATOUT"/ratgraph

# the fonts are too big 
rm "$RATOUT"/ratgraph/asset/fonts/*


cp distrib/appimageskeleton/* "$RATOUT"/

mkdir "$RATOUT"/lib
LOUT="$RATOUT"/lib
#cp /usr/lib/libfreetype.so.6 $LOUT
cp /usr/lib/libSDL3.so.0  $LOUT
#cp /usr/lib/libepoxy.so.0  $LOUT
#cp /usr/lib/libz.so.1  $LOUT
##cp /usr/lib/libm.so.6  $LOUT
##cp /usr/lib/libc.so.6 $LOUT
##cp /usr/lib64/ld-linux-x86-64.so.2 $LOUT
#cp /usr/lib/libglib-2.0.so.0  $LOUT
#cp /usr/lib/libbz2.so.1.0  $LOUT
#cp /usr/lib/libpng16.so.16  $LOUT
#cp /usr/lib/libharfbuzz.so.0  $LOUT
#cp /usr/lib/libbrotlidec.so.1  $LOUT
#cp /usr/lib/libgraphite2.so.3 $LOUT
#cp /usr/lib/libbrotlicommon.so.1 $LOUT
#cp /usr/lib/libpcre2-8.so.0 $LOUT

#cp -r rat_custom "$RATOUT"
