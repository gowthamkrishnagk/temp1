@echo off
setlocal EnableExtensions DisableDelayedExpansion
REM ===============================================================
REM  run-UATLoad.bat - self-contained chained load, TARGET = UAT:
REM    Agency -> Agent (active, terminated) -> Agent Number -> Agent Sales
REM           -> Annuity Product Mix -> APD Contacts -> LSW Annuity Hierarchy
REM           -> LSW Life Hierarchy -> Life Product Mix -> NL Product Hierarchy
REM    then, independent of all of the above:  Leads
REM  Everything in one file. No other script is called.
REM
REM  Reads a Data Loader bean (process-conf.xml) + SDL mapping, gets an
REM  OAuth client-credentials token with curl.exe, runs the load via sf CLI.
REM
REM ===============================================================
REM  v14 - RETARGETED AT UAT, GROUP JOB REMOVED
REM ===============================================================
REM  TWELVE jobs. GroupUpsert (v13) is GONE - not the bat, not the bean list,
REM  not the pre-flight. Account.Group_Number__c has neither External ID nor
REM  Unique set in dev3 OR prod, so Salesforce rejects the job before reading a
REM  row (InvalidJob : Field name provided, Group_Number__c does not match an
REM  External ID, Salesforce Id, or indexed field for Account). It is a field
REM  ATTRIBUTE problem, not a load problem, and it is unfixable from here - so
REM  the job is out until someone flags that field. Nothing else was touched.
REM
REM  MOVING BETWEEN ORGS - ONE FILE CHANGES
REM  Config\clientcreds.json only: domain, clientId, clientSecret, org.
REM  The "org" value IS the alias every sf command in this script uses.
REM    - the BEANS do not change. They carry no org information at all.
REM    - the SDLs do not change.
REM    - the folder structure does not change.
REM  So a UAT run is: point clientcreds.json at UAT, drop the CSVs in, run.
REM
REM  BUT RE-VERIFY THE ORG-SPECIFIC ASSUMPTIONS IN UAT. Everything the beans
REM  assert about schema is per-org, and the Group failure is exactly what that
REM  class of problem looks like. Before the first UAT run, check in UAT:
REM
REM    1. every sfdc.entity exists            (some are ASSUMPTIONS - see the
REM       sf sobject list -s custom -o <alias>    JOB 9/10/11 notes below)
REM    2. every sfdc.externalIdField is flagged External ID or Unique. This is
REM       the one that just cost a run. idLookup is the property that decides:
REM       sf sobject describe -s <Object> -o <alias> --json | ConvertFrom-Json |
REM         ForEach-Object { $_.result.fields } |
REM         Where-Object { $_.externalId -or $_.idLookup } |
REM         Select-Object name, type, externalId, idLookup, unique
REM    3. every "__r." relationship name in every SDL. This chain already uses
REM       two different ones - Contact_ID__r and Contact__r - so do not assume.
REM    4. every SDL right-hand api name exists on its object. Bulk API reports
REM       only the FIRST bad name per run, so check them all at once.
REM
REM  A UAT org is not a copy of dev3. Any of the four can differ.
REM
REM  Usage:  run-UATLoad.bat
REM             runs all twelve jobs in order, pauses at the end.
REM          run-UATLoad.bat /q
REM             same, no pause - for Task Scheduler.
REM          run-UATLoad.bat AgencyUpsert
REM             runs one named bean only, no chaining. Use this to retry
REM             AgentNumberUpsert, AgentSalesUpsert, AnnuityProductMixUpsert
REM             ApdContactUpsert, LswAnnuityHierarchyUpsert, LswLifeHierarchyUpsert,
REM             LifeProductMixUpsert, NlProductHierarchyUpsert or LeadUpsert
REM             on its own after fixing an error CSV.
REM
REM  Flow per job:
REM    Source CSV (Source Data\<Object>\file.csv)
REM      -> results into  Load Result\<Object>\  as
REM         success<MMddyyHHmmssfff>.csv / error<MMddyyHHmmssfff>.csv
REM      -> source CSV moved into the run's single archive folder,
REM         Archive\Archive_<MMdd yyyyHmmss>\   (shared by all twelve jobs)
REM
REM  Source CSV paths are NOT hardcoded here - each job takes its path from
REM  dataAccess.name in its own bean, so the bean is the single place a
REM  filename is defined.
REM
REM  Gating:
REM    Agency hard error (1) -> stop, agent jobs do not run.
REM    Agency partial   (2)  -> stop. An agent whose agency row failed
REM                             cannot resolve its parent. ALLOW_PARTIAL=1
REM                             overrides.
REM    Agent hard error (1)  -> stop; nothing after it runs.
REM    Agent partial    (2)  -> the two agent FILES are independent of each
REM                             other, so job 3 still runs - but jobs 4, 5, 6,
REM                             7, 8, 9, 10 AND 11 are STOPPED. All eight need them:
REM                             job 4 resolves them through
REM                             Agent__r.Master_Agent_ID__c and gets
REM                             "Foreign key external ID ... not found";
REM                             job 5 upserts ON Master_Agent_ID__c and would
REM                             CREATE half-populated Contacts instead;
REM                             job 6 resolves them through
REM                             Contact_ID__r.Master_Agent_ID__c - the same
REM                             foreign-key failure as job 4.
REM                             job 7 upserts ON Contact too - on Global_ID__c
REM                             rather than Master_Agent_ID__c, but with the
REM                             same orphan-creating consequence as job 5.
REM                             ALLOW_PARTIAL=1 overrides this too.
REM    Agent Number partial  -> reported; jobs 5, 6 and 7 still run, none of
REM                             them depends on job 4.
REM    Agent Sales partial   -> reported; jobs 6 and 7 still run. Job 6 writes
REM                             to a different object; job 7 writes to Contact
REM                             but on its own set of fields, and a Contact
REM                             that failed job 5 already exists.
REM    Product Mix partial   -> reported; job 7 still runs, unrelated object.
REM    APD partial           -> reported; jobs 8 and 9 still run.
REM    LSW Annuity partial   -> reported; jobs 9 and 10 still run.
REM    LSW Life partial      -> reported; jobs 10 and 11 still run.
REM    Life Product Mix partial -> reported; jobs 11 and 12 still run.
REM    NL Product Hierarchy partial -> reported; job 12 still runs.
REM    Lead partial          -> reported, nothing downstream to gate.
REM
REM  JOB 12 (Lead) HAS NO DATA DEPENDENCY ON ANYTHING ABOVE IT. Every other job either
REM  resolves Contact or upserts onto it, so a failed agent row matters to all
REM  of them. Lead references neither Agency, Contact nor any agent id, so an
REM  agent problem has no bearing on whether a Lead row can load. That is why
REM  it is not added to the AGENTPARTIAL condition.
REM
REM  BUT BE CLEAR ABOUT WHAT THAT DOES AND DOES NOT MEAN. Every stop in this
REM  script - a hard error at any step, AND the AGENTPARTIAL gate - ends the
REM  whole run through :fatal. So in practice an upstream problem does prevent
REM  job 12 from being reached, not because Lead depends on anything, but
REM  because the chain stops. Load the Leads on their own in that case:
REM    run-UATLoad.bat LeadUpsert
REM
REM  If you would rather Leads ALWAYS load regardless of the agent chain, the
REM  clean fix is to move this job to the FRONT (make it JOB1 and renumber) -
REM  it has no parent, so nothing is lost by loading it first. That is a
REM  deliberate change, not done here.
REM
REM  JOB 4 - AgentNumberUpsert (added v4, 2026-08-29):
REM    Loads the Agent_Number__c custom object, after the agents because its
REM    Agent__c lookup is resolved by external id at load time, so the
REM    Contact must already exist. Only that one column has to pre-exist in
REM    the org - Master_Agency_Number__c / Agency_Number__c are plain text
REM    and are not validated against anything.
REM
REM  JOB 5 - AgentSalesUpsert (added v5, 2026-08-31):
REM    Sales data onto the AGENT itself: entity Contact, external id
REM    Master_Agent_ID__c - the SAME key as jobs 2 and 3. So this is an
REM    upsert INTO existing agent records, and that is the thing to watch:
REM    upsert does not fail on a "missing parent" here, it CREATES a new
REM    Contact when the key is not found. That new record has no LastName,
REM    so it fails with REQUIRED_FIELD_MISSING - or worse, if the sales file
REM    happens to carry a name column, it silently creates a half-populated
REM    duplicate agent. Hence the same gate as job 4: any agent job at
REM    partial stops it.
REM    Runs before job 6 only because it is independent of it; the two could
REM    be swapped without consequence.
REM
REM  JOB 6 - AnnuityProductMixUpsert (added v6, 2026-08-31):
REM    Annuity product mix onto its own child object,
REM    NLG_OBJ_AnnuityProductMix__c, linked to the agent through the lookup
REM    Contact_ID__c and resolved at load time by
REM      Contact_ID__r.Master_Agent_ID__c
REM
REM    IMPORTANT - this is the SAFE direction, unlike job 5. The agent id here
REM    is a foreign key on a CHILD object, not the upsert key on Contact. So an
REM    id that does not exist in the org cannot create anything; the row simply
REM    FAILS with
REM      INVALID_FIELD: Foreign key external ID: 71 not found for field
REM      Master_Agent_ID__c in entity Contact
REM    Nothing gets corrupted. The risk is only a wasted run in which most rows
REM    fail, so count the overlap BEFORE loading:
REM      sf data query -o <alias> --bulk --wait 10 -r csv
REM         -q "SELECT Master_Agent_ID__c FROM Contact
REM             WHERE Master_Agent_ID__c != null"  redirected to dev3-agent-ids.csv
REM      prep-AnnuityProductMix.ps1 -In the.csv -DevIds dev3-agent-ids.csv
REM    and want "NOT IN ORG : 0".
REM
REM    A BLANK agent id is NOT an error if Contact_ID__c is a nillable lookup -
REM    the row loads with an empty lookup. If it is master-detail or required it
REM    is REQUIRED_FIELD_MISSING. Confirm which:
REM      sf sobject describe -s NLG_OBJ_AnnuityProductMix__c -o <alias>
REM
REM    Master_ID__c is DERIVED, not independent data:
REM      <agent id padded left with '0' to 15 chars> + ' ' + Product_Name__c
REM      71 + PARA 5  ->  000000000000071 PARA 5
REM    If the agent id column is ever re-pointed at different agents,
REM    Master_ID__c must be regenerated or it still encodes the OLD producer -
REM    and since it is the upsert key, stale values upsert onto the wrong
REM    record. fill-MasterId.ps1 rebuilds the column.
REM
REM  JOB 7 - ApdContactUpsert (added v7, 2026-08-31):
REM    APD data onto the AGENT itself: entity Contact, external id
REM    Global_ID__c, source Source Data\APD\Apd_Contacts.csv, mapping
REM    Config\APDMapping.sdl.
REM
REM    THIS IS THE DANGEROUS SHAPE, NOT THE SAFE ONE. Like job 5 and unlike
REM    job 6, the id here is the UPSERT KEY on Contact itself, so an id that
REM    is not already in the org does not fail - upsert INSERTS. You get
REM    either
REM      REQUIRED_FIELD_MISSING: LastName        (visible in the error CSV)
REM    or, if Apd_Contacts.csv carries a name column, a half-populated
REM    duplicate agent that no agency owns, while the job reports SUCCESS.
REM    The second one is the one to fear: it is silent.
REM
REM    AND IT KEYS ON A DIFFERENT FIELD FROM EVERY OTHER JOB. Jobs 2, 3 and 5
REM    upsert Contact on Master_Agent_ID__c. This one uses Global_ID__c, and
REM    NOTHING in this chain populates Global_ID__c. So if the agents in dev3
REM    do not already carry one, every APD row matches nothing and inserts a
REM    new Contact - not one orphan, all of them. Check before running:
REM      sf data query -o <alias>
REM         -q "SELECT COUNT() FROM Contact WHERE Global_ID__c != null"
REM    0 means DO NOT RUN. Either the agent extract must populate Global_ID__c
REM    first, or APD must key on Master_Agent_ID__c instead.
REM
REM    Then count the overlap - against Global_ID__c, NOT Master_Agent_ID__c,
REM    so the dev3-agent-ids.csv used for jobs 5 and 6 is the WRONG list here:
REM      sf data query -o <alias> --bulk --wait 10 -r csv
REM         -q "SELECT Global_ID__c FROM Contact
REM             WHERE Global_ID__c != null"  redirected to a csv
REM    then check how many of the APD file's global ids are absent from it.
REM    Filter or load the missing agents first - do not let the upsert invent
REM    Contacts. The AGENTPARTIAL gate below cannot help with this: it only
REM    stops agents that failed THIS run, not agents that were never in the
REM    extract at all.
REM
REM    Runs last only because nothing depends on it. It could equally run
REM    right after job 3, which would arguably be better: it writes Contact
REM    fields, so doing it before the child objects means jobs 4 and 6 resolve
REM    against a fully populated agent. Moving it is a JOBn renumber, nothing
REM    more - the gate would then have to move with it.
REM
REM  JOB 8 - LswAnnuityHierarchyUpsert (added v9, 2026-09-01):
REM    Annuity hierarchy on its own object, LSW_Annuity_Hierarchy__c, source
REM    Source Data\LSWAnnuityHierarchy\LSWAnnuityHierarchy.csv, mapping
REM    Config\LSWAnnuityMapping.sdl.
REM
REM    TWO FIELDS, OPPOSITE RULES. This trips people up, so be clear:
REM
REM      Master_ID__c                     the UPSERT KEY on this object.
REM                                       Does NOT need to pre-exist. A value
REM                                       that matches updates that hierarchy
REM                                       row; a new value INSERTS one. A file
REM                                       mixing both is normal.
REM      Contact__r.Master_Agent_ID__c     a FOREIGN KEY to Contact. MUST
REM                                       already exist, or the row FAILS with
REM                                         INVALID_FIELD: Foreign key external
REM                                         ID: 71 not found for field
REM                                         Master_Agent_ID__c in entity Contact
REM
REM    The general rule for every job in this chain: if the SDL right-hand side
REM    contains "__r." it is a foreign key and the value must already be in the
REM    org. A plain "__c" with no dot is ordinary data and is not validated.
REM
REM    SAFE DIRECTION, like job 6 and unlike jobs 5 and 7. The agent id here is
REM    a foreign key on a child object, not an upsert key on Contact, so an
REM    unknown agent CANNOT create a junk Contact. It only fails that row. The
REM    cost of getting it wrong is a wasted run, not bad data. Count first:
REM      prep-AnnuityProductMix.ps1 -In LSWAnnuityHierarchy.csv
REM         -DevIds dev3-agent-ids.csv -FkColumn Contact__r.Master_Agent_ID__c
REM    and want "NOT IN ORG : 0".
REM
REM    NOT RELATED TO JOB 4, despite looking similar. Job 4's SDL has
REM      Global_Agent_ID=Agent__r.Master_Agent_ID__c
REM    and this file has Contact__r.Master_Agent_ID__c. Different objects,
REM    different lookup FIELDS (Agent__c vs Contact__c), hence different
REM    relationship names left of the dot - but the SAME target right of the
REM    dot, Contact.Master_Agent_ID__c. So one dev3-agent-ids.csv serves both,
REM    and there is NO requirement to reuse only the agent ids that appeared in
REM    AgentNumber.csv. Job 4 did not create agents; jobs 2 and 3 did.
REM
REM    STILL TO CONFIRM, both assumptions:
REM      - Master_ID__c is flagged External Id on this object (upsert needs it)
REM      - the relationship name really is Contact__r
REM          sf sobject describe -s LSW_Annuity_Hierarchy__c -o <alias>
REM    A wrong relationship name means "Field name not found" and ZERO rows
REM    load. Also do not assume this Master_ID__c follows the AnnuityProductMix
REM    recipe; check with fill-MasterId.ps1 -Check before touching it.
REM
REM  JOB 9 - LswLifeHierarchyUpsert (added v10, 2026-09-01):
REM    Life hierarchy on its own object, source
REM    Source Data\LSWLifeHierarchy\LSWLifeHierarchy.csv, mapping
REM    Config\LSWLifeMapping.sdl, external id Master_ID__c.
REM
REM    The twin of job 8. Everything said there applies here - same two-fields-
REM    opposite-rules shape:
REM      Master_ID__c   the UPSERT KEY on this object. Does NOT need to
REM                     pre-exist; a new value INSERTS, a matching value
REM                     UPDATES. A mixed file is normal.
REM      any "__r." column in LSWLifeMapping.sdl is a FOREIGN KEY and its
REM                     value MUST already be in the org, or the row fails.
REM
REM    SAFE DIRECTION, like jobs 6 and 8. The agent id is a foreign key on a
REM    child object, not an upsert key on Contact, so an unknown agent cannot
REM    create a junk Contact - it only fails that row. Cost of getting it wrong
REM    is a wasted run, not bad data. If the SDL maps an agent id, count first:
REM      prep-AnnuityProductMix.ps1 -In LSWLifeHierarchy.csv
REM         -DevIds dev3-agent-ids.csv -FkColumn <the __r. column>
REM
REM    THE OBJECT API NAME IS AN ASSUMPTION. The bean says
REM    LSW_Life_Hierarchy__c, chosen by analogy with LSW_Annuity_Hierarchy__c,
REM    because it was never stated. If it is wrong the job fails immediately
REM    with an invalid sObject type and loads nothing. Confirm with:
REM      sf sobject list -s custom -o <alias> | findstr /i "hierarchy"
REM
REM    Also unconfirmed: that Master_ID__c is flagged External Id on THIS
REM    object. Job 8's flag says nothing about job 9's - they are two objects.
REM
REM  JOB 10 - LifeProductMixUpsert (added v11, 2026-09-01):
REM    Life product mix on its own child object, source
REM    Source Data\LifeProductMix\LifeProductMix.csv, mapping
REM    Config\LifeProductMixMapping.sdl, external id Master_ID__c.
REM
REM    The LIFE counterpart of job 6's annuity product mix, and the same shape
REM    in every respect that matters:
REM
REM      Master_ID__c   the UPSERT KEY on this object. Does NOT need to
REM                     pre-exist - a new value INSERTS, a matching value
REM                     UPDATES. A mixed file is normal.
REM      the Contact lookup column ("__r." in the SDL) is a FOREIGN KEY and its
REM                     value MUST already be in the org, or that row FAILS with
REM                       INVALID_FIELD: Foreign key external ID: 71 not found
REM                       for field Master_Agent_ID__c in entity Contact
REM
REM    SAFE DIRECTION, like jobs 6, 8 and 9. The agent id is a foreign key on a
REM    child object, not an upsert key on Contact, so an unknown agent cannot
REM    create a junk Contact - it only fails that row. Count the overlap first
REM    so a run is not wasted:
REM      prep-AnnuityProductMix.ps1 -In LifeProductMix.csv
REM         -DevIds dev3-agent-ids.csv -FkColumn <the __r. column>
REM    and want "NOT IN ORG : 0".
REM
REM    Master_ID__c IS PROBABLY DERIVED here as it is on AnnuityProductMix:
REM      <agent id padded left to 15 with '0'> + ' ' + Product_Name__c
REM    If the extract's Master_ID__c encodes a DIFFERENT id from its agent id
REM    column, it must be rebuilt or it upserts onto the wrong record:
REM      rebuild-MasterId.ps1        (asks for the path, keeps a .bak)
REM    Confirm the width from the data first with fill-MasterId.ps1 -Check.
REM
REM    THE OBJECT API NAME IS AN ASSUMPTION. The bean says
REM    NLG_OBJ_LifeProductMix__c, by analogy with NLG_OBJ_AnnuityProductMix__c,
REM    because it was never stated. Wrong name = invalid sObject type and
REM    nothing loads. Confirm with:
REM      sf sobject list -s custom -o <alias> | findstr /i "productmix"
REM
REM  JOB 11 - NlProductHierarchyUpsert (added v12, 2026-09-01):
REM    NL product hierarchy on its own child object, source
REM    Source Data\NLProductHierarchy\NLProductHierarchy.csv, mapping
REM    Config\NLProductHierarchyMapping.sdl.
REM
REM    TWO THINGS HERE ARE GUESSES - both were never stated:
REM
REM      sfdc.entity          = NL_Product_Hierarchy__c
REM      sfdc.externalIdField = Master_ID__c
REM
REM    The entity follows the LSW_Annuity_Hierarchy__c / LSW_Life_Hierarchy__c
REM    naming; the external id follows every other hierarchy and product-mix
REM    object in this chain. Both fail LOUDLY if wrong - an invalid sObject type
REM    or a rejected upsert, nothing loads, nothing is corrupted - but that is
REM    still a wasted round trip. Confirm both before the first run:
REM      sf sobject list -s custom -o <alias> | findstr /i "hierarchy"
REM      sf sobject describe -s NL_Product_Hierarchy__c -o <alias>
REM
REM    SAME TWO-FIELD SHAPE as jobs 6, 8, 9 and 10:
REM      Master_ID__c   the UPSERT KEY on this object. Does NOT need to
REM                     pre-exist - a new value INSERTS, a match UPDATES.
REM      any "__r." column in the SDL is a FOREIGN KEY and its value MUST
REM                     already be in the org, or that row FAILS.
REM
REM    SAFE DIRECTION. The agent id is a foreign key on a child object, not an
REM    upsert key on Contact, so an unknown agent cannot create a junk Contact -
REM    it only fails that row. Count the overlap first so a run is not wasted:
REM      prep-AnnuityProductMix.ps1 -In NLProductHierarchy.csv
REM         -DevIds dev3-agent-ids.csv -FkColumn <the __r. column>
REM    and want "NOT IN ORG : 0".
REM
REM    If this file's Master_ID__c is a composite whose number does NOT match
REM    the agent id in the same row, it must be rebuilt or it upserts onto the
REM    wrong record - that already happened on the AnnuityProductMix extract:
REM      fill-MasterId.ps1 -In NLProductHierarchy.csv -Check
REM      rebuild-MasterId.ps1
REM
REM  JOB 12 - LeadUpsert (added v8 as job 8, renumbered to 12 in v12):
REM    Leads: entity Lead, external id SSN_Tax_ID__c, source
REM    Source Data\Lead\Lead.csv, mapping Config\LeadMapping.sdl.
REM
REM    Standalone. Lead does not reference Agency, Contact or any agent id, so
REM    this job has no parent and no gate beyond the chain-wide hard-error
REM    stop. Unlike jobs 5 and 7, an unmatched key here is not a problem - it
REM    is the point. Upsert inserts a Lead that did not exist, which is what
REM    loading leads means.
REM
REM    LEAD HAS REQUIRED FIELDS, and the SDL must cover them or every row
REM    fails REQUIRED_FIELD_MISSING:
REM      LastName   required
REM      Company    required (Salesforce enforces it on Lead, not on Contact -
REM                 this is the one that catches people migrating contact-
REM                 shaped data into Lead)
REM      Status     required, but the org default usually satisfies it
REM
REM    SSN_Tax_ID__c IS THE UPSERT KEY, so:
REM      - it must be flagged External Id on Lead, or upsert is rejected
REM          sf sobject describe -s Lead -o <alias>
REM      - a duplicate SSN in the file means the LAST row silently wins. Bulk
REM        API does not warn. De-duplicate the CSV first if that matters.
REM      - a BLANK SSN cannot match anything and cannot be inserted against a
REM        null external id - those rows fail. Filter them out.
REM
REM    PII: SSN_Tax_ID__c is a social security / tax number going into a
REM    SANDBOX. Sandboxes are routinely refreshed, cloned and opened to more
REM    people than production. If Lead.csv came from prod, mask it before
REM    loading - mask-prod-extract.ps1 on the Desktop exists for this, and the
REM    masked prod-seed plan is described in
REM    Agency-Agent-Chained-Load-Progress.md.
REM
REM    Also worth knowing: Lead ASSIGNMENT rules do not fire here. They only
REM    run when the request asks for them, and sf data upsert bulk does not.
REM    Lead DUPLICATE rules can still block rows, and they surface as ordinary
REM    row errors in the error CSV.
REM
REM  DATES, all jobs: any date column must ALREADY be ISO yyyy-MM-dd in the
REM    CSV. This script does NOT convert date formats; Bulk API 2.0 rejects
REM    M/d/yyyy with "not a valid value for the type xsd:date".
REM
REM  AUTH - ONE token per run per org alias:
REM   1) A credentials JSON (domain, clientId, clientSecret, org). Default
REM      location Config\clientcreds.json; override in the bean with
REM        <entry key="sfdc.credentialsFile" value="Config\uat.json"/>
REM      (no drive letter = relative to the NLG root). Exactly ONE OAuth
REM      round trip happens, before any job starts. "sf org login
REM      access-token -p" persists it under the alias, so all twelve jobs
REM      reuse that one login - no re-authentication between jobs.
REM      The single exception is a session that EXPIRES mid-run: that job
REM      fetches a replacement and retries itself once. That is recovery,
REM      not a routine per-job login, and it is logged as such.
REM   2) No credentials file at all. The script then uses the login the sf
REM      CLI already holds for the org alias. Name the alias with
REM        <entry key="sfdc.orgAlias" value="<alias>"/>
REM      or leave it out and DEFAULTALIAS (top of this file) is used.
REM
REM  ROW-COUNT GUARD (2026-08-27):
REM    The prepared input CSV is counted against the source before the load
REM    runs, and a mismatch is a HARD ERROR. This exists because "more +1"
REM    silently truncated a 100,000-row file to 65,535 rows and the load was
REM    reported as COMPLETED - 5,149 loaded / 60,386 failed, with 34,465 rows
REM    never sent and nothing in the log to say so. "more" stops dead at a
REM    0x1A (Ctrl-Z) byte, and dies if Ctrl-C is pressed while it is copying.
REM    The body copy now uses findstr, which does neither, and the count is
REM    verified either way. A truncated file must never reach Salesforce.
REM
REM  Exit codes:  0 = every job loaded all rows
REM               2 = a job completed but some rows FAILED
REM               1 = hard error, or a job was skipped
REM ===============================================================

