#!/bin/bash

echo "run this script from the repo directory not distrib/"

RATOUT=distrib/appimagebuild


rm -rf "$RATOUT"
mkdir "$RATOUT"

zig build -Doptimize=ReleaseSafe

cp zig-out/bin/rathammer "$RATOUT"
cp zig-out/bin/jsonmaptovmf "$RATOUT"
cp zig-out/bin/mapbuilder "$RATOUT"
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
LIBPATH="/lib/x86_64-linux-gnu"


#cp "$LIBPATH"/libfreetype.so.6 $LOUT
#cp /usr/lib/libSDL3.so.0  $LOUT
#cp "$LIBPATH"/libepoxy.so.0  $LOUT
#cp "$LIBPATH"/libz.so.1  $LOUT
#cp "$LIBPATH"/libm.so.6  $LOUT
##cp /usr/lib/libc.so.6 $LOUT
##cp /usr/lib64/ld-linux-x86-64.so.2 $LOUT
#cp "$LIBPATH"/libbz2.so.1.0  $LOUT
#cp "$LIBPATH"/libpng16.so.16  $LOUT
#cp "$LIBPATH"/libharfbuzz.so.0  $LOUT
#cp "$LIBPATH"/libbrotlidec.so.1  $LOUT
##cp /usr/lib/libglib-2.0.so.0  $LOUT
#cp "$LIBPATH"/libgraphite2.so.3 $LOUT
#cp "$LIBPATH"/libbrotlicommon.so.1 $LOUT
#cp "$LIBPATH"/libpcre2-8.so.0 $LOUT

# Copyright stuff
cp ratgraph/c_libs/libspng/LICENSE "$RATOUT"/SPNG_LICENSE
cp LICENSE "$RATOUT"/LICENSE

cd distrib
zip -r rathammer_linux_x86_x64.zip appimagebuild
cd ..
