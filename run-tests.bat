@echo off
setlocal

REM Usage:
REM   run-tests.bat [features] [env] [tags]
REM Examples:
REM   run-tests.bat
REM   run-tests.bat 04
REM   run-tests.bat "04,05" dev
REM   run-tests.bat "18,19" test "@data-driven"

set "FEATURES=%~1"
set "ENV=%~2"
set "TAGS=%~3"

if "%ENV%"=="" set "ENV=dev"

set "MVN_ARGS=test -Dkarate.env=%ENV%"

if not "%FEATURES%"=="" (
    set "MVN_ARGS=%MVN_ARGS% -Dkarate.features=%FEATURES%"
)

if not "%TAGS%"=="" (
    set "MVN_ARGS=%MVN_ARGS% -Dkarate.tags=%TAGS%"
)

echo ========================================================
echo Running Standalone Karate Tests
echo   Command: mvn %MVN_ARGS%
echo ========================================================

mvn %MVN_ARGS%
endlocal
