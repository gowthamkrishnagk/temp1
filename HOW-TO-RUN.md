# Running one object / one operation

The batch file can run **the whole chain** or **a single named job**. To act on one
object with one operation, you pass that job's **bean id** as the only argument:

```
run-UATLoad.bat <BeanId>
```

That is the whole command. The bean id decides the object, the operation, the source
CSV and the field mapping — all of it comes from `Config\process-conf.xml`, not from
the command line. Nothing else needs to be edited to run a single job.

Look your job up in the tables below, then run it.

---

## Before the first run

| Thing | Where | Notes |
|---|---|---|
| Which org it hits | `C:\NLG\Config\clientcreds.json`, the `org` key | **This is the only file you edit to move between orgs.** Beans and SDLs are org-independent. |
| Bean definitions | `C:\NLG\Config\process-conf.xml` | Repo copy of this file is `uat-bean`. |
| The script | `C:\NLG\run-UATLoad.bat` | Repo copy of this file is `UAT-Bat`. |
| Root folder | `C:\NLG` | Override with the `NLG_ROOT` environment variable if your install is elsewhere. |

Open a normal Command Prompt in the folder holding the batch file, or just
double-click it. Everything runs in that one window.

---

## Load data into an object (upsert)

These read a CSV you supply and upsert it into Salesforce. Put your file at the
path shown, then run the command.

| Object | Bean id — use this as the argument | Matched on | Source CSV you must supply |
|---|---|---|---|
| Account | `AgencyUpsert` | `Master_Agency_ID__c` | `Source Data\Agency\Agency.csv` |
| Contact | `AgentActiveUpsert` | `Master_Agent_ID__c` | `Source Data\Agent\Agent-Active.csv` |
| Contact | `AgentTerminatedUpsert` | `Master_Agent_ID__c` | `Source Data\Agent\Agent-Terminated.csv` |
| Agent_Number__c | `AgentNumberUpsert` | `Agent_Number__c` | `Source Data\AgentNumber\AgentNumber.csv` |
| Contact | `AgentSalesUpsert` | `Master_Agent_ID__c` | `Source Data\AgentSales\Agentsalesdatasalesforce.csv` |
| NLG_OBJ_AnnuityProductMix__c | `AnnuityProductMixUpsert` | `Master_ID__c` | `Source Data\AnnuityProductMix\AnnuityProductMix.csv` |
| Contact | `ApdContactUpsert` | `Global_ID__c` | `Source Data\APD\Apd_Contacts.csv` |
| LSW_Annuity_Hierarchy__c | `LswAnnuityHierarchyUpsert` | `Master_ID__c` | `Source Data\LSWAnnuityHierarchy\LSWAnnuityHierarchy.csv` |
| LSW_Life_Hierarchy__c | `LswLifeHierarchyUpsert` | `Master_ID__c` | `Source Data\LSWLifeHierarchy\LSWLifeHierarchy.csv` |
| NLG_OBJ_LifeProductMix__c | `LifeProductMixUpsert` | `Master_ID__c` | `Source Data\LifeProductMix\LifeProductMix.csv` |
| NL_Product_Hierarchy__c | `NlProductHierarchyUpsert` | `Master_ID__c` | `Source Data\NLProductHierarchy\NLProductHierarchy.csv` |
| Lead | `LeadUpsert` | `SSN_Tax_ID__c` | `Source Data\Lead\Lead.csv` |

Example — load agencies only:

```
run-UATLoad.bat AgencyUpsert
```

Running a single job like this does **no chaining**. Nothing before or after it
runs, and none of the normal gating applies. That is the point of it: use it to
retry one job after fixing its error CSV.

> **`GroupUpsert` exists in the bean file but is not part of the chain and is
> expected to fail.** `Account.Group_Number__c` has neither External ID nor Unique
> set, so Salesforce rejects the job before reading a row. It is a field
> *attribute* problem and cannot be fixed from this script. Don't run it until
> someone flags that field in the org.

---

## Extract rows out of an object

These run the bean's SOQL and write a CSV. They never change anything in the org,
so they are safe to run on their own at any time.

| Object | Bean id | Writes |
|---|---|---|
| Lead | `LeadToDeleteExtract` | `Source Data\Extracted Leads\LeadToBeDeleted.csv` |
| LoginHistoryExt__c | `LoginHistoryExtBackupExtract` | `...\Extracted LoginHistoryExt\LoginHistoryExtAll.csv` |
| LoginHistoryExt__c | `LoginHistoryExtIdExtract` | `...\Extracted LoginHistoryExt\LoginHistoryExtIds.csv` |
| IntegrationLog__c | `IntegrationLogBackupExtract` | `...\Extracted Integration Log\IntegrationLogAll.csv` |
| IntegrationLog__c | `IntegrationLogIdExtract` | `...\Extracted Integration Log\IntegrationLogIds.csv` |
| IntegrationErrorRecordLog__c | `IntegrationErrorRecordLogBackupExtract` | `...\IntegrationErrorRecordLogAll.csv` |
| IntegrationErrorRecordLog__c | `IntegrationErrorRecordLogIdExtract` | `...\IntegrationErrorRecordLogIds.csv` |
| MC4SF__MC_Campaign_Hourly_Stats__c | `MCCampaignHourlyStatBackupExtract` | `...\Extracted MC Campaign Hourly Stats\MCCampaignHourlyStatAll.csv` |
| MC4SF__MC_Campaign_Hourly_Stats__c | `MCCampaignHourlyStatIdExtract` | `...\Extracted MC Campaign Hourly Stats\MCCampaignHourlyStatIds.csv` |
| Task | `TaskBackupExtract` | `Source Data\Task\TasksAll.csv` |
| Task | `TaskIdExtract` | `Source Data\Task\taskIds.csv` |
| Task (auto-created) | `AutoTaskBackupExtract` | `...\Extracted Task\AutoTaskallfield.csv` |
| Task (auto-created) | `AutoTaskIdExtract` | `...\Extracted Task\AutoTaskIds.csv` |

