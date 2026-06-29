# REFERENCE — ADT REST build flow & per-type recipe

Technical notes behind `tools/abap` / `tools/build.sh`. These are the things that cost time to discover; collected here so they don't have to be rediscovered.

**Verified on** ABAP Platform 2023 (release 758, A4H developer edition). The endpoints and the build flow are stable across releases; the **media-type version numbers below are what this system accepts** — on a different release a versioned guess can return `415`, in which case pull the exact (often unversioned) media type from discovery (see the note under the table).

## Build flow

All object creation goes through the same sequence (the tool does this for you). Every request carries `X-sap-adt-sessiontype: stateful` so the server keeps session state across lock/PUT/unlock.

1. **CSRF** — `GET /sap/bc/adt/discovery` with header `X-CSRF-Token: Fetch`; read the token from the response header. Keep the cookie (stateful session) for the lock.
2. **Create** — `POST <collection>?corrNr=<transport>` with the object's create XML and the type's create media type. `corrNr` is omitted entirely (not left empty) for local / non-transportable packages.
3. **Lock** — `POST <object-uri>?_action=LOCK&accessMode=MODIFY`, `Accept: application/vnd.sap.as+xml;dataname=com.sap.adt.lock.Result`. Read `<LOCK_HANDLE>`. **If no `<LOCK_HANDLE>` comes back the lock failed — abort; do not PUT or UNLOCK with an empty handle.**
4. **Put source** — `PUT <object-uri>/source/main?lockHandle=...` with `Content-Type: text/plain` for source-based types; **or** `PUT <object-uri>?lockHandle=...` with the object XML + the type media type for object-XML types (domain, data element). Source text is normalized to **LF** line endings (CRLF → LF) before upload.
5. **Unlock** — `POST <object-uri>?_action=UNLOCK&lockHandle=...`.
6. **Activate** — in a **fresh session with a new CSRF token** (lock/PUT rotate it): `POST /sap/bc/adt/activation?method=activate&preauditRequested=false` with an `<adtcore:objectReferences>` body. Use `/activation`, not `/inactiveobjects` (the latter 304s).
7. **Publish** (service bindings only) — `POST /sap/bc/adt/businessservices/odatav4/publishjobs?servicename=<binding>&serviceversion=0001` with an `<adtcore:objectReferences>` body. `0001` is the initial service version auto-assigned at binding creation (also embedded as `srvb:version="0001"` in the create XML) and is constant for a newly published service.
8. **Run** (classes only) — `POST /sap/bc/adt/oo/classrun/<name>` for a class implementing `if_oo_adt_classrun`.

## Per-type recipe

| Type | Collection endpoint | adtcore type | Create media type | Create XML root | Mode | Name from |
|---|---|---|---|---|---|---|
| class | `/oo/classes` | `CLAS/OC` | `oo.classes.v4+xml` | `class:abapClass` | source | `CLASS x DEFINITION` |
| interface | `/oo/interfaces` | `INTF/OI` | `oo.interfaces.v5+xml` | `intf:abapInterface` | source | `INTERFACE x` |
| program | `/programs/programs` | `PROG/P` | `programs.programs.v2+xml` | `program:abapProgram` | source | `REPORT`/`PROGRAM x` |
| function group | `/functions/groups` | `FUGR/F` | `functions.groups.v3+xml` | `group:abapFunctionGroup` | create-only | (arg) |
| function module | `/functions/groups/<g>/fmodules` | `FUGR/FF` | `functions.fmodules.v3+xml` | `fmodule:abapFunctionModule` | source | `FUNCTION x` |
| CDS view | `/ddic/ddl/sources` | `DDLS/DF` | `ddlSource+xml` | `ddl:ddlSource` | source | `define [root] view entity / abstract entity / hierarchy X` |
| DCL | `/acm/dcl/sources` | `DCLS/DL` | `dclSource+xml` | `dcl:dclSource` | source | `define role X` |
| table | `/ddic/tables` | `TABL/DT` | `tables.v2+xml` | `blue:blueSource` | source | `define table x` |
| structure | `/ddic/structures` | `TABL/DS` | `structures.v2+xml` | `blue:blueSource` | source | `define structure x` |
| type group | `/ddic/typegroups` | `TYPE/DG` | `ddic.typegroups.v2+xml` | `atypgr:abapTypeGroup` | source | `TYPE-POOL x` |
| XSLT | `/xslt/transformations` | `XSLT/VT` | `transformations+xml` | `trans:transformation` | source | (filename) |
| behavior def. | `/bo/behaviordefinitions` | `BDEF/BDO` | `blues.v1+xml` | `blue:blueSource` | source | `define behavior for X` |
| service def. | `/ddic/srvd/sources` | `SRVD/SRV` | `ddic.srvd.v1+xml` | `srvd:srvdSource` | source | `define service X` |
| service binding | `/businessservices/bindings` | `SRVB/SVB` | `businessservices.servicebinding.v2+xml` | `srvb:serviceBinding` | create-only + publish | (arg) |
| domain | `/ddic/domains` | `DOMA/DD` | `domains.v2+xml` | `doma:domain` | object-XML | `adtcore:name` |
| data element | `/ddic/dataelements` | `DTEL/DE` | `dataelements.v2+xml` | `blue:wbobj` | object-XML | `adtcore:name` |

