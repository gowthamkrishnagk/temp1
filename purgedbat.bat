@echo off
setlocal EnableExtensions DisableDelayedExpansion
REM ===============================================================
REM  purgedbat.bat - AUTOMATED PURGER.  Case and Task retention purge.
REM
REM  Replaces the old eight-line "call process" script. That one logged in
REM  with sfdc.username / sfdc.password / process.encryptionKeyFile out of
REM  the bean, and that login is being retired. This one authenticates as an
REM  EXTERNAL CLIENT APP over OAuth client credentials, and the credentials
REM  live in ONE file: Config\clientcreds.json.
REM
REM  Reads purgedbean.bean, gets a token with curl.exe, runs every query and
REM  every delete through the sf CLI. Self-contained - no other script is
REM  called, and Data Loader is no longer involved at all.
REM ===============================================================
REM  v1  2026-09-09   sandbox / UAT
REM ===============================================================
REM
REM  MOVING BETWEEN ORGS - ONE FILE CHANGES
REM  Config\clientcreds.json only: domain, clientId, clientSecret, org.
REM  The "org" value IS the alias every sf command in this script uses.
REM    - the BEAN does not change. It carries no org information at all.
REM    - the SDLs do not change.
REM    - the folder structure does not change.
REM  So a sandbox run is: point clientcreds.json at the sandbox, run it.
REM  Same rule, same file, same shape as the load script.
REM
REM  BUT RE-VERIFY THE ORG-SPECIFIC ASSUMPTIONS. Everything the bean asserts
REM  about schema is per-org. Before the first run in a new org, check there:
REM    1. every field named in every sfdc.extractionSOQL still exists on its
REM       object. The Case backup queries name over 250 fields each and the
REM       Bulk API reports only the FIRST bad name per run, so one missing
REM       field costs one run per missing field if you fix them one at a time.
REM       Check them all at once:
REM         sf sobject describe -s Case -o <alias> --json
REM    2. the three Case RecordType.Name values - 'Buying Customer',
REM       'Selling Customer', 'Conservation Case'. A renamed record type does
REM       NOT error. The backup query silently returns 0 rows while
REM       csvExportIdCases, which filters on the same three names, also
REM       returns 0, so the run reports a clean "nothing to purge" for an
REM       object that is full of rows.
REM    3. that the deleting user can actually delete Case and Task. The
REM       external client app runs as a named user; no delete permission
REM       means every row comes back in the error CSV.
REM
REM  THIS SCRIPT DELETES ROWS. WHAT PROTECTS THEM:
REM    1. Backup before delete, always. A set's delete is SKIPPED if any of
REM       its backup extracts failed - all three Case backups gate the Case
REM       delete, because csvExportIdCases collects ids across all three
REM       record types and a delete cannot be told to spare the one whose
REM       backup did not write.
REM    2. The delete only ever reads what THIS run extracted. Pre-flight
REM       proves each delete bean's dataAccess.name is the same path its own
REM       id extract writes, and the delete MOVES that CSV into the archive
REM       folder as it consumes it - so a stale id file cannot be deleted
REM       from twice.
REM    3. 0 rows extracted means the delete is skipped, not run on an empty
REM       or missing file.
REM    4. An extract that reports success but writes nothing, or writes a
REM       file with no header at all, is a hard error - not "0 rows".
REM
REM  "CreatedDate < LAST_N_MONTHS:12" AND WHY :soqlfile USES POWERSHELL.
REM  In the bean that "<" is written "&lt;", as XML requires. Handed to the
REM  CLI raw it is not a comparison operator, it is five characters, and the
REM  query fails. :soqlfile therefore parses the bean as XML, which decodes
REM  the entity properly, and writes the query to a file.
REM  DO NOT "SIMPLIFY" THIS BY REWRITING THE QUERIES TO USE "!=" the way the
REM  load bean file's purge queries do. LAST_N_MONTHS:12 ENDS on the last day
REM  of the previous month, so "!= LAST_N_MONTHS:12" also matches everything
REM  created THIS MONTH - and these queries feed a delete. "<" means older
REM  than the window, which is what the retention rule says.
REM  It is also why the query never passes through a cmd variable or through
REM  CALL: delayed expansion eats a lone "!" and CALL re-parses "(" as the
REM  start of a block, and four of these queries contain "(".
REM
REM  FOLDERS - THE SERVER'S OWN, UNCHANGED. Source Data sits DIRECTLY under
REM  NLG. It is NOT under Automated Purger, and it must not be moved there:
REM    D:\NLG\Source Data\Extracted Cases\      the Case extracts land here
REM    D:\NLG\Source Data\Extracted Tasks\      the Task extracts land here
REM    D:\NLG\Automated Purger\Config\          clientcreds.json, the bean
REM    D:\NLG\Automated Purger\Config\SDL\      the delete mapping files
REM    D:\NLG\Automated Purger\Load Result\Case Deletion\  success + error CSVs
REM    D:\NLG\Automated Purger\Load Result\Task Deletion\          "
REM    D:\NLG\Automated Purger\Log\             one log per bean, plus the run log
REM    D:\NLG\Automated Purger\Archive\Archive_AutoPurgedExtracts_<MMDDYYYY HMM>\
REM
REM  The two Source Data paths and the Load Result paths are ABSOLUTE IN THE
REM  BEAN, so they do not follow ROOT. Only Config, Load Result, Log and
REM  Archive are derived from it.
REM
REM  NOTHING IS EVER PUT IN EITHER FOLDER BY HAND. Every CSV this script
REM  deletes from is WRITTEN by an extract minutes earlier in the same run,
REM  into Source Data, and moved out into Archive afterwards.
REM  The Load Result folders are the ones named by process.outputSuccess and
REM  process.outputError in the bean - only their FOLDER is taken from the
REM  bean; the run's timestamp is appended to the filename so one run cannot
REM  overwrite another's results the way Data Loader used to.
REM
REM  SAVE THIS FILE WITH WINDOWS (CRLF) LINE ENDINGS. NOT NEGOTIABLE.
REM  It was once saved with Unix (LF) endings and cmd did not report an
REM  error - it MIS-SEEKED. "call :log" returned to the wrong byte offset,
REM  control resumed part-way down :runjob, and an extract that had just
REM  succeeded logged a phantom "Failed to build input CSV". Which call site
REM  broke moved every time an unrelated comment was edited, because what
REM  actually decides it is where each line lands in the file. Converting to
REM  CRLF fixed every symptom at once, with no other change.
REM  Nothing was deleted by it - that was checked with canary files - but a
REM  script that mis-seeks is a script that can skip a gate, and every gate
REM  in here is what stands between a failed backup and a delete.
REM  Editors that do this silently: VS Code with files.eol set to \n, git
REM  with core.autocrlf=input, and anything that writes the file from a
REM  Unix-side tool. To check:  file purgedbat.bat   or in PowerShell count
REM  the CR bytes - there must be one for every line.
REM
REM  Usage:  purgedbat.bat
REM             both sets in order, pauses at the end.
REM          purgedbat.bat /q
REM             same, no pause - for Task Scheduler.
REM          purgedbat.bat csvExportAllTask
REM             one named bean only, no chaining. Use this to re-run a single
REM             backup, id extract or delete after fixing an error CSV.
REM             A delete run this way reads whatever id CSV is on disk - see
REM             :purgeonedelete before doing it.
REM
REM  Exit codes: 0 all clean, 2 completed with failed rows, 1 a set was
REM  stopped or a job hard-errored.
REM ===============================================================


REM ---------------- configuration --------------------------------
REM  Printed on screen and to the log at the top of every run, so the build
REM  actually executing is never in doubt.
set "VERSION=v1 2026-09-09  sandbox"

REM  THESE ARE THE SERVER'S OWN FOLDERS. DO NOT REARRANGE THEM.
REM  The layout is NOT one tidy tree, and that is deliberate - it is what the
REM  old script did and what is on disk now:
REM
REM    D:\NLG\Source Data\Extracted Cases\      the extracts are written here
REM    D:\NLG\Source Data\Extracted Tasks\      and read back from here
REM    D:\NLG\Automated Purger\Config\          bean, clientcreds.json
REM    D:\NLG\Automated Purger\Config\SDL\      the delete mapping files
REM    D:\NLG\Automated Purger\Load Result\     success and error CSVs
REM    D:\NLG\Automated Purger\Archive\         consumed CSVs land here
REM    D:\NLG\Automated Purger\Log\             logs
REM
REM  SOURCE DATA SITS DIRECTLY UNDER NLG, NOT UNDER AUTOMATED PURGER. Nothing
REM  is ever put in either folder by hand: every CSV a delete reads was
REM  written by an extract minutes earlier in the same run, into Source Data,
REM  and is moved out into Archive as the delete consumes it.
REM  The bean carries the two Source Data paths and the Load Result paths as
REM  absolute paths of its own. They are rebased onto ROOT at run time - see
REM  :rebase - so a copy of this tree on another drive works without editing
REM  the bean. On the server, where ROOT is D:\NLG already, that rebase is a
REM  no-op and the paths are used exactly as written.
set "SELFDIR=%~dp0"
set "ROOT=D:\NLG"
REM  FIND THE ROOT FROM THIS SCRIPT'S OWN LOCATION FIRST.
REM  The script lives inside the tree - typically ...\NLG\Automated Purger\
REM  Config\ - so walking up from here to the folder called NLG finds the
REM  install on whatever drive it actually sits on. That is what makes a
REM  sandbox copy on C: work with no edit and no environment variable, which
REM  is exactly the case that produced "The device is not ready" on a laptop
REM  with no D: drive. If the script is moved out of the tree, nothing is
REM  found and the D:\NLG default above stands.
call :rootfromself
if defined NLG_ROOT set "ROOT=%NLG_ROOT%"
if defined NLG_ROOT call :winpath ROOT
REM  NLG_ROOT exists to test this somewhere other than the server - a sandbox
REM  copy on C:, say. From a Unix-style prompt it is natural to export it as
REM  "/d/NLG" or "/cygdrive/d/NLG"; cmd cannot use either, so both are folded
REM  to "D:\NLG" here. A normal Windows path and a UNC path are returned
REM  untouched. If you set it, remember the bean's own absolute paths do not
REM  move with it - edit those too, or the extracts still write to D:.

