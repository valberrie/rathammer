STEAM_PATH=/mnt/flash/SteamLibrary/steamapps/common
SHPATH=Half-Life\ 2/hl2.sh
cd ~/.steam/steam/ubuntu12_32/steam-runtime 

# What does ENABLE_PATHMATCH do? If it isn't set paths in gameinfo don't register
export ENABLE_PATHMATCH=1 

./run.sh "${STEAM_PATH}/${SHPATH}" -game hl2_complete  2>&1 | grep -v "\[S_API" #Make it stop bitching about the damn steam api
