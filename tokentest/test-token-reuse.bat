@echo off
setlocal EnableExtensions DisableDelayedExpansion
REM ===============================================================
REM  test-token-reuse.bat  -  AGENCY AND AGENT ONLY
REM
REM  WHAT THIS IS FOR. It proves how many times the scripts actually log in
REM  to Salesforce. It runs three jobs back to back, and every job needs the
REM  org, so if the login were not being shared you would see three logins.
REM  At the end it prints exactly how many OAuth round trips it performed.
REM
REM  Then check the org and confirm the two numbers agree:
REM    Setup -> Identity -> Login History
REM  Filter on the External Client App's run-as user and sort by time. Count
REM  the rows from the minute you started the run.
REM
REM  WHAT TO EXPECT
REM    First run on a machine that has never authenticated : 1 login
REM    Second run, straight after                          : 0 logins
REM    Run with /fresh                                     : 1 login, always
REM
REM  The second run is the whole point. "sf org login access-token -p"
REM  persisted the login to disk, so a later run can pick it up instead of
REM  asking Salesforce for another one. Before this check existed, every run
REM  authenticated again and every run showed up as a new login.
REM ===============================================================
REM  SAVE THIS FILE WITH WINDOWS (CRLF) LINE ENDINGS.
REM  With Unix (LF) endings cmd does not report an error - it MIS-SEEKS. A
REM  call returns to the wrong byte offset and control resumes in the middle
REM  of an unrelated routine. If you ever see "The system cannot find the
REM  batch label specified", check the line endings before anything else.
REM ===============================================================
REM
REM  FOLDER STRUCTURE - the UAT layout, nothing new
REM    C:\NLG\Config\clientcreds.json          the login, shared by every job
REM    C:\NLG\Config\process-conf.xml          the bean
REM    C:\NLG\Config\AgencyMapping.sdl         mapping, only used by /load
REM    C:\NLG\Config\AgentMapping.sdl
REM    C:\NLG\Source Data\Agency\Agency.csv    only used by /load
REM    C:\NLG\Source Data\Agent\Agent-Active.csv
REM    C:\NLG\Source Data\Agent\Agent-Terminated.csv
REM    C:\NLG\Log\                             this script writes here
REM
REM  Set NLG_ROOT to test from somewhere other than C:\NLG.
REM
REM  USAGE
REM    test-token-reuse.bat              all three jobs, READ ONLY (default)
REM    test-token-reuse.bat /load        the real upserts, WRITES TO THE ORG
REM    test-token-reuse.bat /fresh       force a new login, for comparison
REM    test-token-reuse.bat AgencyUpsert one job on its own
REM
REM  READ ONLY IS THE DEFAULT ON PURPOSE. Counting logins does not require
REM  writing anything, so by default each job runs a small query against its
REM  own object instead of an upsert. That is a real API call over the real
REM  token, which is all the test needs, and it cannot touch your data.
REM  Use /load only when you want the upserts as well.
REM ===============================================================

set "VERSION=v1  token reuse test  Agency + Agent"

REM ---------------- where things are -----------------------------
set "SELFDIR=%~dp0"
set "ROOT=C:\NLG"
if defined NLG_ROOT set "ROOT=%NLG_ROOT%"
set "CONFIGDIR=%ROOT%\Config"
set "BEAN=%CONFIGDIR%\process-conf.xml"
set "SECRETS=%CONFIGDIR%\clientcreds.json"
set "LOGDIR=%ROOT%\Log"
if not exist "%LOGDIR%" md "%LOGDIR%" 2>nul

REM  Full paths, never bare names. A Git for Windows or GnuWin32 install puts
REM  its own find.exe ahead of System32 and the Unix one takes completely
REM  different arguments. The sf CLI is deliberately NOT pinned - it is user
REM  installed and PATH is the only sane way to reach it.
set "CURL=%SystemRoot%\System32\curl.exe"
set "FINDSTR=%SystemRoot%\System32\findstr.exe"

set "LOG=%LOGDIR%\test-token-reuse.log"
set "JTMP=%LOGDIR%\test-jsonval.tmp"
break>"%LOG%"

REM  The three jobs, in order. Agency first because in the real chain the
REM  agents resolve their parent agency by external id.
set "JOB1=AgencyUpsert"
set "JOB2=AgentActiveUpsert"
set "JOB3=AgentTerminatedUpsert"

REM ---------------- arguments ------------------------------------
set "MODE=query"
set "ONEJOB="
set "FORCE_LOGIN="
:args
if "%~1"=="" goto argsdone
if /i "%~1"=="/load"  (set "MODE=load"        & shift & goto args)
if /i "%~1"=="/fresh" (set "FORCE_LOGIN=1"    & shift & goto args)
if /i "%~1"=="/q"     (set "QUIET=1"          & shift & goto args)
set "ONEJOB=%~1"
shift
goto args
:argsdone