Example — pull the Task ids without deleting anything:

```
run-UATLoad.bat TaskIdExtract
```

A `Backup` extract pulls **all fields** — that is your restore copy. An `Id` extract
pulls just the ids of the rows to be removed, and that is the file the matching
delete consumes.

---

## Delete rows from an object

| Object | Bean id | Reads the ids from |
|---|---|---|
| Lead | `LeadDelete` | `Source Data\Extracted Leads\LeadToBeDeleted.csv` |
| LoginHistoryExt__c | `LoginHistoryExtDelete` | `...\Extracted LoginHistoryExt\LoginHistoryExtIds.csv` |
| IntegrationLog__c | `IntegrationLogDelete` | `...\Extracted Integration Log\IntegrationLogIds.csv` |
| MC4SF__MC_Campaign_Hourly_Stats__c | `MCCampaignHourlyStatDelete` | `...\MCCampaignHourlyStatIds.csv` |
| Task | `TaskDelete` | `Source Data\Task\TaskIds.csv` |
| Task (auto-created) | `AutoTaskDelete` | `...\Extracted Task\AutoTaskIds.csv` |

**`IntegrationErrorRecordLog__c` has no delete bean.** It is extract-only, by
design — its rows stay in the org.

### Deleting one object on its own — run two commands, in this order

A delete bean does not query anything. It deletes exactly the ids sitting in its
CSV, so that CSV has to be freshly written first:

```
run-UATLoad.bat TaskIdExtract      REM 1. writes the ids
run-UATLoad.bat TaskDelete         REM 2. deletes exactly those ids
```

Want a full-field backup before you delete? Run the backup extract first:

```
run-UATLoad.bat TaskBackupExtract
run-UATLoad.bat TaskIdExtract
run-UATLoad.bat TaskDelete
```

The id CSV is **moved into the run's Archive folder as the delete consumes it**.
That is deliberate: a stale id file from an older run cannot be picked up and
deleted from a second time. It also means step 2 fails with "source CSV not found"
if you skip step 1 — which is the safe way for it to fail.

---

## Running everything instead of one job

| Command | What it does |
|---|---|
| `run-UATLoad.bat` | All twelve load jobs in order, with gating. Pauses at the end. |
| `run-UATLoad.bat /q` | Same, no pause — for Task Scheduler. |
| `run-UATLoad.bat /purge` | The retention purge chain only (7 sets: backup → ids → delete). Pauses at the end. |
| `run-UATLoad.bat /purge /q` | Same, no pause. |

The load chain and the purge chain are kept apart on purpose: one writes rows, the
other deletes them.

In the purge chain every set is gated — if a backup extract fails, that object's id
extract and delete are both skipped and **nothing is deleted for it**. If the id
extract returns 0 rows, the delete is skipped and that is not treated as a failure.

---

## Where the output goes

| What | Where |
|---|---|
| Per-row results | `Load Result\<Object>\success<stamp>.csv` and `error<stamp>.csv` |
| Consumed source CSVs | `Archive\Archive_<stamp>\` — one folder shared by the whole run |
| Log | `Log\run-UATLoad.log`, plus `Log\<BeanId>.log` per job |

Exit codes: **0** all rows loaded · **2** completed but some rows failed · **1** a
job hard-errored or a set was stopped.

---

## Messages you may hit, and what they mean

| Message | Meaning |
|---|---|
| `sfdc.entity missing (bean id '<name>' not found in ...process-conf.xml?)` | Typo in the bean id. They are case-insensitive but must otherwise match the tables above exactly. |
| `Source CSV not found: <path>` | For a load, your file isn't at the path the bean names. For a delete, you skipped the id extract. |
| `Row count mismatch - ... NOTHING was loaded` | The prepared file didn't match the source row for row. Usually a `0x1A` (Ctrl-Z) or other control character in the CSV. Clean the source and re-run. Nothing was sent to Salesforce. |
| `CSV contains a double quote, so unmapped columns cannot be dropped safely` | A column is missing from the SDL *and* the CSV has quoted fields. Either map every column in the SDL, or pre-trim the CSV. |
| `Unmapped columns dropped: ...` then `Rebuilding rows...` | Normal. Columns not in the SDL are being removed before the load. Takes a second or two even on large files. |
| `powershell.exe not found at ...` | Only ever appears on the drop-unmapped-columns path. Map every column in the SDL to avoid the rebuild entirely. |
| `Field name provided, Group_Number__c does not match an External ID...` | The known `GroupUpsert` problem — see the note above. |

**Do not press Ctrl-C while a file is being prepared.** Answering "N" to
*Terminate batch job?* resumes the script with a half-built input file. The
row-count guard is what stops that reaching Salesforce, but don't rely on it.
