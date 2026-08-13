@echo off
:: =====================================================================
:: Vela Server Tester
:: Tests each server by hitting movie/157336 (Interstellar) via HTTP HEAD.
:: A 200 or 301/302 response = server is up and pointing at something.
:: Run this before adding servers to the app.
:: =====================================================================

setlocal enabledelayedexpansion
set PASS=0
set FAIL=0
set TMDB_ID=157336

echo.
echo ===================================================
echo  Vela Server Tester  ^|  Testing movie ID %TMDB_ID%
echo ===================================================
echo.

:: --- Helper macro: call :test "Name" "URL"
call :test "VixSrc"           "https://vixsrc.to/movie/%TMDB_ID%"
call :test "VidLink"          "https://vidlink.pro/movie/%TMDB_ID%"
call :test "VidSrc.mov"       "https://vidsrc.mov/embed/movie/%TMDB_ID%"
call :test "VidSrc.sbs"       "https://vidsrc.sbs/embed/movie/%TMDB_ID%"
call :test "VidSrc.wiki"      "https://vidsrc.wiki/embed/movie/%TMDB_ID%"
call :test "2Embed.stream"    "https://www.2embed.stream/embed/movie/%TMDB_ID%"
call :test "2Embed.cc"        "https://www.2embed.cc/embed/movie/%TMDB_ID%"
call :test "MoviesApi.to"     "https://moviesapi.to/movie/%TMDB_ID%"
call :test "SuperEmbed"       "https://multiembed.mov/directstream.php?video_id=%TMDB_ID%&tmdb=1"
call :test "AutoEmbed"        "https://autoembed.co/movie/tmdb/%TMDB_ID%"
call :test "SmashyStream"     "https://embed.smashystream.com/playere.php?tmdb=%TMDB_ID%"
call :test "NontonGo"         "https://nontongo.win/embed/movie/%TMDB_ID%"
call :test "VidPhantom"       "https://vidphantom.com/movie/%TMDB_ID%"
call :test "VidNest"          "https://vidnest.fun/movie/%TMDB_ID%"
call :test "HnEmbed"          "https://hnembed.com/embed/movie/%TMDB_ID%"
call :test "ApiPlayer"        "https://apiplayer.ru/embed/movie/%TMDB_ID%"
call :test "EmbedSito"        "https://embedsito.com/v2/movie/%TMDB_ID%"
call :test "MovCloud"         "https://movcloud.net/embed/movie/%TMDB_ID%"

echo.
echo --- Anime servers (use TMDB ID for anime shows) ---
echo  Note: some anime servers need MAL/AniList IDs, not TMDB.
echo  Testing with Attack on Titan TMDB ID 44217 as TV show.
echo.

set ANIME_ID=44217
call :test "VidLink Anime"    "https://vidlink.pro/tv/%ANIME_ID%/1/1"
call :test "2Embed Anime"     "https://www.2embed.stream/embed/tv/%ANIME_ID%/1/1"
call :test "HnEmbed Anime"    "https://hnembed.com/embed/tv/%ANIME_ID%/1/1"

echo.
echo ===================================================
echo  Results: %PASS% PASSED  ^|  %FAIL% FAILED
echo ===================================================
echo.
pause
goto :eof

:: =====================================================================
:test
set NAME=%~1
set URL=%~2
<nul set /p "=[TESTING] %-20s" "%NAME%"
for /f "tokens=*" %%R in ('curl -s -o nul -w "%%{http_code}" --max-time 8 --location "%URL%"') do set CODE=%%R
if "%CODE%"=="200" (
    echo  [OK  %CODE%]  %URL%
    set /a PASS+=1
) else if "%CODE%"=="301" (
    echo  [OK  %CODE%]  %URL%
    set /a PASS+=1
) else if "%CODE%"=="302" (
    echo  [OK  %CODE%]  %URL%
    set /a PASS+=1
) else if "%CODE%"=="403" (
    echo  [OK  %CODE%]  %URL%  ^(blocks bots but server is up^)
    set /a PASS+=1
) else (
    echo  [FAIL %CODE%]  %URL%
    set /a FAIL+=1
)
goto :eof
