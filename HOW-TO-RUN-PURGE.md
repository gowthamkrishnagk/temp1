# Running the Automated Purger — one object at a time

`purgedbat.bat` purges **Case** and **Task** rows older than twelve months. It can run
**both objects** or **a single named job**. To act on one job, pass that job's
**bean id** as the only argument:

```
purgedbat.bat <BeanId>
```

That is the whole command. The bean id decides the object, the operation, the SOQL,
the CSV path and where the results go — all of it comes from
`Config\purgedbean.bean`, not from the command line.

> **This script deletes rows.** Read *Deleting one object on its own* below before
> you run any `csvDelete...` bean by hand. Every safety gate that protects you lives
> in the chain, and running a delete on its own steps around most of them.

---

## Before the first run

| Thing | Where | Notes |
|---|---|---|
| Which org it hits | `C:\NLG\Config\clientcreds.json`, the `org` key | **This is the only file you edit to move between orgs.** The bean and the SDLs are org-independent. |
| How it logs in | `C:\NLG\Config\clientcreds.json` — `domain`, `clientId`, `clientSecret`, `org` | OAuth client credentials against an External Client App. There is no username, password or key file any more. |
| Bean definitions | `C:\NLG\Config\purgedbean.bean` | Repo copy of this file is `purgedbean.bean`. |
| The script | `C:\NLG\purgedbat.bat` | Repo copy of this file is `purgedbat.bat`. |
| Root folder | `C:\NLG` | Override with the `NLG_ROOT` environment variable if your install is elsewhere. Set it to `D:\NLG` for a D: drive layout — but the bean's own paths have to move with it. |

The target org is printed on screen and written to the log **before anything is
queried**, so you can always see which org is about to be deleted from.

Open a normal Command Prompt in the folder holding the batch file, or just
double-click it. Everything runs in that one window.

> **Save `purgedbat.bat` with Windows (CRLF) line endings.** Saved with Unix (LF)
> endings, cmd does not report an error — it mis-jumps, and an extract that
> succeeded can log a phantom failure. If you see
> `The system cannot find the batch label specified`, or messages that belong to a
> different job, check the line endings first.

---

## The two sets

The purge is read as **two independent sets, one object each**. Within a set the
order is fixed: every backup extract, then the id extract, then the delete that
consumes those ids.

| Set | Object | Backups | Ids | Delete |
|---|---|---|---|---|
| 1 | Case | `csvExportBuyingCustomerCases`, `csvExportSellingCustomerCases`, `csvExportConservationCasesCases` | `csvExportIdCases` | `csvDeleteCases` |
| 2 | Task | `csvExportAllTask` | `csvExportIdTask` | `csvDeleteTask` |

A failure in one set does not stop the other. Case failing still lets Task run, and
the report says which set stopped.

---

## Case

Everything here filters on `CreatedDate < LAST_N_MONTHS:12` — rows older than the
last twelve months.

### Back up first — all three, they are the restore copy

| Record type | Bean id — use this as the argument | Writes |
|---|---|---|
| Buying Customer | `csvExportBuyingCustomerCases` | `Automated Purger\Source Data\Extracted Cases\BuyingCustomerCaseBackup.csv` |
| Selling Customer | `csvExportSellingCustomerCases` | `...\Extracted Cases\SellingCustomerCasesBackup.csv` |
| Conservation Case | `csvExportConservationCasesCases` | `...\Extracted Cases\ConservationCasesBackup.csv` |

Each pulls **all fields** — over 250 of them — which is why these are the slow step.

### Then the ids, then the delete

