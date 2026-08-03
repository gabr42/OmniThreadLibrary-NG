@echo off
set "NS=System;System.Win;Winapi;Vcl;Vcl.Imaging;Vcl.Samples;Data;Xml"
set "ALLOK=1"

call :Compile "e:\Delphi\22.0\bin" "Delphi 11 Alexandria"
call :Compile "e:\Delphi\23.0\bin" "Delphi 12 Athens"
call :Compile "e:\Delphi\37.0\bin" "Delphi 13 Florence"

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
set "BINPATH=%~1"
set "ENVNAME=%~2"
set "LOGNAME=%ENVNAME: =_%"
set "LOGFILE=compile_%LOGNAME%.log"
echo Compiling %ENVNAME% ...
"%BINPATH%\dcc32.exe" CompileAllUnits -b -u..;..\src;..\..\fastmm -i.. -ns%NS% -e"c:\0\MultiBuilder\%ENVNAME%\exe" -n0"c:\0\MultiBuilder\%ENVNAME%\dcu\win32" > "%LOGFILE%" 2>&1
if errorlevel 1 (
  echo   [ERROR] %ENVNAME% - see %LOGFILE%
  set "ALLOK=0"
) else (
  erase "%LOGFILE%"
  echo   [OK] %ENVNAME%
)
goto :eof
