# todo this sucks.
# 
set -e
set -u
if [[ $# -lt 2 ]] ; then
    echo 'Script expects two arguments'
    echo 'First: directory of vmf'
    echo 'Second: name of vmf file without vmf extension'
    exit 1
fi


gamename="hl2_complete"
gamedir="/home/rat/.local/share/Steam/steamapps/common/Half-Life 2"
workingdir="/tmp/mapcompile"
outputdir="/home/rat/.local/share/Steam/steamapps/common/Half-Life 2/hl2/maps"
mkdir -p $workingdir


mapdir=$1  # the path to the map folder
mapname=$2 # name of map without the vmf extension

cp "$mapdir"/"$mapname".vmf "$workingdir"/"$mapname".vmf
cd $workingdir

wine "$gamedir"/bin/vbsp.exe -game "$gamedir"/"$ganename"  -novconfig $mapname
wine "$gamedir"/bin/vvis.exe -game "$gamedir"/"$ganename"  -novconfig $mapname
wine "$gamedir"/bin/vrad.exe -game "$gamedir"/"$ganename"  -novconfig $mapname
#sdk_materials.vmf out.bsp
cp "$mapname".bsp "$outputdir"/"$mapname".bsp