All endpoints are under `/sap/bc/adt`. "Mode" — *source*: text → `…/source/main`; *object-XML*: full object XML → object URI; *create-only*: no source PUT. The create XML also carries type-specific attributes (e.g. `class:final/visibility/category`, `program:programType="executableProgram"`, `fmodule:processingType="normal"`, `trans:transformationType="XSLTProgram"`, `srvb:contract="C1"` + `srvb:binding type="ODATA" version="V4"`); see the `TYPES` registry in `tools/abap` for the exact payloads.

**AMDP table functions** ride the same DDLS path (`/ddic/ddl/sources`, `DDLS/DF`, build with `--type cds`): the DDLS + its implementation class **mass-activate together** (see Gotchas), and a client-dependent table function must declare a `CLNT` key field first.

**Media types** are all under `application/vnd.sap.adt.`. The version numbers above are what this system (758) accepts. If a create `POST` returns **`415 Unsupported Media Type`** on another release, fetch the authoritative value from `GET /sap/bc/adt/discovery` → the collection's `<app:accept>` element. New/custom DDIC objects often take the **unversioned** form (`…<x>Source+xml`, e.g. `dclSource+xml`, not `…acm.dcl…`).

## Discovering system values (instead of hardcoding)

Port/client/package/transport differ per system, so the tool reads or probes them rather than assuming. `abap probe` uses these read-only endpoints:

- **Client** — `sap-client` is a query param. Omit it and the server uses the logon default client (verified: `GET …/discovery` without `sap-client` → 200). So the tool omits it unless `SAP_CLIENT` is set.
- **Package** — `GET /sap/bc/adt/packages/<name>` returns 404 if it doesn't exist, else `adtcore:type` (`DEVC/K` = transportable, needs a transport; otherwise local), `adtcore:responsible`, and `pak:softwareComponent`. Use it to validate the target before building.
- **Transport** — `GET /sap/bc/adt/cts/transportrequests/<id>` returns `tm:status_text` (`Modifiable` = open, `Released` = closed), `tm:owner`, `tm:type` (`K` workbench / `W` customizing), `tm:target`. Use it to confirm a transport is open and yours before writing to it.
- **Host/port** come entirely from `SAP_URL`.
- **TLS** — certificates are verified by default; pass `--insecure` to skip verification for self-signed development systems only.

The principle: anything that varies by system is discovered or asked, never baked in.

## Gotchas