REM ---------------- configuration --------------------------------
REM  Printed on screen and to the log at the top of every run, so the build
REM  actually executing is never in doubt. Two runs were diagnosed off
REM  screenshots that turned out to be an older build.
set "VERSION=v14 2026-09-02  UAT"

set "ROOT=C:\NLG"
if defined NLG_ROOT set "ROOT=%NLG_ROOT%"
set "BEAN=%ROOT%\Config\process-conf.xml"
set "ARCHIVEDIR=%ROOT%\Archive"
set "RESULTDIR=%ROOT%\Load Result"
set "LOGDIR=%ROOT%\Log"
set "CURL=%SystemRoot%\System32\curl.exe"

REM  The chain, in order. Bean ids must exist in process-conf.xml.
REM  WHICH ORG THIS RUN HITS
REM  Normally NOT this setting. The live alias is the "org" key inside
REM  Config\clientcreds.json, and that is the only file you edit to move
REM  between orgs - beans, SDLs and folder names are all org-independent.
REM  DEFAULTALIAS is a fallback used ONLY if there is no credentials file at
REM  all. Leave it EMPTY and the script refuses to run rather than guess,
REM  which is what you want when more than one org is in play.
set "DEFAULTALIAS="

set "JOB1=AgencyUpsert"
set "JOB2=AgentActiveUpsert"
set "JOB3=AgentTerminatedUpsert"
set "JOB4=AgentNumberUpsert"
set "JOB5=AgentSalesUpsert"
set "JOB6=AnnuityProductMixUpsert"
set "JOB7=ApdContactUpsert"
set "JOB8=LswAnnuityHierarchyUpsert"
set "JOB9=LswLifeHierarchyUpsert"
set "JOB10=LifeProductMixUpsert"
set "JOB11=NlProductHierarchyUpsert"
set "JOB12=LeadUpsert"

