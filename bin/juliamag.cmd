@echo off
rem Start JuliaMag from this repo: bin\juliamag.cmd [project folder]
rem
rem The optional argument is a project folder to open.
rem Set JULIA to use another Julia than the one on the PATH.
rem Until the app is packaged (plan 5), this is how to start it.
setlocal
set "REPO=%~dp0.."
if not defined JULIA set "JULIA=julia"
rem A full path in JULIA is checked as a file; a bare name is looked up on the PATH.
if exist "%JULIA%" goto run
where "%JULIA%" >nul 2>&1
if errorlevel 1 goto nojulia
:run
"%JULIA%" -t auto,1 "--project=%REPO%\JuliaMagUI" -e "using JuliaMagUI; JuliaMagUI.main(ARGS)" %*
set "CODE=%ERRORLEVEL%"
rem Keep the window open on an error, so a start from Explorer shows the message.
if not "%CODE%"=="0" pause
exit /b %CODE%
:nojulia
echo JuliaMag needs Julia 1.12 or newer.
echo Install it from https://julialang.org/downloads/ and add it to the PATH, or set JULIA to its full path.
pause
exit /b 1
