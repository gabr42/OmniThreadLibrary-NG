@echo off
setlocal enabledelayedexpansion

rem ============================================================
rem  Compile and run OTL-NG unit tests on every supported target.
rem  Win32 / Win64 / Linux64 / Android64 runtime + ARM64EC compile.
rem
rem  Stages run sequentially. A failure in one stage does not abort
rem  the script -- all stages run and a summary is printed at the
rem  end. Script exits with code 1 if any stage failed.
rem
rem  Stress tests
rem  ------------
rem  Tests tagged [Category('Stress')] are EXCLUDED by default (they
rem  run for minutes and would dominate the cross-platform sweep).
rem  Arguments passed to this script are forwarded verbatim to each
rem  runner -- Win32/Win64/Linux64 get them via %* on the command line,
rem  Android64 gets them as a "dunitx_filter" intent string extra that
rem  OtlAndroidTests.dpr / ConfigureDUnitXFilter parses -- so:
rem
rem    build_test_all.bat --include:Stress
rem    build_test_all.bat --run:TestTask.TestStartTask
rem
rem  work on every runtime target. See ConsoleTestRunner.dpr's
rem  HasAnyDUnitXFilterSwitch for the flags that bypass the default
rem  Stress exclusion on the console targets; the FMX runner accepts
rem  whitespace-separated --include:X / --exclude:X tokens.
rem ============================================================

cd /d "%~dp0" || exit /b 1

set "DELPHI_ROOT=C:\Program Files (x86)\Embarcadero\Studio\37.0"
set "DELPHI_BIN=%DELPHI_ROOT%\bin"
set "DELPHI_BIN64=%DELPHI_ROOT%\bin64"
set "ADB=C:\Users\Public\Documents\Embarcadero\Studio\37.0\CatalogRepository\AndroidSDK-37.0.60952.8797\platform-tools\adb.exe"
set "SRC_PATHS=..;../FastMM4"
set "NS_WIN=System;System.Win;Winapi;Vcl"
set "NS_LIN=System;Data;Xml"
set "LINUX_SDK=%USERPROFILE%\Documents\Embarcadero\Studio\SDKs\ubuntu24.04.sdk"
set "LINUX_LIBS=%LINUX_SDK%\usr\lib\x86_64-linux-gnu;%LINUX_SDK%\lib\x86_64-linux-gnu;%LINUX_SDK%\usr\lib\gcc\x86_64-linux-gnu\13;%DELPHI_ROOT%\lib\linux64\debug;%DELPHI_ROOT%\lib\linux64\release"

set "WIN32_RC=skip"
set "WIN64_RC=skip"
set "LINUX_RC=skip"
set "ANDROID_RC=skip"
set "ARM64EC_RC=skip"
set "ANDROID_SUMMARY="

rem ------------------------------------------------------------
echo.
echo ==== [1/5] Win32: compile + run ====
"%DELPHI_BIN%\dcc32.exe" ConsoleTestRunner.dpr -B "-U%SRC_PATHS%" "-NS%NS_WIN%" -DDEBUG -E"./Win32/Debug" -NU"./Win32/Debug"
if errorlevel 1 (
  set "WIN32_RC=compile-fail"
  goto :after_win32
)
".\Win32\Debug\ConsoleTestRunner.exe" %*
set "WIN32_RC=!errorlevel!"
:after_win32

rem ------------------------------------------------------------
echo.
echo ==== [2/5] Win64: compile + run ====
"%DELPHI_BIN%\dcc64.exe" ConsoleTestRunner.dpr -B "-U%SRC_PATHS%" "-NS%NS_WIN%" -DDEBUG -E"./Win64/Debug" -NU"./Win64/Debug"
if errorlevel 1 (
  set "WIN64_RC=compile-fail"
  goto :after_win64
)
".\Win64\Debug\ConsoleTestRunner.exe" %*
set "WIN64_RC=!errorlevel!"
:after_win64

rem ------------------------------------------------------------
echo.
echo ==== [3/5] Linux64: compile + run in WSL ====
rem Links against the Linux SDK that was imported with Delphi's SDK Manager.
if not exist "%LINUX_SDK%" (
  set "LINUX_RC=sdk-missing"
  goto :after_linux
)
"%DELPHI_BIN%\dcclinux64.exe" ConsoleTestRunner.dpr -B "-U%SRC_PATHS%" "-NS%NS_LIN%" -DDEBUG -CC -E"./Linux64/Debug" -NU"./Linux64/Debug" "--syslibroot:%LINUX_SDK%" "--libpath:%LINUX_LIBS%"
if errorlevel 1 (
  set "LINUX_RC=compile-fail"
  goto :after_linux
)
rem WSL may not see the drive with the sources, so pass the program through stdin.
wsl --cd / -- bash -c "cat > /tmp/OtlConsoleTestRunner && chmod +x /tmp/OtlConsoleTestRunner" < ".\Linux64\Debug\ConsoleTestRunner"
if errorlevel 1 (
  set "LINUX_RC=copy-fail"
  goto :after_linux
)
wsl --cd / -- /tmp/OtlConsoleTestRunner %*
set "LINUX_RC=!errorlevel!"
:after_linux

