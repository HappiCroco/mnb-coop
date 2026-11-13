@echo off
rem Runs every headless test of the co-op mod with LOVE's console build (same LuaJIT as the game).
rem Each folder here is a tiny LOVE "game" that loads the mod's files and prints "N passed, M failed".
rem Needs: lovec.exe (set LOVEC if it isn't at D:\Programming\LOVE\lovec.exe), and the game's source
rem unpacked in <workspace>\vanilla-src for the save tests (or set MNB_VANILLA_DIR).
setlocal
if "%LOVEC%"=="" set "LOVEC=D:\Programming\LOVE\lovec.exe"
set "COOP_DIR=%~dp0.."
cd /d "%~dp0"
for %%t in (compilecheck cooptest settingstest camptest classictest hubtest squadtest battletest ordertest defensetest windowtest qmtest modtest ribtest steamtest) do (
    echo == %%t
    "%LOVEC%" %%t
)
endlocal
