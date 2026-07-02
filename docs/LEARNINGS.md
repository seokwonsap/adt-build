# Vibe ABAP — Learnings & Gotcha Catalog

Real problems hit while vibe-coding ABAP on **A4H** (ABAP Platform 2023 / 758) through
**VSP (Vibing Steampunk) MCP + raw ADT REST**, and how they were solved. This is the core
deliverable of the lab: a running log of *symptom → cause → fix/workaround*. Append new
entries as they come up.

> Convention: each entry is **Symptom → Cause → Fix**. Newest session: 2026-07-01 (§N–§P — ZUTIL library, Phase 5 health-check, AWS Clean Core cherry-picks).

---

## A. Object create / edit (VSP mechanics)

**A1. Transportable package needs a transport on every write**
- Symptom: `ADT 400 "Parameter corrNr could not be found"` on create/edit.
- Cause: ZVIBE is transportable (non-`$`); writes must carry a transport.
- Fix: pass `"transport": "A4HK900120"` on every `create`/`edit`/`UPDATE_SOURCE`. Find open requests with `system {"type":"list_transports"}`.

**A2. `deploy_from_file` is broken for class/intf MAIN source**
- Symptom: object shell created, then `423 ... is not locked (invalid lock handle)` on the source write — fails even on an existing active class.
- Cause: VSP's internal lock/write for main source uses a stale/cross-session handle.
- Fix: use the **high-level `edit`** (inline `source`) — it does its own lock/activate correctly. For huge classes, deploy the definition + empty method bodies, then fill **each method** via `edit CLAS {method, source}`.
- Note: `deploy_from_file` *does* work for class **includes** (`.clas.locals_imp.abap`, `.clas.testclasses.abap`) — but the include must already exist (create the class first).

**A3. TABL can't be edited high-level**
- Symptom: `edit target="TABL ..."` → "No handler". `create TABL` needs `fields` as a **stringified JSON array**, and a CURR field fails to save without currency semantics.
- Fix: create a stub, then **low-level** `edit LOCK` → `edit UPDATE_SOURCE` on `/sap/bc/adt/ddic/tables/<t>/source/main` with the full DDL (incl. `@Semantics.amount.currencyCode`) → `edit ACTIVATE` → `edit UNLOCK`.

**A4. CDS / BDEF / SRVD creation**
- `create target=OBJECT` with `object_type` = `DDLS/DF` | `BDEF/BDO` | `SRVD/SRV`, then push source with high-level `edit`. Use `"activate": false` to save without activating (e.g. a BDEF before its handler class exists).