REM ---------------- counters -------------------------------------
REM  These are what the whole script exists to report.
set /a AUTHFETCH=0
set /a AUTHREUSE=0
set /a JOBSRUN=0
set /a JOBSFAILED=0

REM ---------------- checks ---------------------------------------
if not exist "%BEAN%"    (set "ERRMSG=Bean not found: %BEAN%" & goto :fatal)
if not exist "%SECRETS%" (set "ERRMSG=Credentials file not found: %SECRETS%" & goto :fatal)
if not exist "%CURL%"    (set "ERRMSG=curl.exe not found at %CURL%" & goto :fatal)

set "ORGALIAS="
call :jsonval "%SECRETS%" org ORGALIAS
if not defined ORGALIAS (set "ERRMSG=No 'org' key in %SECRETS%" & goto :fatal)

echo(
echo(  %~n0
echo(  ================================================
echo(   TARGET ORG:  %ORGALIAS%
echo(   MODE:        %MODE%
if defined FORCE_LOGIN echo(   /fresh:      forcing a new login, ignoring any stored one
echo(  ================================================
call :log "=== starting - org %ORGALIAS% - mode %MODE% ==="

REM ---------------- authenticate ONCE ----------------------------
echo(
echo(  Authentication
call :ensureauth
if errorlevel 1 goto :fatal

REM ---------------- run the jobs ---------------------------------
echo(
echo(  Jobs
if defined ONEJOB (
  call :runone "%ONEJOB%"
) else (
  call :runone "%JOB1%"
  call :runone "%JOB2%"
  call :runone "%JOB3%"
)

REM ---------------- the answer -----------------------------------
echo(
echo(  ================================================
echo(   RESULT
echo(  ================================================
echo(   Jobs run                     : %JOBSRUN%
echo(   Jobs failed                  : %JOBSFAILED%
echo(   OAuth logins to Salesforce   : %AUTHFETCH%
echo(   Times the stored login was reused : %AUTHREUSE%
echo(
if "%AUTHFETCH%"=="0" echo(   No login was needed. The stored one was still good.
if "%AUTHFETCH%"=="1" echo(   One login, shared by every job in this run.
if %AUTHFETCH% GTR 1  echo(   MORE THAN ONE LOGIN. That is the thing being hunted - send the log.
echo(
echo(   Now open Salesforce and count the rows:
echo(     Setup -^> Identity -^> Login History
echo(   Rows since this run started should equal %AUTHFETCH%.
echo(
call :log "RESULT jobs=%JOBSRUN% failed=%JOBSFAILED% logins=%AUTHFETCH% reused=%AUTHREUSE%"
echo(   Log: %LOG%
echo(
set "RC=0"
if not "%JOBSFAILED%"=="0" set "RC=2"
goto :finish

:fatal
call :log "ERROR: %ERRMSG%"
echo(
echo(  [FAILED]  %ERRMSG%
echo(
set "RC=1"

:finish
del /q "%JTMP%" 2>nul
if "%QUIET%"=="1" (endlocal & exit /b %RC%)
pause
endlocal & exit /b %RC%


REM ===============================================================
REM  :runone  <BeanId>  - one job. Reads the bean for what to do, checks the
REM  login is still there, then makes a real call to Salesforce.
REM ===============================================================
:runone
echo(
echo(  -- %~1
call :log "job %~1"
call :readbean "%~1"
if not defined ENTITY (
  echo(     [ERROR] bean id '%~1' not found in %BEAN%
  call :log "%~1: bean id not found"
  set /a JOBSFAILED+=1
  exit /b 1
)
call :log "%~1: entity=%ENTITY% op=%OPERATION% extid=%EXTID% csv=%CSV%"

REM  Ask again for every job. In a working run this prints "reusing" and
REM  costs nothing - that is the behaviour being demonstrated.
call :ensureauth
if errorlevel 1 (set /a JOBSFAILED+=1 & exit /b 1)

set /a JOBSRUN+=1
if /i "%MODE%"=="load" goto :runload

REM  Read-only: a small query against this job's own object. Real API call,
REM  real token, no writes.
echo(     query: SELECT Id FROM %ENTITY% LIMIT 5
call sf data query --query "SELECT Id FROM %ENTITY% LIMIT 5" --target-org %ORGALIAS% >"%LOGDIR%\%~1-query.txt" 2>&1 <nul
if errorlevel 1 (
  echo(     [ERROR] the query failed - see %LOGDIR%\%~1-query.txt
  call :log "%~1: query FAILED"
  set /a JOBSFAILED+=1
  exit /b 1
)
echo(     [OK] query returned - see %LOGDIR%\%~1-query.txt
call :log "%~1: query OK"
exit /b 0

:runload
if not defined CSV  (echo(     [ERROR] no dataAccess.name in the bean & set /a JOBSFAILED+=1 & exit /b 1)
if not exist "%CSV%" (echo(     [ERROR] source CSV not found: %CSV% & set /a JOBSFAILED+=1 & exit /b 1)
if not defined EXTID (echo(     [ERROR] no sfdc.externalIdField in the bean & set /a JOBSFAILED+=1 & exit /b 1)
echo(     upsert %ENTITY% on %EXTID% from %CSV%
echo(     THE SCREEN STAYS BLANK WHILE THIS RUNS. Do not press Ctrl-C.
call sf data upsert bulk --sobject %ENTITY% --file "%CSV%" --external-id %EXTID% --target-org %ORGALIAS% --wait 30 >"%LOGDIR%\%~1-load.json" 2>&1 <nul
if errorlevel 1 (
  echo(     [ERROR] the upsert failed - see %LOGDIR%\%~1-load.json
  call :log "%~1: upsert FAILED"
  set /a JOBSFAILED+=1
  exit /b 1
)
echo(     [OK] upsert finished - see %LOGDIR%\%~1-load.json
call :log "%~1: upsert OK"
exit /b 0


REM ===============================================================
REM  :ensureauth  - make sure there is a usable login, fetching one only if
REM  there is not. Deliberately has NO setlocal: it updates the counters and
REM  AUTHOK, and those have to survive back into the caller.
REM ===============================================================
:ensureauth
if defined AUTHOK (
  set /a AUTHREUSE+=1
  call :log "reusing the token already fetched in this run - no second authentication"
  exit /b 0
)
REM  Nothing fetched yet IN THIS PROCESS. That does not mean nobody is logged
REM  in - a previous run may have persisted one. Ask before authenticating.
call :haveauth
if not errorlevel 1 (
  set "AUTHOK=1"
  set /a AUTHREUSE+=1
  echo(  The sf CLI is already logged in to %ORGALIAS% - reusing it, no new Salesforce login
  call :log "the sf CLI already holds a live login for '%ORGALIAS%' - reused it, no OAuth round trip"
  exit /b 0
)
call :log "no usable login for '%ORGALIAS%' - fetching a token"
call :fetchtoken
if errorlevel 1 exit /b 1
set "AUTHOK=1"
set /a AUTHFETCH+=1
echo(  Authenticated to %ORGALIAS% - this is ONE new login in Salesforce
call :log "logged in as '%ORGALIAS%' - OAuth round trip number %AUTHFETCH% this run"
exit /b 0


REM ===============================================================
REM  :haveauth  - does the sf CLI already hold a usable login for the alias?
REM  0 = yes, 1 = no.
REM
REM  "sf org display" is a read that resolves the stored auth and touches the
REM  org, so an alias that was never authenticated, or whose token expired or
REM  was revoked, exits non-zero and we fetch a fresh one.
REM  /fresh sets FORCE_LOGIN and skips the check entirely, which is how you
REM  produce a login on demand to compare against.
REM ===============================================================
:haveauth
if defined FORCE_LOGIN exit /b 1
call sf org display --target-org %ORGALIAS% >nul 2>&1 <nul
if errorlevel 1 exit /b 1
exit /b 0


REM ===============================================================
REM  :fetchtoken  - one OAuth client-credentials round trip, then hand the
REM  token to the sf CLI. -p persists it under the alias, which is what lets
REM  a later run reuse it.
REM
REM  Every external command is invoked with CALL. On Windows the Salesforce
REM  CLI is sf.cmd, a batch file, and running one from another without CALL
REM  transfers control and never comes back.
REM
REM  The response JSON is deleted the moment it is read. It holds a live
REM  bearer token in clear text.
REM ===============================================================
:fetchtoken
setlocal
set "FT_TOK=%LOGDIR%\token.json"
set "JTMP=%LOGDIR%\fetchtoken-jsonval.tmp"
call :jsonval "%SECRETS%" domain       FT_DOMAIN
call :jsonval "%SECRETS%" clientId     FT_CLIENTID
call :jsonval "%SECRETS%" clientSecret FT_SECRET
if not defined FT_DOMAIN   (set "FT_ERR=domain missing from %SECRETS%"       & goto :ft_fail)
if not defined FT_CLIENTID (set "FT_ERR=clientId missing from %SECRETS%"     & goto :ft_fail)
if not defined FT_SECRET   (set "FT_ERR=clientSecret missing from %SECRETS%" & goto :ft_fail)

del /q "%FT_TOK%" 2>nul
call "%CURL%" -s -X POST "%FT_DOMAIN%/services/oauth2/token" ^
  -d "grant_type=client_credentials" ^
  -d "client_id=%FT_CLIENTID%" ^
  -d "client_secret=%FT_SECRET%" -o "%FT_TOK%" <nul
if errorlevel 1 (set "FT_ERR=curl could not reach the token endpoint - check 'domain' in %SECRETS%" & goto :ft_fail)
"%FINDSTR%" /l /c:"access_token" "%FT_TOK%" >nul || (set "FT_ERR=the token response carried no access_token - check clientId and clientSecret, and that the External Client App has the client-credentials flow enabled with a run-as user" & goto :ft_fail)
call :jsonval "%FT_TOK%" access_token FT_TOKEN
call :jsonval "%FT_TOK%" instance_url FT_INSTANCE
if not defined FT_TOKEN (set "FT_ERR=could not read access_token from the response" & goto :ft_fail)
if not defined FT_INSTANCE set "FT_INSTANCE=%FT_DOMAIN%"

set "SF_ACCESS_TOKEN=%FT_TOKEN%"
call sf org login access-token -r "%FT_INSTANCE%" -a %ORGALIAS% -p >nul <nul
if errorlevel 1 (set "FT_ERR=sf org login access-token failed for alias %ORGALIAS%" & goto :ft_fail)
del /q "%FT_TOK%" 2>nul
del /q "%JTMP%"   2>nul
REM  Plain exit /b, no endlocal: the implicit one drops SF_ACCESS_TOKEN too.
exit /b 0

:ft_fail
del /q "%FT_TOK%" 2>nul
del /q "%JTMP%"   2>nul
REM  FT_ERR expands while the line is PARSED, before endlocal runs, so the
REM  message survives into the caller. Standard batch idiom.
endlocal & set "ERRMSG=%FT_ERR%" & exit /b 1


REM ===============================================================
REM  :readbean  <BeanId>  - pull one bean's settings out of the XML.
REM  Same reader the real scripts use.
REM ===============================================================
:readbean
set "WANT=%~1"
setlocal EnableDelayedExpansion
set "INBEAN=0"
set "E=" & set "O=" & set "X=" & set "S=" & set "C="
for /f tokens^=1^,2^,4^ delims^=^" %%A in ('call "%FINDSTR%" /i /l /c:"<bean" /c:"<entry" "%BEAN%"') do (
  set "TAG=%%A"
  if not "!TAG:<bean=!"=="!TAG!" (
    if /i "%%B"=="%WANT%" (set "INBEAN=1") else (if "!INBEAN!"=="1" set "INBEAN=2")
  ) else (
    if "!INBEAN!"=="1" (
      set "K=%%B"
      set "V=%%C"
      if "!V!"=="/>" set "V="
      if "!V!"=="/"  set "V="
      if /i "!K!"=="sfdc.entity"          set "E=!V!"
      if /i "!K!"=="process.operation"    set "O=!V!"
      if /i "!K!"=="sfdc.externalIdField" set "X=!V!"
      if /i "!K!"=="process.mappingFile"  set "S=!V!"
      if /i "!K!"=="dataAccess.name"      set "C=!V!"
    )
  )
)
endlocal & (set "ENTITY=%E%" & set "OPERATION=%O%" & set "EXTID=%X%" & set "SDL=%S%" & set "CSV=%C%")
exit /b 0


REM ===============================================================
REM  :jsonval  <file> <key> <outvar>  - pull a string value out of JSON,
REM  pretty-printed or compact. Values must not contain spaces, which is true
REM  of domains, ids, secrets, tokens and urls.
REM ===============================================================
:jsonval
set "%~3="
set "JL="
"%FINDSTR%" /l /c:"%~2" "%~1" >"%JTMP%" 2>nul
set /p JL=<"%JTMP%"
if not defined JL exit /b 0
call set "JL=%%JL:*%~2=%%"
set "JL=%JL: =%"
set "JL=%JL:~2%"
>"%JTMP%" echo(%JL%
for /f tokens^=1^ delims^=^" %%A in ('type "%JTMP%"') do if not defined %~3 set "%~3=%%A"
exit /b 0


REM  THE REDIRECT GOES FIRST, AND IT HAS TO.
REM  Written the natural way round, echo(%~1>>"%LOG%", a message ENDING IN A
REM  DIGIT breaks: cmd reads the trailing "1>>" as "redirect stream 1", eats
REM  the digit and writes nothing to the log. "logins=1" became "logins=".
:log
>>"%LOG%" echo(%DATE% %TIME%  %~1
exit /b 0