REM  Minutes to wait for a bulk job to finish. NOT a Salesforce limit - it is
REM  how long the sf CLI watches before giving up and returning. Exceeding it
REM  does not cancel the job; the job keeps running server-side, but no result
REM  files exist yet, so the run ends UNCONFIRMED / [CHECK] and you have to
REM  chase the job id by hand.
REM  100,000 Contact upserts with a parent lookup and duplicate rules active
REM  took longer than 10 minutes on dev3, which is what 10 used to cost.
set "WAITMIN=60"

REM  1 = keep going past a PARTIAL parent job. Governs both dependency gates:
REM      agency partial -> run the agent jobs anyway, and
REM      agent partial  -> run AgentNumberUpsert anyway.
REM  Leave at 0. A child row whose parent failed to load cannot resolve its
REM  external-id lookup and fails with a foreign-key error, so setting this
REM  to 1 usually converts one visible parent problem into tens of thousands
REM  of child failures.
set "ALLOW_PARTIAL=0"

REM  Set by steps 2 and 3 when an agent job reported failed rows. Read by the
REM  gate in front of step 4, which stops jobs 4 to 11 - some Contacts
REM  are missing, so Agent Number rows cannot resolve
REM  Agent__r.Master_Agent_ID__c, Agent Sales rows (Master_Agent_ID__c) and APD
REM  rows (Global_ID__c) would create new Contacts instead of updating existing
REM  ones, and Annuity Product Mix rows cannot resolve
REM  Contact_ID__r.Master_Agent_ID__c.
set "AGENTPARTIAL=0"