rem ------------------------------------------------------------
echo.
echo ==== [4/5] Android64: build + deploy + run ====
rem rsvars.bat does not set errorlevel; it would report a failure of the previous stage.
set "BDS="
call "%DELPHI_BIN%\rsvars.bat" >nul
if not defined BDS (
  set "ANDROID_RC=env-fail"
  goto :after_android
)
if not exist "%ADB%" (
  set "ANDROID_RC=adb-missing"
  goto :after_android
)
msbuild OtlAndroidTests.dproj /p:Config=Debug /p:Platform=Android64 /t:Make;Deploy /nologo /v:minimal
if errorlevel 1 (
  set "ANDROID_RC=build-fail"
  goto :after_android
)
"%ADB%" get-state >nul 2>&1
if errorlevel 1 (
  set "ANDROID_RC=no-device"
  goto :after_android
)
"%ADB%" install -r "Android64\Debug\OtlAndroidTests\bin\OtlAndroidTests.apk"
if errorlevel 1 (
  set "ANDROID_RC=install-fail"
  goto :after_android
)
"%ADB%" shell am force-stop com.embarcadero.OtlAndroidTests
"%ADB%" logcat -c
rem Forward %* as a string extra so OtlAndroidTests.dpr / ConfigureDUnitXFilter
rem can parse the same --include:/--exclude: tokens the console runners do.
if "%~1"=="" (
  "%ADB%" shell am start -a android.intent.action.MAIN -n com.embarcadero.OtlAndroidTests/com.embarcadero.firemonkey.FMXNativeActivity
) else (
  "%ADB%" shell am start -a android.intent.action.MAIN -n com.embarcadero.OtlAndroidTests/com.embarcadero.firemonkey.FMXNativeActivity --es dunitx_filter "%*"
)
echo     waiting up to 5 minutes for OTL_DIAG: AutoRun: TestCount=...
rem Use absolute path for ping.exe so the poll-loop sleep works reliably
rem even when PATH is inherited from MSYS/Git-bash (where `timeout` would
rem resolve to GNU `timeout`, rejecting the /t switch).
set "_ANDROID_TMP=%TEMP%\otl_android_logcat.txt"
for /l %%i in (1,1,60) do (
  %SystemRoot%\System32\ping.exe -n 6 127.0.0.1 >nul
  "%ADB%" logcat -d > "!_ANDROID_TMP!" 2>nul
  findstr /c:"OTL_DIAG: AutoRun: TestCount" "!_ANDROID_TMP!" >nul
  if not errorlevel 1 goto :android_found
)
set "ANDROID_RC=timeout"
goto :after_android
:android_found
for /f "usebackq delims=" %%L in (`findstr /c:"OTL_DIAG: AutoRun: TestCount" "!_ANDROID_TMP!"`) do set "ANDROID_SUMMARY=%%L"
echo     !ANDROID_SUMMARY!
echo !ANDROID_SUMMARY! | findstr /c:"Failed=0 Errors=0 Leaks=0" >nul
if errorlevel 1 (set "ANDROID_RC=tests-failed") else (set "ANDROID_RC=0")
del /q "!_ANDROID_TMP!" 2>nul
:after_android

rem ------------------------------------------------------------
echo.
echo ==== [5/5] ARM64EC: compile-only smoke ====
if not exist ".\ARM64EC\Debug" mkdir ".\ARM64EC\Debug" 2>nul
"%DELPHI_BIN64%\dccarm64ec.exe" ConsoleTestRunner.dpr -B "-U%SRC_PATHS%" "-NS%NS_WIN%" -DDEBUG -E"./ARM64EC/Debug" -NU"./ARM64EC/Debug"
set "ARM64EC_RC=!errorlevel!"

rem ------------------------------------------------------------
echo.
echo ============================================================
echo  SUMMARY   (rc=0 means success; non-zero or label = failure)
echo    Win32    : !WIN32_RC!
echo    Win64    : !WIN64_RC!
echo    Linux64  : !LINUX_RC!
echo    Android64: !ANDROID_RC!     !ANDROID_SUMMARY!
echo    ARM64EC  : !ARM64EC_RC!
echo ============================================================

set "OVERALL=0"
if not "!WIN32_RC!"=="0"   set "OVERALL=1"
if not "!WIN64_RC!"=="0"   set "OVERALL=1"
if not "!LINUX_RC!"=="0"   set "OVERALL=1"
if not "!ANDROID_RC!"=="0" set "OVERALL=1"
if not "!ARM64EC_RC!"=="0" set "OVERALL=1"
endlocal & exit /b %OVERALL%
