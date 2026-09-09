@echo off
setlocal EnableExtensions DisableDelayedExpansion
REM ===============================================================
REM  ccbat.bat - CONSERVATION CASE AUTOMATION.
REM  Upserts CaseStaging__c rows, which is what creates the Conservation
REM  Cases in Salesforce.
REM
REM  Replaces the single "call process" line. That one logged in with
REM  sfdc.username / sfdc.password / process.encryptionKeyFile out of the
REM  bean. That login is being retired, so this authenticates as an EXTERNAL
REM  CLIENT APP over OAuth client credentials instead, and the credentials
REM  live in ONE file: Config\clientcreds.json.
REM
REM  NOTHING ELSE CHANGED. Same folders, same source CSV, same SDL, same
REM  archive naming. The bean is the file that was on the server with four
REM  entries removed per bean and not one other character touched.
REM ===============================================================
REM  v1  2026-09-10   sandbox
REM ===============================================================
REM
REM  SAVE THIS FILE WITH WINDOWS (CRLF) LINE ENDINGS. NOT NEGOTIABLE.
REM  Saved with Unix (LF) endings cmd does not report an error - it
REM  MIS-SEEKS. A "call" returns to the wrong byte offset and control
REM  resumes in the middle of an unrelated routine. It cost a day on the
REM  purger. If you ever see "The system cannot find the batch label
REM  specified", check the line endings before anything else.
REM
REM  FOLDERS - THE SERVER'S OWN, UNCHANGED. Source Data sits DIRECTLY under
REM  NLG. It is NOT under Conservation Case Automation:
REM    D:\NLG\Source Data\Conservation Cases\    the CSV you supply
REM    D:\NLG\Conservation Case Automation\Config\      clientcreds.json, bean, SDL
REM    D:\NLG\Conservation Case Automation\LoadResult\  success + error CSVs
REM    D:\NLG\Conservation Case Automation\Log\         one log per bean, plus the run log
REM    D:\NLG\Conservation Case Automation\Archive\Archive_<MMDDYYYY HMM>\
REM
REM  The source CSV path and the results folder are ABSOLUTE IN THE BEAN, so
REM  they do not follow ROOT. Only Config, Log and Archive are derived from it.
REM
REM  MOVING BETWEEN ORGS - ONE FILE CHANGES
REM  Config\clientcreds.json only: domain, clientId, clientSecret, org.
REM  The "org" value IS the alias every sf command in this script uses. The
REM  bean and the SDL carry no org information and do not change.
REM  NOTE the retired bean pointed at https://login.salesforce.com, i.e.
REM  production. clientcreds.json is what decides that now - point "domain"
REM  at your sandbox while testing, or this loads into production.
REM
REM  THREE BEAN SETTINGS NO LONGER DO ANYTHING, AND ONE OF THEM MATTERS.
REM  They are Data Loader ProcessRunner settings; this script uses the sf
REM  CLI, which does not read them. They are LEFT IN THE BEAN so it still
REM  matches the server line for line, but do not expect them to take effect:
REM    sfdc.loadBatchSize=1        READ THE NOTE BELOW - this one is a
REM                                behaviour change, not just a dead setting.
REM    sfdc.insertNulls=False      Data Loader used this to stop blank CSV
REM                                cells blanking the field in Salesforce.
REM    process.initialLastRunDate  only ever used by Data Loader bookkeeping.
REM    sfdc.timeoutSecs            the wait is WAITMIN below instead.
REM
REM  ABOUT loadBatchSize=1. Somebody set that deliberately. A batch size of
REM  one is what you do when a trigger, a flow or a row-level error makes
REM  bigger batches fail or roll each other back - it makes every row
REM  succeed or fail entirely on its own. Bulk API v2 through the sf CLI
REM  chooses its own batching and CANNOT be told to use one row per batch,
REM  so that protection is GONE.
REM  What that means in practice: rows that used to fail individually may now
REM  fail in company with others, and if a trigger on CaseStaging__c throws,
REM  more rows can be affected per batch than before.
REM  RUN THIS IN A SANDBOX AGAINST A REAL FILE AND COMPARE THE ERROR CSV
REM  AGAINST A DATA LOADER RUN OF THE SAME FILE BEFORE TRUSTING IT IN
REM  PRODUCTION. If the counts differ, say so - it is fixable, but not by
REM  this script alone.
REM
REM  Usage:  ccbat.bat
REM             runs CaseStagingInsert, pauses at the end.
REM          ccbat.bat /q
REM             same, no pause - for Task Scheduler.
REM          ccbat.bat csvExportLead
REM             the test bean from the bean file. Extract only, writes
REM             10 Lead ids and changes nothing. Use it to prove the login
REM             works before pointing this at real data.
REM
REM  Exit codes: 0 every row loaded, 2 completed with failed rows, 1 the run
REM  stopped.
REM ===============================================================


REM ---------------- configuration --------------------------------
set "VERSION=v1 2026-09-10  sandbox"

set "ROOT=D:\NLG"
if defined NLG_ROOT set "ROOT=%NLG_ROOT%"
if defined NLG_ROOT call :winpath ROOT
REM  NLG_ROOT exists to test this somewhere other than the server. If you set
REM  it, remember the bean's own absolute paths do NOT move with it.

set "CCDIR=%ROOT%\Conservation Case Automation"
set "BEAN=%CCDIR%\Config\ccbean.bean"
if defined CC_BEAN set "BEAN=%CC_BEAN%"
if not exist "%BEAN%" if exist "%CCDIR%\Config\process-conf.xml" set "BEAN=%CCDIR%\Config\process-conf.xml"

set "ARCHIVEDIR=%CCDIR%\Archive"
set "RESULTDIR=%CCDIR%\LoadResult"
set "LOGDIR=%CCDIR%\Log"
set "CURL=%SystemRoot%\System32\curl.exe"

REM  EVERY WINDOWS TOOL IS CALLED BY FULL PATH. A bare name goes through
REM  PATH, and a Git for Windows or MSYS install puts its own find.exe ahead
REM  of System32 - the Unix find takes different arguments and turns the row
REM  count into a recursive walk of the whole drive, which looks like a hang.
set "FIND=%SystemRoot%\System32\find.exe"
set "FINDSTR=%SystemRoot%\System32\findstr.exe"
set "PSEXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"

REM  Fallback alias used ONLY if there is no credentials file at all. Left
REM  EMPTY on purpose so the script refuses to run rather than guess which
REM  org to write to.
set "DEFAULTALIAS="

set "JOB1=CaseStagingInsert"