set "PURGEDIR=%ROOT%\Automated Purger"
set "CONFIGDIR=%PURGEDIR%\Config"

REM  THE BEAN FILE IS FOUND, NOT ASSUMED.
REM  It has been called purgedbean.bean, Process-Config.xml and
REM  process-conf.xml at different points, and a run that dies with "Bean not
REM  found" because somebody renamed it is a waste of everybody's morning.
REM  Order: PURGE_BEAN if set, then the known names, then ANY file in Config
REM  that actually contains this chain's bean ids. The last step is what
REM  makes the name stop mattering.
set "BEAN="
if defined PURGE_BEAN set "BEAN=%PURGE_BEAN%"
if defined BEAN if not exist "%BEAN%" (set "ERRMSG=PURGE_BEAN is set to %BEAN% but there is no file there" & goto :fatal)
if not defined BEAN call :findbean

set "ARCHIVEDIR=%PURGEDIR%\Archive"
set "RESULTDIR=%PURGEDIR%\Load Result"
set "LOGDIR=%PURGEDIR%\Log"
set "CURL=%SystemRoot%\System32\curl.exe"

REM  EVERY WINDOWS TOOL THIS SCRIPT SHELLS OUT TO IS CALLED BY FULL PATH.
REM  Never by bare name. A bare name is resolved through PATH, and PATH is
REM  not ours - a Git for Windows, MSYS or GnuWin32 install puts its own
REM  find.exe ahead of System32, and the Unix find takes completely different
REM  arguments: "find /c /v """ in :rowcount stops being a line count and
REM  becomes a recursive walk of the whole DRIVE, which looks exactly like a
REM  hang at the row check. findstr and powershell are pinned for the same
REM  reason, and curl already was.
REM  The sf CLI is deliberately NOT pinned - it is user-installed, its
REM  location varies, and PATH is the only sane way to find it.
set "FIND=%SystemRoot%\System32\find.exe"
set "FINDSTR=%SystemRoot%\System32\findstr.exe"
set "PSEXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"

REM  WHICH ORG THIS RUN HITS
REM  Normally NOT this setting. The live alias is the "org" key inside
REM  Config\clientcreds.json, and that is the only file you edit to move
REM  between orgs. DEFAULTALIAS is a fallback used ONLY if there is no
REM  credentials file at all. Leave it EMPTY and the script refuses to run
REM  rather than guess which org to delete from.
set "DEFAULTALIAS="

REM  The purge chain, in run order, read as TWO INDEPENDENT SETS:
REM    set 1  Case   PJOB1 PJOB2 PJOB3 backups, PJOB4 ids, PJOB5 delete
REM    set 2  Task   PJOB6 backup,                PJOB7 ids, PJOB8 delete
REM  Within a set: every backup extract, then the id extract, then the delete
REM  that consumes those ids. :purgeset enforces that order and gates every
REM  step. Bean ids must exist in the bean file, and pre-flight says so.
set "PJOB1=csvExportBuyingCustomerCases"
set "PJOB2=csvExportSellingCustomerCases"
set "PJOB3=csvExportConservationCasesCases"
set "PJOB4=csvExportIdCases"
set "PJOB5=csvDeleteCases"
set "PJOB6=csvExportAllTask"
set "PJOB7=csvExportIdTask"
set "PJOB8=csvDeleteTask"

REM  SET 1 HAS THREE BACKUPS AND ONE ID EXTRACT ON PURPOSE, and the three
REM  RecordType.Name values in PJOB1, PJOB2 and PJOB3 must together be
REM  exactly the three PJOB4 filters on. Add a fourth record type to PJOB4
REM  without adding its backup and this script will happily delete rows that
REM  were never backed up - that pairing is the one thing pre-flight cannot
REM  check for you.

REM  Minutes to wait for a bulk job to finish. NOT a Salesforce limit - it is
REM  how long the sf CLI watches before giving up and returning. Exceeding it
REM  does not cancel the job; the job keeps running server-side, but no result
REM  files exist yet, so the run ends UNCONFIRMED and the job id has to be
REM  chased by hand. The Case backups are wide - 250+ fields - so they are
REM  slow even when the row count is modest.
set "WAITMIN=60"

for %%D in ("%RESULTDIR%" "%ARCHIVEDIR%" "%LOGDIR%") do if not exist %%D md %%D 2>nul

REM ---------------- arguments ------------------------------------
REM  ARGUMENTS ARE CANONICALISED BEFORE THEY ARE READ, so this script behaves
REM  the same started from cmd, from PowerShell, or from a Unix-style prompt
REM  (Git Bash / MSYS / Cygwin / WSL). MSYS rewrites anything shaped like a
REM  Unix path BEFORE cmd is ever reached, so from Git Bash "/q" actually
REM  arrives as "Q:/" and would be read as a bean id. :normarg undoes that and
REM  also accepts -q / --q. A bean id comes back untouched: the ids in the
REM  bean file carry no slash and no leading dash.
set "QUIET=0"
set "ONEJOB="
set "PURGEFAILED="
call :normarg ARG1 "%~1"
call :normarg ARG2 "%~2"
if /i "%ARG1%"=="q" set "QUIET=1"
if defined ARG1 if /i not "%ARG1%"=="q" set "ONEJOB=%ARG1%"
if defined ONEJOB if /i "%ARG2%"=="q" set "QUIET=1"

set "LOG=%LOGDIR%\%~n0.log"
break>"%LOG%"
set "WORST=0"

REM  :jsonval needs a scratch file. :runjob and :runjobextract set their own
REM  per-job JTMP; this one is for the calls made out here, i.e. :ensureauth.
set "JTMP=%LOGDIR%\jsonval.tmp"

REM  Show WHICH ORG this run will delete from, before anything is queried.
REM  The alias is the "org" key in clientcreds.json - the same value
REM  :ensureauth will use - so what is printed here is what gets deleted
REM  from. On a script that deletes, a filename alone is not enough.
set "TARGETORG="
if exist "%PURGEDIR%\Config\clientcreds.json" call :jsonval "%PURGEDIR%\Config\clientcreds.json" org TARGETORG
if not defined TARGETORG set "TARGETORG=%DEFAULTALIAS%"
if not defined TARGETORG set "TARGETORG=(unknown - no credentials file)"

