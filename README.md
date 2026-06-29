# adt-build

Build ABAP objects **headless from source files** via the ADT REST API — no Eclipse, no SAP GUI. One command auto-detects the object's type and name, then creates → locks → PUTs source → activates (and publishes / runs) over plain HTTP(S). **16 object types**, including a full RAP service exposed as a **live OData V4 endpoint**.

```bash
tools/abap zcl_demo.abap --run     # detects: class ZCL_DEMO → create, activate, run classrun
tools/abap zi_orders.asddls        # detects: CDS view ZI_ORDERS
tools/abap --type srvb --name ZUI_ORDERS_O4 --srvd ZUI_ORDERS   # OData V4 binding + publish
```

## Why

The supported way to create and activate ABAP objects is Eclipse ADT (or SAP GUI). That's a wall if you want to

- script object creation in CI/CD,
- drive ABAP development from an AI agent,
- work from outside the corporate LAN,
- do it with zero install (one Python file, standard library only).

ADT is a REST API underneath. This tool speaks it directly and encodes the per-object-type quirks — media types, create payloads, the service-binding publish step, RAP mass-activation — that are otherwise scattered and undocumented. See **[REFERENCE.md](REFERENCE.md)**.

## Install

Requires **Python 3** (standard library only — nothing to pip install). `bash` + `curl` only for the optional fallback engine.

```bash
git clone <this-repo> && cd adt-build
cp .env.example .env      # then fill in your system + credentials
```

`.env`:

```
SAP_URL=http://your-host:50000
SAP_USER=DEVELOPER
SAP_PASSWORD=...
SAP_CLIENT=001
SAP_PACKAGE=ZLOCAL
SAP_TRANSPORT=            # leave empty for local ($TMP) packages
```

The user needs a **non-initial** SU01 password (log in once via GUI to clear "change on first logon") and ADT active (`SICF` → `/sap/bc/adt`).

## Usage

`tools/abap <file>` infers the type from the file extension + first source line, and the name from the declaration:

| You write | Detected as |
|---|---|
| `CLASS zcl_x DEFINITION ...` | class `ZCL_X` |
| `INTERFACE zif_x ...` | interface |
| `REPORT zr_x.` | program |
| `define view entity ZI_X ...` (`.asddls`) | CDS view |
| `define structure zs_x` (`.asddls`) | DDIC structure |
| `define behavior for ZI_X ...` (`.asbdef`) | behavior definition |
| `define service ZUI_X { ... }` (`.assrvd`) | service definition |
| `<doma:domain ...>` (`.xml`) | domain |

Flags: `--run` (run a class via classrun), `--group ZFG` (function module's group), `--srvd ZX` (binding's service definition), `--type` / `--name` (override detection, or no-source types), `--src` (explicit source file), `--host` / `--user` / `--client` / `--package` / `--transport` (override `.env`), `--insecure` (skip TLS cert verification — self-signed dev systems only).

### Supported object types (16)

| Cluster | Types |
|---|---|
| OO / procedural | class, interface, program, function group, function module |
| DDIC | table, structure, data element, domain, type group |
| CDS / access control | CDS view, DCL access control |
| Transformation | XSLT |
| RAP | behavior definition, service definition, service binding → OData V4 |

### CDS view → live OData V4 (end to end)

```bash
tools/abap zi_orders.asddls                                    # CDS view
tools/abap zui_orders.assrvd                                   # service definition exposing it
tools/abap --type srvb --name ZUI_ORDERS_O4 --srvd ZUI_ORDERS  # binding + auto-publish
# → GET /sap/opu/odata4/sap/zui_orders_o4/srvd/sap/zui_orders/0001/Orders  returns live JSON
```

## Discover, don't assume

System-specific values vary per system (port, client, package, transport). The tool never hardcodes or silently defaults them:

- **port** is part of `SAP_URL` — yours, whatever it is.
- **client** is omitted unless you set `SAP_CLIENT`; the server then uses your logon default.
- **package / transport** are validated against the system, not guessed.

`abap probe` shows exactly what the tool will talk to before you build:

```
$ abap probe
host     : https://your-host:50001
user     : DEVELOPER
client   : (omitted -> server logon default)
connect  : discovery http=200  (ok)
package  : ZLOCAL  exists (type=DEVC/K, responsible=DEVELOPER, softwareComponent=HOME)
           -> TRANSPORTABLE: a transport request is required
transport: ABCK900123  [Modifiable] owner=DEVELOPER
```

**Package and transport decide where and how your changes land** — and a value sitting in `.env` is a *standing choice*, not necessarily this task's intent. So the tool requires them explicitly (no default — it never invents a target), and for AI-driven use the agent should **confirm scope up front, before creating anything**:

> which package? · local or transportable? · broad access or limited?

Then `abap probe` to surface the live state, and build with explicit values. **Probe, confirm, then write** — never assume the standing config fits a new task.

## How it works

Per object: fetch a CSRF token → `POST` create (stateful session) → `LOCK` → `PUT` source (or object XML) → `UNLOCK` → `POST` activate in a **fresh session** (lock/PUT rotate the token). Service bindings additionally publish; classes optionally run. Full per-type endpoints, media types, and gotchas: **[REFERENCE.md](REFERENCE.md)**.

Two implementations, identical flow:

- **`tools/abap`** — Python, primary. Auto-detection + a type registry, standard library only.
- **`tools/build.sh`** — bash/curl, the transparent reference & fallback: `build.sh <type> <NAME> <src>`.

**Platforms.** `tools/abap` is pure Python standard library (no `pip`, no `curl`, no platform-specific calls) — it runs on macOS, Linux, and Windows. On Windows run `py tools\abap ...`, or use the bundled `abap.cmd` so `abap ...` works (it falls back to `python` if the `py` launcher is absent). `tools/build.sh` is Unix only (bash + curl — use WSL or Git Bash on Windows). Verified on macOS; Windows is supported by design (stdlib-only) but not yet tested on a Windows host.

## Compared to other tools

- **abapGit** — git-based serialization/transport of *existing* objects. This builds objects *from source files* via ADT REST; a different job.
- **SAP's official ADT-for-VS-Code MCP** (GA 2026) — ABAP Cloud only. This works against on-prem / any ADT-enabled system.
- **Community ADT MCP servers** — wrap the ADT API for an agent. This is a dependency-free CLI you can drop straight into a script or pipeline.

## Security

Plain HTTP sends your password in cleartext. Prefer `https://` or an SSH tunnel / VPN, especially over the internet. Credentials live only in `.env`, which is gitignored — never commit it.

## License

MIT — see [LICENSE](LICENSE).