REM  Minutes to wait for the bulk job. NOT a Salesforce limit - it is how
REM  long the sf CLI watches before returning. The job keeps running
REM  server-side past it, but no result files exist yet.
set "WAITMIN=60"

for %%D in ("%RESULTDIR%" "%ARCHIVEDIR%" "%LOGDIR%") do if not exist %%D md %%D 2>nul

REM ---------------- arguments ------------------------------------
REM  Canonicalised first, so this behaves the same from cmd, PowerShell or a
REM  Unix-style prompt. MSYS rewrites "/q" into "Q:/" before cmd ever sees it.
set "QUIET=0"
set "ONEJOB="
call :normarg ARG1 "%~1"
call :normarg ARG2 "%~2"
if /i "%ARG1%"=="q" set "QUIET=1"
if defined ARG1 if /i not "%ARG1%"=="q" set "ONEJOB=%ARG1%"
if defined ONEJOB if /i "%ARG2%"=="q" set "QUIET=1"
if not defined ONEJOB set "ONEJOB=%JOB1%"

set "LOG=%LOGDIR%\%~n0.log"
break>"%LOG%"
set "WORST=0"
set "JTMP=%LOGDIR%\jsonval.tmp"

REM  Show WHICH ORG before anything is written. The retired bean pointed at
REM  production, so this line is worth reading every single run.
set "TARGETORG="
if exist "%CCDIR%\Config\clientcreds.json" call :jsonval "%CCDIR%\Config\clientcreds.json" org TARGETORG
if not defined TARGETORG set "TARGETORG=%DEFAULTALIAS%"
if not defined TARGETORG set "TARGETORG=(unknown - no credentials file)"