echo(
echo(  %~n0   %VERSION%
echo(  ================================================
echo(   AUTOMATED PURGER - THIS SCRIPT DELETES ROWS
echo(   TARGET ORG:  %TARGETORG%
echo(  ================================================
echo(  2 sets ^| backup before delete ^| skip delete on 0 rows ^| wait %WAITMIN% min
call :log "=== %~n0 %VERSION% starting - TARGET ORG %TARGETORG% ==="
call :log "Bean file: %BEAN%"
if not defined BEAN goto :nobean
if not exist "%BEAN%" goto :nobean
goto :beanok
:nobean
REM  Say what was looked for AND what is actually there. "Bean not found"
REM  on its own sends people hunting; the listing usually answers it on sight.
echo(
echo(  [FAILED]   No bean file found in:
echo(             %CONFIGDIR%
echo(
echo(  Looked for purgedbean.bean, Process-Config.xml, process-conf.xml, then
echo(  any file in that folder containing "csvExportIdCases".
echo(
echo(  What is actually in there:
dir /b /a-d "%CONFIGDIR%" 2>nul
echo(
echo(  Fix it by renaming the bean to purgedbean.bean, or point at it with:
echo(      set "PURGE_BEAN=%CONFIGDIR%\<your file>"
echo(
set "ERRMSG=No bean file found in %CONFIGDIR% - see the listing above"
goto :fatal
:beanok
if not exist "%CURL%" (set "ERRMSG=curl.exe not found at %CURL% - needs Windows 10 1803 or later" & goto :fatal)
if not exist "%FIND%" (set "ERRMSG=find.exe not found at %FIND% - the row-count guard cannot run without it" & goto :fatal)
if not exist "%FINDSTR%" (set "ERRMSG=findstr.exe not found at %FINDSTR%" & goto :fatal)
REM  A hard requirement here, unlike on the load side: :soqlfile parses the
REM  bean as XML to decode "&lt;", and without that no extract can run.
if not exist "%PSEXE%" (set "ERRMSG=powershell.exe not found at %PSEXE% - it is needed to read the queries out of %BEAN%" & goto :fatal)

REM  Write the query reader :soqlfile runs. Must happen before pre-flight and
REM  before single-job mode, because both reach :soqlfile.
call :writesoqlhelper
if errorlevel 1 goto :fatal

REM ---------------- one archive folder for the whole run ----------
REM  Same name the old script built: Archive_AutoPurgedExtracts_ then MMDD,
REM  YYYY, the hour space-padded, and the minute - so "0904 2026 0 32" reads
REM  as "09042026 032" and sorts next to the folders already in there.
call :stamp
set "ARCHSUB=%ARCHIVEDIR%\Archive_AutoPurgedExtracts_%A_MMDD%%A_YYYY%%A_HHSP%%A_MI%"
call :log "Archive folder for this run: %ARCHSUB%"

REM  A single extract or delete bean by name.
if defined ONEJOB goto :purgeone


REM ---------------- pre-flight -----------------------------------
REM  Deliberately not the load script's source-CSV check: every CSV this
REM  chain deletes from is WRITTEN by the extract that runs minutes earlier
REM  in the same run, so its absence now is the normal case. What is checked
REM  instead, before anything is queried or deleted:
REM    - every bean id really is in the bean file, and carries the operation
REM      this chain expects to find on it
REM    - every extract bean has a non-empty sfdc.extractionSOQL that can
REM      actually be read out of the XML
REM    - every delete bean reads back the exact file its own id extract
REM      writes. If those two paths ever drift apart the delete consumes
REM      whatever else is sitting at its path - most likely a stale id file -
REM      which means deleting rows nobody extracted today.
set "PREOK=1"
echo(
echo(  Pre-flight
for %%J in ("%PJOB1%" "%PJOB2%" "%PJOB3%" "%PJOB4%" "%PJOB6%" "%PJOB7%") do call :checkextract %%J
for %%J in ("%PJOB5%" "%PJOB8%") do call :checkdelete %%J
call :checkpair "%PJOB4%" "%PJOB5%"
call :checkpair "%PJOB7%" "%PJOB8%"
if not "%PREOK%"=="1" (set "ERRMSG=Purge pre-flight failed - NOTHING was extracted and NOTHING was deleted" & goto :fatal)

REM ---------------- authenticate once for the whole run -----------
REM  One :ensureauth call per bean, because a bean MAY name its own
REM  sfdc.credentialsFile / sfdc.orgAlias. They share an alias here, so only
REM  the first call does an OAuth round trip and only a real fetch prints -
REM  what appears on screen is the literal number of authentications this run
REM  performed.
echo(
echo(  Authentication
set "PAUTHOK=1"
for %%J in ("%PJOB1%" "%PJOB2%" "%PJOB3%" "%PJOB4%" "%PJOB5%" "%PJOB6%" "%PJOB7%" "%PJOB8%") do call :purgeauth %%J
if not "%PAUTHOK%"=="1" goto :fatal

REM ---------------- set 1/2  Case ---------------------------------
REM  Three backups, then the ids, then the delete. Any backup failing stops
REM  the whole set: the id extract spans all three record types, so a delete
REM  after a failed backup deletes rows that have no backup.
call :purgeset "1/2  Case" "%PJOB4%" "%PJOB5%" "%PJOB1%" "%PJOB2%" "%PJOB3%"
set "RC=%ERRORLEVEL%"
if "%RC%"=="1" set "PURGEFAILED=%PURGEFAILED% Case"
if "%RC%"=="2" set "WORST=2"
call :archivebackups "%PJOB1%" "%PJOB2%" "%PJOB3%"

REM ---------------- set 2/2  Task ---------------------------------
call :purgeset "2/2  Task" "%PJOB7%" "%PJOB8%" "%PJOB6%"
set "RC=%ERRORLEVEL%"
if "%RC%"=="1" set "PURGEFAILED=%PURGEFAILED% Task"
if "%RC%"=="2" set "WORST=2"
call :archivebackups "%PJOB6%"

REM ---------------- report ----------------------------------------
REM  A stopped set is not a stopped run - the other set still did its work
REM  and its backup and delete stand. Say which one stopped rather than
REM  reporting a clean total.
if not defined PURGEFAILED goto :report
set "ERRMSG=These purge sets were STOPPED and nothing was deleted for them:%PURGEFAILED%. Every other set completed - see the per-job logs in %LOGDIR%. Re-run one set by naming its beans, backups first, ids next, delete last."
goto :fatal


REM ---------------- single extract or delete bean -----------------
:purgeone
call :log "Single-job mode: %ONEJOB%"
echo(
echo(  Authentication
call :ensureauth "%ONEJOB%"
if errorlevel 1 goto :fatal
call :readbean "%ONEJOB%"
if not defined OPERATION (set "ERRMSG=bean id '%ONEJOB%' not found in %BEAN%" & goto :fatal)
if /i "%OPERATION%"=="delete" goto :purgeonedelete
call :runjobextract "%ONEJOB%"
set "RC=%ERRORLEVEL%"
if "%RC%"=="1" (set "ERRMSG=%ONEJOB% did not complete - see %LOGDIR%\%ONEJOB%.log" & goto :fatal)
if "%RC%"=="2" set "WORST=2"
goto :report

:purgeonedelete
REM  A delete run on its own reads whatever id CSV is already on disk. That
REM  file is written by this object's id extract and MOVED into the archive
REM  by the delete that consumed it, so one sitting there is either from a
REM  run that stopped before the delete, or one somebody put back
REM  deliberately. Re-run the id extract first if there is any doubt which of
REM  the two it is - the ids in it decide what gets deleted.
call :runjob "%ONEJOB%"
set "WORST=%ERRORLEVEL%"
if "%WORST%"=="1" (set "ERRMSG=%ONEJOB% did not complete - see %LOGDIR%\%ONEJOB%.log" & goto :fatal)
goto :report


REM ---------------- report ---------------------------------------
:report
set "RC=%WORST%"
if "%RC%"=="0" call :log "SUCCESS - every job completed with no failed rows"
if "%RC%"=="2" call :log "COMPLETED WITH FAILURES - check the error CSVs under %RESULTDIR%"
call :log "Extracts archived to %ARCHSUB%"
goto :finish

:fatal
call :log "ERROR: %ERRMSG%"
set "RC=1"
goto :finish

:finish
REM  :jsonval leaves the value it extracted in this scratch file. Out here
REM  that is only ever the org alias, but the match is by substring, so a
REM  clientId containing "org" could put a credential fragment there. Cheap
REM  to be sure.
del /q "%JTMP%" 2>nul
echo(
if "%RC%"=="0" echo(  [OK]       Purge complete - no failed rows.
if "%RC%"=="2" echo(  [PARTIAL]  Completed, but some rows FAILED to delete - see the error CSVs.
if "%RC%"=="1" echo(  [FAILED]   The run stopped. %ERRMSG%
echo(             Log: %LOG%
echo(
if "%QUIET%"=="1" (endlocal & exit /b %RC%)
pause
endlocal & exit /b %RC%


REM ===============================================================
REM  :purgeset  <label> <idsBean> <deleteBean> [<backup> <backup> <backup>]
REM  One object's purge, in the only order that is safe.
REM  THE BACKUPS COME LAST IN THE ARGUMENT LIST AND RUN FIRST. That reads
REM  backwards and it is deliberate - a set can have one backup or three, and
REM  only a trailing argument can be optional in batch. The label says which
REM  set it is; the order inside is fixed by this routine, not by the caller.
REM  Returns 0 = done, 2 = the delete completed with failed rows,
REM          1 = the set was STOPPED and nothing was deleted for it.
REM ===============================================================
:purgeset
setlocal
set "PS_LABEL=%~1"
set "PS_IDS=%~2"
set "PS_DEL=%~3"
set "PS_STOP="
echo(
echo(  --- %PS_LABEL% ---------------------------------

REM  Backups first, and stop the whole set if any of them fails. Every other
REM  failure in this chain costs a re-run; deleting rows whose backup never
REM  wrote costs the rows.
REM  errorlevel cannot be read reliably inside a for body, so :psbackup is
REM  called out of the loop and reports through PS_STOP instead.
for %%B in ("%~4" "%~5" "%~6") do if not "%%~B"=="" call :psbackup "%%~B" "%PS_LABEL%"
if defined PS_STOP (call :log "%PS_LABEL% STOPPED - a backup extract failed, so the id extract and the delete were both skipped. Nothing was deleted for this object." & endlocal & exit /b 1)

echo(     ids      %PS_IDS%
call :runjobextract "%PS_IDS%"
set "RC=%ERRORLEVEL%"
call :log "%PS_IDS% exit code %RC%"
if "%RC%"=="1" (call :log "%PS_LABEL% STOPPED - the id extract failed, so the delete was skipped. Nothing was deleted for this object." & endlocal & exit /b 1)
if "%RC%"=="3" (call :log "%PS_LABEL%: 0 rows matched, so there is nothing to delete - delete skipped, this is not a failure" & endlocal & exit /b 0)

REM  :runjob reads the same bean, finds the CSV the id extract has just
REM  written, maps it through the SDL if there is one, runs
REM  "sf data delete bulk", routes the success and error CSVs into the folder
REM  the bean names, and MOVES the id file into this run's archive folder as
REM  it consumes it - which is what stops it being deleted from twice.
echo(     delete   %PS_DEL%
call :runjob "%PS_DEL%"
set "RC=%ERRORLEVEL%"
call :log "%PS_DEL% exit code %RC%"
if "%RC%"=="1" (call :log "%PS_LABEL%: the delete failed - see %LOGDIR%\%PS_DEL%.log. The backups and the id file for this object are on disk, so it can be re-run on its own." & endlocal & exit /b 1)
if "%RC%"=="2" (endlocal & exit /b 2)
endlocal & exit /b 0

REM ===============================================================
REM  :psbackup  <backupBean> <setLabel>  - one backup extract, reporting
REM  through PS_STOP because it is called from inside a for loop.
REM  No setlocal: PS_STOP has to survive back into :purgeset.
REM ===============================================================
:psbackup
echo(     backup   %~1
call :runjobextract "%~1"
set "PS_RC=%ERRORLEVEL%"
call :log "%~1 exit code %PS_RC%"
if "%PS_RC%"=="1" set "PS_STOP=1"
if "%PS_RC%"=="3" call :log "%~1 returned 0 rows - nothing to back up"
exit /b 0

REM ===============================================================
REM  :archivebackups  <bean> [<bean> ...]  - move each backup extract's CSV
REM  into this run's archive folder, which is what the old script's six
REM  "move" lines did at the end of the run.
REM  Called after the set finishes WHATEVER the outcome. A backup that wrote
REM  is worth keeping even when the delete failed, and getting it out of
REM  Source Data is what leaves the folder clean for the next run.
REM  The id CSVs are not handled here - :runjob moves those as it consumes
REM  them, so they are already in the archive folder by now.
REM ===============================================================
:archivebackups
if not exist "%ARCHSUB%" md "%ARCHSUB%" 2>nul
for %%B in (%*) do call :archiveone %%B
exit /b 0

:archiveone
call :readbean "%~1"
if not defined CSV exit /b 0
if not exist "%CSV%" exit /b 0
if not exist "%ARCHSUB%" (call :log "WARNING: archive folder %ARCHSUB% does not exist, so the backup CSV for %~1 was left in Source Data" & exit /b 0)
move /y "%CSV%" "%ARCHSUB%" >nul
if exist "%CSV%" (call :log "WARNING: could not move the backup CSV for %~1 into the archive folder - it is still in Source Data" & exit /b 0)
call :log "Archived the backup CSV for %~1 into %ARCHSUB%"
exit /b 0

REM ===============================================================
REM  :purgeauth  <BeanId>  - :ensureauth in a form a for loop can call,
REM  since errorlevel cannot be read reliably inside one.
REM ===============================================================
:purgeauth
call :ensureauth "%~1"
if errorlevel 1 set "PAUTHOK=0"
exit /b 0

REM ===============================================================
REM  :checkextract  <BeanId>  - pre-flight one extract bean.
REM  Does NOT check for a source CSV: an extract WRITES its dataAccess.name,
REM  it does not read it.
REM ===============================================================
:checkextract
call :readbean "%~1"
if not defined ENTITY (echo(  [ERROR] %~1: bean id not found in %BEAN% & set "PREOK=0" & exit /b 0)
if /i not "%OPERATION%"=="extract" (echo(  [ERROR] %~1: process.operation is '%OPERATION%', expected 'extract' & set "PREOK=0" & exit /b 0)
if not defined CSV (echo(  [ERROR] %~1: dataAccess.name missing & set "PREOK=0" & exit /b 0)
call :soqlfile "%~1" "%LOGDIR%\%~1.soql"
for %%Z in ("%LOGDIR%\%~1.soql") do if %%~zZ lss 10 (echo(  [ERROR] %~1: sfdc.extractionSOQL missing, empty, or unreadable from the bean XML & set "PREOK=0" & exit /b 0)
echo(  OK  %~1  -^>  %CSV%
exit /b 0

REM ===============================================================
REM  :checkdelete  <BeanId>  - pre-flight one delete bean.
REM  Its CSV is written later in this same run by the matching id extract,
REM  so its absence now is the normal case and is not checked. :checkpair
REM  checks the thing that actually matters about it.
REM ===============================================================
:checkdelete
call :readbean "%~1"
if not defined ENTITY (echo(  [ERROR] %~1: bean id not found in %BEAN% & set "PREOK=0" & exit /b 0)
if /i not "%OPERATION%"=="delete" (echo(  [ERROR] %~1: process.operation is '%OPERATION%', expected 'delete' & set "PREOK=0" & exit /b 0)
if not defined CSV (echo(  [ERROR] %~1: dataAccess.name missing & set "PREOK=0" & exit /b 0)
REM  A mapping file is OPTIONAL for these: the id extract writes a single
REM  column called Id, which is already an api name, so :runjob's "no SDL"
REM  path passes it straight through. Worth saying out loud, not worth
REM  failing - the old Data Loader run needed the SDL, this one does not.
if not defined SDL echo(  --  %~1: no process.mappingFile - the Id column is used as-is
if defined SDL if not exist "%SDL%" echo(  --  %~1: mapping file not found: %SDL% - the Id column is used as-is
if not defined OUTSUCC echo(  --  %~1: no process.outputSuccess - results go to %RESULTDIR% under the source folder's name
echo(  OK  %~1  ^<-  %CSV%
exit /b 0

REM ===============================================================
REM  :checkpair  <idsBean> <deleteBean>  - prove the delete reads back
REM  exactly the file its own id extract writes. Compared case-insensitively
REM  because Windows paths are. This is the check worth having: if the two
REM  paths drift apart, the delete still runs, still succeeds, and deletes
REM  whatever else was sitting at its path.
REM ===============================================================
:checkpair
call :readbean "%~1"
set "PP_IDS=%CSV%"
call :readbean "%~2"
set "PP_DEL=%CSV%"
if /i "%PP_IDS%"=="%PP_DEL%" (echo(  OK  %~2 reads the file %~1 writes & exit /b 0)
echo(  [ERROR] %~2 reads %PP_DEL% but %~1 writes %PP_IDS% - they must be the same file
set "PREOK=0"
exit /b 0

REM ===============================================================
REM  :readbean  <BeanId>  - pull this bean's entries into
REM  ENTITY OPERATION SDL CSV OUTSUCC OUTERR CREDFILE BEANALIAS
REM  Splitting each line on the quote character hands us the attribute
REM  values directly, so raw XML never lands in a variable.
REM  sfdc.extractionSOQL is NOT read here - it holds "&lt;" and "(" and would
REM  have to survive a cmd variable. :soqlfile handles it separately.
REM ===============================================================
:readbean
set "WANT=%~1"
setlocal EnableDelayedExpansion
set "INBEAN=0"
set "E=" & set "O=" & set "S=" & set "C=" & set "S2=" & set "S3=" & set "R2=" & set "R3="
for /f tokens^=1^,2^,4^ delims^=^" %%A in ('call "%FINDSTR%" /i /l /c:"<bean" /c:"<entry" "%BEAN%"') do (
  set "TAG=%%A"
  if not "!TAG:<bean=!"=="!TAG!" (
    REM  a <bean ...> line: token 2 is its id
    if /i "%%B"=="%WANT%" (set "INBEAN=1") else (if "!INBEAN!"=="1" set "INBEAN=2")
  ) else (
    if "!INBEAN!"=="1" (
      set "K=%%B"
      set "V=%%C"
      REM  value="" collapses under for/f, leaving the tag close as token 4
      if "!V!"=="/>" set "V="
      if "!V!"=="/" set "V="
      if /i "!K!"=="sfdc.entity"            set "E=!V!"
      if /i "!K!"=="process.operation"      set "O=!V!"
      if /i "!K!"=="process.mappingFile"    set "S=!V!"
      if /i "!K!"=="dataAccess.name"        set "C=!V!"
      if /i "!K!"=="process.outputSuccess"  set "S2=!V!"
      if /i "!K!"=="process.outputError"    set "S3=!V!"
      if /i "!K!"=="sfdc.credentialsFile"    set "R2=!V!"
      if /i "!K!"=="process.credentialsFile" set "R2=!V!"
      if /i "!K!"=="sfdc.orgAlias"           set "R3=!V!"
      if /i "!K!"=="process.orgAlias"        set "R3=!V!"
    )
  )
)
endlocal & (set "ENTITY=%E%" & set "OPERATION=%O%" & set "SDL=%S%" & set "CSV=%C%" & set "OUTSUCC=%S2%" & set "OUTERR=%S3%" & set "CREDFILE=%R2%" & set "BEANALIAS=%R3%")
REM  Put every path the bean gave us onto the root this run resolved. A no-op
REM  on the server; what makes a sandbox copy on another drive work.
call :rebase CSV
call :rebase SDL
call :rebase OUTSUCC
call :rebase OUTERR
exit /b 0

REM ===============================================================
REM  :soqlfile  <BeanId> <outFile>  - write one bean's sfdc.extractionSOQL
REM  to a file, with the XML entities decoded.
REM
REM  THIS IS THE ONE ROUTINE THAT HAD TO CHANGE FROM THE LOAD SCRIPT, AND
REM  READ THIS BEFORE TOUCHING IT.
REM  Every query here contains "CreatedDate &lt; LAST_N_MONTHS:12". The load
REM  script lifts the query out with findstr and writes it verbatim, which
REM  would hand the CLI the five characters "&lt;" instead of a comparison
REM  operator. So the bean is parsed as XML instead, by the one thing on the
REM  box that can be relied on to decode an entity correctly.
REM  The rules the load script's version was built around still hold and are
REM  still met, which is why the query goes bean -> file -> CLI and is never
REM  logged:
REM    1 the text never goes into a cmd variable. Delayed expansion eats a
REM      lone "!" and would turn "!=" into "=" - valid SOQL, opposite rows,
REM      and those rows get deleted. It is passed here through the
REM      ENVIRONMENT, which cmd does not re-parse.
REM    2 the text is never passed to CALL. Call re-parses its argument line
REM      and would read the "(" in four of these queries as a block.
REM  The .soql file is left in Log\ on purpose: it is the only readable
REM  record of what was actually asked for, it is not a secret, and it is the
REM  first thing to look at when an extract returns a surprising row count.
REM  Written without a BOM - the CLI reads the file as the whole query, and a
REM  BOM in front of SELECT is a syntax error.
REM  Exit code is not read by the callers; both judge the result by the size
REM  of the file it wrote, which also catches a bean id that does not exist.
REM
REM  THE PARSING IS IN A GENERATED .ps1, NOT IN A -Command STRING HERE, AND
REM  THAT IS NOT A STYLE CHOICE. It was one 630-character line, and at that
REM  length cmd intermittently FAILED TO FIND THIS VERY LABEL: the same file
REM  reported "The system cannot find the batch label specified - soqlfile"
REM  on a call from :runjobextract while the identical call from
REM  :checkextract minutes earlier had worked. Adding or removing a single
REM  byte ANYWHERE earlier in the file made it appear and disappear, so the
REM  script was one unrelated comment edit away from breaking. Measured on
REM  this box on 2026-09-09, not guessed. Keep every line in this file short.
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
REM  :writesoqlhelper  - write the query reader that :soqlfile runs.
REM  Called once, before pre-flight, so every later call is just an invoke.
REM  It reads three environment variables - SQ_BEAN, SQ_ID, SQ_DEST - which
REM  is how the query text is kept out of a cmd variable and away from CALL.
REM  Exit codes: 0 wrote the query, 2 no such bean id, 3 no query on it.
REM  Left in Log\ after the run: it is generated, not a secret, and seeing it
REM  is the quickest way to check what the bean is being read with.
REM  The "^(" and "^)" are cmd escapes for echo. The file they produce is
REM  ordinary PowerShell - read %LOGDIR%\readsoql.ps1 to see it.
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
exit /b 0

REM ===============================================================
REM  :runjobextract  <BeanId>  - the whole run for one extract bean:
REM  take the bean's sfdc.extractionSOQL, run it through the Bulk API and
REM  write the result to the bean's dataAccess.name.
REM  Returns 0 = rows written, 3 = ran clean but 0 data rows,
REM          1 = hard error.
REM ===============================================================
:runjobextract
setlocal
set "PROCESS=%~1"
set "LOG=%LOGDIR%\%PROCESS%.log"
set "SECRETS=%PURGEDIR%\Config\clientcreds.json"
set "RAWERR=%LOGDIR%\%PROCESS%-raw.txt"
set "JTMP=%LOGDIR%\%PROCESS%-jsonval.tmp"
set "QFILE=%LOGDIR%\%PROCESS%.soql"
break>"%LOG%"

call :log "Process=%PROCESS%"

REM ---------------- 1) read the bean -----------------------------
call :readbean "%PROCESS%"
if not defined ENTITY    (set "ERRMSG=sfdc.entity missing (bean id '%PROCESS%' not found in %BEAN%?)" & goto :exdie)
if not defined OPERATION (set "ERRMSG=process.operation missing for bean '%PROCESS%'" & goto :exdie)
if /i not "%OPERATION%"=="extract" (set "ERRMSG=bean '%PROCESS%' is a '%OPERATION%' bean - :runjobextract only runs 'extract'" & goto :exdie)
if not defined CSV       (set "ERRMSG=dataAccess.name missing for bean '%PROCESS%'" & goto :exdie)
call :log "entity=%ENTITY% op=%OPERATION% out=%CSV%"

REM ---------------- 2) the query ---------------------------------
call :soqlfile "%PROCESS%" "%QFILE%"
for %%Z in ("%QFILE%") do if %%~zZ lss 10 (set "ERRMSG=sfdc.extractionSOQL is missing, empty or unreadable for bean '%PROCESS%' - see %BEAN%" & goto :exdie)
call :log "Query file: %QFILE%"

REM ---------------- 3) credentials + org alias -------------------
REM  A bean may name its own credentials file; a relative path is taken as
REM  relative to ROOT. Normally none of them do and the default is used.
if not defined CREDFILE goto :excreddefault
set "ABS=0"
if "%CREDFILE:~1,1%"==":"  set "ABS=1"
if "%CREDFILE:~0,2%"=="\\" set "ABS=1"
if "%ABS%"=="0" set "CREDFILE=%ROOT%\%CREDFILE%"
set "SECRETS=%CREDFILE%"
if not exist "%SECRETS%" (set "ERRMSG=Credentials file not found: %SECRETS%" & goto :exdie)
call :log "Credentials: %SECRETS%"
:excreddefault

set "ORGALIAS=%BEANALIAS%"
if not defined ORGALIAS if exist "%SECRETS%" call :jsonval "%SECRETS%" org ORGALIAS
if not defined ORGALIAS set "ORGALIAS=%DEFAULTALIAS%"
if not defined ORGALIAS (set "ERRMSG=No org alias for bean '%PROCESS%' - add sfdc.orgAlias to the bean, or an 'org' key to %SECRETS%, or set DEFAULTALIAS" & goto :exdie)
if exist "%SECRETS%" if not defined AUTHOK_%ORGALIAS% call :fetchtoken "%SECRETS%" "%ORGALIAS%"

REM ---------------- 4) keep whatever is already there ------------
REM  The bean names ONE output path, so a second run would overwrite the
REM  first. For an id file that is harmless - the delete moves it into the
REM  archive as it consumes it - but a backup file is the whole point of the
REM  exercise and must not be silently replaced by a newer, smaller one.
REM  Anything already sitting at the path goes into this run's archive folder
REM  first, under a stamped name.
for %%P in ("%CSV%") do if not exist "%%~dpP" md "%%~dpP" 2>nul
for %%P in ("%CSV%") do if not exist "%%~dpP" (set "ERRMSG=Could not create the output folder for %CSV%" & goto :exdie)
if not exist "%CSV%" goto :exnoprev
if not exist "%ARCHSUB%" md "%ARCHSUB%" 2>nul
call :stamp
for %%P in ("%CSV%") do move /y "%CSV%" "%ARCHSUB%\%%~nP_%STAMP%%%~xP" >nul
if exist "%CSV%" (set "ERRMSG=An earlier %CSV% is in the way and could not be moved into %ARCHSUB%" & goto :exdie)
call :log "An earlier output was already at %CSV% - moved into %ARCHSUB% before this run wrote over it"
:exnoprev

REM ---------------- 5) run the query -----------------------------
REM  CALL on every external command: sf is sf.cmd, a BATCH file, and running
REM  one from another without CALL transfers control and never comes back.
REM  stderr goes to its own file so a CLI error never lands in the CSV.
set "EXRETRIED="
:exrun
call :log "Running: sf data query --bulk on %ENTITY% into %CSV%"
REM  THE WAIT NOTICE BELOW IS NOT DECORATION - LEAVE IT IN.
REM  Both of this command's output streams are redirected (stdout is the CSV
REM  itself, stderr is the raw log), so the console shows NOTHING from here
REM  until Salesforce is done. On the Case backups - 250+ fields - that is
REM  minutes of dead screen, which is indistinguishable from a hang, and the
REM  natural reaction is Ctrl-C. That kills the CLI mid-download, leaves a
REM  part-written CSV and a non-zero exit code, and the backup is then
REM  correctly reported as FAILED - which stops the delete for the whole set.
echo(
echo(     Querying Salesforce. THE SCREEN STAYS BLANK UNTIL THIS FINISHES -
echo(     that is normal. The job runs server-side and prints nothing here.
echo(     Waiting up to %WAITMIN% minutes.
echo(     DO NOT PRESS Ctrl-C - it aborts the download and wastes the run.
echo(     To watch it from a second Command Prompt:
echo(         dir "%CSV%"
echo(
call sf data query --file "%QFILE%" --target-org %ORGALIAS% --bulk --wait %WAITMIN% --result-format csv >"%CSV%" 2>"%RAWERR%" <nul
if not errorlevel 1 goto :exran

REM  One-shot session retry. Re-running a query is safe in a way that
REM  re-running a load is not - it reads, it writes nothing to the org - but
REM  it is still guarded to a single attempt, because a second failure is a
REM  real error and not an expiry.
if defined EXRETRIED goto :exfailed
if not exist "%SECRETS%" goto :exfailed
"%FINDSTR%" /l /c:"INVALID_SESSION_ID" "%RAWERR%" >nul || goto :exfailed
call :log "Session had expired mid-run - fetching a replacement token and retrying this query once"
call :fetchtoken "%SECRETS%" "%ORGALIAS%"
if errorlevel 1 goto :exdie
set "EXRETRIED=1"
goto :exrun

:exfailed
set "ERRMSG=sf data query failed for %PROCESS% - see %RAWERR%. Nothing was written to %CSV%, so no delete downstream of this extract will run."
goto :exdie

:exran
REM  An empty file is NOT "0 rows" - 0 rows still writes a header line. It
REM  means the CLI produced nothing at all, and the delete that reads this
REM  file must not be allowed to guess which of the two happened.
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
REM  :runjob  <BeanId>  - the whole delete for one bean.
REM  DELETE ONLY. The load script's :runjob also handles insert, update and
REM  upsert; nothing in this file does any of those, so the branches are gone
REM  rather than left in to be maintained for no caller.
REM  Returns 0 = every row deleted, 2 = some rows failed or the results were
REM  not confirmed, 1 = hard error.
REM ===============================================================
:runjob
setlocal
set "PROCESS=%~1"
set "LOG=%LOGDIR%\%PROCESS%.log"
set "SECRETS=%PURGEDIR%\Config\clientcreds.json"
set "RAWJSON=%LOGDIR%\%PROCESS%-raw.json"
set "JTMP=%LOGDIR%\%PROCESS%-jsonval.tmp"
set "HPAT=%LOGDIR%\%PROCESS%-hdr.txt"
set "WORK=%RESULTDIR%\%PROCESS%_input.csv"
break>"%LOG%"

call :log "Process=%PROCESS%"

REM ---------------- 1) read the bean -----------------------------
call :readbean "%PROCESS%"
if not defined ENTITY    (set "ERRMSG=sfdc.entity missing (bean id '%PROCESS%' not found in %BEAN%?)" & goto :jobdie)
if not defined OPERATION (set "ERRMSG=process.operation missing for bean '%PROCESS%'" & goto :jobdie)
if /i not "%OPERATION%"=="delete" (set "ERRMSG=bean '%PROCESS%' is a '%OPERATION%' bean - :runjob in this script only runs 'delete'" & goto :jobdie)
if not defined CSV       (set "ERRMSG=dataAccess.name missing for bean '%PROCESS%'"   & goto :jobdie)
if not exist "%CSV%"     (set "ERRMSG=Id CSV not found: %CSV%. It is written by this object's id extract - run that first." & goto :jobdie)
call :log "entity=%ENTITY% op=%OPERATION% csv=%CSV%"

if not exist "%RESULTDIR%" md "%RESULTDIR%" 2>nul

REM  sfdc.credentialsFile in the bean overrides Config\clientcreds.json.
REM  A path with no drive letter and no leading \\ is taken as relative to ROOT.
if not defined CREDFILE goto :creddefault
set "ABS=0"
if "%CREDFILE:~1,1%"==":"  set "ABS=1"
if "%CREDFILE:~0,2%"=="\\" set "ABS=1"
if "%ABS%"=="0" set "CREDFILE=%ROOT%\%CREDFILE%"
set "SECRETS=%CREDFILE%"
REM  Named explicitly in the bean, so a missing file is an error.
if not exist "%SECRETS%" (set "ERRMSG=Credentials file not found: %SECRETS%" & goto :jobdie)
call :log "Credentials: %SECRETS%"
goto :credresolved
:creddefault
REM  Nothing named in the bean. The default file is optional - without it we
REM  fall back to the auth the sf CLI already holds for the alias.
if exist "%SECRETS%" (call :log "Credentials: %SECRETS%") else (call :log "No credentials file at %SECRETS% - will use the sf CLI's stored auth")
:credresolved

REM ---------------- 2) SDL mapping + CSV header remap ------------
REM  In practice a no-op: the id extract writes ONE column called Id, which
REM  is already the api name "sf data delete bulk" wants. It is here for the
REM  BOM strip and because a mapping file is allowed to exist.
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
if not defined LINE (endlocal & set "ERRMSG=Id CSV is empty: %CSV%" & goto :jobdie)
call :split
set "NCOL=!NF!"

REM  The source header line goes to a pattern file BEFORE any BOM handling,
REM  so it matches the file byte for byte. findstr /v /l /g: then drops
REM  exactly that line and streams every other line through unchanged.
REM  "more" is used NOWHERE in this script and must not be reintroduced: it
REM  stops dead at a 0x1A byte and dies if Ctrl-C is pressed while it copies.
>"%HPAT%" echo(!LINE!

REM  Strip a UTF-8 BOM off column 1. With an SDL, the BOM is detected by the
REM  first column name failing to match any mapping key and matching once
REM  three characters are removed.
if !NMAP! gtr 0 (
  for %%c in ("!F1!") do if not defined M_%%~c (
    set "TRY=!F1:~3!"
    for %%d in ("!TRY!") do if defined M_%%~d (
      set "F1=!TRY!"
      echo(NOTE: UTF-8 BOM skipped on the first header - the CSV is fine, no action needed
    )
  )
)
REM  Belt and braces for the no-SDL path, where there are no mapping keys to
REM  test against. Every Salesforce api name starts with a letter, so a first
REM  character that is not a letter means junk in front of it. Three
REM  characters are removed only if that makes the name start with a letter,
REM  so a header that was already fine is never touched.
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
  ) else (
    set "DROPPED=!DROPPED! !F%%j!"
  )
)
if not defined NEWHDR (endlocal & set "ERRMSG=No CSV column matched the SDL - check %SDL% against the header of %CSV%" & goto :jobdie)
set "NEWHDR=!NEWHDR:~1!"

REM  AN UNMAPPED COLUMN IS A HARD STOP HERE, not something to drop.
REM  The load script rebuilds every row without the unmapped columns, because
REM  a load CSV legitimately carries columns Salesforce does not want. This
REM  file's delete input is a single Id column written by its own id extract
REM  minutes earlier, so an unmapped column means the file is not what this
REM  bean thinks it is - and rebuilding rows to guess past that is how a
REM  delete ends up reading the wrong ids.
if defined DROPPED (endlocal & set "ERRMSG=Columns in the id CSV are not in the SDL:%DROPPED%. Map every column, or delete the process.mappingFile entry so the header is used as-is. NOTHING was deleted." & goto :jobdie)

echo(Preparing input CSV ^(header renamed, !NCOL! columns kept^)
>"%WORK%" echo(!NEWHDR!
endlocal

REM  findstr streams the whole file and is indifferent to 0x1A, so it does
REM  not truncate the way "more" did.
REM  NO /x HERE. "set /p" SILENTLY DROPS A UTF-8 BOM when it reads the header
REM  line, so the pattern in HPAT begins at the first real character while
REM  the file itself begins EF BB BF. Under /x - whole-line match - the two
REM  never match, the header is NOT dropped, and the prepared file comes out
REM  one row longer than the source, which the row guard then reports as a
REM  count mismatch on a file that is perfectly fine apart from a BOM.
REM  Without /x the match is "line contains the pattern", which catches the
REM  header whether or not a BOM sits in front of it.
"%FINDSTR%" /v /l /g:"%HPAT%" "%CSV%" >>"%WORK%"

REM  THE GUARD. Source data rows must equal prepared data rows. On the load
REM  side a mismatch once meant 34,465 rows silently never sent. Here it
REM  would mean rows silently never DELETED, which is quieter and worse: the
REM  ids stay in the org, their backup is archived, and the run reports
REM  success.
if not exist "%WORK%" (set "ERRMSG=Failed to build input CSV: %WORK%" & goto :jobdie)
call :rowcount "%CSV%"  SRCROWS
call :rowcount "%WORK%" WRKROWS
if "%SRCROWS%"=="%WRKROWS%" goto :rowsok
set "ERRMSG=Row count mismatch - %CSV% has %SRCROWS% data rows but the prepared file has %WRKROWS%. NOTHING was deleted. A 0x1A (Ctrl-Z) byte or other control character in the CSV is the usual cause; do not press Ctrl-C while the file is being prepared."
goto :jobdie
:rowsok
if "%SRCROWS%"=="0" (call :log "The id CSV has a header but no rows - nothing to delete" & del /q "%WORK%" 2>nul & del /q "%HPAT%" 2>nul & endlocal & exit /b 0)
call :log "Row check OK - %SRCROWS% source data rows, %WRKROWS% prepared: %WORK%"
echo(Row check OK - %SRCROWS% ids in, %WRKROWS% ready to delete

REM ---------------- 3) resolve the org alias ---------------------
REM  No token fetch here in the normal case. :ensureauth already got one for
REM  this alias before any job started and persisted it into the sf CLI's
REM  auth store with "sf org login access-token -p", so every job in the run
REM  shares it. All this step has to do is work out WHICH alias the sf
REM  commands below should target. The one exception is a direct :runjob call
REM  with no :ensureauth ahead of it - that still fetches, so :runjob stays
REM  usable on its own.
set "ORGALIAS=%BEANALIAS%"
if not exist "%SECRETS%" goto :usestoredauth
if not defined ORGALIAS call :jsonval "%SECRETS%" org ORGALIAS
if not defined ORGALIAS (set "ERRMSG=org missing from %SECRETS% and no sfdc.orgAlias in the bean" & goto :jobdie)
if defined AUTHOK_%ORGALIAS% (
  call :log "Reusing the single token fetched for alias '%ORGALIAS%' at the start of this run - no re-authentication"
  goto :authdone
)
call :log "No token cached for alias '%ORGALIAS%' - fetching one for this job"
call :fetchtoken "%SECRETS%" "%ORGALIAS%"
if errorlevel 1 goto :jobdie
goto :authdone

:usestoredauth
REM  Reached only when there is NO credentials file. DEFAULTALIAS is empty at
REM  the top of this file on purpose - a missing clientcreds.json must not
REM  silently send a DELETE at whichever org the CLI happens to remember.
if not defined ORGALIAS set "ORGALIAS=%DEFAULTALIAS%"
if not defined ORGALIAS (set "ERRMSG=No credentials file at %SECRETS%, no sfdc.orgAlias in the bean, and DEFAULTALIAS is empty at the top of this script. Refusing to guess which org to DELETE from - set one of those three." & goto :jobdie)
call :log "No credentials file - using the sf CLI's stored auth for alias '%ORGALIAS%'"
:authdone

REM ---------------- 4) run the delete ----------------------------
REM  Stale *-records*.csv from an earlier run would be picked up below as if
REM  they belonged to this job, reporting someone else's row counts.
del /q "%RESULTDIR%\*success-records*.csv" 2>nul
del /q "%RESULTDIR%\*failed-records*.csv"  2>nul

set "RETRIED="
:runload
call :log "Running: sf data delete bulk --sobject %ENTITY%"
echo(
echo(     Deleting from Salesforce. THE SCREEN STAYS BLANK UNTIL THIS
echo(     FINISHES - that is normal. Waiting up to %WAITMIN% minutes.
echo(     DO NOT PRESS Ctrl-C - the bulk job keeps running in the org, but
echo(     this script loses track of it and cannot collect the results, so
echo(     you end up not knowing which rows went.
echo(     Progress is visible in Setup ^> Bulk Data Load Jobs.
echo(
REM  <nul on every external call: nothing in this script is interactive, and
REM  a CLI that decides to prompt must fail rather than sit there holding up
REM  an unattended run.
call sf data delete bulk --sobject %ENTITY% --file "%WORK%" --target-org %ORGALIAS% --wait %WAITMIN% --json >"%RAWJSON%" 2>&1 <nul

REM  One token for the whole run means a slow set 1 can leave set 2 holding a
REM  session that has since timed out. If that happened, fetch a replacement
REM  and run this delete once more. Re-running is safe: INVALID_SESSION_ID is
REM  the API rejecting the request outright, so no bulk job was created and
REM  no row was touched. Guarded to a single attempt - a second failure is a
REM  real error, not an expiry.
if defined RETRIED goto :loadran
if not exist "%SECRETS%" goto :loadran
"%FINDSTR%" /l /c:"INVALID_SESSION_ID" "%RAWJSON%" >nul || goto :loadran
call :log "Session had expired mid-run - fetching a replacement token and retrying this delete once"
call :fetchtoken "%SECRETS%" "%ORGALIAS%"
if errorlevel 1 goto :jobdie
set "RETRIED=1"
goto :runload
:loadran

REM  Job id: find the first "750..." then cut at the closing quote. Do NOT
REM  take a fixed number of characters - an id of unexpected length then
REM  swallows the quote and the junk ends up on the next command line.
set "JOBID="
"%FINDSTR%" /l /c:"750" "%RAWJSON%" >"%JTMP%" 2>nul
set "JLINE="
set /p JLINE=<"%JTMP%"
if not defined JLINE goto :jobidcheck
set "JTAIL=%JLINE:*750=%"
>"%JTMP%" echo(750%JTAIL%
for /f tokens^=1^ delims^=^" %%A in ('type "%JTMP%"') do if not defined JOBID set "JOBID=%%A"
:jobidcheck
REM  Salesforce ids are 15 or 18 chars - anything shorter means we scraped junk.
if defined JOBID if "%JOBID:~14,1%"=="" (
  call :log "WARNING: scraped job id looks malformed: %JOBID%"
  set "JOBID="
)
if not defined JOBID (set "ERRMSG=sf delete: no job id found. See %RAWJSON% - if it mentions an expired or invalid session, re-authorise alias %ORGALIAS% or check the credentials file so this script can fetch its own token." & goto :jobdie)
call :log "Job Id: %JOBID%"

REM ---------------- 5) fetch + route the result files ------------
pushd "%RESULTDIR%"
call sf data bulk results --job-id %JOBID% --target-org %ORGALIAS% >nul 2>&1 <nul
popd

REM  WHERE THE RESULTS GO IS THE BEAN'S DECISION.
REM  process.outputSuccess / process.outputError name the folder - "Case
REM  Deletion" and "Task Deletion" - and their base names. Only the FOLDER
REM  and the base name are used: the run's timestamp is appended, because
REM  Data Loader overwrote successExportCase.csv on every run and the
REM  previous run's results were gone. With no such entry in the bean, fall
REM  back to the load script's rule and use the source folder's own name.
set "OUTDIR="
set "SUCCNAME=success"
set "FAILNAME=error"
if defined OUTSUCC for %%P in ("%OUTSUCC%") do (set "OUTDIR=%%~dpP" & set "SUCCNAME=%%~nP")
if defined OUTERR  for %%P in ("%OUTERR%")  do set "FAILNAME=%%~nP"
if defined OUTDIR if "%OUTDIR:~-1%"=="\" set "OUTDIR=%OUTDIR:~0,-1%"
if not defined OUTDIR for %%P in ("%CSV%") do for %%Q in ("%%~dpP.") do set "OUTDIR=%RESULTDIR%\%%~nxQ"
if not exist "%OUTDIR%" md "%OUTDIR%" 2>nul
if not exist "%OUTDIR%" (set "ERRMSG=Could not create the results folder '%OUTDIR%'. Job %JOBID% HAS already run - check it with: sf data bulk results --job-id %JOBID% --target-org %ORGALIAS%" & goto :jobdie)

call :stamp
set "SUCCDEST=%OUTDIR%\%SUCCNAME%%STAMP%.csv"
set "FAILDEST=%OUTDIR%\%FAILNAME%%STAMP%.csv"

set "SUCCSRC="
for /f "delims=" %%F in ('dir /b /a-d /o-d "%RESULTDIR%\*success-records*.csv" 2^>nul') do if not defined SUCCSRC set "SUCCSRC=%%F"
set "FAILSRC="
for /f "delims=" %%F in ('dir /b /a-d /o-d "%RESULTDIR%\*failed-records*.csv" 2^>nul')  do if not defined FAILSRC set "FAILSRC=%%F"

set "SUCCCOUNT=0"
set "FAILCOUNT=0"
set "NORESULTS="
REM  No result files at all means we know nothing about what the job did - it
REM  must NOT be reported as success. The job itself may well have worked.
if not defined SUCCSRC if not defined FAILSRC set "NORESULTS=1"
REM  Usually means the job outlived --wait %WAITMIN% and is still running
REM  server-side, so no result files exist YET. It is not a failure and the
REM  job must not be re-run blindly - it may be deleting every row right now.
if defined NORESULTS call :log "WARNING: no result files for job %JOBID% after waiting %WAITMIN% min - it is probably STILL RUNNING, not failed. Do NOT re-run. Check state: sf data delete resume --job-id %JOBID% --target-org %ORGALIAS%   then: sf data bulk results --job-id %JOBID% --target-org %ORGALIAS%"
if defined SUCCSRC (
  move /y "%RESULTDIR%\%SUCCSRC%" "%SUCCDEST%" >nul
  call :rowcount "%SUCCDEST%" SUCCCOUNT
) else (
  break>"%SUCCDEST%"
)
if defined FAILSRC (
  move /y "%RESULTDIR%\%FAILSRC%" "%FAILDEST%" >nul
  call :rowcount "%FAILDEST%" FAILCOUNT
) else (
  break>"%FAILDEST%"
)
REM  No "->" in this message. call re-parses its own argument line, and ">"
REM  survives that second pass as a REDIRECTION even inside the quotes: it
REM  writes the line into a file called "Load" - the first token of "Load
REM  Result" - and the log entry itself vanishes. No parentheses either: with
REM  OUTDIR holding a path that contains a space, call's second parse treats
REM  "(" as the start of a block and the line is logged truncated. Commas only.
call :log "Results in %OUTDIR% - success=%SUCCCOUNT% rows, error=%FAILCOUNT% rows"

REM  Every id submitted must come back in one file or the other. If it does
REM  not, the result files are an incomplete picture and the counts below
REM  would understate the damage - say so instead of quietly reporting a
REM  clean total. STATEMENT LEVEL, not a parenthesised block: %ACCOUNTED%
REM  inside a block would expand when the block is PARSED, before the set /a
REM  that fills it ever runs.
if defined NORESULTS goto :skipaccount
set /a ACCOUNTED=%SUCCCOUNT%+%FAILCOUNT%
if not "%ACCOUNTED%"=="%WRKROWS%" call :log "WARNING: %WRKROWS% ids were submitted but only %ACCOUNTED% appear in the result files, success=%SUCCCOUNT% error=%FAILCOUNT%. Verify job %JOBID% in the org before trusting these numbers."
:skipaccount

REM ---------------- 6) archive the id CSV ------------------------
REM  MOVED, not copied, and this is what stops the same ids being deleted
REM  from twice. ARCHSUB is set once for the whole run, so both sets share
REM  one folder - the same shape the old script's "md Archive_..." produced.
if not exist "%ARCHSUB%" md "%ARCHSUB%" 2>nul
if not exist "%ARCHSUB%" (set "ERRMSG=Could not create archive folder '%ARCHSUB%'. Job %JOBID% HAS already run - check it with: sf data bulk results --job-id %JOBID% --target-org %ORGALIAS%" & goto :jobdie)
for %%P in ("%CSV%") do move /y "%CSV%" "%ARCHSUB%\%%~nxP" >nul
del /q "%WORK%" 2>nul
del /q "%HPAT%" 2>nul

if defined NORESULTS (
  call :log "UNCONFIRMED - job %JOBID% ran but no result files were returned, so it is not known which ids were deleted. Id file archived to %ARCHSUB%"
  endlocal & exit /b 2
)
if "%FAILCOUNT%"=="0" (
  call :log "SUCCESS - %SUCCCOUNT% deleted, 0 failed, out of %WRKROWS% submitted. Id file archived to %ARCHSUB%"
  endlocal & exit /b 0
)
call :log "COMPLETED - %SUCCCOUNT% deleted, %FAILCOUNT% failed, out of %WRKROWS% submitted. Id file archived to %ARCHSUB%; results in %OUTDIR%"
endlocal & exit /b 2

:jobdie
call :log "ERROR: %ERRMSG%"
endlocal & exit /b 1

REM ===============================================================
REM  :ensureauth  <BeanId>  - guarantee a usable token for this bean's org
REM  alias, fetching one ONLY if this run has not already done so.
REM
REM  Deliberately has NO setlocal: it sets AUTHOK_<alias> and that marker has
REM  to survive into the parent scope, which is the whole point. :runjob and
REM  :runjobextract read it to decide whether to skip their own fetch. The
REM  cost is that EA_* and :readbean's outputs leak into the caller -
REM  harmless, since both runners re-read their own bean and the pre-flight
REM  has already finished with them.
REM
REM  Keyed on the ALIAS, not the credentials file, because what matters is
REM  "does the sf CLI hold a live login for alias X". An alias with spaces or
REM  punctuation would not be a legal variable name and would need hashing.
REM
REM  Only a real fetch prints to the console. A reuse goes to the log alone,
REM  so the number of lines on screen is the number of authentications.
REM  Returns 0 = ready, 1 = hard error with ERRMSG set.
REM ===============================================================
:ensureauth
call :readbean "%~1"
set "EA_SECRETS=%PURGEDIR%\Config\clientcreds.json"
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
if not defined EA_ALIAS (set "ERRMSG=No org alias for bean '%~1' - add sfdc.orgAlias to the bean, or an 'org' key to %EA_SECRETS%" & exit /b 1)
if defined AUTHOK_%EA_ALIAS% (
  call :log "%~1: reusing the token already fetched for alias '%EA_ALIAS%' - no second authentication"
  exit /b 0
)
call :log "Fetching ONE client-credentials token for alias '%EA_ALIAS%' - every job in this run shares it"
call :fetchtoken "%EA_SECRETS%" "%EA_ALIAS%"
if errorlevel 1 exit /b 1
set "AUTHOK_%EA_ALIAS%=1"
echo(  Authenticated once for %EA_ALIAS% - this login is reused by every job in the run
call :log "Logged in as alias '%EA_ALIAS%'"
exit /b 0

REM ===============================================================
REM  :fetchtoken  <credentialsFile> <orgAlias>  - exactly one OAuth
REM  client-credentials round trip against the external client app, then hand
REM  the token to the sf CLI. -p persists it under the alias, which is what
REM  lets one fetch serve the whole run.
REM
REM  THIS IS THE WHOLE OF THE NEW LOGIN. There is no username, no password
REM  and no key file anywhere in this script or in the bean. What the org
REM  needs for it: an External Client App with the client-credentials flow
REM  enabled and a run-as user that can query and delete Case and Task.
REM
REM  The response JSON is deleted the moment it has been read. It holds a
REM  live bearer token in clear text, and the log truncation at the top of a
REM  run does not cover files it does not know about.
REM  Returns 0 on success, 1 with ERRMSG set on failure.
REM ===============================================================
:fetchtoken
setlocal
set "FT_SECRETS=%~1"
set "FT_ALIAS=%~2"
set "FT_TOK=%LOGDIR%\token.json"
REM  Our own scratch file, so a call from either scope works. :jsonval writes
REM  the value it extracted into JTMP, which means this file holds the
REM  clientSecret and then the access token. EVERY exit path below goes
REM  through :ft_done or :ft_fail so it is always deleted.
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
REM  Plain exit /b, no endlocal: the implicit one drops SF_ACCESS_TOKEN with it.
exit /b 0

:ft_fail
del /q "%FT_TOK%" 2>nul
del /q "%JTMP%"   2>nul
REM  FT_ERR expands while the line is PARSED, i.e. before endlocal runs, so
REM  the message survives into the caller's scope. Standard batch idiom.
endlocal & set "ERRMSG=%FT_ERR%" & exit /b 1


REM ===============================================================
REM  :rootfromself  - set ROOT by walking up from this script's own folder
REM  to the one called NLG. Leaves ROOT alone if there isn't one, so a script
REM  kept outside the tree still uses the default at the top of the file.
REM  SELFDIR is captured at the top level on purpose: %~dp0 inside a
REM  subroutine expands to the label, not to the script.
REM ===============================================================
:rootfromself
if not defined SELFDIR exit /b 0
set "RS=%SELFDIR%"
if "%RS:~-1%"=="\" set "RS=%RS:~0,-1%"
:rs_loop
if not defined RS exit /b 0
REM  A bare drive - "C:" - means we walked past the top without finding it.
if "%RS:~-1%"==":" exit /b 0
for %%A in ("%RS%") do set "RSNAME=%%~nxA"
if /i "%RSNAME%"=="NLG" (set "ROOT=%RS%" & exit /b 0)
for %%A in ("%RS%") do set "RS=%%~dpA"
if "%RS:~-1%"=="\" set "RS=%RS:~0,-1%"
goto :rs_loop

REM ===============================================================
REM  :findbean  - locate the bean file in Config whatever it is called.
REM  Sets BEAN, or leaves it empty for the caller's "Bean not found" check.
REM ===============================================================
:findbean
for %%N in (purgedbean.bean Process-Config.xml process-config.xml purge-process-conf.xml process-conf.xml purgedbean.xml purgedbean.txt) do if not defined BEAN if exist "%CONFIGDIR%\%%N" set "BEAN=%CONFIGDIR%\%%N"
if defined BEAN exit /b 0
REM  Nothing matched a known name. Look for a file that contains this
REM  chain's bean ids - the content is what matters, not the extension.
REM  Directories are excluded with /a-d so the SDL subfolder is skipped.
for /f "delims=" %%F in ('dir /b /a-d "%CONFIGDIR%\*" 2^>nul') do if not defined BEAN call :beanprobe "%CONFIGDIR%\%%F"
exit /b 0

:beanprobe
REM  <path>. A real bean file for this chain names csvExportIdCases. Checked
REM  with findstr rather than by extension, which is how Process-Config.xml
REM  was found after it had been renamed away from purgedbean.bean.
"%FINDSTR%" /l /c:"csvExportIdCases" "%~1" >nul 2>&1
if errorlevel 1 exit /b 0
set "BEAN=%~1"
exit /b 0

REM ===============================================================
REM  :rebase  <varname>  - rewrite a bean path that starts "X:\NLG\" so it
REM  starts with ROOT instead.
REM
REM  WHY THIS EXISTS. The bean holds the server's absolute paths, D:\NLG\...,
REM  and it must keep them - it is the server's file. But a sandbox copy of
REM  the tree lives on whatever drive the laptop has, and without this every
REM  extract fails with "The device is not ready" on a box with no D: drive.
REM  On the server ROOT is D:\NLG, so this rewrites D:\NLG to D:\NLG and
REM  changes nothing at all.
REM  Only paths shaped exactly like "<drive>:\NLG\..." are touched. Anything
REM  else - a UNC path, or a path outside the NLG tree - is left alone.
REM ===============================================================
:rebase
call set "RB=%%%~1%%"
if not defined RB exit /b 0
if /i not "%RB:~1,6%"==":\NLG\" exit /b 0
set "%~1=%ROOT%%RB:~6%"
exit /b 0

REM ===============================================================
REM  shared subroutines
REM ===============================================================

:log
echo(%DATE% %TIME%  %~1
>>"%LOG%" echo(%DATE% %TIME%  %~1
exit /b 0

REM  :split  - LINE -> F1..Fn plus NF.  Handles empty fields, which plain
REM  "for /f tokens=" cannot (it collapses repeated delimiters).
REM  Caller must have delayed expansion ON.  Assumes no quotes and no "!".
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

REM  :jsonval  <file> <key> <outvar>  - pull a string value out of JSON,
REM  pretty-printed or compact.  Values must not contain spaces (true for
REM  domain / ids / secrets / tokens / urls).
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
REM  The "call" is load-bearing, not decoration. for /f runs its command
REM  through cmd /c, and cmd /c strips the first and last quote of a string
REM  that BEGINS with a quote. With the exe path quoted first, the command
REM  comes apart and every call prints "The filename, directory name, or
REM  volume label syntax is incorrect." while reading no beans at all.
REM  Starting the string with "call" means it no longer begins with a quote,
REM  so nothing is stripped. Do not "tidy" the call away.

REM  :normarg  <outvar> <raw>  - the canonical form of one command-line
REM  argument: no path in front of it, no leading slashes or dashes. See the
REM  argument block near the top for what MSYS does and why this is needed.
:normarg
set "%~1="
set "NA=%~2"
if not defined NA exit /b 0
REM  MSYS drive form - a lone "/x" reaches cmd as "X:/", "X:\" or "X:".
if "%NA:~1%"==":/" (set "%~1=%NA:~0,1%" & exit /b 0)
if "%NA:~1%"==":\" (set "%~1=%NA:~0,1%" & exit /b 0)
if "%NA:~1%"==":" (set "%~1=%NA:~0,1%" & exit /b 0)
REM  MSYS prefix form, and plain "/q" from cmd - keep the last component.
for %%P in ("%NA:/=\%") do set "NA=%%~nxP"
:normarg_strip
if "%NA:~0,1%"=="-" (set "NA=%NA:~1%" & goto :normarg_strip)
if "%NA:~0,1%"=="/" (set "NA=%NA:~1%" & goto :normarg_strip)
set "%~1=%NA%"
exit /b 0

REM  :winpath  <varname>  - rewrite an MSYS/Cygwin path in that variable as a
REM  Windows one. "/c/NLG" and "/cygdrive/c/NLG" both become "C:\NLG"; a path
REM  that is already a Windows or UNC path is left exactly as it is.
:winpath
REM  A Unix path always begins with "/". Anything else - every ordinary
REM  Windows path and every UNC path - leaves here untouched, before delayed
REM  expansion is ever switched on, so a "!" in a Windows path is safe.
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
REM  A_MI, the minute on its own. A_MI is what keeps the folder name the same
REM  shape the old script produced from "%Time:~3,2%".
REM  EVERYTHING HERE IS STATEMENT LEVEL ON PURPOSE. Put the fallback inside
REM  an if/else block and %VAR% expands when the block is PARSED - before the
REM  SET that fills it runs - which on a machine without wmic produced folder
REM  names like "Archive_0807 2026~0,2~3,2T:~6,2", so md and move both failed
REM  and no results were collected.
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
REM  came out "Archive_AutoPurgedExtracts_09042026 032". Keep it, so this
REM  run's folder sorts next to the ones already in the Archive folder.
if "%A_HH:~0,1%"=="0" (set "A_HHSP= %A_HH:~1%") else (set "A_HHSP=%A_HH%")
exit /b 0