for %%D in ("%RESULTDIR%" "%ARCHIVEDIR%" "%LOGDIR%") do if not exist %%D md %%D 2>nul

REM ---------------- arguments ------------------------------------
set "QUIET=0"
set "ONEJOB="
if /i "%~1"=="/q" set "QUIET=1"
if not "%~1"=="" if /i not "%~1"=="/q" set "ONEJOB=%~1"

set "LOG=%LOGDIR%\%~n0.log"
break>"%LOG%"
set "WORST=0"

REM  :jsonval needs a scratch file. :runjob sets its own per-job JTMP; this one
REM  is for the calls made out here in the parent scope, i.e. :ensureauth.
set "JTMP=%LOGDIR%\jsonval.tmp"

REM  Show WHICH ORG this run will hit, before anything loads. The alias is the
REM  "org" key in clientcreds.json - the same value :ensureauth will use - so
REM  what is printed here is what gets written to. Two scripts pointing at two
REM  orgs is exactly the situation where a filename alone is not enough.
set "TARGETORG="
if exist "%ROOT%\Config\clientcreds.json" call :jsonval "%ROOT%\Config\clientcreds.json" org TARGETORG
if not defined TARGETORG set "TARGETORG=%DEFAULTALIAS%"
if not defined TARGETORG set "TARGETORG=(unknown - no credentials file)"

