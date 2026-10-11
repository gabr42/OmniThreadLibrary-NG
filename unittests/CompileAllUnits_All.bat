@echo off
rem Compiles all OTL-NG units with every supported Delphi.
rem   Delphi 11, 12, 13: Win32 (dcc32) and Win64 (dcc64).
rem   Delphi 13 only:    Linux64, Android64 and Windows ARM64EC (see :ExtraTargets).
set "NS=System;System.Win;Winapi;Vcl;Vcl.Imaging;Vcl.Samples;Data;Xml"
set "ALLOK=1"

call :Compile "e:\Delphi\22.0\bin" "Delphi 11 Alexandria"
call :Compile "e:\Delphi\23.0\bin" "Delphi 12 Athens"
call :Compile "e:\Delphi\37.0\bin" "Delphi 13 Florence"
call :ExtraTargets

echo.
echo ================================
if "%ALLOK%"=="1" (
  echo GLOBAL STATUS: OK
) else (
  echo GLOBAL STATUS: ERROR
)
echo ================================
goto :eof

:Compile
rem %1 = compiler bin folder, %2 = environment name
set "BINPATH=%~1"
set "ENVNAME=%~2"
set "OUTROOT=c:\0\MultiBuilder\%ENVNAME%"
set "LOGNAME=%ENVNAME: =_%"
mkdir "%OUTROOT%\exe" "%OUTROOT%\exe64" "%OUTROOT%\dcu\win32" "%OUTROOT%\dcu\win64" 2>nul

echo Compiling %ENVNAME% ...
"%BINPATH%\dcc32.exe" CompileAllUnits -b -u..;..\src;..\..\fastmm -i.. -ns%NS% -e"%OUTROOT%\exe" -n0"%OUTROOT%\dcu\win32" > "compile_%LOGNAME%.log" 2>&1
call :Report "%ENVNAME%" "compile_%LOGNAME%.log" %errorlevel%

echo Compiling %ENVNAME% (64-bit) ...
"%BINPATH%\dcc64.exe" CompileAllUnits -b -u..;..\src;..\..\fastmm -i.. -ns%NS% -e"%OUTROOT%\exe64" -n0"%OUTROOT%\dcu\win64" > "compile_%LOGNAME%_64.log" 2>&1
call :Report "%ENVNAME% 64-bit" "compile_%LOGNAME%_64.log" %errorlevel%
goto :eof

:ExtraTargets
rem Delphi 13 only. These targets need tools that the other versions do not have (and that the
rem e:\Delphi\37.0 copy lacks, e.g. dccaarm64), so the standard installation is used.
set "D13=C:\Program Files (x86)\Embarcadero\Studio\37.0"
set "XNAME=Delphi 13 Florence"
set "XLOG=compile_Delphi_13_Florence"
set "XROOT=c:\0\MultiBuilder\%XNAME%"
set "XNS_LIN=System;Data;Xml"
mkdir "%XROOT%\exe-arm64ec" "%XROOT%\dcu\arm64ec" "%XROOT%\exe-linux64" "%XROOT%\dcu\linux64" "%XROOT%\exe-android64" "%XROOT%\dcu\android64" 2>nul

rem --- Windows ARM64EC: compiled and linked, but cannot be run on an x64 machine.
echo Compiling %XNAME% (ARM64EC) ...
"%D13%\bin64\dccarm64ec.exe" CompileAllUnits -b -u..;..\src;..\..\fastmm -i.. -ns%NS% -e"%XROOT%\exe-arm64ec" -n0"%XROOT%\dcu\arm64ec" > "%XLOG%_ARM64EC.log" 2>&1
call :Report "%XNAME% ARM64EC" "%XLOG%_ARM64EC.log" %errorlevel%

rem --- Linux64: dcclinux64 links against a Linux SDK that was synced with the IDE (PAServer).
set "LSDK=%USERPROFILE%\Documents\Embarcadero\Studio\SDKs\ubuntu24.04.sdk"
if exist "%LSDK%" goto :linux64_build
echo   [ERROR] %XNAME% Linux64 - Linux SDK not found: %LSDK%
set "ALLOK=0"
goto :linux64_done
:linux64_build
echo Compiling %XNAME% (Linux64) ...
"%D13%\bin\dcclinux64.exe" CompileAllUnits -b -u..;..\src;..\..\fastmm -i.. -ns%XNS_LIN% -cc -e"%XROOT%\exe-linux64" -n0"%XROOT%\dcu\linux64" --syslibroot:"%LSDK%" --libpath:"%LSDK%\usr\lib\x86_64-linux-gnu;%LSDK%\lib\x86_64-linux-gnu;%LSDK%\usr\lib\gcc\x86_64-linux-gnu\13;%D13%\lib\linux64\debug;%D13%\lib\linux64\release" > "%XLOG%_Linux64.log" 2>&1
call :Report "%XNAME% Linux64" "%XLOG%_Linux64.log" %errorlevel%
:linux64_done

rem --- Android64: compile only. CompileAllUnits is a console program, so there is nothing
rem useful to link (and the NDK linker is not needed to know that all units compile). The only
rem failure that is accepted is the final "File not found: 'ldandroid.exe'".
echo Compiling %XNAME% (Android64, compile only) ...
"%D13%\bin\dccaarm64.exe" CompileAllUnits -b -u..;..\src;..\..\fastmm -i.. -ns%XNS_LIN% -e"%XROOT%\exe-android64" -n0"%XROOT%\dcu\android64" > "%XLOG%_Android64.log" 2>&1
set "XRC=%errorlevel%"
if "%XRC%"=="0" goto :android64_report
findstr /c:" Error: " "%XLOG%_Android64.log" >nul && goto :android64_report
findstr /c:"Fatal: " "%XLOG%_Android64.log" | findstr /v /c:"F1026 File not found: 'ldandroid.exe'" >nul && goto :android64_report
set "XRC=0"
:android64_report
call :Report "%XNAME% Android64" "%XLOG%_Android64.log" %XRC%
goto :eof

:Report
rem %1 = name, %2 = log file, %3 = compiler exit code. Deletes the log on success.
if "%~3"=="0" goto :report_ok
echo   [ERROR] %~1 - see %~2
set "ALLOK=0"
goto :eof
:report_ok
erase "%~2"
echo   [OK] %~1
goto :eof