echo(
echo(  %~n0   %VERSION%
echo(  ================================================
echo(   CONSERVATION CASE AUTOMATION
echo(   TARGET ORG:  %TARGETORG%
echo(  ================================================
echo(  job: %ONEJOB% ^| wait %WAITMIN% min
call :log "=== %~n0 %VERSION% starting - TARGET ORG %TARGETORG% ==="
call :log "Bean file: %BEAN%"
if not exist "%BEAN%" (set "ERRMSG=Bean not found: %BEAN%" & goto :fatal)
if not exist "%CURL%" (set "ERRMSG=curl.exe not found at %CURL% - needs Windows 10 1803 or later" & goto :fatal)
if not exist "%FIND%" (set "ERRMSG=find.exe not found at %FIND% - the row-count guard cannot run without it" & goto :fatal)
if not exist "%FINDSTR%" (set "ERRMSG=findstr.exe not found at %FINDSTR%" & goto :fatal)
if not exist "%PSEXE%" (set "ERRMSG=powershell.exe not found at %PSEXE%" & goto :fatal)

call :writesoqlhelper
if errorlevel 1 goto :fatal

REM ---------------- one archive folder for this run ---------------
REM  Same name the old script built: Archive_ then MMDD, YYYY, the hour
REM  space-padded, and the minute - so midnight reads "Archive_09042026 032"
REM  and sorts next to the folders already in there.
call :stamp
set "ARCHSUB=%ARCHIVEDIR%\Archive_%A_MMDD%%A_YYYY%%A_HHSP%%A_MI%"
call :log "Archive folder for this run: %ARCHSUB%"

REM ---------------- pre-flight ------------------------------------
echo(
echo(  Pre-flight
call :readbean "%ONEJOB%"
if not defined ENTITY (set "ERRMSG=Bean id '%ONEJOB%' not found in %BEAN%" & goto :fatal)
if /i "%OPERATION%"=="extract" goto :preflightok
if not defined CSV (set "ERRMSG=dataAccess.name missing for bean '%ONEJOB%'" & goto :fatal)
if not exist "%CSV%" (set "ERRMSG=Source CSV not found: %CSV% - put the file there and re-run. Nothing was loaded." & goto :fatal)
call :rowcount "%CSV%" PFROWS
echo(  OK  %ONEJOB%  ^<-  %CSV%  ^(%PFROWS% data rows^)
goto :preflightdone
:preflightok
echo(  OK  %ONEJOB%  -^>  %CSV%   ^(extract - changes nothing in the org^)
:preflightdone

REM ---------------- authenticate ----------------------------------
echo(
echo(  Authentication
call :ensureauth "%ONEJOB%"
if errorlevel 1 goto :fatal

REM ---------------- run -------------------------------------------
if /i "%OPERATION%"=="extract" goto :runextractjob
call :runjob "%ONEJOB%"
set "WORST=%ERRORLEVEL%"
if "%WORST%"=="1" (set "ERRMSG=%ONEJOB% did not complete - see %LOGDIR%\%ONEJOB%.log" & goto :fatal)
goto :report

:runextractjob
call :runjobextract "%ONEJOB%"
set "RC=%ERRORLEVEL%"
if "%RC%"=="1" (set "ERRMSG=%ONEJOB% did not complete - see %LOGDIR%\%ONEJOB%.log" & goto :fatal)
goto :report

REM ---------------- report ----------------------------------------
:report
set "RC=%WORST%"
if "%RC%"=="0" call :log "SUCCESS - every row loaded"
if "%RC%"=="2" call :log "COMPLETED WITH FAILURES - check the error CSV under %RESULTDIR%"
goto :finish

:fatal
call :log "ERROR: %ERRMSG%"
set "RC=1"
goto :finish

:finish
del /q "%JTMP%" 2>nul
echo(
if "%RC%"=="0" echo(  [OK]       Completed - no failed rows.
if "%RC%"=="2" echo(  [PARTIAL]  Completed, but some rows FAILED - see the error CSV.
if "%RC%"=="1" echo(  [FAILED]   The run stopped. %ERRMSG%
echo(             Log: %LOG%
echo(
if "%QUIET%"=="1" (endlocal & exit /b %RC%)
pause
endlocal & exit /b %RC%


REM ===============================================================
REM  :runjob  <BeanId>  - the whole load for one bean.
REM  Returns 0 = all rows loaded, 2 = some rows failed or results
REM  unconfirmed, 1 = hard error.
REM ===============================================================
:runjob
setlocal
set "PROCESS=%~1"
set "LOG=%LOGDIR%\%PROCESS%.log"
set "SECRETS=%CCDIR%\Config\clientcreds.json"
set "RAWJSON=%LOGDIR%\%PROCESS%-raw.json"
set "JTMP=%LOGDIR%\%PROCESS%-jsonval.tmp"
set "QPAT=%LOGDIR%\%PROCESS%-qpat.txt"
set "HPAT=%LOGDIR%\%PROCESS%-hdr.txt"
set "HDRNEW=%LOGDIR%\%PROCESS%-hdrnew.txt"
set "WORK=%LOGDIR%\%PROCESS%_input.csv"
break>"%LOG%"

call :log "Process=%PROCESS%"

REM ---------------- 1) read the bean -----------------------------
call :readbean "%PROCESS%"
if not defined ENTITY    (set "ERRMSG=sfdc.entity missing (bean id '%PROCESS%' not found in %BEAN%?)" & goto :jobdie)
if not defined OPERATION (set "ERRMSG=process.operation missing for bean '%PROCESS%'" & goto :jobdie)
if not defined CSV       (set "ERRMSG=dataAccess.name missing for bean '%PROCESS%'"   & goto :jobdie)
if not exist "%CSV%"     (set "ERRMSG=Source CSV not found: %CSV%" & goto :jobdie)
call :log "entity=%ENTITY% op=%OPERATION% csv=%CSV%"

if not defined STATUSDIR set "STATUSDIR=%RESULTDIR%"
if not exist "%STATUSDIR%" md "%STATUSDIR%" 2>nul

if not defined CREDFILE goto :creddefault
set "ABS=0"
if "%CREDFILE:~1,1%"==":"  set "ABS=1"
if "%CREDFILE:~0,2%"=="\\" set "ABS=1"
if "%ABS%"=="0" set "CREDFILE=%ROOT%\%CREDFILE%"
set "SECRETS=%CREDFILE%"
if not exist "%SECRETS%" (set "ERRMSG=Credentials file not found: %SECRETS%" & goto :jobdie)
call :log "Credentials: %SECRETS%"
goto :credresolved
:creddefault
if exist "%SECRETS%" (call :log "Credentials: %SECRETS%") else (call :log "No credentials file at %SECRETS% - will use the sf CLI's stored auth")
:credresolved

REM ---------------- 2) SDL mapping + CSV header remap ------------
REM  The SDL maps this CSV's headers onto api names. A column the SDL does
REM  not mention is DROPPED before the load, which is normal for a load file
REM  - source extracts routinely carry columns Salesforce has no field for.
setlocal EnableDelayedExpansion
set "NMAP=0"
if defined SDL if exist "%SDL%" (
  for /f "usebackq eol=# tokens=1,* delims==" %%A in ("%SDL%") do (
    set "SK=%%A"
    set "SV=%%B"
    if defined SV (
      set /a NMAP+=1
      set "M_!SK!=!SV!"
    )
  )
)
if !NMAP! equ 0 (
  echo(SDL mappings: 0 - assuming CSV headers are already API names
) else (
  echo(SDL mappings: !NMAP!
)

set "LINE="
set /p LINE=<"%CSV%"
if not defined LINE (endlocal & set "ERRMSG=Source CSV is empty: %CSV%" & goto :jobdie)
call :split
set "NCOL=!NF!"

REM  The header goes to a pattern file BEFORE any BOM handling, so it matches
REM  the file byte for byte. findstr /v /l /g: then drops exactly that line.
REM  "more" is used NOWHERE here and must not be reintroduced - it stops dead
REM  at a 0x1A byte and dies if Ctrl-C is pressed while it copies.
>"%HPAT%" echo(!LINE!

REM  Strip a UTF-8 BOM off column 1.
if !NMAP! gtr 0 (
  for %%c in ("!F1!") do if not defined M_%%~c (
    set "TRY=!F1:~3!"
    for %%d in ("!TRY!") do if defined M_%%~d (
      set "F1=!TRY!"
      echo(NOTE: UTF-8 BOM skipped on the first header - the CSV is fine, no action needed
    )
  )
)
if !NMAP! equ 0 (
  echo(!F1!|"%FINDSTR%" /r /c:"^[A-Za-z]" >nul
  if errorlevel 1 (
    set "TRY=!F1:~3!"
    echo(!TRY!|"%FINDSTR%" /r /c:"^[A-Za-z]" >nul
    if not errorlevel 1 (
      set "F1=!TRY!"
      echo(NOTE: UTF-8 BOM stripped from the first header - the CSV is fine, no action needed
    )
  )
)

set "NEWHDR="
set "KEEP="
set "DROPPED="
for /l %%j in (1,1,!NCOL!) do (
  set "AP="
  if !NMAP! gtr 0 (
    for %%c in ("!F%%j!") do set "AP=!M_%%~c!"
  ) else (
    set "AP=!F%%j!"
  )
  if defined AP (
    set "NEWHDR=!NEWHDR!,!AP!"
    set "KEEP=!KEEP! %%j"
  ) else (
    set "DROPPED=!DROPPED! !F%%j!"
  )
)
if not defined NEWHDR (endlocal & set "ERRMSG=No CSV column matched the SDL - check %SDL% against the header of %CSV%" & goto :jobdie)
set "NEWHDR=!NEWHDR:~1!"

if defined DROPPED (
  echo(Unmapped columns dropped:!DROPPED!
  set "FILTER=1"
) else (
  set "FILTER=0"
)

>"%HDRNEW%" echo(!NEWHDR!
>"%WORK%"   echo(!NEWHDR!

if "!FILTER!"=="0" (
  echo(Preparing input CSV ^(header renamed, !NCOL! columns kept^)
  endlocal
  goto :copybody
)

REM  Rebuild every row without the dropped columns. A quoted field containing
REM  a comma cannot be split on commas alone, so a CSV containing any double
REM  quote is refused rather than written back out silently mis-aligned.
>"%QPAT%" echo "
"%FINDSTR%" /l /g:"%QPAT%" "%CSV%" >nul 2>&1
if not errorlevel 1 (endlocal & set "ERRMSG=CSV contains a double quote, so unmapped columns cannot be dropped safely. Map every column in the SDL, or pre-trim the CSV." & goto :jobdie)

REM  THE REBUILD IS DONE BY POWERSHELL AND MUST STAY THAT WAY. A pure-cmd
REM  loop is quadratic here - 300 rows x 12 columns measured at 21 seconds,
REM  and a 100,000-row file took about two hours with nothing printed.
REM  Latin-1 (28591) on both read and write ON PURPOSE: it maps every byte
REM  1:1, so accented names pass through untouched. Do not "fix" it to UTF-8.
echo(Rebuilding rows without the dropped columns - this takes a few seconds
set "PREP_CSV=%CSV%"
set "PREP_WORK=%WORK%"
set "PREP_KEEP=!KEEP!"
"%PSEXE%" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%REBUILDPS%"
if errorlevel 1 (endlocal & set "ERRMSG=Rebuilding %CSV% without the unmapped columns failed - see the console output just above." & goto :jobdie)
call :rowcount "%WORK%" NROW
echo(Prepared input CSV ^(!NROW! rows rebuilt, unmapped columns dropped^)
endlocal
goto :rowguard

:copybody
"%FINDSTR%" /v /l /g:"%HPAT%" "%CSV%" >>"%WORK%"

:rowguard
REM  THE GUARD. Source data rows must equal prepared data rows. A mismatch
REM  used to sail straight through: 100,000 rows in, 65,535 prepared,
REM  COMPLETED reported, and 34,465 rows never sent to Salesforce.
if not exist "%WORK%" (set "ERRMSG=Failed to build input CSV: %WORK%" & goto :jobdie)
call :rowcount "%CSV%"  SRCROWS
call :rowcount "%WORK%" WRKROWS
if "%SRCROWS%"=="%WRKROWS%" goto :rowsok
set "ERRMSG=Row count mismatch - %CSV% has %SRCROWS% data rows but the prepared file has %WRKROWS%. NOTHING was loaded. A 0x1A (Ctrl-Z) byte or other control character in the CSV is the usual cause; do not press Ctrl-C while the file is being prepared."
goto :jobdie
:rowsok
if "%SRCROWS%"=="0" (set "ERRMSG=%CSV% has a header but no data rows - nothing to load." & goto :jobdie)
call :log "Row check OK - %SRCROWS% source data rows, %WRKROWS% prepared: %WORK%"
echo(Row check OK - %SRCROWS% rows in, %WRKROWS% ready to load

REM ---------------- 3) resolve the org alias ---------------------
set "ORGALIAS=%BEANALIAS%"
if not exist "%SECRETS%" goto :usestoredauth
if not defined ORGALIAS call :jsonval "%SECRETS%" org ORGALIAS
if not defined ORGALIAS (set "ERRMSG=org missing from %SECRETS% and no sfdc.orgAlias in the bean" & goto :jobdie)
if defined AUTHOK_%ORGALIAS% (
  call :log "Reusing the token fetched at the start of this run - no re-authentication"
  goto :authdone
)
call :fetchtoken "%SECRETS%" "%ORGALIAS%"
if errorlevel 1 goto :jobdie
goto :authdone

:usestoredauth
if not defined ORGALIAS set "ORGALIAS=%DEFAULTALIAS%"
if not defined ORGALIAS (set "ERRMSG=No credentials file at %SECRETS%, no sfdc.orgAlias in the bean, and DEFAULTALIAS is empty. Refusing to guess which org to write to." & goto :jobdie)
call :log "No credentials file - using the sf CLI's stored auth for alias '%ORGALIAS%'"
:authdone

REM ---------------- 4) run the load ------------------------------
set "SFCMD="
if /i "%OPERATION%"=="insert" set "SFCMD=sf data import bulk"
if /i "%OPERATION%"=="update" set "SFCMD=sf data update bulk"
if /i "%OPERATION%"=="delete" set "SFCMD=sf data delete bulk"
if /i "%OPERATION%"=="upsert" set "SFCMD=sf data upsert bulk"
if not defined SFCMD (set "ERRMSG=Unsupported operation: %OPERATION%" & goto :jobdie)

set "SFEXTRA="
if /i "%OPERATION%"=="insert" set "SFEXTRA=--column-delimiter COMMA"
if /i "%OPERATION%"=="upsert" (
  if not defined EXTID (set "ERRMSG=upsert needs sfdc.externalIdField in the bean" & goto :jobdie)
  set "SFEXTRA=--external-id %EXTID%"
)

del /q "%STATUSDIR%\*success-records*.csv" 2>nul
del /q "%STATUSDIR%\*failed-records*.csv"  2>nul

set "RETRIED="
:runload
call :log "Running: %SFCMD% --sobject %ENTITY% %SFEXTRA%"
echo(
echo(     Loading into Salesforce. THE SCREEN STAYS BLANK UNTIL THIS
echo(     FINISHES - that is normal. Waiting up to %WAITMIN% minutes.
echo(     DO NOT PRESS Ctrl-C - the bulk job keeps running in the org, but
echo(     this script loses track of it and cannot collect the results.
echo(     Progress is visible in Setup ^> Bulk Data Load Jobs.
echo(
call %SFCMD% --sobject %ENTITY% --file "%WORK%" --target-org %ORGALIAS% --wait %WAITMIN% --json %SFEXTRA% >"%RAWJSON%" 2>&1 <nul

REM  One-shot retry if the session expired mid-run. Safe: INVALID_SESSION_ID
REM  is the API rejecting the request outright, so no job was created and no
REM  row was touched.
if defined RETRIED goto :loadran
if not exist "%SECRETS%" goto :loadran
"%FINDSTR%" /l /c:"INVALID_SESSION_ID" "%RAWJSON%" >nul || goto :loadran
call :log "Session had expired mid-run - fetching a replacement token and retrying once"
call :fetchtoken "%SECRETS%" "%ORGALIAS%"
if errorlevel 1 goto :jobdie
set "RETRIED=1"
goto :runload
:loadran

REM  Job id: find the first "750..." then cut at the closing quote. Do NOT
REM  take a fixed number of characters.
set "JOBID="
"%FINDSTR%" /l /c:"750" "%RAWJSON%" >"%JTMP%" 2>nul
set "JLINE="
set /p JLINE=<"%JTMP%"
if not defined JLINE goto :jobidcheck
set "JTAIL=%JLINE:*750=%"
>"%JTMP%" echo(750%JTAIL%
for /f tokens^=1^ delims^=^" %%A in ('type "%JTMP%"') do if not defined JOBID set "JOBID=%%A"
:jobidcheck
if defined JOBID if "%JOBID:~14,1%"=="" (
  call :log "WARNING: scraped job id looks malformed: %JOBID%"
  set "JOBID="
)
if not defined JOBID (set "ERRMSG=sf load: no job id found. See %RAWJSON% - if it mentions an expired or invalid session, check the credentials file." & goto :jobdie)
call :log "Job Id: %JOBID%"

REM ---------------- 5) fetch + route the result files ------------
pushd "%STATUSDIR%"
call sf data bulk results --job-id %JOBID% --target-org %ORGALIAS% >nul 2>&1 <nul
popd

call :stamp
set "SUCCDEST=%STATUSDIR%\success%STAMP%.csv"
set "FAILDEST=%STATUSDIR%\error%STAMP%.csv"

set "SUCCSRC="
for /f "delims=" %%F in ('dir /b /a-d /o-d "%STATUSDIR%\*success-records*.csv" 2^>nul') do if not defined SUCCSRC set "SUCCSRC=%%F"
set "FAILSRC="
for /f "delims=" %%F in ('dir /b /a-d /o-d "%STATUSDIR%\*failed-records*.csv" 2^>nul')  do if not defined FAILSRC set "FAILSRC=%%F"

set "SUCCCOUNT=0"
set "FAILCOUNT=0"
set "NORESULTS="
if not defined SUCCSRC if not defined FAILSRC set "NORESULTS=1"
if defined NORESULTS call :log "WARNING: no result files for job %JOBID% after waiting %WAITMIN% min - it is probably STILL RUNNING, not failed. Do NOT re-run. Check: sf data upsert resume --job-id %JOBID% --target-org %ORGALIAS%"
if defined SUCCSRC (
  move /y "%STATUSDIR%\%SUCCSRC%" "%SUCCDEST%" >nul
  call :rowcount "%SUCCDEST%" SUCCCOUNT
) else (
  break>"%SUCCDEST%"
)
if defined FAILSRC (
  move /y "%STATUSDIR%\%FAILSRC%" "%FAILDEST%" >nul
  call :rowcount "%FAILDEST%" FAILCOUNT
) else (
  break>"%FAILDEST%"
)
REM  No "->" and no parentheses in this message. call re-parses its own
REM  argument line, and ">" survives that second pass as a REDIRECTION even
REM  inside quotes, while "(" is read as the start of a block when the path
REM  contains a space. Commas only.
call :log "Results in %STATUSDIR% - success=%SUCCCOUNT% rows, error=%FAILCOUNT% rows"

if defined NORESULTS goto :skipaccount
set /a ACCOUNTED=%SUCCCOUNT%+%FAILCOUNT%
if not "%ACCOUNTED%"=="%WRKROWS%" call :log "WARNING: %WRKROWS% rows were submitted but only %ACCOUNTED% appear in the result files, success=%SUCCCOUNT% error=%FAILCOUNT%. Verify job %JOBID% in the org before trusting these numbers."
:skipaccount

REM ---------------- 6) archive the source CSV --------------------
REM  MOVED, exactly as the old script's "move" line did, into this run's
REM  Archive_<stamp> folder.
if not exist "%ARCHSUB%" md "%ARCHSUB%" 2>nul
if not exist "%ARCHSUB%" (set "ERRMSG=Could not create archive folder '%ARCHSUB%'. Job %JOBID% HAS already run - check it with: sf data bulk results --job-id %JOBID% --target-org %ORGALIAS%" & goto :jobdie)
for %%P in ("%CSV%") do move /y "%CSV%" "%ARCHSUB%\%%~nxP" >nul
del /q "%WORK%"   2>nul
del /q "%HPAT%"   2>nul
del /q "%HDRNEW%" 2>nul
del /q "%QPAT%"   2>nul

if defined NORESULTS (
  call :log "UNCONFIRMED - job %JOBID% ran but no result files were returned. Source archived to %ARCHSUB%"
  endlocal & exit /b 2
)
if "%FAILCOUNT%"=="0" (
  call :log "SUCCESS - %SUCCCOUNT% loaded, 0 failed, out of %WRKROWS% submitted. Source archived to %ARCHSUB%"
  endlocal & exit /b 0
)
call :log "COMPLETED - %SUCCCOUNT% loaded, %FAILCOUNT% failed, out of %WRKROWS% submitted. Source archived to %ARCHSUB%; results in %STATUSDIR%"
endlocal & exit /b 2

:jobdie
call :log "ERROR: %ERRMSG%"
endlocal & exit /b 1

REM ===============================================================
REM  :runjobextract  <BeanId>  - run the bean's SOQL through the Bulk API
REM  and write the result to its dataAccess.name. Used by the test bean.
REM  Returns 0 = rows written, 3 = ran clean but 0 rows, 1 = hard error.
REM ===============================================================
:runjobextract
setlocal
set "PROCESS=%~1"
set "LOG=%LOGDIR%\%PROCESS%.log"
set "SECRETS=%CCDIR%\Config\clientcreds.json"
set "RAWERR=%LOGDIR%\%PROCESS%-raw.txt"
set "JTMP=%LOGDIR%\%PROCESS%-jsonval.tmp"
set "QFILE=%LOGDIR%\%PROCESS%.soql"
break>"%LOG%"
call :log "Process=%PROCESS%"

call :readbean "%PROCESS%"
if not defined ENTITY (set "ERRMSG=sfdc.entity missing for bean '%PROCESS%'" & goto :exdie)
if not defined CSV    (set "ERRMSG=dataAccess.name missing for bean '%PROCESS%'" & goto :exdie)
call :soqlfile "%PROCESS%" "%QFILE%"
for %%Z in ("%QFILE%") do if %%~zZ lss 10 (set "ERRMSG=sfdc.extractionSOQL missing or unreadable for bean '%PROCESS%'" & goto :exdie)

set "ORGALIAS=%BEANALIAS%"
if not defined ORGALIAS if exist "%SECRETS%" call :jsonval "%SECRETS%" org ORGALIAS
if not defined ORGALIAS set "ORGALIAS=%DEFAULTALIAS%"
if not defined ORGALIAS (set "ERRMSG=No org alias for bean '%PROCESS%'" & goto :exdie)

for %%P in ("%CSV%") do if not exist "%%~dpP" md "%%~dpP" 2>nul
echo(
echo(     Querying Salesforce. THE SCREEN STAYS BLANK UNTIL THIS FINISHES -
echo(     that is normal. Waiting up to %WAITMIN% minutes.
echo(     DO NOT PRESS Ctrl-C - it aborts the download and wastes the run.
echo(
call sf data query --file "%QFILE%" --target-org %ORGALIAS% --bulk --wait %WAITMIN% --result-format csv >"%CSV%" 2>"%RAWERR%" <nul
if errorlevel 1 (set "ERRMSG=sf data query failed for %PROCESS% - see %RAWERR%" & goto :exdie)
if not exist "%CSV%" (set "ERRMSG=%PROCESS%: sf reported success but wrote no file at %CSV%" & goto :exdie)
for %%Z in ("%CSV%") do if %%~zZ equ 0 (set "ERRMSG=%PROCESS%: sf reported success but %CSV% is empty - not even a header row. See %RAWERR%." & goto :exdie)
call :rowcount "%CSV%" EXROWS
call :log "%PROCESS% wrote %EXROWS% data rows to %CSV%"
echo(     %EXROWS% rows written
if "%EXROWS%"=="0" (endlocal & exit /b 3)
endlocal & exit /b 0

:exdie
call :log "ERROR: %ERRMSG%"
endlocal & exit /b 1

REM ===============================================================
REM  :readbean  <BeanId>  - pull this bean's entries into
REM  ENTITY OPERATION EXTID SDL CSV STATUSDIR CREDFILE BEANALIAS
REM  Splitting each line on the quote character hands us the attribute
REM  values directly, so raw XML never lands in a variable.
REM  sfdc.extractionSOQL is NOT read here - :soqlfile handles it separately.
REM ===============================================================
:readbean
set "WANT=%~1"
setlocal EnableDelayedExpansion
set "INBEAN=0"
set "E=" & set "O=" & set "X=" & set "S=" & set "C=" & set "S2=" & set "R2=" & set "R3="
for /f tokens^=1^,2^,4^ delims^=^" %%A in ('call "%FINDSTR%" /i /l /c:"<bean" /c:"<entry" "%BEAN%"') do (
  set "TAG=%%A"
  if not "!TAG:<bean=!"=="!TAG!" (
    if /i "%%B"=="%WANT%" (set "INBEAN=1") else (if "!INBEAN!"=="1" set "INBEAN=2")
  ) else (
    if "!INBEAN!"=="1" (
      set "K=%%B"
      set "V=%%C"
      if "!V!"=="/>" set "V="
      if "!V!"=="/" set "V="
      if /i "!K!"=="sfdc.entity"                 set "E=!V!"
      if /i "!K!"=="process.operation"           set "O=!V!"
      if /i "!K!"=="sfdc.externalIdField"        set "X=!V!"
      if /i "!K!"=="process.mappingFile"         set "S=!V!"
      if /i "!K!"=="dataAccess.name"             set "C=!V!"
      if /i "!K!"=="process.statusOutputDirectory" set "S2=!V!"
      if /i "!K!"=="sfdc.credentialsFile"        set "R2=!V!"
      if /i "!K!"=="process.credentialsFile"     set "R2=!V!"
      if /i "!K!"=="sfdc.orgAlias"               set "R3=!V!"
      if /i "!K!"=="process.orgAlias"            set "R3=!V!"
    )
  )
)
endlocal & (set "ENTITY=%E%" & set "OPERATION=%O%" & set "EXTID=%X%" & set "SDL=%S%" & set "CSV=%C%" & set "STATUSDIR=%S2%" & set "CREDFILE=%R2%" & set "BEANALIAS=%R3%")
exit /b 0

REM ===============================================================
REM  :soqlfile  <BeanId> <outFile>  - write one bean's sfdc.extractionSOQL
REM  to a file with the XML entities decoded, by parsing the bean as XML.
REM  The query text is passed to PowerShell through the ENVIRONMENT, never
REM  through a cmd variable and never through CALL: delayed expansion eats a
REM  lone "!" and CALL re-parses "(" as the start of a block.
REM  KEEP EVERY LINE IN THIS FILE SHORT - see :writesoqlhelper.
REM ===============================================================
:soqlfile
setlocal DisableDelayedExpansion
set "SQ_BEAN=%BEAN%"
set "SQ_ID=%~1"
set "SQ_DEST=%~2"
break>"%SQ_DEST%"
"%PSEXE%" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%SOQLPS%" <nul
endlocal & exit /b 0

REM ===============================================================
REM  :writesoqlhelper  - write the two PowerShell helpers this script runs.
REM  Generated rather than inlined as -Command strings because a very long
REM  batch line made cmd fail to find nearby LABELS - the same file reported
REM  "cannot find the batch label specified" depending on where lines fell.
REM  Keep the generated lines short. The "^(" and "^)" are cmd escapes for
REM  echo; the files they produce are ordinary PowerShell, readable in Log\.
REM ===============================================================
:writesoqlhelper
set "SOQLPS=%LOGDIR%\readsoql.ps1"
break>"%SOQLPS%"
>>"%SOQLPS%" echo($ErrorActionPreference = 'Stop'
>>"%SOQLPS%" echo($doc = New-Object System.Xml.XmlDocument
>>"%SOQLPS%" echo($doc.XmlResolver = $null
>>"%SOQLPS%" echo($doc.LoadXml^([IO.File]::ReadAllText^($env:SQ_BEAN^)^)
>>"%SOQLPS%" echo($want = $env:SQ_ID
>>"%SOQLPS%" echo($soql = $null
>>"%SOQLPS%" echo(foreach ^($bean in $doc.GetElementsByTagName^('bean'^)^) {
>>"%SOQLPS%" echo(  if ^($bean.GetAttribute^('id'^) -ne $want^) { continue }
>>"%SOQLPS%" echo(  foreach ^($e in $bean.GetElementsByTagName^('entry'^)^) {
>>"%SOQLPS%" echo(    if ^($e.GetAttribute^('key'^) -eq 'sfdc.extractionSOQL'^) {
>>"%SOQLPS%" echo(      $soql = $e.GetAttribute^('value'^)
>>"%SOQLPS%" echo(    }
>>"%SOQLPS%" echo(  }
>>"%SOQLPS%" echo(}
>>"%SOQLPS%" echo(if ^($null -eq $soql^) { exit 2 }
>>"%SOQLPS%" echo(if ^($soql.Trim^(^).Length -eq 0^) { exit 3 }
>>"%SOQLPS%" echo($enc = New-Object -TypeName Text.UTF8Encoding -ArgumentList $false
>>"%SOQLPS%" echo([IO.File]::WriteAllText^($env:SQ_DEST, $soql, $enc^)
>>"%SOQLPS%" echo(exit 0
if not exist "%SOQLPS%" (set "ERRMSG=Could not write the query reader to %SOQLPS%" & exit /b 1)

REM  The column-dropping rebuild. Reads PREP_CSV, writes PREP_WORK keeping
REM  only the 1-based column numbers in PREP_KEEP. Latin-1 both ways so
REM  bytes pass through untouched.
set "REBUILDPS=%LOGDIR%\rebuildcsv.ps1"
break>"%REBUILDPS%"
>>"%REBUILDPS%" echo($ErrorActionPreference = 'Stop'
>>"%REBUILDPS%" echo($enc = [Text.Encoding]::GetEncoding^(28591^)
>>"%REBUILDPS%" echo($keep = @^(^)
>>"%REBUILDPS%" echo(foreach ^($k in $env:PREP_KEEP.Split^(' '^)^) {
>>"%REBUILDPS%" echo(  if ^($k.Length -gt 0^) { $keep += ^([int]$k - 1^) }
>>"%REBUILDPS%" echo(}
>>"%REBUILDPS%" echo($r = New-Object IO.StreamReader^($env:PREP_CSV, $enc^)
>>"%REBUILDPS%" echo($w = New-Object IO.StreamWriter^($env:PREP_WORK, $true, $enc^)
>>"%REBUILDPS%" echo($null = $r.ReadLine^(^)
>>"%REBUILDPS%" echo(while ^($null -ne ^($l = $r.ReadLine^(^)^)^) {
>>"%REBUILDPS%" echo(  if ^($l.Length -eq 0^) { continue }
>>"%REBUILDPS%" echo(  $f = $l.Split^(','^)
>>"%REBUILDPS%" echo(  $o = New-Object Text.StringBuilder
>>"%REBUILDPS%" echo(  foreach ^($i in $keep^) {
>>"%REBUILDPS%" echo(    if ^($o.Length -gt 0^) { $null = $o.Append^(','^) }
>>"%REBUILDPS%" echo(    if ^($i -lt $f.Length^) { $null = $o.Append^($f[$i]^) }
>>"%REBUILDPS%" echo(  }
>>"%REBUILDPS%" echo(  $w.WriteLine^($o.ToString^(^)^)
>>"%REBUILDPS%" echo(}
>>"%REBUILDPS%" echo($w.Close^(^)
>>"%REBUILDPS%" echo($r.Close^(^)
>>"%REBUILDPS%" echo(exit 0
if not exist "%REBUILDPS%" (set "ERRMSG=Could not write the CSV rebuilder to %REBUILDPS%" & exit /b 1)
exit /b 0

REM ===============================================================
REM  :ensureauth  <BeanId>  - guarantee a usable token for this bean's org
REM  alias, fetching one ONLY if this run has not already done so.
REM  Deliberately has NO setlocal: it sets AUTHOK_<alias> and that marker has
REM  to survive into the parent scope, which is the whole point.
REM ===============================================================
:ensureauth
call :readbean "%~1"
set "EA_SECRETS=%CCDIR%\Config\clientcreds.json"
if not defined CREDFILE goto :ea_haveconf
set "EA_ABS=0"
if "%CREDFILE:~1,1%"==":"  set "EA_ABS=1"
if "%CREDFILE:~0,2%"=="\\" set "EA_ABS=1"
if "%EA_ABS%"=="0" (set "EA_SECRETS=%ROOT%\%CREDFILE%") else (set "EA_SECRETS=%CREDFILE%")
if not exist "%EA_SECRETS%" (set "ERRMSG=Credentials file not found: %EA_SECRETS% (named by bean '%~1')" & exit /b 1)
:ea_haveconf
if not exist "%EA_SECRETS%" (
  echo(  --  %~1  no credentials file, will use the sf CLI stored auth
  exit /b 0
)
set "EA_ALIAS=%BEANALIAS%"
if not defined EA_ALIAS call :jsonval "%EA_SECRETS%" org EA_ALIAS
if not defined EA_ALIAS (set "ERRMSG=No org alias for bean '%~1' - add an 'org' key to %EA_SECRETS%" & exit /b 1)
if defined AUTHOK_%EA_ALIAS% exit /b 0
call :log "Fetching ONE client-credentials token for alias '%EA_ALIAS%'"
call :fetchtoken "%EA_SECRETS%" "%EA_ALIAS%"
if errorlevel 1 exit /b 1
set "AUTHOK_%EA_ALIAS%=1"
echo(  Authenticated once for %EA_ALIAS%
call :log "Logged in as alias '%EA_ALIAS%'"
exit /b 0

REM ===============================================================
REM  :fetchtoken  <credentialsFile> <orgAlias>  - exactly one OAuth
REM  client-credentials round trip against the External Client App, then
REM  hand the token to the sf CLI. -p persists it under the alias.
REM
REM  THIS IS THE WHOLE OF THE NEW LOGIN. No username, no password, no key
REM  file anywhere in this script or in the bean. What the org needs: an
REM  External Client App with the client-credentials flow enabled and a
REM  run-as user that can upsert CaseStaging__c.
REM
REM  The response JSON is deleted the moment it is read - it holds a live
REM  bearer token in clear text.
REM ===============================================================
:fetchtoken
setlocal
set "FT_SECRETS=%~1"
set "FT_ALIAS=%~2"
set "FT_TOK=%LOGDIR%\token.json"
set "JTMP=%LOGDIR%\fetchtoken-jsonval.tmp"
call :jsonval "%FT_SECRETS%" domain       FT_DOMAIN
call :jsonval "%FT_SECRETS%" clientId     FT_CLIENTID
call :jsonval "%FT_SECRETS%" clientSecret FT_SECRET
if not defined FT_DOMAIN   (set "FT_ERR=domain missing from %~1"       & goto :ft_fail)
if not defined FT_CLIENTID (set "FT_ERR=clientId missing from %~1"     & goto :ft_fail)
if not defined FT_SECRET   (set "FT_ERR=clientSecret missing from %~1" & goto :ft_fail)

del /q "%FT_TOK%" 2>nul
call "%CURL%" -s -X POST "%FT_DOMAIN%/services/oauth2/token" ^
  -d "grant_type=client_credentials" ^
  -d "client_id=%FT_CLIENTID%" ^
  -d "client_secret=%FT_SECRET%" -o "%FT_TOK%" <nul
if errorlevel 1 (set "FT_ERR=curl failed calling the token endpoint - check the domain in %~1 and that this box can reach it" & goto :ft_fail)
"%FINDSTR%" /l /c:"access_token" "%FT_TOK%" >nul || (set "FT_ERR=Token request failed - the response carried no access_token. Check clientId/clientSecret in %~1, and that the External Client App has the client-credentials flow enabled with a run-as user." & goto :ft_fail)
call :jsonval "%FT_TOK%" access_token FT_TOKEN
call :jsonval "%FT_TOK%" instance_url FT_INSTANCE
if not defined FT_TOKEN (set "FT_ERR=Could not read access_token from the token response" & goto :ft_fail)
if not defined FT_INSTANCE set "FT_INSTANCE=%FT_DOMAIN%"

set "SF_ACCESS_TOKEN=%FT_TOKEN%"
call sf org login access-token -r "%FT_INSTANCE%" -a %FT_ALIAS% -p >nul <nul
if errorlevel 1 (set "FT_ERR=sf org login access-token failed for alias %FT_ALIAS%" & goto :ft_fail)

:ft_done
del /q "%FT_TOK%" 2>nul
del /q "%JTMP%"   2>nul
REM  Plain exit /b, no endlocal: the implicit one drops SF_ACCESS_TOKEN.
exit /b 0

:ft_fail
del /q "%FT_TOK%" 2>nul
del /q "%JTMP%"   2>nul
endlocal & set "ERRMSG=%FT_ERR%" & exit /b 1


REM ===============================================================
REM  shared subroutines
REM ===============================================================

:log
echo(%DATE% %TIME%  %~1
>>"%LOG%" echo(%DATE% %TIME%  %~1
exit /b 0

REM  :split  - LINE -> F1..Fn plus NF. Handles empty fields, which plain
REM  "for /f tokens=" cannot. Caller must have delayed expansion ON.
:split
set "NF=0"
set "R=#!LINE:,=,#!"
:split_next
if not defined R exit /b 0
set "T=" & set "NEXT="
for /f "tokens=1* delims=," %%A in ("!R!") do (set "T=%%A" & set "NEXT=%%B")
set /a NF+=1
set "F!NF!=!T:~1!"
set "R=!NEXT!"
goto :split_next

REM  :jsonval  <file> <key> <outvar>  - pull a string value out of JSON.
REM  Values must not contain spaces (true for domain / ids / secrets / urls).
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

REM  NOTE ON THE "for /f ('call \"%FINDSTR%\" ...')" LINE IN :readbean.
REM  The "call" is load-bearing. for /f runs its command through cmd /c, and
REM  cmd /c strips the first and last quote of a string that BEGINS with a
REM  quote - the command then comes apart and no beans are read at all.
REM  Starting the string with "call" means nothing is stripped.

REM  :normarg  <outvar> <raw>  - canonical form of one argument: no path in
REM  front, no leading slashes or dashes. MSYS turns "/q" into "Q:/" before
REM  cmd ever sees it.
:normarg
set "%~1="
set "NA=%~2"
if not defined NA exit /b 0
if "%NA:~1%"==":/" (set "%~1=%NA:~0,1%" & exit /b 0)
if "%NA:~1%"==":\" (set "%~1=%NA:~0,1%" & exit /b 0)
if "%NA:~1%"==":" (set "%~1=%NA:~0,1%" & exit /b 0)
for %%P in ("%NA:/=\%") do set "NA=%%~nxP"
:normarg_strip
if "%NA:~0,1%"=="-" (set "NA=%NA:~1%" & goto :normarg_strip)
if "%NA:~0,1%"=="/" (set "NA=%NA:~1%" & goto :normarg_strip)
set "%~1=%NA%"
exit /b 0

REM  :winpath  <varname>  - rewrite an MSYS/Cygwin path as a Windows one.
REM  "/d/NLG" and "/cygdrive/d/NLG" both become "D:\NLG"; a Windows or UNC
REM  path is left exactly as it is.
:winpath
call set "WP=%%%~1%%"
if not defined WP exit /b 0
if not "%WP:~0,1%"=="/" (set "WP=" & exit /b 0)
setlocal EnableDelayedExpansion
if /i "!WP:~0,10!"=="/cygdrive/" set "WP=!WP:~9!"
if "!WP:~0,1!"=="/" if "!WP:~2,1!"=="/" set "WP=!WP:~1,1!:!WP:~2!"
set "WP=!WP:/=\!"
endlocal & set "%~1=%WP%"
set "WP="
exit /b 0

REM  :rowcount  <csv> <outvar>  - data rows, i.e. lines minus the header.
REM  Uses CNT, not RC - RC is the caller's exit code and must not be touched.
:rowcount
set "%~2=0"
set "CNT=0"
for /f %%N in ('type "%~1" 2^>nul ^| "%FIND%" /c /v ""') do set "CNT=%%N"
if %CNT% gtr 0 set /a CNT-=1
set "%~2=%CNT%"
exit /b 0

REM  :stamp  - STAMP=MMddyyHHmmssfff for result files, plus the pieces the
REM  archive folder name needs: A_MMDD, A_YYYY, the hour space-padded, and
REM  A_MI, the minute on its own.
REM  EVERYTHING HERE IS STATEMENT LEVEL ON PURPOSE. Put the fallback inside
REM  an if/else block and %VAR% expands when the block is PARSED - before the
REM  SET that fills it runs - which produced folder names like
REM  "Archive_0807 2026~0,2~3,2T:~6,2" on a machine without wmic.
:stamp
set "LDT="
for /f "tokens=2 delims==" %%I in ('wmic os get localdatetime /value 2^>nul') do set "LDT=%%I"
if not defined LDT goto :stamp_fallback
set "A_YYYY=%LDT:~0,4%"
set "A_MMDD=%LDT:~4,4%"
set "A_HH=%LDT:~8,2%"
set "A_MI=%LDT:~10,2%"
set "STAMP=%LDT:~4,2%%LDT:~6,2%%LDT:~2,2%%LDT:~8,2%%LDT:~10,2%%LDT:~12,2%%LDT:~15,3%"
goto :stamp_check

:stamp_fallback
REM  wmic is deprecated and absent on newer Windows builds.
set "TT=%TIME: =0%"
set "A_MMDD="
set "A_YYYY="
for /f "tokens=1-4 delims=/.- " %%a in ("%DATE%") do call :stamp_date "%%a" "%%b" "%%c" "%%d"
set "A_HH=%TT:~0,2%"
set "A_MI=%TT:~3,2%"
set "STAMP=%A_MMDD%%A_YYYY:~2,2%%TT:~0,2%%TT:~3,2%%TT:~6,2%%TT:~9,2%0"
goto :stamp_check

:stamp_date
REM  %DATE% is "MM/DD/YYYY" or "Ddd MM/DD/YYYY" depending on locale
if "%~4"=="" (set "A_MMDD=%~1%~2" & set "A_YYYY=%~3") else (set "A_MMDD=%~2%~3" & set "A_YYYY=%~4")
exit /b 0

:stamp_check
REM  Never let a malformed stamp reach a filename - digits only.
echo %STAMP%|"%FINDSTR%" /r /c:"^[0-9][0-9]*$" >nul
if errorlevel 1 (
  call :log "WARNING: could not build a timestamp - using a fixed name for this run's files"
  set "STAMP=00000000000000"
  set "A_MMDD=0000"
  set "A_YYYY=0000"
  set "A_HH=00"
  set "A_MI=00"
)
REM  The hour is space-padded, not zero-padded, because that is what
REM  "%Time:~0,2%" gave the old script: midnight produced " 0" and the folder
REM  came out "Archive_09042026 032". Keep it, so this run's folder sorts
REM  next to the ones already in Archive.
if "%A_HH:~0,1%"=="0" (set "A_HHSP= %A_HH:~1%") else (set "A_HHSP=%A_HH%")
exit /b 0
