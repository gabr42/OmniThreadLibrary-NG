@echo off
setlocal
call "C:\Program Files (x86)\Embarcadero\Studio\37.0\bin\rsvars.bat" || exit /b 1
set ADB=C:\Users\gabr\AppData\Local\Android\sdk\platform-tools\adb.exe
msbuild OtlAndroidTests.dproj /p:Config=Debug /p:Platform=Android64 /t:Make;Deploy /nologo /v:minimal || exit /b 1
"%ADB%" install -r "Android64\Debug\OtlAndroidTests\bin\OtlAndroidTests.apk" || exit /b 1
"%ADB%" shell am start -a android.intent.action.MAIN -n com.embarcadero.OtlAndroidTests/com.embarcadero.firemonkey.FMXNativeActivity
endlocal
