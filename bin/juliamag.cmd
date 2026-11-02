@echo off
rem Start JuliaMag from this repo: bin\juliamag.cmd [project folder]
rem
rem The optional argument is a project folder to open.
rem Set JULIA to use another Julia than the one on the PATH.
rem Until the app is packaged (plan 5), this is how to start it.
setlocal
set "REPO=%~dp0.."
if not defined JULIA set "JULIA=julia"
rem A full path in JULIA is checked as a file (a folder does not count); a bare name is
rem looked up on the PATH.
if exist "%JULIA%\" goto nojulia
if exist "%JULIA%" goto run
where "%JULIA%" >nul 2>&1
if errorlevel 1 goto nojulia
:run
rem start.jl installs the packages on the first start, then starts the app.
set "START=%REPO%\bin\start.jl"
set "ARG=%~1"
if not defined ARG goto noarg
if not "%~2"=="" goto allargs
rem A folder that ends in a backslash: "C:\My Project\" would reach Julia as
rem C:\My Project" (a backslash before a quote escapes it), so double that backslash.
if "%ARG:~-1%"=="\" set "ARG=%ARG%\"
"%JULIA%" -t auto,1 "--project=%REPO%\JuliaMagUI" "%START%" "%ARG%"
goto ran
:noarg
"%JULIA%" -t auto,1 "--project=%REPO%\JuliaMagUI" "%START%"
goto ran
:allargs
rem More than one argument: the app says it takes one project folder.
"%JULIA%" -t auto,1 "--project=%REPO%\JuliaMagUI" "%START%" %*
:ran
set "CODE=%ERRORLEVEL%"
rem Keep the window open on an error, so a start from Explorer shows the message.
if not "%CODE%"=="0" pause
exit /b %CODE%
:nojulia
echo JuliaMag needs Julia 1.12 or newer.
echo Install it from https://julialang.org/downloads/ and add it to the PATH, or set JULIA to its full path.
pause
exit /b 1
