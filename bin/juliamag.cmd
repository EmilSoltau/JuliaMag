@echo off
rem Start JuliaMag from this repo: bin\juliamag.cmd [project folder]
rem
rem The optional argument is a project folder to open.
rem Set JULIA to use another Julia than the one on the PATH.
rem Until the app is packaged (plan 5), this is how to start it.
setlocal
set "REPO=%~dp0.."
if not defined JULIA set "JULIA=julia"
"%JULIA%" -t auto,1 "--project=%REPO%\JuliaMagUI" -e "using JuliaMagUI; JuliaMagUI.main(ARGS)" %*
exit /b %ERRORLEVEL%
