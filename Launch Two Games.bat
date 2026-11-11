@echo off
rem Opens two copies of Mud and Blood for co-op testing on one PC:
rem   1. the normal one, through Steam
rem   2. a second one started directly from mnb.exe (works because of steam_appid.txt
rem      next to mnb.exe; delete that file to undo the trick)
rem Both copies are logged in as you and share the same save files.
rem In one copy: Multiplayer, HOST. In the other: Multiplayer, type 127.0.0.1, JOIN.

setlocal
if "%MNB_GAME_DIR%"=="" (set "GAME=D:\Games\Steam\steamapps\common\MudandBlood") else (set "GAME=%MNB_GAME_DIR%")

if not exist "%GAME%\mnb.exe" (
    echo Could not find mnb.exe in "%GAME%".
    echo Set MNB_GAME_DIR to your Mud and Blood folder.
    pause
    exit /b 1
)
if not exist "%GAME%\steam_appid.txt" (
    echo steam_appid.txt is missing next to mnb.exe, so the second copy can't start.
    echo Create it with the single line 1391530 and run this again.
    pause
    exit /b 1
)

echo Starting Mud and Blood through Steam...
start "" "steam://rungameid/1391530"

echo Waiting for it to load before starting the second copy...
timeout /t 10 /nobreak >nul

echo Starting the second copy...
start "" /D "%GAME%" "%GAME%\mnb.exe"
endlocal
