#!/bin/sh
APPDIR=.

#LD_LIBRARY_PATH=$LD_LIBRARY_PATH
export LD_LIBRARY_PATH="$APPDIR"/lib:$LD_LIBRARY_PATH

echo "hello from appimage" $APPDIR 
echo "lib path" $LD_LIBRARY_PATH

"$APPDIR"/rathammer $@