| Bean id | What it does |
|---|---|
| `csvExportIdCases` | Writes `...\Extracted Cases\CaseIdToBeDeleted.csv` — ids only, across **all three** record types above. |
| `csvDeleteCases` | Deletes exactly the ids in that file. Results land in `Automated Purger\Load Result\Case Deletion\`. |

> **All three Case backups gate the Case delete.** `csvExportIdCases` collects ids
> across all three record types at once, and a delete cannot be told to spare the one
> whose backup did not write. So if any one backup fails, the id extract and the
> delete are both skipped and **nothing is deleted for Case**.

### Run the whole Case object on its own

```
purgedbat.bat csvExportBuyingCustomerCases
purgedbat.bat csvExportSellingCustomerCases
purgedbat.bat csvExportConservationCasesCases
purgedbat.bat csvExportIdCases
purgedbat.bat csvDeleteCases
```

Check each one reported rows written before you run the next. Running them by hand
like this gives you **no gating** — the script will not stop you running
`csvDeleteCases` after a backup that failed.

---

## Task

Same rule: `CreatedDate < LAST_N_MONTHS:12`.

| Bean id | What it does |
|---|---|
| `csvExportAllTask` | All fields, to `Automated Purger\Source Data\Extracted Tasks\TasksBackup.csv`. Your restore copy. |
| `csvExportIdTask` | Ids only, to `...\Extracted Tasks\TaskIdsToBeDeleted.csv`. |
| `csvDeleteTask` | Deletes exactly those ids. Results land in `Automated Purger\Load Result\Task Deletion\`. |

### Run the whole Task object on its own

```
purgedbat.bat csvExportAllTask
purgedbat.bat csvExportIdTask
purgedbat.bat csvDeleteTask
```

---

## Extract without deleting

Every `csvExport...` bean only runs its SOQL and writes a CSV. None of them change
anything in the org, so they are safe to run on their own at any time — to check how
many rows a retention rule actually matches, for instance:

```
purgedbat.bat csvExportIdTask
```

The row count is printed when it finishes, and the exact query that ran is left in
`Automated Purger\Log\csvExportIdTask.soql` if you want to read it.

---

## Deleting one object on its own

A delete bean **does not query anything**. It deletes exactly the ids sitting in its
CSV, so that CSV has to be freshly written first:

```
purgedbat.bat csvExportIdTask       REM 1. writes the ids
purgedbat.bat csvDeleteTask         REM 2. deletes exactly those ids
```

The id CSV is **moved into the run's archive folder as the delete consumes it**. That
is deliberate: a stale id file from an older run cannot be picked up and deleted from
a second time. It also means step 2 fails with `Id CSV not found` if you skip step 1,
which is the safe way for it to fail.

> If an id CSV is already sitting there, it is either from a run that stopped before
> its delete, or one somebody put back deliberately. **Re-run the id extract if there
> is any doubt which** — the ids in that file decide what gets deleted.

---

## Running everything instead of one job

| Command | What it does |
|---|---|
| `purgedbat.bat` | Both sets in order, with gating. Pauses at the end. |
| `purgedbat.bat /q` | Same, no pause — for Task Scheduler. |

This is the form to schedule. Every set is gated: a failed backup skips that object's
id extract and delete entirely, and if the id extract returns 0 rows the delete is
skipped and that is **not** treated as a failure.

Before anything is queried, a pre-flight checks that every bean id exists, that it
carries the operation the chain expects, that every extract has a readable query, and
that **each delete reads back the exact file its own id extract writes**. If any of
that fails, nothing is extracted and nothing is deleted.

---

## Where the output goes

| What | Where |
|---|---|
| Extracted CSVs | `Automated Purger\Source Data\Extracted Cases\` and `...\Extracted Tasks\` |
| Case results | `Automated Purger\Load Result\Case Deletion\successExportCase<stamp>.csv` and `errorExportCase<stamp>.csv` |
| Task results | `Automated Purger\Load Result\Task Deletion\successtask<stamp>.csv` and `errortask<stamp>.csv` |
| Consumed CSVs | `PurgedExtracts\Archive_AutoPurgedExtracts_<MMDDYYYY HMM>\` — one folder shared by the whole run |
| Log | `Automated Purger\Log\purgedbat.log`, plus `<BeanId>.log` and `<BeanId>.soql` per job |

The result filenames come from `process.outputSuccess` and `process.outputError` in
the bean, with the run's timestamp appended. Data Loader used to overwrite
`successExportCase.csv` every night; it no longer does, so previous runs survive.

Exit codes: **0** everything deleted cleanly · **2** completed but some rows failed ·
**1** a set was stopped or a job hard-errored.

---

## Messages you may hit, and what they mean

| Message | Meaning |
|---|---|
| `sfdc.entity missing (bean id '<name>' not found in ...)` | Typo in the bean id. They are case-insensitive but must otherwise match the tables above exactly. |
| `Purge pre-flight failed - NOTHING was extracted and NOTHING was deleted` | A bean id, an operation, a query or an id/delete path pairing is wrong. Nothing ran. |
| `<set> STOPPED - a backup extract failed ...` | That object's id extract and delete were both skipped. Nothing was deleted for it. The other set still ran. |
| `0 rows matched, so there is nothing to delete - delete skipped` | Normal and not a failure. No rows are old enough to purge. |
| `Id CSV not found: <path>` | You ran a delete without running its id extract first. |
| `Row count mismatch - ... NOTHING was deleted` | The prepared file didn't match the source row for row. Usually a `0x1A` (Ctrl-Z) or other control character. Nothing was sent to Salesforce. |
| `Columns in the id CSV are not in the SDL: ...` | The id file is not what the bean expects. Map every column, or remove `process.mappingFile` from the bean so the header is used as-is. |
| `sf reported success but <path> is empty - not even a header row` | The CLI produced nothing at all. Treated as a hard error, because 0 rows would still write a header — the downstream delete must not guess which happened. |
| `Token request failed - the response carried no access_token` | Check `clientId` / `clientSecret` in `clientcreds.json`, and that the External Client App has the client-credentials flow enabled with a run-as user. |
| `Refusing to guess which org to DELETE from` | No `clientcreds.json` and no alias. It will not fall back to whichever org the sf CLI happens to remember. |
| `no result files for job <id> ... probably STILL RUNNING` | The job outlived the 60-minute wait. **Do not re-run it** — it may be deleting right now. Chase it with `sf data delete resume --job-id <id>`. |
| `powershell.exe not found at ...` | Needed to read the queries out of the bean. Nothing can run without it. |
| `The system cannot find the batch label specified` | The line endings. See the CRLF note at the top. |

---

## The screen going quiet is normal

While a query or a delete is running, the console prints **nothing**. Both of the
CLI's output streams are redirected to files, so there is no progress to show — the
job is running server-side in Salesforce. The script waits up to **60 minutes**.

The three Case backups are the slowest thing here, because each one pulls over 250
fields. Every extract and delete prints a notice before it starts. To confirm it is
alive, open a second Command Prompt:

```
dir "C:\NLG\Automated Purger\Source Data\Extracted Cases\BuyingCustomerCaseBackup.csv"
```

A growing file means results are downloading. For a delete, Setup > Bulk Data Load
Jobs shows the job's progress.

**Do not press Ctrl-C. A quiet screen is not a hang.** Ctrl-C kills the CLI
mid-download, which leaves a part-written file and a non-zero exit code — the run is
then reported as FAILED for what was actually a healthy query. On a Case backup that
incomplete file is also what gates the Case delete, so the whole set has to be re-run.

---

## Before the first run in a new org

Everything the bean asserts about schema is per-org. Check these there first:

1. **Every field in every backup query still exists.** The Case queries name over 250
   fields each, and the Bulk API reports only the *first* bad name per run — so one
   missing field costs one run per missing field if you fix them one at a time. Check
   them all at once with `sf sobject describe -s Case -o <alias> --json`.
2. **The three Case record type names** — `Buying Customer`, `Selling Customer`,
   `Conservation Case`. A renamed record type does **not** error. The backup silently
   returns 0 rows, `csvExportIdCases` returns 0 too, and the run reports a clean
   "nothing to purge" for an object that is full of rows.
3. **The run-as user can delete Case and Task.** No delete permission means every row
   comes back in the error CSV.
