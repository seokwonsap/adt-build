# REFERENCE — ADT REST build flow & per-type recipe

Technical notes behind `tools/abap` / `tools/build.sh`. These are the things that cost time to discover; collected here so they don't have to be rediscovered.

## Build flow

All object creation goes through the same sequence (the tool does this for you):

1. **CSRF** — `GET /sap/bc/adt/discovery` with header `X-CSRF-Token: Fetch`; read the token from the response header. Keep the cookie (stateful session) for the lock.
2. **Create** — `POST <collection>?corrNr=<transport>` with the object's create XML and the type's create media type. `corrNr` is omitted for local / non-transportable packages.
3. **Lock** — `POST <object-uri>?_action=LOCK&accessMode=MODIFY`, `Accept: application/vnd.sap.as+xml;dataname=com.sap.adt.lock.Result`. Read `<LOCK_HANDLE>`.
4. **Put source** — `PUT <object-uri>/source/main?lockHandle=...` with `Content-Type: text/plain` for source-based types; **or** `PUT <object-uri>?lockHandle=...` with the object XML + the type media type for object-XML types (domain, data element).
5. **Unlock** — `POST <object-uri>?_action=UNLOCK&lockHandle=...`.
6. **Activate** — in a **fresh session with a new CSRF token** (lock/PUT rotate it): `POST /sap/bc/adt/activation?method=activate&preauditRequested=false` with an `<adtcore:objectReferences>` body. Use `/activation`, not `/inactiveobjects` (the latter 304s).
7. **Publish** (service bindings only) — `POST /sap/bc/adt/businessservices/odatav4/publishjobs?servicename=<binding>&serviceversion=0001` with an `<adtcore:objectReferences>` body.
8. **Run** (classes only) — `POST /sap/bc/adt/oo/classrun/<name>` for a class implementing `if_oo_adt_classrun`.

## Per-type recipe

| Type | Collection endpoint | adtcore type | Create media type | Mode | Name from |
|---|---|---|---|---|---|
| class | `/oo/classes` | `CLAS/OC` | `oo.classes.v4+xml` | source | `CLASS x DEFINITION` |
| interface | `/oo/interfaces` | `INTF/OI` | `oo.interfaces.v5+xml` | source | `INTERFACE x` |
| program | `/programs/programs` | `PROG/P` | `programs.programs.v2+xml` | source | `REPORT`/`PROGRAM x` |
| function group | `/functions/groups` | `FUGR/F` | `functions.groups.v3+xml` | create-only | (arg) |
| function module | `/functions/groups/<g>/fmodules` | `FUGR/FF` | `functions.fmodules.v3+xml` | source | `FUNCTION x` |
| CDS view | `/ddic/ddl/sources` | `DDLS/DF` | `ddlSource+xml` | source | `define view ... X` |
| DCL | `/acm/dcl/sources` | `DCLS/DL` | `dclSource+xml` | source | `define role X` |
| table | `/ddic/tables` | `TABL/DT` | `tables.v2+xml` | source | `define table x` |
| structure | `/ddic/structures` | `TABL/DS` | `structures.v2+xml` | source | `define structure x` |
| type group | `/ddic/typegroups` | `TYPE/DG` | `ddic.typegroups.v2+xml` | source | `TYPE-POOL x` |
| XSLT | `/xslt/transformations` | `XSLT/VT` | `transformations+xml` | source | (filename) |
| behavior def. | `/bo/behaviordefinitions` | `BDEF/BDO` | `blues.v1+xml` | source | `define behavior for X` |
| service def. | `/ddic/srvd/sources` | `SRVD/SRV` | `ddic.srvd.v1+xml` | source | `define service X` |
| service binding | `/businessservices/bindings` | `SRVB/SVB` | `businessservices.servicebinding.v2+xml` | create-only + publish | (arg) |
| domain | `/ddic/domains` | `DOMA/DD` | `domains.v2+xml` | object-XML | `adtcore:name` |
| data element | `/ddic/dataelements` | `DTEL/DE` | `dataelements.v2+xml` | object-XML | `adtcore:name` |

All endpoints are under `/sap/bc/adt`. Media types are under `application/vnd.sap.adt.`. "Mode" — *source*: text → `…/source/main`; *object-XML*: full object XML → object URI; *create-only*: no source PUT.

## Discovering system values (instead of hardcoding)

Port/client/package/transport differ per system, so the tool reads or probes them rather than assuming. `abap probe` uses these read-only endpoints:

- **Client** — `sap-client` is a query param. Omit it and the server uses the logon default client (verified: `GET …/discovery` without `sap-client` → 200). So the tool omits it unless `SAP_CLIENT` is set.
- **Package** — `GET /sap/bc/adt/packages/<name>` returns 404 if it doesn't exist, else `adtcore:type` (`DEVC/K` = transportable, needs a transport; otherwise local), `adtcore:responsible`, and `pak:softwareComponent`. Use it to validate the target before building.
- **Transport** — `GET /sap/bc/adt/cts/transportrequests/<id>` returns `tm:status_text` (`Modifiable` = open, `Released` = closed), `tm:owner`, `tm:type` (`K` workbench / `W` customizing), `tm:target`. Use it to confirm a transport is open and yours before writing to it.
- **Host/port** come entirely from `SAP_URL`.

The principle: anything that varies by system is discovered or asked, never baked in.

## Gotchas

- **Send an `Accept` header.** Several endpoints (class/domain PUT, `publishjobs`) reject a request with *"Accept header missing"*. `curl` sends `*/*` by default; raw HTTP clients (e.g. Python `urllib`) do not — set it explicitly.
- **Activate in a fresh session.** Lock + PUT rotate the CSRF token. Re-fetch a token (new session) before `/activation`.
- **`activationExecuted="false"` is often benign.** Re-activating an unchanged, already-active object returns false with no errors. Treat it as success unless the response carries `severity="error"` messages.
- **Object-XML schemas are strict.** Domains/data elements want specific child elements in order (e.g. a domain needs `fixValues`, even if empty; a data element needs the full type + search-help/parameter block). Model the XML on an existing object's `GET`.
- **DDIC naming.** Structure/table names can't have `_` in the 2nd or 3rd character (`ZS_X` is rejected; `ZSX` / `ZCUST_X` are fine).
- **Service bindings must be published.** Activation alone leaves `published=false` → the OData service group returns 404. Publish via `publishjobs` with an `objectReferences` body (URL params alone → 400). The live URL is `/sap/opu/odata4/sap/<binding_lc>/srvd/sap/<srvd_lc>/0001/<EntitySet>`.
- **RAP managed BO.** Needs a root CDS view over a persistent table + a behavior pool class. Under `strict ( 2 )` every entity needs `authorization master`/`dependent`. The behavior definition ↔ pool class form a circular pair — **mass-activate** them together (one `/activation` call listing both object references).
- **Expose a projection/consumption view for OData,** not a bare interface view over a client table — the latter publishes but the query 500s with a metadata error.
- **classrun** runs a class that implements `if_oo_adt_classrun` (the runnable "ABAP console" class), via `/oo/classrun/<name>`.
- **Transient 503.** Busy systems intermittently return 503 (which cascades into "CSRF token validation failed" on the next call). The tool retries once.

## Verify a build

- **Source types** — re-`GET` the object and check `adtcore:version="active"`.
- **CDS / tables** — data preview: `POST /sap/bc/adt/datapreview/ddic?...` or query the generated OData.
- **Services** — `GET …/$metadata` and an entity set on the live OData V4 URL.
- **ATC** — run the ABAP Test Cockpit over the object for static checks.