**A5. JSON-escaping ABAP through the MCP `source` param**
- Every `"` → `\"`, every `\` → `\\` (PCRE `\s`/`\d` become `\\s`/`\\d`; ABAP `'\\'` → `'\\\\'`). One bad escape = activation failure pointing at a line.

---

## B. RAP behavior

**B1. `strict(2)` requires authorization**
- Symptom: BDEF won't activate — "every entity must be flagged authorization master/dependent".
- Fix: keep `authorization master ( instance )` and implement `get_instance_authorizations` in the handler (grant `%update`/`%delete`/`%action-...` = `if_abap_behv=>auth-allowed`).

**B2. View-entity vs DDIC annotations**
- Symptom: `@Semantics.currencyCode` "not allowed in view entities".
- Fix: in CDS **view entities** the amount's `@Semantics.amount.currencyCode: 'CurrencyCode'` reference is enough; don't annotate the currency field itself (that's for tables).

---

## C. Service binding (OData)

**C1. Binding comes out V2, not V4**
- Symptom: passed `binding_type:"ODATA_V4_UI"`, got OData **V2**.
- Cause: VSP `create` has **no `binding_type` param** — it reads `binding_version` (default **V2**) and `binding_category`.
- Fix: pass `binding_version:"V4"` + `binding_category:"0"`. **`0` = UI, `1` = Web API** — SAP's format spec confirms this; **VSP's own help text has it reversed.** Activate the binding **before** publish. VSP can't `read` SRVB → verify with curl: `srvb:version="V4"`.
- V4 runtime URL: `/sap/opu/odata4/sap/<binding>/srvd/sap/<servicedef>/0001/`.

**C2. OData V4 is stricter than V2**
- `Edm.Decimal` must be a JSON **number** (`Amount: 0`), not a string (`"0.00"` → parse error).
- Bound action invocation: `POST /Booking(<guid>)/<SchemaNamespace>.<action>` with CSRF + body `{}`. Get the namespace + key from `$metadata`.

---

## D. Messages (T100)

**D1. VSP can't create a message class**
- Symptom: `create MSAG` → "unsupported object type"; `deploy_from_file` rejects `.msag.xml`.
- Fix: **raw ADT REST** — `POST /sap/bc/adt/messageclass?corrNr=<tr>` (CSRF + `Content-Type: application/vnd.sap.adt.messageclass.v1+xml`, body `<mc:messageClass>`), then `edit LOCK` → `PUT …/messageclass/<name>?lockHandle=…` with `<mc:messages mc:msgno="001" mc:msgtext="…"/>` → `edit ACTIVATE`.

**D2. T100 text renders as the key (`E:ZVIBE_BOOKING:001`)**
- Cause: message text is stored in the **creating user's logon language**; `DEV001` has a **blank** logon language (`USR01.LANGU=''`), so text lands in `SPRSL=''` while the OData runtime resolves in the system default language → no match.
- Fix: set DEV001's logon language to EN in **SU01**. (The validation rejection itself still works — only the displayed text is affected.)
- Use in RAP: `new_message( id = 'ZVIBE_BOOKING' number = '001' severity = if_abap_behv_message=>severity-error )`.

---

## E. ABAP Unit (RAP test doubles)

**E1. Which test double?**
- To test the BO's **own** logic (determinations/validations/actions): `cl_osql_test_environment=>create( VALUE #( ( 'ZVIBE_BOOK' ) ) )` — mock the table, the **real** handler runs.
- NOT `cl_botd_txbufdbl_bo_test_env` (that's a buffer double for testing **consumers**; throws *"Actions not supported with TXBUFDBL variant"*). `cl_abap_behv_test_environment=>create` is **private**.

**E2. `mapped` is empty after CREATE**
- Cause: managed UUID is **late-numbered** → the key isn't in the MODIFY's `mapped`.
- Fix: read the key back from the doubled table (`SELECT SINGLE booking_uuid FROM zvibe_book`).

**E3. Action test returns zero instances**
- Symptom: `EXECUTE approve` after a separate `COMMIT ENTITIES` processes nothing (empty result), status unchanged.
- Fix: do **CREATE + EXECUTE in one `MODIFY`** via `%cid_ref` (no commit between); assert on the action's `RESULT` (`res[1]-%param-status`). A separate EXECUTE in a new LUW doesn't resolve the instance in the OSQL-double harness.
- ⚠️ **Only works when the action has no feature control.** If the action is **status-gated** (`action ( features : instance )`), the enabling status isn't set until the determination runs at save, so the in-one-MODIFY EXECUTE is rejected — and `IN LOCAL MODE` to force it **dumps**. See **I4**.

**E4. Test class deployment**
- Deploy as `<class>.clas.testclasses.abap` (CCAU) via `deploy_from_file`, but the include must exist — create the class first. The **behavior-pool** CCAU init fails ("no inactive version") → use a **standalone test class** (`ZCL_..._TEST`).

**E5. Raw-REST ABAP Unit run (`tools/abap --test`) — the silent-empty trap**
`POST /sap/bc/adt/abapunit/testruns` with `Content-Type`/`Accept` = **`application/*`** (wildcards sidestep the config.vN↔result.vN version pairing entirely — the versioned media types pair inconsistently: config.v4→result.v2, config.v1/v2→result.v1).
- ⚠ **The `<options>` element and its children (`uriType`, `testRiskLevels`, `testDurations`, …) must be UNqualified** (no `aunit:` prefix). A namespaced `<aunit:options>` is silently dropped → server returns a schema-valid **empty `<aunit:runResult/>` with HTTP 200** that ran *nothing* and reads as green. The body that actually runs: `<aunit:runConfiguration>` → `<external><coverage active="false"/></external>` + unqualified `<options>` + `<adtcore:objectSets>`. (the objectSet element must be `adtcore:objectSets`, not `aunit:adtObjectSet`.)
- ⚠ **Empty `<runResult/>` ≠ pass.** A bogus/non-existent object URI *and* a whole-package run both return the same empty result. Distinguish: **no `<program>` element = nothing ran** (report "no tests found", never "passed"). A real pass emits `<program><testClasses><testClass><testMethods><testMethod …/>`; a failure adds an `<alert kind="failedAssertion|runtimeAbortion" severity="critical|fatal"><title>…`. Parse alerts across the whole body (program/class/method level) so a setup **dump** (program-level `runtimeAbortion`, 0 testMethods) is caught as FAIL, not green (cf. I6). Verified live: passing class → "N methods, all passed"; deliberate `assert_equals(1,2)` → "1 FAILED [failedAssertion]".
- **Create a testclasses (CCAU) include from scratch** (needed to deploy a test on a fresh class): lock the class (stateful), `POST /sap/bc/adt/oo/classes/<cl>/includes?lockHandle=&corrNr=` body `<class:abapClassInclude xmlns:class=… xmlns:adtcore=… adtcore:name="dummy" class:includeType="testclasses"/>` (`application/*`, **same stateful session as the lock**) → **201**, then PUT the source to **`/includes/testclasses`** (NOT `/includes/testclasses/source/main` — that 404s), then activate. The include must exist before any PUT.

**E6. Raw-REST ATC run (`tools/abap --atc`) — 3-step worklist flow**
1. resolve the system check variant: `GET /sap/bc/adt/atc/customizing` → property `name="systemCheckVariant"` `value="…"` (attr order varies — match both ways).
2. `POST /sap/bc/adt/atc/worklists?checkVariant=<v>` `Accept: text/plain` → 32-hex worklist id.
3. `POST /sap/bc/adt/atc/runs?worklistId=<id>` body `<atc:run maximumVerdicts="100">…<objectSets …>` (`application/xml`). The run reply carries `FINDING_STATS` = `p1,p2,p3` priority counts (authoritative total). `GET /sap/bc/adt/atc/worklists/<id>?includeExemptedFindings=false` for finding detail (`priority`/`checkTitle`/`messageTitle`/`location#…start=<line>` attrs) — ⚠ the worklist **lists each finding more than once**, so dedup by (message, line); use `FINDING_STATS` for the headline count, not `len(findings)`.

---

## F. Debugger

**F1. `403 websocket: bad handshake` was NOT an ICM param**
- The param was renamed: `icm/HTTP/support_websocket` → **`icm/HTTP/support_websocket_upgrade`** (already `TRUE`). Reading the old name returns blank and misleads.
- Real cause: the APC/ICF node `/sap/bc/apc/sap/zadt_vsp` didn't exist (SAP returns **403** for an inactive/absent ICF node).

**F2. `install_zadt_vsp` ships empty stubs (VSP 2.38.1, latest)**
- Prints "✓ Deployed" but only creates one empty `FINAL` handler with no `ON_MESSAGE` → SAPC activation fails (`sapc_message 016`).
- Fix: hand-deploy the real backend from `github.com/oisee/vibing-steampunk/embedded/abap` (debug domain only) via inline edit, then create the **SAPC** app + activate the **SICF** node (GUI). See `VSP_DEBUG_BACKEND.md`.

**F3. Debugger is split across two backends**
- `SET/GET/DELETE breakpoint` + `LISTEN` + `ATTACH` work (breakpoint CRUD over our websocket; LISTEN/ATTACH over standard ADT). But `GET_STACK`/`GET_VARIABLES`/`STEP` fail `noSessionAttached` — VSP doesn't **hold** the debuggee across MCP calls (it runs to completion right after attach).
- Result: live step-through isn't usable via VSP → do it in **Eclipse ADT**. The external-debugging *setup* (BP → cross-session trigger → catch → attach) is proven.

**F4. Running code**
- `if_oo_adt_classrun` classes run over plain **HTTP+CSRF** (`POST /sap/bc/adt/oo/classrun/<class>`). Reports (`WRITE`) **dump** in that windowless context ("dynpro ... No window system type") and need the debugger websocket for `RUN_REPORT` (not deployed). Cross-session debug trigger: a classrun that `SUBMIT`s a **no-`WRITE`** report.

---

## G. Cleanup / catalog

**G1. Orphaned TADIR blocks package delete**
- Symptom: programs are 404 (deleted) but `DEVC` delete says "still contains objects"; `TADIR` still lists `R3TR PROG` rows.
- Cause: VSP delete doesn't clean TADIR for cross-user/cross-transport objects; re-create to clean is blocked by the package guard (`SAP_ALLOWED_PACKAGES=ZVIBE`); no TADIR-write API.
- Fix: SAP GUI — **SE80** right-click package → Delete, or **SE03** "Delete Object Directory Entries".

---

## H. Web (lab console)

**H1. Browser → SAP without CORS or exposing creds**
- Vite dev proxy (`/sap` → A4H) injects **Basic auth server-side** in `vite.config.ts`; the browser only calls same-origin localhost (no CORS), and the SAP password (in `.env`) never reaches the browser.
- For OData **writes**, fetch `X-CSRF-Token: Fetch` then POST; set `cookieDomainRewrite: ''` on the proxy so the session cookie stays valid for the token.

---

## Meta — what reliably unblocks
When VSP can't do something: read `SAP(action="help")` / the relevant SAP class source, and if still stuck, drop to **raw ADT REST via curl** (discover endpoints from `/sap/bc/adt/discovery`). GUI-only transactions (SAPC/SICF/SE03/SU01/RZ10) must be done by the user in SAP GUI.

---

## Session 2 — Experiment 02 (ZI_DeployRequest: parent-child + lifecycle)

**I1. Circular CDS (composition ↔ association-to-parent) can't be activated via VSP**
- Symptom: root `composition of Child` + child `association to parent Root` — VSP `edit` (high-level) fails the syntax gate each way; low-level `UPDATE_SOURCE`+`ACTIVATE` reports success but leaves an **"active-but-no-runtime" zombie** (data preview "Cannot find ENTITY", BDEF "Type X is unknown"). `ACTIVATE_PACKAGE` finds 0; the raw ADT `/activation/inactiveobjects` mass-activate returns **304** (because VSP already marked them "active").
- Cause: VSP doesn't do true mass activation, and its writes mark objects active in place — so the cycle never resolves and the runtime view is never generated.
- Fix/Workaround: avoid the cycle for now (build the BO **single-entity**), or create the composition in **Eclipse ADT** (Ctrl+F3 mass-activates). Child/composition modeling via VSP is an open gap.

**I2. "Type ZXXX is unknown" in a BDEF** = the underlying CDS entity has no runtime (zombie activation), not a real type error. Verify with a data-preview SELECT; if "Cannot find", the view didn't truly activate.

**I3. Fresh test include (CCAU) init**: `deploy_from_file` of `*.clas.testclasses.abap` on a class whose CCAU was never created → 500 "does not have any inactive version". Seed the include first with `create CLASS_WITH_TESTS` (it fails on the [[A2]] lock-bug but **initializes the CCAU shell**), then `deploy_from_file` updates it. (Must delete the class first if it already exists — CLASS_WITH_TESTS won't reuse it.)

**I4. Status-gated RAP actions can't be unit-tested through the OSQL double — verify via OData e2e instead.** Three dead ends: (a) `EXECUTE <action> FROM ( %key-... = uuid )` on seeded/committed data resolves **no instance**; (b) `CREATE + EXECUTE` in one `MODIFY` runs the action *before* the determination sets the enabling status, so **feature control rejects it**; (c) adding **`IN LOCAL MODE`** to dodge (b) **short-dumps `BEHAVIOR_INTERNAL_ACCESS`** ("Illegal attempt to call an internal operation … only callable by the implementation") — the local API is impl-only and illegal from a test/consumer. So unit-test only what the **external** API reaches (determinations + validations via `CREATE`/`COMMIT ENTITIES`); cover actions + cross-BO gates with live OData calls.
> ⚠️ **Correction to the earlier I4 / [[E3]] advice**: the "CREATE+EXECUTE in one MODIFY + `IN LOCAL MODE`" pattern is **wrong for tests** — it dumps. The "green" submit/approve action tests in experiment 02 were **false positives** (see I6). Booking's action tests passed only because that BO had **no feature control** (no `IN LOCAL MODE` needed).

**I5. `timestampl` current value**: use `GET TIME STAMP FIELD <ts>` (ts TYPE timestampl) — not `utclong_current( )` (that's for `utclong` fields).

**I6. A RAP short-dump makes the ABAP Unit REST return an empty `<aunit:runResult/>`** — trivially misparsed as "0 failures = green." Always confirm via the **structured** runner (VSP `test` action / ADT `testMethods` list): a real pass lists every `testMethod`; a class with empty `testMethods` + one `runtimeAbortion`/`fatal` alert is a **dump**, not success. Read the real cause from the ST22 feed: `GET /sap/bc/adt/runtime/dumps` with `Accept: application/atom+xml;type=feed` — the `<summary>` embeds the whole dump (category, terminating method, line).

**I7. Circular composition CDS — REST mass-activation doesn't work here either; model as related root BOs.** Beyond VSP (I1), the raw ADT `POST /sap/bc/adt/activation/inactiveobjects?method=activate` returns **304 / activates nothing even for a single valid object** (confirmed via stateful lock→PUT→activate). So a true managed parent-child **composition** can't be activated outside Eclipse on this setup. Workaround used for the deploy sign-off chain: make the child a **separate root BO** (`ZI_DeployApproval`) linked by a `DeployUuid` field, expose it as a 2nd entity set, and enforce the parent↔child rule in the root action handler (read the child table, block on non-approved steps). Delivers the governance without a CDS composition.
> Gotcha: giving the child an `association [1..1] to <root>` is unnecessary and not required for the FK link — keep the child standalone to avoid dragging the root into a multi-BO model.

---

## Session 3 — ABAP-dev capability demos (classrun, RTTI, hierarchy, AMDP, web runner)

**J1. `if_oo_adt_classrun` is the headless workhorse** — write a class implementing `if_oo_adt_classrun`, run it with `POST /sap/bc/adt/oo/classrun/<class>` (CSRF), get `out->write(...)` console text back. No Fiori/gateway. The web console runs all demos this way through the vite proxy. The single best F9-equivalent for vibe-coding verification.

**J2. ❌ WRONG — superseded by K5 (kept as a lesson in false boundaries).** Original claim: "AMDP table function from scratch = circular-activation wall, needs Eclipse." That was **two of my own bugs**, not a real limit: (a) activating via the wrong endpoint `/inactiveobjects` (304 no-op → zombie) instead of the bare `/activation` (**K1**); and (b) a client-dependent table function needs a **CLNT field first** in its return structure (**K5**). With both fixed, the DDLS↔class pair mass-activates and runs **fully headless** — `ZBASIS_TF` now returns live HANA rows. The "won't save / zombie" symptoms were all downstream of (a)+(b). **Lesson: a `generationExecuted="false"` activation carries a *message* — read it before declaring a boundary.**

**J3. CDS hierarchy gotcha — source view may not expose a column named `parent_id`.** `define hierarchy ... source ZI_ORG ...` fails with *"Entity ZI_ORG contains column PARENT_ID (not allowed within hierarchies)"* — `parent_id` collides with the generated hierarchy columns. **Alias the FK to anything else** (used `Mgr`). Then `SELECT FROM zh_org` exposes `hierarchy_level` / `hierarchy_rank` / `hierarchy_tree_size`, and `HIERARCHY_DESCENDANTS( SOURCE zh_org START WHERE ... )` exposes `hierarchy_distance`. Self-association (`ZI_ORG` → `ZI_ORG as _Parent`) activates fine (no cycle — normal association).

**J4. `FOR` iteration variable leaks into method scope (strict mode).** `DATA(cols) = VALUE #( FOR c IN comps ( ... ) ).` then `LOOP AT comps INTO DATA(c).` → *"C was already declared / obscures a global field"*. The constructor-expression `FOR` var is method-scoped here; **use a different name** for the later inline declaration.

**J5. RTTI generic serializer pattern** — `CAST cl_abap_tabledescr( cl_abap_typedescr=>describe_by_data( tab ) )` → `get_table_line_type( )` → `CAST cl_abap_structdescr( )` → `get_components( )`, then per row `ASSIGN COMPONENT comp-name OF STRUCTURE <row> TO FIELD-SYMBOL(<v>)` + `|{ <v> }|`. Joins cleanly with `concat_lines_of( table = ... sep = ... )`. `/ui2/cl_json=>serialize/deserialize` with `pretty_mode-camel_case` round-trips any table; assert with `cl_abap_unit_assert=>assert_equals`.

**J6. EML as a consumer (classrun) reproduces every RAP result table** — `MODIFY ENTITIES ... CREATE ... EXECUTE <action> ... MAPPED/FAILED/REPORTED`, action `RESULT`, then `COMMIT ENTITIES RESPONSE OF ... FAILED/REPORTED`. Validation-on-save surfaces only at COMMIT (commit-FAILED + reported `%msg->if_message~get_text( )`). Confirms D2: the T100 message still renders as the key (`I:ZVIBE_BOOKING:001`) under DEV001's blank logon language.

**J7. Web read paths recap** — browser → vite proxy → A4H, three read shapes, all zero-write at runtime: (a) **ADT atom feeds** (`/runtime/dumps`), GET, parse XML; (b) **Data Preview freestyle SQL** (`POST /datapreview/freestyle`, `Accept: application/vnd.sap.adt.datapreview.table.v1+xml`, CSRF) — any table/CDS, column-oriented XML → rows; (c) **classrun** (`POST /oo/classrun/<class>`, CSRF) — runs ABAP, returns console text. `/runtime/workprocesses` is **GET-405** (SM50 not reachable read-only).

**J8. RAP parameterized + factory actions — three traps (all hit, all fixed).** Added `action applyDiscount parameter ZA_VIBE_DISCOUNT result [1] $self;` (abstract entity input) + `factory action copyBooking [1];` to the managed Booking BO.
- (a) **Implicit response params clash**: in a behavior-handler method, `mapped`/`failed`/`reported` are implicit CHANGING params. A local `MODIFY ... CREATE ... MAPPED DATA(mapped)` → *"MAPPED was already declared."* Capture into a **local** (`MAPPED DATA(ls_mapped)`) then feed the response: `mapped-booking = ls_mapped-booking.`
- (b) **`deploy_from_file` hides CCIMP compile errors**: it reported *"updated and activated"* despite the (a) error, so the behavior pool had **no valid methods** → runtime `CX_RAP_HANDLER_NOT_IMPLEMENTED (Method: MODIFY)` on the new action. **Force a full class compile** by re-saving the class **main** via high-level `edit` — that surfaces the real CCIMP error (and rebinds the pool). Always do this after `deploy_from_file` of a behavior-pool include.
- (c) **Factory action needs a `%cid`**: `EXECUTE copyBooking FROM VALUE #( ( %cid_ref = 'c1' ) )` → `BEHAVIOR_CONTRACT_VIOLATION: MISSING_CID`. A factory action is instance-generating, so the EML input must carry a **`%cid`** for the new instance: `( %cid = 'cpy1' %cid_ref = 's1' )`.
- Read the action parameter in the handler via `keys[...]-%param-<field>`; the abstract entity is just `define abstract entity ZA_VIBE_DISCOUNT { Percent : abap.int1; }`. Verified live: applyDiscount 200→180, copyBooking made a persisted copy.

**J9. DCL (CDS row-level security) — not creatable headless here (boundary).** `@AccessControl.authorizationCheck: #CHECK` on a view + a `define role ZX { grant select on ZX where (...) = aspect pfcg_auth(...); }` is the technique. But: VSP `create OBJECT` rejects **`DCLS/DL`** ("unsupported object type"), and the raw ADT endpoint `/sap/bc/adt/acm/dcl/sources` returns **415** for every guessed media type (the create content-type isn't in discovery). So DCL authoring needs the right create media type or **Eclipse** — but note this is a **CREATE** problem (415), unrelated to activation. (A view left at `#CHECK` with no DCL returns no rows, so revert to `#NOT_REQUIRED`.)

> **Headless-creation boundary summary (REVISED after K1/K5):** AMDP table functions ✅ build headless (K5 — J2 was a *false* boundary). Still unconfirmed: **composition CDS** (I1 — very likely also just needed **mass**-activation of root+child together via the bare `/activation`, never properly tried) and **DCL** (J9 — a CREATE media-type problem, not activation). Confirmed buildable headless via VSP + raw ADT REST: managed/related-root RAP BOs · CDS views/joins/aggregation/hierarchies · abstract-entity parameter + factory actions · **AMDP table functions** + consumption · classrun · RTTI · message classes. **Moral: before calling something a boundary, read the activation message and try mass-activation via `/sap/bc/adt/activation`.**

---

## Session 4 — out-of-house (public IP) + raw-REST build toolchain

**K1. `/sap/bc/adt/activation/inactiveobjects` is for LISTING; the bare `/sap/bc/adt/activation` is for ACTIVATING.** The whole session's "raw-REST activation returns 304 / can't mass-activate" pain was the **wrong endpoint**. `POST /sap/bc/adt/activation?method=activate&preauditRequested=false` (body `adtcore:objectReferences`) returns `200` with `<chkl:properties activationExecuted="true" generationExecuted="true"/>` and actually activates. `/inactiveobjects` (same params/body) returns `304` and does nothing. (VSP's `edit ACTIVATE` used the right one — that's why VSP worked and my raw attempts didn't.) ⇒ **the I1/J2/J9 "needs Eclipse" boundaries deserve a re-test** with the correct endpoint.

**K2. CSRF token rotates after a modifying op in a stateful session.** After `_action=LOCK` / `PUT source`, the next `POST /activation` can `403`. **Re-fetch the token** (GET `/discovery` with `X-CSRF-Token: Fetch`, same cookie jar) immediately before the activate. Safest: re-fetch before every create/lock/PUT/activate.

**K3. Out-of-house reachability** — A4H is at public `<PUBLIC_IP>:50000` (home WAN, port-forwarded; HTTPS 50001). Auth enforced (no creds → 401). The **VSP MCP** server is pinned to the LAN IP in `.mcp.json` (`SAP_URL=http://<HOME_LAN_IP>:50000`) so it's dead outside; the **vibe-lab-web** vite proxy likewise targets the LAN. ⇒ out-of-house, do everything via **raw ADT REST over the public IP** (the full toolchain: create → lock → PUT → re-fetch CSRF → `/activation` → classrun/datapreview). `.env` carries a `VSP_A4HPUB_*` profile for the public IP (CLI mode only). ⚠️ plain HTTP over the internet sends the password in clear — prefer SSH tunnel/VPN; rotate after.

**K4. Reusable raw-REST build toolchain (out-of-house, no VSP) — proven end-to-end.** Per object, over the public IP:
1. **CSRF/session**: GET `/sap/bc/adt/discovery` with `X-CSRF-Token: Fetch` + `X-sap-adt-sessiontype: stateful` (cookie jar).
2. **CREATE**: `POST /sap/bc/adt/oo/classes?corrNr=<tr>`, `Content-Type: application/vnd.sap.adt.oo.classes.v4+xml`, body `<class:abapClass xmlns:class=… xmlns:adtcore=… adtcore:name="ZCL_X" class:final="true" class:visibility="public" class:category="generalObjectType"><adtcore:packageRef adtcore:name="ZVIBE"/></class:abapClass>` → 200. (CDS → `/sap/bc/adt/ddic/ddl/sources`; tables → `/sap/bc/adt/ddic/tables`.)
3. **LOCK**: `POST <uri>?_action=LOCK&accessMode=MODIFY` → parse `<LOCK_HANDLE>`.
4. **PUT source**: `PUT <uri>/source/main?lockHandle=<lh>&corrNr=<tr>` (`text/plain`).
5. **UNLOCK**: `POST <uri>?_action=UNLOCK&lockHandle=<lh>`.
6. **ACTIVATE in a FRESH session** (new cookie jar + freshly-fetched token): `POST /sap/bc/adt/activation?method=activate&preauditRequested=false` with `adtcore:objectReferences` → `activationExecuted="true"`. (Lock/PUT poison the session's CSRF → fresh session needed; and it's the **bare** `/activation`, not `/inactiveobjects` — see K1/K2.)
7. **RUN/verify**: `POST /sap/bc/adt/oo/classrun/<class>` (text/plain) or datapreview SQL.
Proof: built `ZCL_VIBE_PKGINFO` (TADIR-based ZVIBE inventory, 75 objects) entirely headless from outside the LAN.

**K5. AMDP table function builds fully headless — J2 was a FALSE boundary.** Two fixes turned the "zombie / needs Eclipse" AMDP TF into a working one: (a) mass-activate the DDLS + AMDP class **together** in one bare-`/activation` call (K1), and (b) a **client-dependent** TF (reads USR02 etc.) must declare a **CLNT key field first** — else activation cancels with *"ZBASIS_TF is marked as client-specific; type field BNAME at pos. 1 is CHAR (not CLNT)"* and `generationExecuted="false"`. Working shape:
```
define table function ZBASIS_TF
  with parameters @Environment.systemField: #CLIENT p_clnt : abap.clnt
  returns { key client : abap.clnt; key bname : xubname;
            trdat : abap.dats; seq : abap.int8; dormant_days : abap.int4; }
  implemented by method zcl_vibe_amdp=>get;
-- AMDP: SELECT mandt AS client, bname, trdat,
--   ROW_NUMBER() OVER(ORDER BY trdat DESC) AS seq,
--   DAYS_BETWEEN(TO_DATE(trdat,'YYYYMMDD'), CURRENT_DATE) AS dormant_days
--   FROM usr02 WHERE mandt = :p_clnt AND trdat <> '00000000';
```
Types: `seq` int8 (ROW_NUMBER→BIGINT), `dormant_days` int4 (DAYS_BETWEEN→INT). Build order: PUT both sources → **mass-activate both in one `/activation` call (fresh session)**. `ZBASIS_TF` then returns live HANA rows via datapreview (verified: DEV001 dormant 0d, DEVELOPER_5 1195d). The HANA SQLScript pushdown (window fn + date math) runs in-DB.

**K6. Composition CDS also builds headless — I1 was ALSO a false boundary.** Root `define root view entity … composition [0..*] of ZCHILD as _Steps` + child `define view entity … association to parent ZROOT as _Hdr on …` form an activation cycle. Fix is identical to K5: **mass-activate both DDLS in one bare-`/activation` call** (VSP's one-at-a-time activate is what zombied them — the cycle resolves only when both are activated in the same pass). Built `ZIC_DREQ` (root over ztb_deploy_req) + `ZIC_DAPP` (child over ztb_deploy_appr) headless over the public IP — both active + queryable (4 + 5 rows). Two sub-gotchas: (a) the activation response showed `generationExecuted="false"` with **no error messages**, yet the views are fully active — for view entities that flag is not a failure signal, **verify with an actual query**; (b) DDLS create media type = `application/vnd.sap.adt.ddlSource+xml` (no version suffix — the `.ddic.ddlsources.v2+xml` guess 415s).

> **FINAL boundary verdict:** the "needs Eclipse" list (I1 composition CDS, J2 AMDP table functions) was **wrong on both counts** — both build fully headless via mass-activation through `/sap/bc/adt/activation`. Only **DCL** (J9) is still unconfirmed, and it's a *create*-media-type problem (415), not an activation one — very likely crackable the same way DDLS was (find the unversioned `…+xml` media type). The lab is, as far as tested, **100% headless-buildable**.

**K7. DCL (CDS row-level security) builds + filters headless — J9 was just a CREATE-media-type problem.** The only blocker was the create media type (415). Correct: `POST /sap/bc/adt/acm/dcl/sources`, `Content-Type: application/vnd.sap.adt.dclSource+xml` (NOT `…acm.dcl…` — the collection's `<app:accept>` in discovery is authoritative). Then PUT the role (`text/plain`) and **mass-activate the view + DCL together** via `/activation`. Verified live: `@AccessControl.authorizationCheck:#CHECK` view `ZC_ORG_DCL` + `define role ZC_ORG_DCL { grant select on ZC_ORG_DCL where id <> '1'; }` → normal `SELECT FROM zc_org_dcl` = 5 rows (id='1' hidden), `SELECT … WITH PRIVILEGED ACCESS` = all 6. Literal DCL conditions are allowed; access control is enforced on Open-SQL reads, bypassed with `WITH PRIVILEGED ACCESS`. **General rule for any "VSP can't create X": pull the exact create media type from the discovery `<app:accept>` of its collection — they're the unversioned `application/vnd.sap.adt.<x>Source+xml` form.**

> **🏁 ALL "needs Eclipse" boundaries falsified (K5/K6/K7).** AMDP table functions · composition CDS · DCL access controls — all build, activate, and run **fully headless** via raw ADT REST over the public IP. Every one of the three was my own bug (wrong endpoint / one-at-a-time vs mass activation / wrong create media type), not a platform limit. **As tested, the A4H lab is 100% headless-buildable from outside the LAN — no Eclipse, no VSP, no GUI required for authoring.** This is the empirical basis for a "ClaudeGUI" that drives ABAP entirely over the ADT REST API.

---

## L. Classic ABAP (reports, function modules) — headless build

**L1. Classic ALV report (PROG) builds headless; the grid runs in GUI.** Create: `POST /sap/bc/adt/programs/programs`, `Content-Type: application/vnd.sap.adt.programs.programs.v2+xml`, body `<program:abapProgram … program:programType="executableProgram">`. PUT the `REPORT` source (`text/plain`), activate via bare `/activation`. Built `ZVIBE_ALV_DEMO` (`REPORT` + `PARAMETERS`/`SELECT-OPTIONS` + `SELECT` + `CL_SALV_TABLE=>factory( )` + `display( )`) — compiles clean. `display( )` needs SAP GUI → **run in SE38/SA38** to see the grid (headless can't render dynpro/ALV — the CLAUDEGUI.md GUI boundary). Verify the *data* logic headless by replicating the SELECT in a classrun.

**L2. Function module — ADT source is a method-style inline signature, NOT the `*"` block.** Create the group: `POST /sap/bc/adt/functions/groups` (`…functions.groups.v3+xml`). Create the FM inside it: `POST /sap/bc/adt/functions/groups/<fg>/fmodules` (`…functions.fmodules.v3+xml`) with `<fmodule:abapFunctionModule><adtcore:containerRef adtcore:uri="…/groups/<fg>" adtcore:type="FUGR/F" …/></fmodule:abapFunctionModule>`. **FM source format:** `FUNCTION z_x IMPORTING VALUE(iv_a) TYPE … EXPORTING VALUE(ev_b) TYPE …. <body> ENDFUNCTION.` — the inline signature (like a method), **not** the classic SE37 `*"…Local Interface` comment block (PUTting the `*"` form → **400**; GET the created skeleton to see the expected shape).

**L3. Activating a FM needs its OWN reference (`FUGR/FF`), not the group (`FUGR/F`).** Activating just the function group leaves the FM inactive → `activationExecuted="false"` and `CALL FUNCTION` dumps. Put the FM in the activation `objectReferences` with `adtcore:type="FUGR/FF"`, uri `…/groups/<fg>/fmodules/<fm>`. Verified: `Z_VIBE_JOB_STATS` (counts TBTCO jobs by status) → F=5922, A=12, S=5, R=0.

**L4. Verify classic code headless by calling it from a classrun.** A FM / classic class / a report's data logic is testable headless via an `if_oo_adt_classrun` class that `CALL FUNCTION`s (or instantiates) and `out->write`s the result — closing build→activate→run for classic objects too. Only the dynpro/ALV *presentation* needs GUI; the *logic* is fully headless-verifiable.

**L5. Classic GUI-control ALV (CL_GUI_ALV_GRID + containers) — code headless, screen GUI-only.** ADT discovery exposes **no dynpro/screen endpoint** → dynpros (SE51) + GUI statuses (SE41) are GUI-only (the CLAUDEGUI.md boundary, now confirmed by probe).
- **CL_GUI_DOCKING_CONTAINER + CL_GUI_ALV_GRID** — *fully* headless-buildable **and** SE38-runnable with **no screen painting**: dock the grid to the selection screen in `AT SELECTION-SCREEN OUTPUT` — `NEW cl_gui_docking_container( side = cl_gui_docking_container=>dock_at_bottom extension = 250 )` → `NEW cl_gui_alv_grid( i_parent = … )` → `set_table_for_first_display( EXPORTING i_structure_name = 'TBTCO' CHANGING it_outtab = … )`. Built `ZVIBE_GRID_DOCK`, compiles clean. Guard with `IF go_grid IS BOUND. RETURN.` (the event re-fires).
- **CL_GUI_CUSTOM_CONTAINER** — needs a painted custom control on a dynpro. The **ABAP code compiles + activates headless even though screen 100 doesn't exist** (screen existence is a *runtime* check, not an activation one). Built `ZVIBE_GRID_CUSTOM` (PBO/PAI modules + `cl_gui_custom_container( container_name = 'CC_ALV' )`). To *run* it, the human paints in SAP GUI: screen 100 (custom control `CC_ALV`, resizable/full-size) + flow logic (`PROCESS BEFORE OUTPUT. MODULE pbo_0100.` / `PROCESS AFTER INPUT. MODULE pai_0100.`) + GUI status `STAT100` (BACK F3 / EXIT shift-F3 / CANCEL F12) + title `TIT100`. **Honest division: Claude writes the control-framework code; the human paints the trivial screen.**

**L6. Classic OO (interface + custom exception + singleton factory) — fully headless.** Built + verified the canonical classic-OO stack: **interface** `ZIF_VIBE_JOBSTAT` (create via `/sap/bc/adt/oo/interfaces`, `application/vnd.sap.adt.oo.interfaces.v5+xml`); **custom exception** `ZCX_VIBE_BIZ` (`INHERITING FROM cx_static_check`, a `reason` attribute — created via the normal `/oo/classes` endpoint; the superclass in the *source* makes it an exception class); **service class** `ZCL_VIBE_JOBSTAT` (`CREATE PRIVATE` + `CLASS-METHODS get_instance` singleton, `INTERFACES zif_…`, `RAISE EXCEPTION NEW zcx_…( reason = … )`, `SELECT … GROUP BY`). Verified via classrun: factory → interface calls → GROUP BY stats, abort_rate 0.20%, exception path (`count_by_status('Q')` → caught, read `lx->reason`).
- **Gotcha — method/interface params can't use inline `TYPE p LENGTH n DECIMALS n`.** The source PUT returns a generic **400 "An error occurred during the save operation"** (NOT a clear syntax error). Define a **named type** in the interface (`TYPES ty_pct TYPE p LENGTH 5 DECIMALS 2.`) and reference it. (Also avoid the component name `count` — it shadows the built-in; use `cnt`.) **Isolate such save-400s by PUTting a minimal stub first** — if the stub saves, your content is the problem, not the mechanism.

> **Classic ABAP coverage (L1–L6) — done headless:** ALV report (`CL_SALV`) · GUI-control ALV (`CL_GUI_ALV_GRID` + docking/custom container) · function group + module · interface + custom exception + singleton OO. The only GUI-bound gaps are *dynpro screens* + *GUI statuses* (SE51/SE41) — code compiles headless, the human paints the screen. The lab now spans **modern (RAP/CDS/AMDP) AND classic (reports/FM/OO/GUI-ALV)** ABAP, all built over the ADT REST API.

**L5b. SAP GUI for Java (Mac/Linux) has NO graphical Screen Painter** — opening Layout shows *"GUI is not a GUI for Windows (continue with alphanumeric editor)"*. So a **custom control** (`CL_GUI_CUSTOM_CONTAINER`, drawn by dragging in SE51) effectively needs SAP GUI **for Windows**. Workaround that stays Java-GUI-friendly: use a **`CL_GUI_DOCKING_CONTAINER`** which fills the screen without any drawn control — then the screen needs only **flow logic** (`PROCESS BEFORE OUTPUT. MODULE pbo_0100. PROCESS AFTER INPUT. MODULE pai_0100.`), which is pure text and fully editable in the alphanumeric editor. No GUI status needed either (`MODULE pai_0100. LEAVE PROGRAM.`). Net: the *only* truly Windows-GUI-only artifact (the graphical layout) is routed around — the docking container makes even the "custom container" screen buildable+runnable from a Mac.

**L7. BAPI from ABAP (user password reset) — full lifecycle headless, with explicit commit.** Drove the user-management BAPIs from a classrun, **safe + self-cleaning** (create throwaway → reset password → verify → delete; nothing persists). Pattern: `CALL FUNCTION 'BAPI_USER_CREATE1' EXPORTING username / logondata(BAPILOGOND) / password(BAPIPWD) / address(BAPIADDR3) TABLES return` → **`BAPI_USER_CHANGE` with `password(BAPIPWD)` + `passwordx(BAPIPWDX)-bapipwd='X'`** sets an initial (must-change) password = the "reset" → `BAPI_USER_GET_DETAIL` to verify → `BAPI_USER_DELETE`. **BAPIs don't auto-commit** — every write needs `CALL FUNCTION 'BAPI_TRANSACTION_COMMIT' EXPORTING wait='X'`. Read the `RETURN` (`bapiret2_t`) table for messages (`WHERE type CA 'EAWS'`); got `S01102 created` / `S01039 changed` / `S01232 deleted`.
- **Gotcha — `PERFORM_CONFLICT_TAB_TYPE` dump:** passing `STANDARD TABLE OF bapiret2 WITH EMPTY KEY` to the BAPI's classic `TABLES return` parameter **dumps** (the internal FORM is strict about table type). Use the **official table type `bapiret2_t`** (or `WITH DEFAULT KEY`), never `WITH EMPTY KEY`, for classic `TABLES` parameters.
- **Safety on the internet-exposed system:** demo used a throwaway user and **deleted + committed** it (verified gone from USR02), so no credential lingers on the public IP. BDC (recording SU01 screens) is the legacy alternative, but BAPI is the correct tool for user/password ops.

**L8. BDC + the classrun-vs-report execution boundary.**
- **`if_oo_adt_classrun` classes are ADT-only — NOT runnable in SAP GUI.** Running a `ZCL_VIBE_*` classrun class via SE38/SE24-execute fails referencing `IF_OO_ADT_CLASSRUN~MAIN` (the `main( out )` method needs the ADT runtime to supply the `out` console object; SAP GUI has no equivalent). Run them via **Eclipse F9**, the **web runner** (vibe-lab-web → classrun REST), or curl `POST /sap/bc/adt/oo/classrun/<class>`. By contrast the **REPORTS** (`ZVIBE_ALV_DEMO`/`ZVIBE_GRID_DOCK`/`ZVIBE_GRID_CUSTOM`, PROG type 1) **are** runnable in SE38/SA38. Rule: PROG → SE38; CLAS(classrun) → ADT/web only.
- **BDC technique (headless):** build `BDCDATA` (a screen row = program/dynpro/`dynbegin='X'`; field rows = fnam/fval incl. `BDC_OKCODE`), then `CALL TRANSACTION '<tcode>' USING bdc OPTIONS FROM opt MESSAGES INTO msg` with `opt-dismode='N'` (no display = headless-safe) + `opt-updmode='S'` (synchronous). Inspect `sy-subrc` + the `bdcmsgcoll` table (each message carries the screen it stopped on: `dyname`/`dynumb`).
- **Modern SU01 makes BDC fragile (the BAPI-wins lesson):** a SU01-create BDC returned `sy-subrc=1001` *"No batch input data found for dynpro **SAPLSUID_MAINTENANCE 1050**"* — SU01's real initial screen is the SUID-framework `SAPLSUID_MAINTENANCE/1050` (complex tabstrip), not the classic `SAPLSUU5/0050`. Such flows are release-dependent and brittle → **prefer BAPIs (`BAPI_USER_*`) over BDC** whenever an API exists; BDC is the fallback only for transactions with no API.

**L9. Clean BDC success — CALL TRANSACTION on a custom report transaction (headless).** For a *reliable* BDC (vs the fragile standard SU01 in L8), BDC your **own report's selection screen** (dynpro 1000, field names = the `PARAMETERS` names).
- **Create the report transaction headless**: `CALL FUNCTION 'RPY_TRANSACTION_INSERT' EXPORTING transaction program dynpro='1000' language development_class='$TMP' transaction_type='R' shorttext=…`. **`transaction_type='R'` (report transaction) is essential** — with `' '` (dialog) the FM returns `sy-subrc 0` but **silently creates nothing** (a dialog tcode for a report program is inconsistent; TSTC stays empty — verify with a SELECT). The text param is **`SHORTTEXT`** (no underscore) and **mandatory** (missing → `CX_SY_DYN_CALL_PARAM_MISSING` *dump*, not a catchable FM exception). `COMMIT WORK AND WAIT` after.
- **BDC + verify without a table**: `BDCDATA = ( program=<rep> dynpro='1000' dynbegin='X' )( fnam='BDC_OKCODE' fval='ONLI' )( fnam='P_TEXT' … )( fnam='P_NUM' … )` → `CALL TRANSACTION '<tcode>' USING bdc OPTIONS FROM opt (dismode='N', updmode='S') MESSAGES INTO msg`. Have the report `MESSAGE s398(00) WITH <params>` — the echo lands in `msg` (proves the BDC delivered the data) with no Z table needed.
- **`sy-subrc=1001` "No batch input data found for dynpro <rep> 1000"** *after* the report ran = the report **returned to its selection screen** and the BDC ran out of steps. Add **`LEAVE PROGRAM.`** at the end of `START-OF-SELECTION` → clean **`sy-subrc=0`**. Verified: P_TEXT='hello-from-bdc' / P_NUM=42 delivered + echoed.

## M. Session 5 — XCO · JSON · parallel processing + raw-REST-as-default (codezentrale)

> 빌드 방법 전체는 `DEVELOPING.md`. 여기는 이 세션에서 검증한 기법·함정.

**M1. vsp `create` blocked → raw REST is the build path.** On a memory-pressured A4H (mem ~90%), vsp's `create` (and `read DEVC`) call `repository/nodestructure?parent_name=ZVIBE` which **times out** (ZVIBE has 90+ objects) → vsp reports *"package ZVIBE does not exist"* (false negative from the timeout); retry doesn't help. `$TMP` is blocked by `SAP_ALLOWED_PACKAGES=ZVIBE`. → **create/activate/run via `tools/abap` (raw ADT REST)**; use vsp only for read/search/test. Also: **this shell reaches only the public IP** (`<PUBLIC_IP>:50000` → 401), not the home LAN (`<HOME_LAN_IP>` → curl exit 7), so raw REST runs over the public IP. (vsp MCP is a separate process bound to the LAN config; big standard-class `read` over it also times out.)

**M2. XCO — read CDS entity metadata + content** (codezentrale: *Lesen des Inhalts von CDS-Entitäten*). `ZCL_VIBE_XCO_CDS` / `ZCL_VIBE_XCO_DEEP`.
- Existence + fields: `xco_cds=>view_entity( name )->exists( )`; `…->fields->all->get( )` → loop `f->name` (READ-ONLY attr of `if_xco_cds_field`).
- Deep: `f->content( )->get( )` returns `if_xco_cds_field_content=>ts_content` with **`key_indicator`**, `alias`, `virtual_indicator`, `type` (ref `if_xco_cds_field_type`), `association`/`composition`. Verified BOOKINGUUID = `[KEY]`. (`if_xco_cds_field` also implements `if_xco_cds_ann_target` → annotations.)

**M3. Dynamic content read — inline `@DATA()` needs a *static* FROM.** `SELECT * FROM (lv_name) INTO TABLE @DATA(lt)` **fails** at activation: *"Inline data declarations are possible only if … the FROM clause [is] specified statically …"* → generic pattern:
```abap
DATA r TYPE REF TO data.
CREATE DATA r TYPE TABLE OF (lv_name).
ASSIGN r->* TO FIELD-SYMBOL(<t>).
SELECT * FROM (lv_name) INTO TABLE @<t> UP TO n ROWS.
```
(a *static* FROM, e.g. `FROM zc_vibe_booking`, *can* use inline `@DATA`.)

**M4. JSON via `xco_cp_json`** (codezentrale: *OData als JSON-String*). `ZCL_VIBE_JSON`.
- `xco_cp_json=>data->from_abap( lt )->to_string( )` → JSON string (RAW UUID fields come out base64).
- `xco_cp_json=>data->from_string( json )->write_to( REF #( lt ) )` → back to ABAP. Round-trip verified (3 rows).

**M5. Parallel processing — `cl_abap_parallel`.** `ZCL_VIBE_PARALLEL`.
- Subclass `cl_abap_parallel`, **redefine `do` in PUBLIC SECTION** — *"In a redefinition, the visibility cannot be changed"* if placed in PROTECTED (base `do` is PUBLIC).
- `do( IMPORTING p_in TYPE xstring EXPORTING p_out TYPE xstring )` runs in a **parallel work process** → self-contained; marshal via `cl_abap_codepage=>convert_to/convert_from`.
- `NEW …( p_num_tasks = N )` then `->run( EXPORTING p_in_tab = <table of xstring> IMPORTING p_out_tab = lt_out )`; each `lt_out` row = `RESULT`(xstring)/`INDEX`/`TIME`(ms)/`MESSAGE`. Verified: 8 tasks / 4 workers ran as **2 waves of 4** (start timestamps cluster per wave = real parallelism).

**M6. Read the API before building.** For unfamiliar standard classes/interfaces, `curl …/oo/{classes|interfaces}/<name>/source/main` first to get exact signatures (did this for `cl_abap_parallel` do/run and `if_xco_cds_field(_content)` key_indicator) — avoids guess→activation-fail loops on a slow system.

**M7. Builders by object type — source-based vs object-XML.** `tools/build.sh <type>` (+ per-type wrappers) covers **class · prog · cds · tabl · doma · dtel · intf · fugr · fm**, all verified live (three flows: source-based, object-XML, create-only).
- **Source-based** (CLAS/PROG/DDLS-CDS/TABL): create skeleton → lock → **PUT text to `…/<obj>/source/main`** → unlock → activate. Tables ARE source-based on 758 (`define table ztb { key client : abap.clnt not null; … }`, media `tables.v2+xml`, create root `<blue:blueSource type=TABL/DT>`).
- **Object-XML** (DOMA, DTEL — **no `source/main`**, 404): create skeleton → lock → **PUT the whole object XML to the object URI** (`/ddic/domains/<n>` media `domains.v2+xml`; `/ddic/dataelements/<n>` media `dataelements.v2+xml`) → unlock → activate. The schema is **strict on element presence/order** → PUT 400 *"System expected the element X"*: a domain's `<doma:valueInformation>` must include `<doma:fixValues/>` (even empty); a data element needs the **full** `<dtel:dataElement>` set in order (`typeKind`/`typeName`/`dataType`/`dataTypeLength`/`dataTypeDecimals`/{short,medium,long,heading}Field{Label,Length,MaxLength}/`searchHelp`/`searchHelpParameter`/`setGetParameter`/`defaultComponentName`/`deactivateInputHistory`/`changeDocument`/`leftToRightDirection`/`deactivateBIDIFiltering`). **Model the XML on an existing object's GET** (`curl …/ddic/{domains|dataelements}/<existing>`).
- **Buildable via ADT (from discovery `<app:collection>`), not yet in build.sh:** Structure (`/ddic/structures`), Table Type (`/ddic/tabletypes`), **Lock Object** (`/ddic/lockobjects/sources` — source-based; an earlier note that lock objects 404 was wrong, that was the *object* path `/ddic/lockobjects/<n>`, not the create collection), TypeGroup, Table Index; RAP/services BDEF (`/bo/behaviordefinitions`), SRVD (`/ddic/srvd/sources`), SRVB (`/businessservices/bindings`), DCL (`/acm/dcl/sources`), DDLX/DDLA, OData V4/V2; XSLT (`/xslt/transformations`), Program Include (`/programs/includes`); Enhancement/BAdI impl+spot (`/enhancements/*`).
- **Genuinely NOT createable via ADT** (no discovery collection → GUI only): Search Help (→ use CDS value-help annotations), classic maintenance View (→ CDS view entity), dynpro screens, SICF nodes, authorization objects, number ranges. Modern ABAP also lets you skip DOMA/DTEL — type fields with built-in types (`abap.char(n)`).
- **vsp `create` capability (probed):** supports CLAS/PROG/INTF/FUGR/TABL/DEVC (TABL via a dedicated `create target="TABL"` with a structured `fields` param), but **returns *"unsupported object type"* for DOMA/DD and DTEL/DE**. So the raw-REST builders aren't only a create-timeout workaround — for **DDIC metadata types (DOMA/DTEL) they fill a real vsp gap** (vsp can't make them at all; only raw ADT REST or Eclipse/SE11 can). For TABL, raw REST also lets you write the `define table` source directly instead of vsp's structured `fields` param.
- **INTF** (interface) is **source-based** like a class (`source/main` text, create root `<intf:abapInterface>`, media `oo.interfaces.v5+xml`, type `INTF/OI`). **FUGR** (function group) is a **create-only container**: `tools/abap --type fugr --name <NAME>` takes **no source** — it just creates + activates the group shell (the FUGR's `source/main` is the system-generated function-pool include, not user content). `activationExecuted="false"` on the empty group is **benign** (the shell is created `active` — verified via GET `adtcore:version="active"`); add function modules separately via `POST …/functions/groups/<fg>/fmodules` (media `functions.fmodules.v3+xml`). build.sh's `MODE=createonly` skips the lock/PUT/unlock steps for FUGR. **FM** (function module) lives *under* a group: URI `/functions/groups/<fg>/fmodules/<fm>`, type `FUGR/FF`, media `fmodules.v3+xml`, source-based but with an **inline signature** (`FUNCTION z.. IMPORTING VALUE(iv) TYPE .. EXPORTING ... .` — never the `*"` block). `tools/abap <src> --group <GROUP>` builds the FM (the `fm` path builds the nested URL + activates with `FUGR/FF`).
- **More source-based types added + verified:** **DCL** (`/acm/dcl/sources`, `define role`, type DCLS/DL), **Structure** (`/ddic/structures`, `define structure`, type TABL/DS via `<blue:blueSource>` — ⚠ DDIC name rule: **no `_` at the 2nd/3rd char**, so `ZVIBE_STRU` not `ZS_VIBE_DEMO`), **XSLT** (`/xslt/transformations`, type XSLT/VT — create XML needs `trans:transformationType="XSLTProgram"`), **TypeGroup** (`/ddic/typegroups`, legacy). **BDEF** (RAP behavior, `/bo/behaviordefinitions`, `<blue:blueSource>` type BDEF/BDO) — case added + root verified, but a real BDEF needs its CDS root + persistent table + behavior pool to activate.
- **RAP service exposure ADDED + verified live (headless OData V4):** **SRVD** (`/ddic/srvd/sources`, source-based `define service { expose <Entity> as <Alias>; }`, root `<srvd:srvdSource>` type SRVD/SRV) + **SRVB** (`/businessservices/bindings`, XML-object, `<srvb:serviceBinding srvb:contract="C1">` → `<srvb:serviceDefinition>` ref + `<srvb:binding srvb:type="ODATA" srvb:version="V4">`, type SRVB/SVB; `tools/abap --type srvb --name <BINDING> --srvd <SRVD>`). ⚠ **Activation is NOT enough — you must PUBLISH:** `POST /sap/bc/adt/businessservices/odatav4/publishjobs?servicename=<binding>&serviceversion=0001` with an `<adtcore:objectReferences>` body (URL params alone → 400 "expected objectReferences"; without publish → `published=false` → OData 404 "service group not published"). `tools/abap` auto-publishes the srvb after activate. **Live URL:** `/sap/opu/odata4/sap/<binding_lc>/srvd/sap/<srvd_lc>/0001/<EntitySet>`. Verified: SRVD exposing `ZC_VIBE_BOOKING` → `…/Booking?$top=2&$format=json` returns live JSON rows (200). (Exposing an unsuitable view — e.g. an interface view over a client table with `mandt` as key — publishes but the query 500s "Metadata_Error"; expose a proper projection/consumption view.)
- **Not added (by ROI call):** **Enhancement/BAdI** (`/enhancements/*`) — XML/wizard-type, not RAP, low ROI → **dropped**. **TTYP** (table type) is XML-object (source/main 404), not yet added.
- **Consolidated into one CLI — `tools/abap`** (replaces the 15 `build_*.sh` wrappers): a Python script (urllib, no deps) with a **type registry** (data) + **auto-detection** — type from extension + first source line, name from the declaration regex (`CLASS x`, `define structure x`, `define service X`, `adtcore:name=` for XML, …). `tools/abap <file>` builds anything; flags `--type/--name` (no-source types fugr/srvb), `--group` (fm), `--srvd` (srvb), `--run` (classrun). **Gotcha porting curl→urllib:** urllib sends NO default `Accept` header, and several ADT endpoints (class/doma source PUT, `publishjobs`) reject with *"Accept header missing"* → set `Accept: */*` on every request (curl defaults it). `tools/build.sh` (bash) stays as the low-level reference/fallback; both share the exact same REST flow. **All 16 types re-verified live via `abap`** — incl. `bdef` proven by building a full **managed RAP BO** (root view `ZI_VIBE_DEMO` over `ZTB_VIBE_DEMO` + bdef + empty behavior pool class `ZBP_I_VIBE_DEMO`): the bdef needs `authorization master ( instance )` under `strict(2)` and its impl class to exist; the bdef↔pool-class circular pair **mass-activates** (one `/activation` call with both refs — K6). The system runs hot (~90% mem) so create occasionally returns a transient **503** (cascading to "CSRF token validation failed" on the next lock); `abap` now **retries once on 503/conn-drop**, which clears it.

---

## N. Session 6 — ZUTIL standard library: DEVC-create REST, cloud-readiness ATC, classrun timing, message-class-free exceptions

> Building the reusable **ZUTIL** util library (`ZUTIL_PLAN.md`) headless via `tools/abap`. Connectivity: from this shell the **home LAN `<HOME_LAN_IP>` is unreachable** (TCP refused instantly); only the **public IP** answers → build over **HTTPS :50001** (`--host https://<PUBLIC_IP>:50001 --insecure`, self-signed) so basic-auth isn't cleartext, and `--package ZUTIL`.

**N1. Create a package (DEVC) via raw ADT REST** — not in `tools/abap` (no DEVC type). `POST /sap/bc/adt/packages?corrNr=<transport>`:
- Media type **`application/vnd.sap.adt.packages.v2+xml`** — v1 returns **415** (both are advertised in discovery `<app:accept>`, but only v2 accepts the create).
- Body `<pak:package>` needs, **in order**: `<pak:attributes pak:packageType="development"/>`, `<pak:superPackage/>`, `<pak:applicationComponent pak:name=""/>`, `<pak:transport><pak:softwareComponent pak:name="HOME"/><pak:transportLayer pak:name=""/></pak:transport>`, then **`<pak:useAccesses/><pak:packageInterfaces/><pak:subPackages/>`** (omit → 400 *"System expected the element useAccesses"*).
- Root attrs must include **`adtcore:responsible="<valid user>"`** (omit → 400 *"Enter a valid user … as the person responsible"*) + `adtcore:masterLanguage="EN"` + `adtcore:name` / `adtcore:type="DEVC/K"` / `adtcore:description`. → **201**, no separate activation. Model on an existing `GET /sap/bc/adt/packages/<pkg>`.

**N2. classrun "does not implement if_oo_adt_classrun~main" on the FIRST call after activate → succeeds on retry.** Right after a fresh activate, `POST /oo/classrun/<name>` can falsely report the class doesn't implement `main` (activation metadata lag); the SAME call succeeds on the 2nd/3rd try (source GET confirms `main` present + `version=active`). `tools/abap --run` fires classrun immediately post-activate → hits this. **Workaround: retry classrun once on "does not implement".** (Candidate fix for `tools/abap`.)

**N3. ABAP Unit test-class include is NOT writable via raw ADT REST.** `PUT …/oo/classes/<c>/includes/testclasses` → **500 *"<CLASS>…CCAU does not have any inactive version"*** (GET the include first → 404; it's never instantiated). Re-PUTting `source/main` to force an inactive class version first doesn't help. So headless ABAP Unit for global classes needs **VSP** (`deploy_from_file` handles class includes — see A2) or an unsolved include-create flow. → In this lab, **verify via `if_oo_adt_classrun` runner + ATC** instead (the ZUTIL plan's primary verify path).

**N4. The system's DEFAULT ATC check variant is the cloud-readiness / restricted-scope one.** `tools/abap --atc` uses `systemCheckVariant` from customizing, and here it flags — as **P1** — things that are valid on-prem: **non-released APIs** (`cl_numberrange_runtime`, `DATE_COMPUTE_DAY`), **`OPEN/READ/TRANSFER DATASET`** ("Syntax error in restricted language scope (file interface)" + "directory traversal risk"); and **`sy-datum`** as **P2** ("restricted language scope (SY fields)"). Objects still **activate=true** (standard ABAP compiles fine) — only the cloud-readiness ATC objects. Consequences:
- Prefer released/deterministic alternatives where cheap: weekday via **date arithmetic** (`( ( date - '20200106' ) MOD 7 ) + 1`; anchor = a known Monday; ABAP `MOD` is non-negative for a positive divisor) instead of `DATE_COMPUTE_DAY`; **`cl_abap_context_info=>get_system_date( )`** (behind a `ZIF_UTIL_SYSTEM` seam) instead of `sy-datum`.
- For code that legitimately MUST use on-prem-only APIs (number ranges, DATASET file IO, later IDoc `EDIDC`/`EDIDS` selects + `RSLG_*`/`TH_WPINFO`): accept the findings as **advisory** — build with **`--atc-max-prio 0`** (ATC runs + reports but never gates) and document, or pragma-suppress. Refines `ZUTIL_PLAN.md` §5: the *default* variant here is stricter than "classic".

**N5. Message-class-free exception (no SE91/MSAG — which isn't headless-buildable).** `ZCX_UTIL INHERITING FROM cx_static_check` + `INTERFACES if_t100_dyn_msg`; raise free text against SAP's standard message class **`00` / no `001`** (text `&1&2&3&4`) via `textid = VALUE scx_t100key( msgid='00' msgno='001' attr1='IF_T100_DYN_MSG~MSGV1' … attr4=… )` and `msgv1..4` = the text split 4×50 (`lv_text(50)`, `+50(50)`, …; declare `lv_text TYPE c LENGTH 200` so the offsets never overflow). `get_text( )` then renders the full free text — **verified live**. Non-final exception classes still need an (empty) **`PROTECTED SECTION.` / `PRIVATE SECTION.`** (activation warning otherwise); don't `CONV #( )` a `c(50)` into `symsgv` (redundant-conversion warning).

**N6. `OPEN/READ DATASET` works at runtime on A4H even though ATC (N4) forbids it.** `DEV001` has the file-IO auth, and a **bare filename** (`zutil_demo.txt`) opens relative to the work-process dir → write+read round-trip returned `"hello from zutil"` live. So the FILE util is functional on-prem; the ATC P1 is purely a cloud-readiness signal. (Cross-cutting design: put non-deterministic/system state — now/today/uuid, and non-CDS table/FM reads — behind a `ZIF_UTIL_*` provider interface so classes stay ABAP-Unit-mockable even when the raw source can't be doubled.)

**N7. `cl_bcs_mail_message` is NOT a simple fluent send API.** `if_bcs_mail_message` doesn't exist (GET **404**); `cl_bcs_mail_message` exposes a `create_instance` **factory** (returns `ref cl_bcs_mail_message`, raises `cx_bcs_mail`) + only **low-level** public methods (`add_recipient_to_request`, `set_envelope_sender`, `internal_send`, …) — **no high-level `set_subject`/`set_main`/`send`**. Composing+sending headless is non-trivial and unverifiable without SMTP/SCOT. → `ZCL_UTIL_MAIL` is kept as a **fluent builder** (`to`/`subject`/`body_html`) whose `send( )` **raises `zcx_util` "SMTP/BCS not configured"** (explicit + catchable, never a silent no-op); swap that body for the BCS call once SMTP is wired. (Recon first per M6 — read `…/oo/classes/<c>/source/main`, split on `PROTECTED SECTION`, list `METHODS`.)

**N8. `cl_abap_parallel` exact contract (extends M5).** `run( IMPORTING p_in_tab TYPE cl_abap_parallel=>t_in_tab … EXPORTING p_out_tab TYPE t_out_tab )` where **`t_in_tab = STANDARD TABLE OF xstring WITH NON-UNIQUE DEFAULT KEY`** — a `… WITH EMPTY KEY` table is **not type-compatible** (activation error *"LT_IN is not type-compatible with formal parameter P_IN_TAB"*) → declare `DATA lt_in TYPE cl_abap_parallel=>t_in_tab`. Output rows carry `result`(xstring)/`index`/`time`/`message`. Subclass + `METHODS do REDEFINITION` (base `do` is PUBLIC → redefine in PUBLIC); a **redefinition can't carry an ABAP-Doc `"!`** ("No ABAP Doc comments are possible for the current statement"), and the non-final subclass needs an (empty) `PROTECTED SECTION.`/`PRIVATE SECTION.`. `cl_abap_parallel` + `cl_abap_codepage` are ATC-non-released (N4) → build `--atc-max-prio 0`. Verified live: 2 tasks → `ALPHA BETA`.

**N9. DDIC config table + reader, fully headless.** `ZUTIL_CONFIG` (`define table` via `tools/abap` type **`tabl`**: `key client : abap.clnt not null; key cfgkey : abap.char(60)…; changed_at : timestampl;`) built + activated + **ATC-clean** (a plain transparent table needs no non-released API). `ZCL_UTIL_CONFIG` `get`/`set` via client-dependent `SELECT SINGLE cfgvalue … WHERE cfgkey = @lv` / `MODIFY zutil_config FROM @ls` + `COMMIT WORK` — round-trip verified live (`set('DEMO_KEY','demo_val_42')` → `get` returns it). Use **`cl_abap_context_info=>get_user_technical_name( )`** (released) for a changed-by field, not `sy-uname` (restricted-scope per N4).

> **(operational)** Passing `tools/abap` flags via a shell variable in **zsh** silently does **not** word-split (`$FLAGS` → one arg → argparse *"unrecognized arguments"* / exit 2). **Inline the flags** (`--host … --insecure --package ZUTIL …`) or use a zsh array (`flags=(…); tools/abap f "${flags[@]}"`). Also capture the real exit code before any `| sed` mask — zsh `$?` after a pipe is the mask's, not the tool's (use `cmd > out; E=$?; sed … out`).

**N10. Generic itab ↔ `.xlsx` round-trip, headless + no-install — VERIFIED live (Phase 3 Excel).**
- **WRITE (native SALV, no abap2xlsx):** copy the input into a writable table ref first (`CREATE DATA lr LIKE it_data. ASSIGN lr->* TO <t>. <t> = it_data.` — `cl_salv_table=>factory` needs a `CHANGING t_table`, an IMPORTING param can't be passed there), then `cl_salv_table=>factory( IMPORTING r_salv_table = lo CHANGING t_table = <t> )` → `cl_salv_controller_metadata=>get_lvc_fieldcatalog( r_columns = lo->get_columns( ) r_aggregations = lo->get_aggregations( ) )` → `cl_salv_ex_util=>factory_result_data_table( r_data = lr t_fieldcatalog = lt_fcat )` → `cl_salv_bs_lex=>export_from_result_data_table( is_format = if_salv_bs_lex_format=>mc_format_xlsx ir_result_data_table = <rdt> IMPORTING er_result_file = rv_xstring )`. Output is a real `.xlsx` — starts with **`504B`** ("PK" zip magic); a 2-row demo → 3766 bytes. (`factory_result_data_table` returns `cl_salv_ex_result_data_table`, accepted where `export` wants `ir_result_data_table` — it's a subclass of `cl_salv_bs_result_data_table`.)
- **READ (`cl_fdt_xl_spreadsheet`, on-prem/non-released → ATC-advisory):** `NEW cl_fdt_xl_spreadsheet( document_name = 'x' xdocument = xs )` (raises `cx_fdt_excel_core`) → `->if_fdt_doc_spreadsheet~get_worksheet_names( IMPORTING worksheet_names = lt )` → `->get_itab_from_worksheet( lt[1] )` returns **`REF TO data`** (dynamic table, **every cell a string**, generic column names a/b/c, **first row = the header**). `ASSIGN rr->* TO <FS TYPE ANY TABLE>` to use it; serialize with `zcl_util_json` to inspect. Round-trip verified live: `{id,name,city}` × 2 → xlsx → read back Alice/Seoul, Bob/Busan.
- **`xco_cp_xlsx` read-access** is the released/ATC-clean alternative to swap into the reader when cloud-readiness matters; SALV write is already close to clean.

**N11. Phase 4 (IDoc monitor) — CDS → OData V4 over EDIDC + 3 headless gotchas.**
- **Method/interface parameters can NOT use a `LENGTH`/`DECIMALS` addition** (`… TYPE c LENGTH 1`). The class source-scanner rejects the whole PUT with **400 *"the class can't be separated into its different source parts"* (`OO_SOURCE_BASED011`)** — a misleading error whose real cause is the invalid param type (and it persists across delete+recreate, so don't chase a "corrupted shell"). Fix: declare `TYPES ty_x TYPE c LENGTH 1` and reference it, or use a DDIC/table-field type (`TYPE edidc-direct`). (`CONSTANTS`/`TYPES`/`DATA` *do* allow `LENGTH`.)
- **`define view entity … as projection on X`** is a **RAP transactional** projection → activation fails *"Transactional Projection View must be part of a business object"* (`SD_CDS_PC_TQ 009`). For a read-only consumption / OData view use **`as select from X`**.
- **Generically-typed host variables (`TYPE clike`) can't appear in an ABAP-SQL `WHERE`** → *"No generically typed variables (like IV_DIRECTION) can be used in expressions"*. Type such params concretely (`TYPE edidc-direct` / `edidc-mestyp`).
- **Chain (all headless):** CDS interface view over `EDIDC` LEFT JOIN `TEDS2` (status text, `teds2.langua = $session.system_language`) → consumption `as select from` → `srvd` (`define service { expose <View> as IDocs; }`) → `srvb` V4 (`tools/abap --type srvb --name … --srvd …`, auto-publishes → *"published locally"*). **Live OData V4 verified 200 + valid JSON** (`value:[]` — EDIDC/EDIDS COUNT=0 on the trial, so structure verified, not content). Everything reading `EDIDC` is ATC-non-released → `--atc-max-prio 0`. `classify(status,direction)` is direction-dependent (`CASE lv_st WHEN a OR b`): verified in/51=E, in/53=S, in/64=P, out/12=S, out/02=E.

## O. Session 6 (cont.) — Phase 5 daily system-health check: doma/dtel XML, DDIC-structure DDL, ADBC on HANA, check framework

> Phase 5 (`ZUTIL_PLAN.md` §4.C) = EarlyWatch-lite: one `ZIF_UTIL_CHECK` per legacy BC daily-check item (ST22/SM13/SM37/SM12/SP01/SM21/SM50/DB), all data behind a `ZIF_UTIL_CHK_SOURCE` seam (the only layer touching system tables/FMs/ADBC), a registry runner that isolates each check and persists a snapshot under one `cl_system_uuid` run-id → CDS → OData V4. **22 objects, all headless, live-verified (self-test PASS + real-data live run + OData 200).**

**N12. Domain (`doma`) + data element (`dtel`) built headless via `tools/abap` type `doma`/`dtel` — the source file IS the full ADT object XML (mode=xml), PUT verbatim.** No local example existed (Phases 1–4 had none) → **model the XML on a live GET of a real SAP object** (`GET /sap/bc/adt/ddic/domains/shkzg` with `Accept: application/vnd.sap.adt.domains.v2+xml`; dtel = `/dataelements/…` v2). Musts:
- **Domain**: `<doma:domain xmlns:doma=… xmlns:adtcore=… adtcore:name=… adtcore:type="DOMA/DD" adtcore:description=… adtcore:masterLanguage="EN" adtcore:responsible="DEV001"><adtcore:packageRef adtcore:name="ZUTIL"/><doma:content>` then **in order** `<doma:typeInformation>`(datatype/length **zero-padded `000001`**/decimals) → `<doma:outputInformation>` → `<doma:valueInformation>` with `<doma:fixValues>` (each `<doma:fixValue>` = position `0001`.. ascending / low / **empty `<doma:high/>`** / text). Fixed-value CHAR1 domain (G/W/R/N) built + activated + **ATC-clean**.
- **Data element**: root `<blue:wbobj xmlns:blue="http://www.sap.com/wbobj/dictionary/dtel" …>` + `<adtcore:packageRef/>` + `<dtel:dataElement xmlns:dtel=…>` with the **exact strict element order** (`typeKind`(=`domain`)→`typeName`→`dataType`→`dataTypeLength`→`dataTypeDecimals`→short/medium/long/heading FieldLabel+Length+MaxLength→`searchHelp`…→`deactivateBIDIFiltering`). **Field-label max caps are fixed: short 10 / medium 20 / long 40 / heading 55**, and each label text ≤ its declared length. Missing any element → 400. Verified live.

**N13. A DDIC structure via DDL (`define structure`, type `stru`) needs BOTH `@EndUserText.label` AND `@AbapCatalog.enhancement.category` — with only the label, PUT fails `400 "Can't save due to errors in source"` (`SBD_MESSAGES/007`).** A `define table` (which already carries the full `@AbapCatalog.*` block) does *not* hit this, so the same component syntax that builds a table fails as a structure until the enhancement-category annotation is added. (Discovered live; fixed by copying wpinfo's header shape: `@EndUserText.label` + `@AbapCatalog.enhancement.category : #NOT_EXTENSIBLE` above `define structure`.) Component types `abap.char(n)`, `abap.int4`, a data-element ref, and `timestampl`/`sysuuid_c32` all work in both `stru` and `tabl`; an `int4` key and a data-element key are fine for a transparent table.

**N14. `if_oo_adt_classrun~main`'s output param type is `if_oo_adt_classrun_out`, NOT `if_oo_adt_output`.** Only matters when a classrun **passes `out` to its own helper methods** (`METHODS foo IMPORTING out TYPE REF TO if_oo_adt_classrun_out`) — the wrong name activates as `activate=false` + *"Type IF_OO_ADT_OUTPUT is unknown"* and classrun reports the misleading *"does not implement main"*. Classruns that only call `out->write( )` inside `main` never reference the type by name so never hit this. (Confirmed via `GET …/oo/interfaces/if_oo_adt_classrun/source/main`.)

**N15. ADBC on HANA — three real traps (all caught by the pre-build review, confirmed live).**
- **Integer division truncates**: `(TOTAL_SIZE - USED_SIZE) / TOTAL_SIZE * 100` over BIGINT columns evaluates `/` first → **0 for any non-empty disk** → the DB free-% check would be **permanently RED**. Fix: multiply before dividing + force decimal + cast: `CAST( ROUND( (TOTAL_SIZE - USED_SIZE) * 100.0 / TOTAL_SIZE ) AS INT )`, wrap in `COALESCE( MIN(…), 100 )` so an empty match reads 100% not 0. Live result went 0% → **87%** after the fix.
- **Catch scope**: `cl_sql_result_set->set_param`/`next` raise `cx_parameter_invalid[_type]` (binding a computed DECIMAL to `TYPE i`), which is **not** a subclass of `cx_sql_exception` — a `TRY … CATCH cx_sql_exception` alone lets it escape and dump, defeating per-check isolation. Catch `cx_sql_exception cx_parameter_invalid` (or `cx_root`). `SYS.M_DISKS` (cols `TOTAL_SIZE`/`USED_SIZE`/`USAGE_TYPE`) is readable by `DEV001` on the trial.

**N16. System-table read gotchas verified live for the check source.** `VBHDR-vbdate` is **CHAR(14) `YYYYMMDDHHMMSS`, not DATS** → a `d(8)` host var in `BETWEEN` blank-pads to 14 and silently drops the current day; build 14-char bounds (`lv(8) = iv_from. lv+8 = '000000'.`). `SNAP` (distinct dump = datum+uzeit+ahost+uname+modno; group-by, never count raw rows) and `VBHDR` both have `mandt`/`vbmandt` as a **non-leading** key → **no automatic client filter** → add `vbmandt = @sy-mandt` explicitly (SNAP dumps are fine cross-client since mandt isn't in the distinct key). `TSP01` spool errors = `rqpjserr`/`rqpjherr` (both int2). `TBTCO` aborted = `status = 'A'` + `strtdate` in window. `ENQUEUE_READ` with `gclient = space guname = space` returns total locks in EXPORTING `number`. `TH_WPINFO` → `wplist LIKE wpinfo`, status char field `wp_status`.

**N17. ATC posture, Phase 5 (refines N4).** Under the cloud-readiness default variant, the **single** class concentrating all P1 "non-released API" findings is `ZCL_UTIL_CHK_SOURCE_DB` (SNAP/VBHDR/TBTCO/TSP01 reads, ENQUEUE_READ/TH_WPINFO, ADBC dynamic SQL, large-table-no-index on TSP01) → build `--atc-max-prio 0`. The pure check classes, interfaces, DDIC, CDS/srvd, runner, stub and classrun are **clean or only P3** ("Strings without text elements" on message literals — pervasive, acceptable in this lab; ABAP-Doc position warnings fixed by keeping `"!` only on methods, plain `"` for type/intro comments). Notably `COMMIT WORK` in the runner was **not** flagged P1/P2 by this system's variant (only the persistence class carried a P3 text-element); the `--atc-max-prio 0` on it was precautionary.

**N18. The check framework pattern (reusable).** `ZIF_UTIL_CHECK` (`meta()` + `run(from,to)`→0..n G/W/R/N rows) — one impl per check; `ZIF_UTIL_CHK_SOURCE` = the mockable data seam (each method returns one int metric → checks are pure threshold logic); `ZCL_UTIL_SYSCHECK` runs each check in its own `TRY … CATCH cx_root`, maps any failure to a **status-N row from `check->meta( )`** (one bad check never aborts the run / never dumps), assigns one `cl_system_uuid` run-id, and persists to `ZUTIL_CHK_LOG` (persist itself guarded → a persist failure surfaces as a visible `PERSIST`/N row, never a silent catch). Headless unit test = a `ZCL_UTIL_CHK_STUB` (fixed metrics) driven by the classrun's **deterministic self-test** (healthy→8×G, critical→G=0/R≥1 asserted) — the N3-compliant substitute for ABAP Unit includes. `created_by` via `cl_abap_context_info=>get_user_technical_name( )`, `created_at`/`now`/`today`/`uuid` via the `ZIF_UTIL_SYSTEM` seam (never `sy-*`). Live: 8 checks, DUMPS=3→W / LOCKS=26 / DB=87% / SYSLOG=N, 2 runs × 8 rows persisted and read back over OData V4.

**N19. (process) A parallel pre-build adversarial review (4 lens agents: compile/type · SQL·FM·ADBC · DDIC-XML · spec/ATC) paid for itself.** It caught the **ADBC integer-division blocker** (silent wrong-RED, invisible to activation *and* ATC), the `vbdate` CHAR(14) window bug, and the too-narrow ADBC catch — all *before* any live round-trip. The live system authoritatively catches compile/activation errors, but **not** logic-correct-but-wrong-value bugs; that gap is exactly what the review closes. Verified live schema/FM facts up front (read-only ADT GETs) so the SELECTs/FM calls compiled first-try — only 2 live fixes needed (N13 structure annotation, N14 classrun output type), both quick.

**N20. Pass-2 adversarial re-review + live boundary test harness (post-activation) found 5 more real defects that pass-1 and ATC both missed.** Four fresh lens-agents (threshold/band · runner/persist/concurrency · data-source semantics · security/OData) re-reviewed the *active* objects, and a throwaway classrun `ZCL_UTIL_CHK_ATEST` ran a per-check G/W/R **boundary matrix** + runner-isolation/empty-registry/inverted-window cases against the live system (deterministic via the stub; the stub gained an `iv_raise` knob to test isolation → N). Confirmed defects + fixes:
- **DB traffic-light band degeneracy** (`ZCL_UTIL_CHK_DB`): the `WHEN pct >= thr-10 THEN W ELSE R` band leaves **RED unreachable for any threshold ≤ 10** (and *always GREEN* at thr=0 — a full disk shows green). Fix: proportional critical floor `crit = nmax( 1, thr/2 )`; default thr=20 unchanged (G≥20/W 10-19/R<10). ATEST case `DB free=0/thr=5 → R` proves it.
- **`COMMIT WORK` hard-coded in a library method** (`ZCL_UTIL_SYSCHECK.persist`): commits the whole LUW → corrupts a RAP save / update-task caller. Fix: `run_all( iv_commit = )` (default X for standalone; pass '' when the caller owns the LUW).
- **Silent all-GREEN on an inverted/future window**: `from > to` makes every `BETWEEN` match zero rows → a false "all healthy". Fix: swap the bounds in `run_all` when inverted.
- **WP stopped-count denylist** (`read_stopped_wp_cnt`): `wp_status` is CHAR7 kernel text with **no DDIC fixed values**, so a `CS 'STOP'/'HALT'/'ENDED'` denylist silently misses `Killed`/`On hold`/`Shutdown`/`Restart`/PRIV (and `'HALT'` matches nothing → dead branch). Fix: **allowlist** — healthy = blank ∨ `CS 'WAIT'` ∨ `CS 'RUN'`, count everything else. Live run then shows WP=0 (no false-positive on a healthy system → allowlist validated empirically).
- **Cross-client / scope bugs in the source**: `SNAP` is **not** auto-client-filtered (leading key is `DATUM`, not a client field) — dumps read system-wide; added `mandt` to the distinct GROUP BY (kept system-wide by design for a basis monitor, documented). `TSP01` is cross-client too (`rqclient` non-leading) → added `rqclient = @sy-mandt`. `read_db_free_pct` now covers **DATA *and* LOG** disks (a full log volume freezes HANA) and returns `COUNT(*)` so an empty match **raises → N** instead of a false 100%-healthy (`COALESCE(…,100)` was a false-GREEN).
- Accepted-with-note (documented, not fixed — lab-appropriate): `read_updterm_count` counts pending+terminated (no clean `vbstate` filter — INT1 kernel-coded); `read_aborted_jobs` misses pre-start aborts (blank `strtdate`) and finished-with-bad-RC jobs (`F`, an SM37 limitation); `read_lock_count` is a raw all-lock count (age not cheap from SEQG3); LOCKS `thr*2` yellow-band + all-checks negative-threshold degenerate on misconfig only (defaults safe). **Security (must-fix before multi-user/production, accept-in-lab):** the consumption CDS ships `@AccessControl.authorizationCheck:#NOT_REQUIRED` (open read of health/dump/username data — contradicts the spec's own `S_IDOCMONI` stance; fixable via the proven headless DCL path, LEARNINGS K7); and raw `get_text( )` of ADBC/persist exceptions is persisted into `Message` and served on that open surface (route detail to a log, persist a generic message). **OData robustness itself is clean**: live probes of malformed `$filter`, an injection-style value, unknown fields, and POST returned clean **400/403** (gateway parses+binds — no SQL passthrough, no 500/dump; client column not exposed; surface is read-only).

*(process)* The pattern holds: activation + ATC prove compile-correctness; **only adversarial review + a boundary test harness catch logic-correct-but-wrong-value defects** (wrong traffic-light color, false all-clear, silent under-count, COMMIT side-effects). Worth a second pass on anything with threshold/state logic.

## P. Cherry-picks from AWS "SAP Clean Core journey using Kiro agents"
Source: `aws-solutions-library-samples/guidance-for-accelerating-sap-clean-core-journey-using-kiro-agents` (Kiro CLI agents + a Python MCP server on :8001 → SAP ADT, Claude Opus 4.5 default). Same MCP→ADT shape as this lab; we kept the *knowledge/data*, dropped the runtime (VSP + raw-REST here is more mature). Deliberately skipped: their MCP server, the Kiro framework, and the agent-per-task 5-way split (workflow.md here is single-Opus implement+review).

**P1. Clean Core A–D rubric — now built into `tools/abap --atc`.** Object grade = **worst ATC finding**: any P1 (Error)→**D** "Not Clean, blocks cloud readiness"; else P2 (Warning)→**C** "Conditionally Clean (internal/undocumented APIs)"; else P3 (Info)→**B** "Pragmatically Clean (documented extension points)"; no findings→**A** "Fully Clean". "One Error = Level D." Implemented as `_cc_level(p1,p2,p3)` fed by the priority buckets `_atc` *already* parses out of `FINDING_STATS` (ordered `[P1,P2,P3]`, padded; falls back to counting `priority=` attrs off the worklist when no stats block). Purely additive: the A–D line is appended to the existing ATC output, the pass/fail gate (`--atc-max-prio`) is unchanged. The grade is only as meaningful as the variant — added `--atc-variant` / `ABAP_ATC_VARIANT` (default = system-configured variant, i.e. old behavior) so you can point it at a real cloud-readiness variant (the AWS agents force `variant: CLEAN_CORE` + `includeDocumentation:true` + `includeQuickFixes:true`). (refines N4/N17.)

**P1-live. Smoke-tested live on A4H (public IP, verify-only ATC on deployed ZUTIL classes) — 3 findings that changed the picture:**
- **A4H's default variant is already `ZABAP_CLOUD_DEVELOPMENT`** — a full cloud-readiness variant (flags "Usage of not released ABAP Platform APIs", "Syntax error in restricted language scope"). So on this system the A–D grade is meaningful on the *default* path; **do not** pass `--atc-variant`. The AWS repo's literal `CLEAN_CORE` **does not exist here** (`GET /sap/bc/adt/atc/checkvariants/CLEAN_CORE` → 404). The variant name is not portable across systems.
- **Gotcha found + fixed:** an ATC run (`POST /atc/worklists?checkVariant=X` → `/atc/runs`) **silently accepts an unknown variant** and executes a weaker fallback check set — `CLEAN_CORE` and a deliberately-bogus `ZZZ_NOPE_XYZ` returned *byte-identical* results (6 findings vs the default's 26), i.e. a wrong/typo'd variant yields a misleadingly clean grade with no error. Fix: when `--atc-variant` is explicit, `_atc` now pre-checks `GET /atc/checkvariants/{NAME}` (200=exists, 404=not) and on miss prints `check variant 'X' not found (HTTP …) — falling back to the system-configured variant`, then uses the real default. Variant is upper-cased first (server case-folds, but keeps display canonical). Default path (no `--atc-variant`) adds **no** extra round-trip.
- **Live grade spread (default variant):** A = `ZCL_UTIL_JSON`/`_LOG`/`_CALENDAR`/`_CONFIG` (0 findings); B = `ZCL_UTIL_SYSCHECK`/`_MAIL`/`_RTTI` (worst = P3 text-element); D = `ZCL_UTIL_CHK_SOURCE_DB` (17 P1 not-released-API), `_FILE` (8 P1), `_PARALLEL`/`_NUMRANGE` (2 P1). **No live Level C observed** — this variant emits only P1 (hard) or P3 (advisory) for these objects; the P2/Warning bucket was 0 everywhere, so worst-P2 never occurred. C is unit-test-proven only. Confirmed live: `FINDING_STATS` prints **comma-separated** counts in `[P1,P2,P3]` order (e.g. `prio 17,0,9`), and `_cc_level`'s printed grade matched the highest-priority finding actually listed in every case.

**P2. SUSG/SCMON dead-code decision matrix (technique — not yet implemented here).** For retiring dormant Z*/Y* objects, combine **runtime stats + call graph + static source refs**, first-match-wins top→bottom:
| exec | callers | in SUSG? | src refs | verdict | conf |
|---|---|---|---|---|---|
| >0 | any | yes | any | USED | HIGH |
| 0 | >0 | yes | any | USED | HIGH |
| 0 | 0 | yes | none (verified) | **UNUSED** | HIGH |
| 0 | 0 | yes | can't verify | LIKELY_UNUSED | MED |
| any | any | **no** | any | INDETERMINATE | LOW |
Guardrails worth stealing: a single caller ⇒ USED even at 0 executions (don't orphan the caller); object absent from the SUSG export ⇒ INDETERMINATE + "manual review", never delete; **never** mark UNUSED with <30 days of observation (`ADMIN0001.xml/DAYS_AVAILABLE`) without asking; deletion is always a *manual* "create transport to delete" step, never auto. Data sources: `DATA*.xml` (exec counters + LAST_USED), `RDATA*.xml` (SUBID1 caller→SUBID2 callee), plus a source scan via ADT. Their parser is `parse-susg.py`. Fits a future ZUTIL/package cleanup pass.

**P3. SAP released-API reference dataset (ground truth for released-vs-internal).** `input/sap-api-reference/` merges five files pulled from **SAP's own public GitHub** — `objectReleaseInfoLatest.json` (deprecated→successor), `objectClassifications_SAP.json` (by app component), `objectClassifications_3TierModel.json`, `objectReleaseInfo_BTPLatest.json`, `objectClassifications.json` — into `api-parsed.json` (~30,201 APIs). This is the authoritative allowlist for "is this custom code calling a released (cloud-safe) API or an internal one," and the basis for classifying objects into business areas (Finance/SD/MM…). The ATC `CLEAN_CORE` variant checks released-API usage server-side, so this dataset is mainly for *offline* classification/mapping. Pull straight from SAP if we ever want local scoring. `custom-mappings.json` overrides SAP defaults.

*(orchestration, FYI only)* Their `AGENTS.md` conventions: checkpoint every 3 objects to `progress.json` for resumable package-wide sweeps; normalize compound types to base (`CLAS/OC`→`CLAS`, which our `TYPES` registry already does); file-based agent hand-off via `/reports/{atc,docs,unused,executive}/`. Only relevant if we do long package-wide batch runs.