echo(
echo(  %~n0   %VERSION%
echo(  ================================================
echo(   TARGET ORG:  %TARGETORG%
echo(  ================================================
echo(  12 jobs ^| row-count guard ACTIVE ^| findstr body copy ^| no "more" ^| wait %WAITMIN% min
call :log "=== %~n0 %VERSION% starting - TARGET ORG %TARGETORG% ==="
if not exist "%BEAN%" (set "ERRMSG=Bean not found: %BEAN%" & goto :fatal)
if not exist "%CURL%" (set "ERRMSG=curl.exe not found at %CURL% - needs Windows 10 1803 or later" & goto :fatal)

REM ---------------- one archive folder for the whole run ----------
call :stamp
set "ARCHSUB=%ARCHIVEDIR%\Archive_%A_MMDD% %A_YYYY%%A_HHSP%%A_MISS%"
call :log "Archive folder for this run: %ARCHSUB%"

REM ---------------- single-job mode ------------------------------
if not defined ONEJOB goto :chain
call :log "Single-job mode: %ONEJOB%"
echo(
echo(  Authentication
call :ensureauth "%ONEJOB%"
if errorlevel 1 goto :fatal
call :runjob "%ONEJOB%"
set "WORST=%ERRORLEVEL%"
if "%WORST%"=="1" (set "ERRMSG=%ONEJOB% did not complete - see %LOGDIR%\%ONEJOB%.log" & goto :fatal)
goto :report

REM ---------------- pre-flight -----------------------------------
REM  Every source CSV is checked before anything loads. Finding job 2's file
REM  missing AFTER job 1 has run means job 1's source is already archived,
REM  which makes a clean re-run awkward.
:chain
set "PREOK=1"
echo(
echo(  Pre-flight
for %%J in ("%JOB1%" "%JOB2%" "%JOB3%" "%JOB4%" "%JOB5%" "%JOB6%" "%JOB7%" "%JOB8%" "%JOB9%" "%JOB10%" "%JOB11%" "%JOB12%") do call :checkjob %%J
if not "%PREOK%"=="1" (set "ERRMSG=One or more source CSVs are missing - nothing was loaded" & goto :fatal)

REM ---------------- authenticate once for the whole run -----------
REM  One :ensureauth call per bean, because each bean MAY name its own
REM  sfdc.credentialsFile / sfdc.orgAlias. When they share an alias - the
REM  normal case - only the first call does an OAuth round trip; the others
REM  find AUTHOK_<alias> already set and return immediately. Only a real
REM  fetch prints to the console, so what you see on screen is the literal
REM  number of authentications this run performed.
echo(
echo(  Authentication
call :ensureauth "%JOB1%"
if errorlevel 1 goto :fatal
call :ensureauth "%JOB2%"
if errorlevel 1 goto :fatal
call :ensureauth "%JOB3%"
if errorlevel 1 goto :fatal
call :ensureauth "%JOB4%"
if errorlevel 1 goto :fatal
call :ensureauth "%JOB5%"
if errorlevel 1 goto :fatal
call :ensureauth "%JOB6%"
if errorlevel 1 goto :fatal
call :ensureauth "%JOB7%"
if errorlevel 1 goto :fatal
call :ensureauth "%JOB8%"
if errorlevel 1 goto :fatal
call :ensureauth "%JOB9%"
if errorlevel 1 goto :fatal
call :ensureauth "%JOB10%"
if errorlevel 1 goto :fatal
call :ensureauth "%JOB11%"
if errorlevel 1 goto :fatal
call :ensureauth "%JOB12%"
if errorlevel 1 goto :fatal

REM ---------------- 1/12 ------------------------------------------
echo(
echo(  --- 1/12  %JOB1% ------------------------------------
call :runjob "%JOB1%"
set "RC=%ERRORLEVEL%"
call :log "%JOB1% exit code %RC%"
if "%RC%"=="1" (set "ERRMSG=%JOB1% failed - all later jobs skipped. See %LOGDIR%\%JOB1%.log" & goto :fatal)
if not "%RC%"=="2" goto :step2
if "%ALLOW_PARTIAL%"=="1" goto :agencypartial
set "ERRMSG=%JOB1% completed with failed rows - all later jobs skipped. Fix the error CSV, or set ALLOW_PARTIAL=1 in this file."
goto :fatal
:agencypartial
call :log "%JOB1% had failed rows - continuing because ALLOW_PARTIAL=1"
set "WORST=2"

REM ---------------- 2/12 ------------------------------------------
:step2
echo(
echo(  --- 2/12  %JOB2% -------------------------------
call :runjob "%JOB2%"
set "RC=%ERRORLEVEL%"
call :log "%JOB2% exit code %RC%"
if "%RC%"=="1" (set "ERRMSG=%JOB2% failed - %JOB3% to %JOB12% skipped. See %LOGDIR%\%JOB2%.log" & goto :fatal)
if "%RC%"=="2" (set "WORST=2" & set "AGENTPARTIAL=1")

REM ---------------- 3/12 ------------------------------------------
echo(
echo(  --- 3/12  %JOB3% ---------------------------
call :runjob "%JOB3%"
set "RC=%ERRORLEVEL%"
call :log "%JOB3% exit code %RC%"
if "%RC%"=="1" (set "ERRMSG=%JOB3% failed - %JOB4% to %JOB12% skipped. See %LOGDIR%\%JOB3%.log" & goto :fatal)
if "%RC%"=="2" (set "WORST=2" & set "AGENTPARTIAL=1")

REM ---------------- gate in front of jobs 4 to 11 -----------------
REM  All eight of these jobs need the Contacts to be there already:
REM    job 4 resolves them by Agent__r.Master_Agent_ID__c, so a Contact that
REM          failed above becomes a foreign-key failure.
REM    job 5 upserts ON Master_Agent_ID__c, so a Contact that failed above is
REM          not "missing parent" - it is a brand new Contact with nothing but
REM          sales fields, which fails REQUIRED_FIELD_MISSING on LastName, or
REM          quietly creates a half-populated duplicate agent if the file has
REM          a name column.
REM    job 6 resolves them by Contact_ID__r.Master_Agent_ID__c - the same
REM          foreign-key failure as job 4. It cannot corrupt anything, but a
REM          run where most rows fail is still a wasted run.
REM    jobs 8, 9, 10 and 11 resolve them through a Contact lookup - the same
REM          foreign-key failure as jobs 4 and 6. Neither can corrupt anything,
REM          but a run where most rows fail is still a wasted run.
REM    job 7 upserts ON Contact as well, so it carries job 5's risk: a missing
REM          agent is silently INSERTED, not rejected. Note it keys on
REM          Global_ID__c, not Master_Agent_ID__c, so a Contact that failed
REM          above is missing under BOTH keys. This is the job that can
REM          actually leave bad data behind, so it is gated and not relaxed.
REM  Stop rather than manufacture thousands of any of them. Once the agent
REM  error CSV is cleared and the agents reloaded, run them on their own:
REM    run-UATLoad.bat AgentNumberUpsert
REM    run-UATLoad.bat AgentSalesUpsert
REM    run-UATLoad.bat AnnuityProductMixUpsert
REM    run-UATLoad.bat ApdContactUpsert
REM    run-UATLoad.bat LswAnnuityHierarchyUpsert
REM    run-UATLoad.bat LswLifeHierarchyUpsert
REM    run-UATLoad.bat LifeProductMixUpsert
REM    run-UATLoad.bat NlProductHierarchyUpsert
if "%AGENTPARTIAL%"=="0" goto :step4
if "%ALLOW_PARTIAL%"=="1" (
  call :log "An agent job had failed rows - running %JOB4% to %JOB11% anyway because ALLOW_PARTIAL=1"
  goto :step4
)
set "ERRMSG=An agent job completed with failed rows, so %JOB4% to %JOB11% were all skipped - job 4 resolves Contacts by Master_Agent_ID__c and would hit foreign-key errors, job 5 upserts on that same key and job 7 upserts on Global_ID__c, so both would CREATE new Contacts instead of updating the agents, job 6 resolves the same key through Contact_ID__r and would hit foreign-key errors too. Fix the agent error CSV, reload the agents, then run each of them in single-job mode. Note this stop also ends the run before %JOB12%, which does not depend on the agents at all - run LeadUpsert on its own."
goto :fatal

REM ---------------- 4/12 ------------------------------------------
:step4
echo(
echo(  --- 4/12  %JOB4% -------------------------------
call :runjob "%JOB4%"
set "RC=%ERRORLEVEL%"
call :log "%JOB4% exit code %RC%"
if "%RC%"=="1" (set "ERRMSG=%JOB4% failed - %JOB5% to %JOB12% skipped. See %LOGDIR%\%JOB4%.log" & goto :fatal)
if "%RC%"=="2" set "WORST=2"

REM ---------------- 5/12 ------------------------------------------
REM  No gate on job 4's result: job 5 writes to Contact and does not touch
REM  Agent_Number__c, so a partial job 4 is irrelevant to it.
echo(
echo(  --- 5/12  %JOB5% -------------------------------
call :runjob "%JOB5%"
set "RC=%ERRORLEVEL%"
call :log "%JOB5% exit code %RC%"
if "%RC%"=="1" (set "ERRMSG=%JOB5% failed - %JOB6% to %JOB12% skipped. See %LOGDIR%\%JOB5%.log" & goto :fatal)
if "%RC%"=="2" set "WORST=2"

REM ---------------- 6/12 ------------------------------------------
REM  No gate on job 5's result either: job 6 writes to
REM  NLG_OBJ_AnnuityProductMix__c and only READS Contact through the
REM  Contact_ID__r.Master_Agent_ID__c lookup. A partial job 5 means some
REM  agents are missing sales figures, which has no bearing on whether their
REM  product-mix rows can resolve.
echo(
echo(  --- 6/12  %JOB6% ---------------------------
call :runjob "%JOB6%"
set "RC=%ERRORLEVEL%"
call :log "%JOB6% exit code %RC%"
if "%RC%"=="1" (set "ERRMSG=%JOB6% failed - %JOB7% to %JOB12% skipped. See %LOGDIR%\%JOB6%.log" & goto :fatal)
if "%RC%"=="2" set "WORST=2"

REM ---------------- 7/12 ------------------------------------------
REM  No gate on job 6's result: job 6 writes NLG_OBJ_AnnuityProductMix__c and
REM  job 7 writes Contact, so they do not touch the same records at all.
REM  The gate that matters for job 7 is the AGENTPARTIAL one above, because
REM  job 7 shares job 5's upsert key and therefore job 5's orphan risk.
echo(
echo(  --- 7/12  %JOB7% -------------------------------
call :runjob "%JOB7%"
set "RC=%ERRORLEVEL%"
call :log "%JOB7% exit code %RC%"
if "%RC%"=="1" (set "ERRMSG=%JOB7% failed - %JOB8% to %JOB12% skipped. See %LOGDIR%\%JOB7%.log" & goto :fatal)
if "%RC%"=="2" set "WORST=2"

REM ---------------- 8/12 ------------------------------------------
REM  No gate on job 7's result: job 8 writes its own object and only READS
REM  Contact through the Contact__r.Master_Agent_ID__c lookup, so whether an
REM  agent got its APD fields has no bearing on whether a hierarchy row can
REM  resolve. The gate that matters for job 8 is the AGENTPARTIAL one above.
echo(
echo(  --- 8/12  %JOB8% ------------------------
call :runjob "%JOB8%"
set "RC=%ERRORLEVEL%"
call :log "%JOB8% exit code %RC%"
if "%RC%"=="1" (set "ERRMSG=%JOB8% failed - %JOB9% to %JOB12% skipped. See %LOGDIR%\%JOB8%.log" & goto :fatal)
if "%RC%"=="2" set "WORST=2"

REM ---------------- 9/12 -----------------------------------------
REM  No gate on job 8's result. Both LSW hierarchy jobs write their own
REM  objects and only READ Contact through a lookup, so they are independent
REM  of each other - a partial job 8 says nothing about whether a LIFE
REM  hierarchy row can resolve. The gate that matters for job 9 is the
REM  AGENTPARTIAL one above.
echo(
echo(  --- 9/12  %JOB9% ---------------------------
call :runjob "%JOB9%"
set "RC=%ERRORLEVEL%"
call :log "%JOB9% exit code %RC%"
if "%RC%"=="1" (set "ERRMSG=%JOB9% failed - %JOB10%, %JOB11% and %JOB12% skipped. See %LOGDIR%\%JOB9%.log" & goto :fatal)
if "%RC%"=="2" set "WORST=2"

REM ---------------- 10/12 ----------------------------------------
REM  No gate on job 9's result. Job 10 is the LIFE counterpart of job 6's
REM  annuity product mix: its own child object, reading Contact only through a
REM  lookup, so nothing job 6 to 9 did can invalidate it. The gate that matters
REM  for job 10 is the AGENTPARTIAL one above.
REM  It sits here rather than next to job 6 purely because it was added later -
REM  grouping the two product-mix jobs together is cosmetic, they are
REM  independent of each other.
echo(
echo(  --- 10/12  %JOB10% ----------------------------
call :runjob "%JOB10%"
set "RC=%ERRORLEVEL%"
call :log "%JOB10% exit code %RC%"
if "%RC%"=="1" (set "ERRMSG=%JOB10% failed - %JOB11% and %JOB12% skipped. See %LOGDIR%\%JOB10%.log" & goto :fatal)
if "%RC%"=="2" set "WORST=2"

REM ---------------- 11/12 ----------------------------------------
REM  No gate on job 10's result. Another child object reading Contact only
REM  through a lookup, so nothing jobs 6 to 10 did can invalidate it. The gate
REM  that matters for job 11 is the AGENTPARTIAL one above.
echo(
echo(  --- 11/12  %JOB11% ------------------------
call :runjob "%JOB11%"
set "RC=%ERRORLEVEL%"
call :log "%JOB11% exit code %RC%"
if "%RC%"=="1" (set "ERRMSG=%JOB11% failed - %JOB12% skipped. See %LOGDIR%\%JOB11%.log" & goto :fatal)
if "%RC%"=="2" set "WORST=2"

REM ---------------- 12/12 ----------------------------------------
REM  Standalone. Lead has no reference to Agency, Contact or any agent id, so
REM  nothing above can invalidate it, and it is not part of the AGENTPARTIAL
REM  condition. It sits last purely because it was added last.
REM  Note that any upstream stop - hard error or the agent gate - ends the run
REM  through :fatal, so job 12 is simply never reached in those cases. Load the
REM  Leads on their own then:
REM    run-UATLoad.bat LeadUpsert
echo(
echo(  --- 12/12  %JOB12% ---------------------------------
call :runjob "%JOB12%"
set "RC=%ERRORLEVEL%"
call :log "%JOB12% exit code %RC%"
if "%RC%"=="1" (set "ERRMSG=%JOB12% failed. See %LOGDIR%\%JOB12%.log" & goto :fatal)
if "%RC%"=="2" set "WORST=2"

REM ---------------- report ---------------------------------------
:report
set "RC=%WORST%"
if "%RC%"=="0" call :log "SUCCESS - every job loaded all rows"
if "%RC%"=="2" call :log "COMPLETED WITH FAILURES - check the error CSVs under Load Result"
call :log "Sources archived to %ARCHSUB%"
goto :finish

:fatal
call :log "ERROR: %ERRMSG%"
set "RC=1"
goto :finish

:finish
REM  :jsonval leaves the value it extracted in this scratch file. Out here that
REM  is only ever the org alias, but the match is by substring, so a clientId
REM  containing "org" could put a credential fragment there. Cheap to be sure.
del /q "%JTMP%" 2>nul
echo(
if "%RC%"=="0" echo(  [OK]       All jobs completed - no failed rows.
if "%RC%"=="2" echo(  [PARTIAL]  Completed, but some rows FAILED - see the error CSVs.
if "%RC%"=="1" echo(  [FAILED]   The run stopped. %ERRMSG%
echo(             Log: %LOG%
echo(
if "%QUIET%"=="1" (endlocal & exit /b %RC%)
pause
endlocal & exit /b %RC%

REM ===============================================================
REM  :checkjob  <BeanId>  - pre-flight one job's source CSV
REM ===============================================================
:checkjob
call :readbean "%~1"
if not defined CSV (echo(  [ERROR] %~1: dataAccess.name missing, or bean id not in process-conf.xml & set "PREOK=0" & exit /b 0)
if not exist "%CSV%" (echo(  [ERROR] %~1: source CSV not found: %CSV% & set "PREOK=0" & exit /b 0)
call :rowcount "%CSV%" CJROWS
echo(  OK  %~1  ^<-  %CSV%  ^(%CJROWS% data rows^)
exit /b 0

REM ===============================================================
REM  :readbean  <BeanId>  - pull this bean's entries into
REM  ENTITY OPERATION EXTID SDL CSV CREDFILE BEANALIAS
REM  Splitting each line on the quote character hands us the attribute
REM  values directly, so raw XML never lands in a variable.
REM ===============================================================
:readbean
set "WANT=%~1"
setlocal EnableDelayedExpansion
set "INBEAN=0"
set "E=" & set "O=" & set "X=" & set "S=" & set "C=" & set "R2=" & set "R3="
for /f tokens^=1^,2^,4^ delims^=^" %%A in ('findstr /i /l /c:"<bean" /c:"<entry" "%BEAN%"') do (
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
      if /i "!K!"=="sfdc.entity"          set "E=!V!"
      if /i "!K!"=="process.operation"    set "O=!V!"
      if /i "!K!"=="sfdc.externalIdField" set "X=!V!"
      if /i "!K!"=="process.mappingFile"  set "S=!V!"
      if /i "!K!"=="dataAccess.name"      set "C=!V!"
      if /i "!K!"=="sfdc.credentialsFile"    set "R2=!V!"
      if /i "!K!"=="process.credentialsFile" set "R2=!V!"
      if /i "!K!"=="sfdc.orgAlias"           set "R3=!V!"
      if /i "!K!"=="process.orgAlias"        set "R3=!V!"
    )
  )
)
endlocal & (set "ENTITY=%E%" & set "OPERATION=%O%" & set "EXTID=%X%" & set "SDL=%S%" & set "CSV=%C%" & set "CREDFILE=%R2%" & set "BEANALIAS=%R3%")
exit /b 0

REM ===============================================================
REM  :runjob  <BeanId>  - the whole load for one bean.
REM  Returns 0 = all rows loaded, 2 = some rows failed or results
REM  unconfirmed, 1 = hard error.
REM ===============================================================
:runjob
setlocal
set "PROCESS=%~1"
set "LOG=%LOGDIR%\%PROCESS%.log"
set "SECRETS=%ROOT%\Config\clientcreds.json"
set "RAWJSON=%LOGDIR%\%PROCESS%-raw.json"
set "JTMP=%LOGDIR%\%PROCESS%-jsonval.tmp"
set "QPAT=%LOGDIR%\%PROCESS%-qpat.txt"
set "HPAT=%LOGDIR%\%PROCESS%-hdr.txt"
set "HDRNEW=%LOGDIR%\%PROCESS%-hdrnew.txt"
set "WORK=%RESULTDIR%\%PROCESS%_input.csv"
break>"%LOG%"

call :log "Process=%PROCESS%"

REM ---------------- 1) read the bean -----------------------------
call :readbean "%PROCESS%"
if not defined ENTITY    (set "ERRMSG=sfdc.entity missing (bean id '%PROCESS%' not found in %BEAN%?)" & goto :jobdie)
if not defined OPERATION (set "ERRMSG=process.operation missing for bean '%PROCESS%'" & goto :jobdie)
if not defined CSV       (set "ERRMSG=dataAccess.name missing for bean '%PROCESS%'"   & goto :jobdie)
if not exist "%CSV%"     (set "ERRMSG=Source CSV not found: %CSV%" & goto :jobdie)
call :log "entity=%ENTITY% op=%OPERATION% csv=%CSV%"

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

REM  The source header line goes to a pattern file BEFORE any BOM handling, so
REM  it matches the file byte for byte. findstr /v /x /l /g: then drops exactly
REM  that line and streams every other line through unchanged - the replacement
REM  for "more +1", which stops at a 0x1A byte and dies on Ctrl-C.
>"%HPAT%" echo(!LINE!

REM  Strip a UTF-8 BOM off column 1.
REM  With an SDL, the BOM is detected by the first column name failing to match
REM  any mapping key and matching once three characters are removed.
if !NMAP! gtr 0 (
  for %%c in ("!F1!") do if not defined M_%%~c (
    set "TRY=!F1:~3!"
    for %%d in ("!TRY!") do if defined M_%%~d (
      set "F1=!TRY!"
      echo(NOTE: UTF-8 BOM skipped on the first header - CSV UTF-8 is fine, no action needed
    )
  )
)
REM  Belt and braces for the no-SDL path, where there are no mapping keys to
REM  test against. Measured on this machine, "set /p" drops a UTF-8 BOM before
REM  it ever reaches the variable, so F1 is already clean and neither of these
REM  blocks fires - the BOM damage happens later, in the header-drop, and is
REM  handled at :copybody. But that behaviour depends on the console codepage,
REM  so if a BOM ever does survive into F1 on another machine this catches it.
REM  Test: every Salesforce api name starts with a letter, so a first character
REM  that is not a letter means junk in front of it. Three characters are removed
REM  only if that makes the name start with a letter, so a header that was
REM  already fine is never touched.
if !NMAP! equ 0 (
  echo(!F1!|findstr /r /c:"^[A-Za-z]" >nul
  if errorlevel 1 (
    set "TRY=!F1:~3!"
    echo(!TRY!|findstr /r /c:"^[A-Za-z]" >nul
    if not errorlevel 1 (
      set "F1=!TRY!"
      echo(NOTE: UTF-8 BOM stripped from the first header - CSV UTF-8 is fine, no action needed
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

REM  The rewritten header goes to its own file as well as to WORK. :copybody
REM  needs it to rebuild WORK from scratch on the fallback attempt, and a file
REM  carries it across the endlocal below without any variable gymnastics.
>"%HDRNEW%" echo(!NEWHDR!
>"%WORK%"   echo(!NEWHDR!

if "!FILTER!"=="0" (
  REM  Fast path: only the header changed, so the body is copied verbatim.
  echo(Preparing input CSV ^(header renamed, !NCOL! columns kept^)
  endlocal
  goto :copybody
)

REM  Filter path: columns have to be dropped, so every row is rebuilt.
REM  A quoted field containing a comma cannot be split correctly in cmd,
REM  and a "!" would be eaten by delayed expansion - refuse both rather
REM  than write silently mis-aligned data.  The quote pattern lives in a
REM  file because an escaped quote unbalances cmd's own parser.
>"%QPAT%" echo "
findstr /l /g:"%QPAT%" "%CSV%" >nul 2>&1
if not errorlevel 1 (endlocal & set "ERRMSG=CSV contains a double quote, so unmapped columns cannot be dropped safely. Map every column in the SDL, or pre-trim the CSV." & goto :jobdie)
findstr /l /c:"!" "%CSV%" >nul 2>&1
if not errorlevel 1 (endlocal & set "ERRMSG=CSV contains an exclamation mark, which cmd cannot process safely. Map every column in the SDL, or pre-trim the CSV." & goto :jobdie)

set "NROW=0"
for /f "usebackq skip=1 eol=| delims=" %%L in ("%CSV%") do (
  set "LINE=%%L"
  call :split
  set "OUT="
  for %%k in (!KEEP!) do set "OUT=!OUT!,!F%%k!"
  >>"%WORK%" echo(!OUT:~1!
  set /a NROW+=1
)
echo(Prepared input CSV ^(!NROW! rows rebuilt, unmapped columns dropped^)
endlocal
goto :rowguard

REM ---------------- 2b) copy the body, then prove it ------------
REM  findstr streams the whole file and is indifferent to 0x1A, so it does not
REM  truncate the way "more +1" did, and it copied 100,000 rows in 0.6s under
REM  test. "more" is used NOWHERE in this script and must not be reintroduced:
REM  it stops dead at a 0x1A byte, dies if Ctrl-C is pressed while it copies,
REM  and hung indefinitely on a 100,001-line file under test. It silently cost
REM  two runs 34,465 rows each.
REM  If the count still comes out wrong, that is a hard error with no second
REM  attempt - every alternative is worse than stopping.
REM  NO /x HERE - fixed in v5, 2026-08-31.
REM  "set /p" SILENTLY DROPS A UTF-8 BOM when it reads the header line, so the
REM  pattern in HPAT begins at "M" while the real first line of the file begins
REM  EF BB BF. Under /x (whole-line match) the two never matched, the header was
REM  NOT dropped, and the prepared file came out one row longer than the source -
REM  which the row guard then reported as "Row count mismatch ... a 0x1A (Ctrl-Z)
REM  byte or other control character is the usual cause", a hard stop on a file
REM  that is perfectly fine apart from a BOM. It failed safe, but it failed, and
REM  the message pointed at the wrong thing entirely. v3 and v4 both do this.
REM  Without /x the match is "line contains the pattern", which catches the
REM  header whether or not a BOM sits in front of it. The only way this could
REM  over-match is a DATA row containing the entire header line as a substring,
REM  and that would trip the row guard rather than load anything wrong.
:copybody
findstr /v /l /g:"%HPAT%" "%CSV%" >>"%WORK%"
call :rowcount "%CSV%"  SRCROWS
call :rowcount "%WORK%" WRKROWS
:rowguard

REM  THE GUARD. Source data rows must equal prepared data rows. A mismatch used
REM  to sail straight through: 100,000 rows in, 65,535 prepared, COMPLETED
REM  reported, 34,465 rows never sent to Salesforce and no hint in the log.
if not exist "%WORK%" (set "ERRMSG=Failed to build input CSV: %WORK%" & goto :jobdie)
call :rowcount "%CSV%"  SRCROWS
call :rowcount "%WORK%" WRKROWS
if "%SRCROWS%"=="%WRKROWS%" goto :rowsok
set "ERRMSG=Row count mismatch - %CSV% has %SRCROWS% data rows but the prepared file has %WRKROWS%. NOTHING was loaded. A 0x1A (Ctrl-Z) byte or other control character in the CSV is the usual cause; do not press Ctrl-C while the file is being prepared. Clean the source and re-run."
goto :jobdie
:rowsok
call :log "Row check OK - %SRCROWS% source data rows, %WRKROWS% prepared: %WORK%"
echo(Row check OK - %SRCROWS% rows in, %WRKROWS% ready to load

REM ---------------- 3) resolve the org alias ---------------------
REM  No token fetch here. :ensureauth already got one for this alias before
REM  any job started, and persisted it into the sf CLI's auth store with
REM  "sf org login access-token -p", so every job in the run shares it.
REM  All this step has to do is work out WHICH alias the sf commands below
REM  should target. The one exception is a direct :runjob call with no
REM  :ensureauth ahead of it - that still fetches, so :runjob stays usable
REM  on its own.
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
REM  Reached only when there is NO credentials file. Until v14 this line
REM  hardcoded a specific alias, which meant a missing clientcreds.json could
REM  silently send a whole run at the WRONG ORG. Now it uses DEFAULTALIAS from
REM  the top of this file, and refuses to guess if that is empty too.
if not defined ORGALIAS set "ORGALIAS=%DEFAULTALIAS%"
if not defined ORGALIAS (set "ERRMSG=No credentials file at %SECRETS%, no sfdc.orgAlias in the bean, and DEFAULTALIAS is empty at the top of this script. Refusing to guess which org to load - set one of those three." & goto :jobdie)
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

REM  Stale *-records*.csv from an earlier run would be picked up below as if
REM  they belonged to this job, reporting someone else's row counts.
del /q "%RESULTDIR%\*success-records*.csv" 2>nul
del /q "%RESULTDIR%\*failed-records*.csv"  2>nul

set "RETRIED="
:runload
call :log "Running: %SFCMD% --sobject %ENTITY% %SFEXTRA%"
REM  <nul on every external call: nothing in this script is interactive, and a
REM  CLI that decides to prompt must fail rather than sit there holding up an
REM  unattended run.
call %SFCMD% --sobject %ENTITY% --file "%WORK%" --target-org %ORGALIAS% --wait %WAITMIN% --json %SFEXTRA% >"%RAWJSON%" 2>&1 <nul

REM  One token for the whole run means a slow job 1 can leave job 2 or 3 holding
REM  a session that has since timed out. If that happened, fetch a replacement
REM  and run this load once more.
REM  Re-running is safe: INVALID_SESSION_ID is the API rejecting the request
REM  outright, so no bulk job was created and no row was touched. Guarded to a
REM  single attempt - a second failure is a real error, not an expiry.
if defined RETRIED goto :loadran
if not exist "%SECRETS%" goto :loadran
findstr /l /c:"INVALID_SESSION_ID" "%RAWJSON%" >nul || goto :loadran
call :log "Session had expired mid-run - fetching a replacement token and retrying this load once"
call :fetchtoken "%SECRETS%" "%ORGALIAS%"
if errorlevel 1 goto :jobdie
set "RETRIED=1"
goto :runload
:loadran

REM  Job id: find the first "750..." then cut at the closing quote. Do NOT take
REM  a fixed number of characters - an id of unexpected length then swallows the
REM  quote and the junk ends up on the next command line.
set "JOBID="
findstr /l /c:"750" "%RAWJSON%" >"%JTMP%" 2>nul
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
if not defined JOBID (set "ERRMSG=sf load: no job id found. See %RAWJSON% - if it mentions an expired or invalid session, re-authorise alias %ORGALIAS% or add a credentials file so this script can fetch its own token." & goto :jobdie)
call :log "Job Id: %JOBID%"

REM ---------------- 5) fetch + route the result files ------------
pushd "%RESULTDIR%"
call sf data bulk results --job-id %JOBID% --target-org %ORGALIAS% >nul 2>&1 <nul
popd

for %%P in ("%CSV%") do for %%Q in ("%%~dpP.") do set "SUB=%%~nxQ"
set "OUTDIR=%RESULTDIR%\%SUB%"
if not exist "%OUTDIR%" md "%OUTDIR%"

call :stamp
set "SUCCDEST=%OUTDIR%\success%STAMP%.csv"
set "FAILDEST=%OUTDIR%\error%STAMP%.csv"

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
REM  server-side, so no result files exist YET. It is not a failure and the job
REM  must not be re-run blindly - it may be loading every row right now.
if defined NORESULTS call :log "WARNING: no result files for job %JOBID% after waiting %WAITMIN% min - it is probably STILL RUNNING, not failed. Do NOT re-run. Check state: sf data upsert resume --job-id %JOBID% --target-org %ORGALIAS%   then: sf data bulk results --job-id %JOBID% --target-org %ORGALIAS%"
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
REM  No "->" in this message. call re-parses its own argument line, and the ">"
REM  survived that second pass as a REDIRECTION even inside the quotes: it wrote
REM  the line into a file called "Load" (first token of "Load Result") in the
REM  current directory and the log entry itself vanished. Found under test on
REM  2026-08-29; v2 and v3 both do it. Keep it as plain text.
REM  No parentheses either - with OUTDIR holding a path that contains a space
REM  ("...\Load Result\Agent"), call's second parse treated the "(" as the start
REM  of a block and the line was logged truncated at "...\Load". Commas only.
call :log "Results in %OUTDIR% - success=%SUCCCOUNT% rows, error=%FAILCOUNT% rows"

REM  Every row submitted must come back in one file or the other. If it does
REM  not, the result files are an incomplete picture and the counts below would
REM  understate the damage - say so instead of quietly reporting a clean total.
REM  STATEMENT LEVEL, not a parenthesised block: %ACCOUNTED% inside a block
REM  would expand when the block is PARSED, before the set /a that fills it
REM  ever runs - the same trap that produced malformed archive folder names.
if defined NORESULTS goto :skipaccount
set /a ACCOUNTED=%SUCCCOUNT%+%FAILCOUNT%
if not "%ACCOUNTED%"=="%WRKROWS%" call :log "WARNING: %WRKROWS% rows were submitted but only %ACCOUNTED% appear in the result files (success=%SUCCCOUNT%, error=%FAILCOUNT%). Verify job %JOBID% in the org before trusting these numbers."
:skipaccount

REM ---------------- 6) archive the source CSV --------------------
REM  ARCHSUB is set once by the caller, so all jobs in a run share one folder.
if not defined ARCHSUB set "ARCHSUB=%ARCHIVEDIR%\Archive_%A_MMDD% %A_YYYY%%A_HHSP%%A_MISS%"
if not exist "%ARCHSUB%" md "%ARCHSUB%" 2>nul
if not exist "%ARCHSUB%" (set "ERRMSG=Could not create archive folder '%ARCHSUB%'. Job %JOBID% HAS already run - check it with: sf data bulk results --job-id %JOBID% --target-org %ORGALIAS%" & goto :jobdie)
for %%P in ("%CSV%") do move /y "%CSV%" "%ARCHSUB%\%%~nxP" >nul
del /q "%WORK%"   2>nul
del /q "%HPAT%"   2>nul
del /q "%HDRNEW%" 2>nul

if defined NORESULTS (
  call :log "UNCONFIRMED - job %JOBID% ran but no result files were returned, so row counts are unknown. Source archived to %ARCHSUB%"
  endlocal & exit /b 2
)
if "%FAILCOUNT%"=="0" (
  call :log "SUCCESS - %SUCCCOUNT% loaded, 0 failed, out of %WRKROWS% submitted. Source archived to %ARCHSUB%"
  endlocal & exit /b 0
)
call :log "COMPLETED - %SUCCCOUNT% loaded, %FAILCOUNT% failed, out of %WRKROWS% submitted. Source archived to %ARCHSUB%; results in %OUTDIR%"
endlocal & exit /b 2

:jobdie
call :log "ERROR: %ERRMSG%"
endlocal & exit /b 1

REM ===============================================================
REM  :ensureauth  <BeanId>  - guarantee a usable token for this bean's org
REM  alias, fetching one ONLY if this run has not already done so.
REM
REM  Deliberately has NO setlocal: it sets AUTHOK_<alias> and that marker has
REM  to survive into the parent scope, which is the whole point. :runjob reads
REM  it to decide whether to skip its own fetch. The cost is that EA_* and
REM  :readbean's outputs leak into the caller - harmless, since :runjob re-reads
REM  its own bean and the pre-flight has already finished with them.
REM
REM  Keyed on the ALIAS, not the credentials file, because what matters is
REM  "does the sf CLI hold a live login for alias X". Aliases here are
REM  alphanumeric (dev3cc, dev4cc), which is what makes AUTHOK_%ALIAS% a legal
REM  variable name - an alias with spaces or punctuation would need hashing.
REM
REM  Only a real fetch prints to the console. A reuse goes to the log alone,
REM  so the number of lines on screen is the number of authentications.
REM  Returns 0 = ready (fetched or already cached, or no creds file so stored
REM  auth will be used), 1 = hard error with ERRMSG set.
REM ===============================================================
:ensureauth
call :readbean "%~1"
set "EA_SECRETS=%ROOT%\Config\clientcreds.json"
if not defined CREDFILE goto :ea_haveconf
REM  Same relative-to-ROOT rule :runjob uses for sfdc.credentialsFile.
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
REM  client-credentials round trip, then hand the token to the sf CLI.
REM  -p persists it under the alias, which is what lets one fetch serve the
REM  whole run.
REM
REM  The response JSON is deleted the moment it has been read. It holds a live
REM  bearer token in clear text, and an earlier version left one per job
REM  sitting in Log\ after every run - the log truncation at the top of a run
REM  does not cover files it does not know about.
REM  Returns 0 on success, 1 with ERRMSG set on failure.
REM ===============================================================
:fetchtoken
setlocal
set "FT_SECRETS=%~1"
set "FT_ALIAS=%~2"
set "FT_TOK=%LOGDIR%\token.json"
REM  Our own scratch file, so a call from either scope works.
REM  :jsonval writes the value it extracted into JTMP, which means this file
REM  holds the clientSecret and then the access token. EVERY exit path below
REM  goes through :ft_done or :ft_fail so it is always deleted - an early
REM  return that skipped the cleanup used to leave the secret on disk.
set "JTMP=%LOGDIR%\fetchtoken-jsonval.tmp"
call :jsonval "%FT_SECRETS%" domain       FT_DOMAIN
call :jsonval "%FT_SECRETS%" clientId     FT_CLIENTID
call :jsonval "%FT_SECRETS%" clientSecret FT_SECRET
if not defined FT_DOMAIN   (set "FT_ERR=domain missing from %~1"       & goto :ft_fail)
if not defined FT_CLIENTID (set "FT_ERR=clientId missing from %~1"     & goto :ft_fail)
if not defined FT_SECRET   (set "FT_ERR=clientSecret missing from %~1" & goto :ft_fail)

REM  NOTE: every external command below is invoked with CALL. On Windows the
REM  Salesforce CLI is sf.cmd - a BATCH file - and running a batch file from a
REM  batch file without CALL transfers control and never comes back, killing
REM  this script silently mid-run. CALL is harmless for real .exe files too.
del /q "%FT_TOK%" 2>nul
call "%CURL%" -s -X POST "%FT_DOMAIN%/services/oauth2/token" ^
  -d "grant_type=client_credentials" ^
  -d "client_id=%FT_CLIENTID%" ^
  -d "client_secret=%FT_SECRET%" -o "%FT_TOK%" <nul
if errorlevel 1 (set "FT_ERR=curl failed calling the token endpoint - check the domain in %~1 and that this box can reach it" & goto :ft_fail)
findstr /l /c:"access_token" "%FT_TOK%" >nul || (set "FT_ERR=Token request failed - the response carried no access_token. Check clientId/clientSecret in %~1" & goto :ft_fail)
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
REM  FT_ERR expands while the line is PARSED, i.e. before endlocal runs, so the
REM  message survives into the caller's scope. Standard batch idiom.
endlocal & set "ERRMSG=%FT_ERR%" & exit /b 1

REM ===============================================================
REM  shared subroutines
REM ===============================================================

:log
echo(%DATE% %TIME%  %~1
>>"%LOG%" echo(%DATE% %TIME%  %~1
exit /b 0

REM  :split  - LINE -> F1..Fn plus NF.  Handles empty fields, which
REM  plain "for /f tokens=" cannot (it collapses repeated delimiters).
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
findstr /l /c:"%~2" "%~1" >"%JTMP%" 2>nul
set /p JL=<"%JTMP%"
if not defined JL exit /b 0
call set "JL=%%JL:*%~2=%%"
set "JL=%JL: =%"
set "JL=%JL:~2%"
>"%JTMP%" echo(%JL%
for /f tokens^=1^ delims^=^" %%A in ('type "%JTMP%"') do if not defined %~3 set "%~3=%%A"
exit /b 0

REM  :rowcount  <csv> <outvar>  - data rows, i.e. lines minus the header.
REM  Uses CNT, not RC - RC is the caller's exit code and must not be touched.
:rowcount
set "%~2=0"
set "CNT=0"
for /f %%N in ('type "%~1" 2^>nul ^| find /c /v ""') do set "CNT=%%N"
if %CNT% gtr 0 set /a CNT-=1
set "%~2=%CNT%"
exit /b 0

REM  :stamp  - STAMP=MMddyyHHmmssfff for result files, plus the pieces the
REM  archive folder name needs (hour space-padded).
REM  EVERYTHING HERE IS STATEMENT LEVEL ON PURPOSE. An earlier version put the
REM  fallback inside an if/else block, where %VAR% expands when the block is
REM  PARSED - before the SET that fills it ran. On a machine without wmic that
REM  produced folder names like "Archive_0807 2026~0,2~3,2T:~6,2", so md and
REM  move both failed and no results were collected.
:stamp
set "LDT="
for /f "tokens=2 delims==" %%I in ('wmic os get localdatetime /value 2^>nul') do set "LDT=%%I"
if not defined LDT goto :stamp_fallback
set "A_YYYY=%LDT:~0,4%"
set "A_MMDD=%LDT:~4,4%"
set "A_HH=%LDT:~8,2%"
set "A_MISS=%LDT:~10,4%"
set "STAMP=%LDT:~4,2%%LDT:~6,2%%LDT:~2,2%%LDT:~8,2%%LDT:~10,2%%LDT:~12,2%%LDT:~15,3%"
goto :stamp_check

:stamp_fallback
REM  wmic is deprecated and absent on newer Windows builds.
set "TT=%TIME: =0%"
set "A_MMDD="
set "A_YYYY="
for /f "tokens=1-4 delims=/.- " %%a in ("%DATE%") do call :stamp_date "%%a" "%%b" "%%c" "%%d"
set "A_HH=%TT:~0,2%"
set "A_MISS=%TT:~3,2%%TT:~6,2%"
set "STAMP=%A_MMDD%%A_YYYY:~2,2%%TT:~0,2%%TT:~3,2%%TT:~6,2%%TT:~9,2%0"
goto :stamp_check

:stamp_date
REM  %DATE% is "MM/DD/YYYY" or "Ddd MM/DD/YYYY" depending on locale
if "%~4"=="" (set "A_MMDD=%~1%~2" & set "A_YYYY=%~3") else (set "A_MMDD=%~2%~3" & set "A_YYYY=%~4")
exit /b 0

:stamp_check
REM  Never let a malformed stamp reach a filename - digits only.
echo %STAMP%|findstr /r /c:"^[0-9][0-9]*$" >nul
if errorlevel 1 (
  call :log "WARNING: could not build a timestamp - using a fixed name for this run's files"
  set "STAMP=00000000000000"
  set "A_MMDD=0000"
  set "A_YYYY=0000"
  set "A_HH=00"
  set "A_MISS=0000"
)
if "%A_HH:~0,1%"=="0" (set "A_HHSP= %A_HH:~1%") else (set "A_HHSP=%A_HH%")
exit /b 0