- **Send an `Accept` header.** Several endpoints (class/domain PUT, `publishjobs`) reject a request with *"Accept header missing"*. `curl` sends `*/*` by default; raw HTTP clients (e.g. Python `urllib`) do not — set it explicitly (the tool defaults to `*/*`).
- **Activate in a fresh session.** Lock + PUT rotate the CSRF token. Re-fetch a token (new session) before `/activation`.
- **`activationExecuted="false"` is often benign.** Re-activating an unchanged, already-active object returns false with no errors. Treat it as success unless the response carries `severity="error"` messages.
- **Object-XML schemas are strict.** Domains/data elements want specific child elements in order (e.g. a domain needs `fixValues`, even if empty; a data element needs the full type + search-help/parameter block). Model the XML on an existing object's `GET`.
- **DDIC naming.** Structure/table names can't have `_` in the 2nd or 3rd character (`ZS_X` is rejected; `ZSX` / `ZCUST_X` are fine).
- **Function module source = inline signature.** Use `FUNCTION z_x IMPORTING VALUE(iv_a) TYPE ... EXPORTING ...` (like a method), **not** the classic SE37 `*"…Local Interface` comment block — the `*"` form returns `400` on PUT.
- **Mass-activate circular pairs together.** Objects that form a dependency cycle must be activated in **one** `/activation` call listing both references — activating them one at a time leaves them inactive ("zombied"). Applies to: behavior definition ↔ behavior pool class; composition CDS (root ↔ child views); AMDP table-function DDLS ↔ its implementation class.
- **RAP managed BO.** Needs a root CDS view over a persistent table + a behavior pool class. Under `strict ( 2 )` every entity needs `authorization master`/`dependent`.
- **Service bindings must be published.** Activation alone leaves `published=false` → the OData service group returns 404. Publish via `publishjobs` with an `objectReferences` body (URL params alone → 400). The live URL is `/sap/opu/odata4/sap/<binding_lc>/srvd/sap/<srvd_lc>/0001/<EntitySet>`.
- **Expose a projection/consumption view for OData,** not a bare interface view over a client table — the latter publishes but the query 500s with a metadata error.
- **classrun** runs a class that implements `if_oo_adt_classrun` (the runnable "ABAP console" class), via `/oo/classrun/<name>`.
- **ABAP Unit false-positive trap.** A handler dump makes `/abapunit/testruns` return an empty `<aunit:runResult/>` — easily misread as "0 failures = pass". A real pass lists every `testMethod`; an empty `testMethods` plus a `runtimeAbortion`/`fatal` alert is a **dump**, not success. Read the cause from `GET /sap/bc/adt/runtime/dumps` (`Accept: application/atom+xml;type=feed`).
- **Transient 503.** Busy systems intermittently return 503 (which cascades into "CSRF token validation failed" on the next call). The tool retries once.

## HTTP status codes (in ADT context)

| Code | Meaning |
|---|---|
| 400 | Bad payload — malformed create XML, wrong source format (e.g. FM `*"` block), or a syntax/validation error |
| 401 | Auth failed — wrong user / password |
| 403 | Forbidden — missing dev authorization (`S_DEVELOP`) or the package/object isn't writable |
| 409 | Conflict — object locked by another session, or already exists |
| 415 | Unsupported media type — wrong / over-versioned create media type (pull the right one from discovery `<app:accept>`) |
| 422 | Unprocessable — DDIC schema violation (bad name, missing required element) |
| 423 | Locked — a stale or foreign lock is held |
| 503 | Server busy — retry (the tool retries once) |

## Verify a build

- **Read it back** — `GET /sap/bc/adt/<collection>/<object>/source/main` for source, and check `adtcore:version="active"` on the object `GET`.
- **CDS / tables** — data preview: typed `POST /sap/bc/adt/datapreview/ddic?...`, or **freestyle SQL** `POST /sap/bc/adt/datapreview/freestyle` (`Accept: application/vnd.sap.adt.datapreview.table.v1+xml`, CSRF, body = a `SELECT`) which reads any table/CDS and returns column-oriented XML. Or query the generated OData.
- **Services** — `GET …/$metadata` and an entity set on the live OData V4 URL.
- **ABAP Unit** — `POST /sap/bc/adt/abapunit/testruns` with an object-references body → `<aunit:runResult>` (mind the empty-result trap above).
- **ATC** — `POST /sap/bc/adt/atc/runs` (multi-step: configure worklist → run → fetch findings) for static checks; returns `atc:finding` elements.
- **Debug** — pass `--verbose` to dump the raw server response body when an error comes back with an empty message (non-XML JSON/HTML error bodies).
