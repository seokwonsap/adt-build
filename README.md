# adt-build

**English** · [한국어](README.ko.md)

A headless CLI tool to build and activate ABAP objects directly from source files using the ADT REST API—no Eclipse, no SAP GUI required.

With a single command, adt-build automatically detects the object's type and name, then handles the entire lifecycle: Create → Lock → Upload Source → Activate. It can even execute classruns or publish service bindings over HTTP(S). It supports 16 ABAP object types, including everything needed to expose a RAP service as a live OData V4 endpoint.

```bash
tools/abap zcl_demo.abap --run     # Detects: class ZCL_DEMO → creates, activates, and runs it
tools/abap zi_orders.asddls        # Detects: CDS view ZI_ORDERS
tools/abap --type srvb --name ZUI_ORDERS_O4 --srvd ZUI_ORDERS   # OData V4 binding + auto-publish
```

## Why adt-build?

The standard way to create and activate ABAP objects is via Eclipse ADT or SAP GUI. However, these GUI-based tools become bottlenecks when you want to:

- Automate object creation in CI/CD pipelines.
- Delegate ABAP development to AI coding agents.
- Work remotely without VPN access to the corporate LAN.
- Get things done with zero heavy installations (requires only Python 3 and standard libraries).

Under the hood, ADT is just a REST API. This tool interacts with it directly, abstracting away the undocumented quirks and per-object complexities—such as media types, creation payloads, service-binding publish steps, and RAP mass-activations. (For deep technical details, see [REFERENCE.md](REFERENCE.md)).

## Installation

You only need Python 3 (it strictly uses the standard library; no `pip install` is required). `bash` and `curl` are only needed if you plan to use the optional fallback script.

```bash
git clone <this-repo> && cd adt-build
cp .env.example .env      # Fill in your system details and credentials
```

`.env` Configuration:

```ini
SAP_URL=http://your-host:50000
SAP_USER=DEVELOPER
SAP_PASSWORD=...
SAP_CLIENT=001
SAP_PACKAGE=ZLOCAL
SAP_TRANSPORT=            # Leave empty for local ($TMP) packages
```

**User Requirements:** The user must have a non-initial SU01 password (log in once via SAP GUI to clear the "change on first logon" prompt).

**System Requirements:** ADT must be active on the system (transaction `SICF` → `/sap/bc/adt`).

### System Port Configuration

The port in `SAP_URL` is not fixed; it depends on your system's ICM configuration. If your instance number is `nn`, common values are:

- HTTP: `50000` (`5nn00`) or `8000` (`80nn`)
- HTTPS: `50001` (`5nn01`) or `44300` (`443nn`)

You can find your exact port in transaction `SMICM` → Goto → Services, or by checking the `icm/server_port_*` parameters in the instance profile. When connecting over the internet, prefer HTTPS (use the `--insecure` flag if your dev system uses self-signed certificates).

## Usage

Simply run `tools/abap <file>`. The tool infers the object type from the file extension and the first line of code, and extracts the object name directly from the declaration.

| You write (Source code) | Extension | Detected As |
|---|---|---|
| `CLASS zcl_x DEFINITION ...` | `.abap` | Class `ZCL_X` |
| `INTERFACE zif_x ...` | `.abap` | Interface `ZIF_X` |
| `REPORT zr_x.` | `.abap` | Program `ZR_X` |
| `define view entity ZI_X ...` | `.asddls` | CDS View `ZI_X` |
| `define structure zs_x ...` | `.asddls` | DDIC Structure `ZS_X` |
| `define behavior for ZI_X ...` | `.asbdef` | Behavior Definition |
| `define service ZUI_X { ... }` | `.assrvd` | Service Definition |
| `<doma:domain ...>` | `.xml` | Domain |

**Useful Flags:**

- `--run`: Execute a class via classrun after activation.
- `--group ZFG`: Specify the function group for a function module.
- `--srvd ZX`: Specify the service definition for a service binding.
- `--type` / `--name`: Override automatic detection, or use for objects without source files.
- `--src`: Explicitly define the source file to upload.
- `--host` / `--user` / `--client` / `--package` / `--transport`: Override variables defined in `.env`.
- `--insecure`: Skip TLS certificate verification (for dev systems with self-signed certs).

### Supported Object Types (16)

| Category | Supported Objects |
|---|---|
| OO / Procedural | Class, Interface, Program, Function Group, Function Module |
| DDIC | Table, Structure, Data Element, Domain, Type Group |
| CDS / Access Control | CDS View, DCL Access Control |
| Transformation | XSLT |
| RAP | Behavior Definition, Service Definition, Service Binding (OData V4) |

### Example: CDS View to Live OData V4 (End-to-End)

```bash
tools/abap zi_orders.asddls                                    # 1. Create CDS view
tools/abap zui_orders.assrvd                                   # 2. Create Service definition
tools/abap --type srvb --name ZUI_ORDERS_O4 --srvd ZUI_ORDERS  # 3. Create Binding + Auto-publish

# → Success! GET /sap/opu/odata4/sap/zui_orders_o4/srvd/sap/zui_orders/0001/Orders now returns live JSON
```

## No Guesswork: Explicit Configuration

System-specific values (port, client, package, transport) vary wildly. adt-build never hardcodes these or relies on silent fallbacks:

- The port is explicitly taken from your `SAP_URL`.
- The client is omitted from the header unless `SAP_CLIENT` is set (forcing the server to use your logon default).
- Package and transport values are strictly validated against the live system, never guessed.

Use `abap probe` to see exactly how the tool will interact with the system before executing a build:

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

Because `.env` variables are standing configurations, they might not fit your current task. For AI-driven workflows, the agent should always confirm the scope upfront (e.g., Which package? Local or transportable?), use `probe` to verify the live state, and then execute the build.

## How It Works

For every object, the tool executes the following lifecycle:

Fetch CSRF token → `POST` create (stateful session) → `LOCK` → `PUT` source (or object XML) → `UNLOCK` → `POST` activate in a fresh session (since the lock/PUT rotates the token). Service bindings have an extra publish step, and classes optionally execute.

There are two implementations that follow this exact flow:

- **`tools/abap` (Primary):** Pure Python (standard library only). Features auto-detection and a robust type registry. Runs seamlessly on macOS, Linux, and Windows (use `py tools\abap ...` or the bundled `abap.cmd`). *Verified on macOS/Linux; Windows is supported by design but not yet tested on a Windows host.*
- **`tools/build.sh` (Fallback):** A Bash + Curl script that serves as a transparent reference implementation. (Unix only; use WSL or Git Bash on Windows).

## Use Cases & Integrations

adt-build intentionally focuses on one job: the build step (create, activate, publish). It works great standalone, but shines in automated workflows:

- **AI Agents (e.g., Claude Code):** An agent can write the source code, invoke the CLI to build it, and read the results in a continuous loop.
- **Coupling with MCP Servers:** While `abap probe` and `--run` handle basic reading and execution, you can pair adt-build with a community ADT MCP server (like VSP) for an interactive read/edit/test workflow. adt-build handles the heavy lifting of building, while the MCP handles inspection.
- **MCP Fallback:** Even if an MCP server is blocked or unavailable, this raw REST CLI continues to work reliably.

## Compared to Other Tools

- **abapGit:** Designed for Git-based serialization and transport of existing objects. adt-build focuses on headless creation from local source files via REST.
- **SAP's ADT-for-VS-Code MCP (GA 2026):** Restricted to ABAP Cloud environments. adt-build works against on-premise systems and any ADT-enabled environment.
- **Community ADT MCP Servers:** These wrap the ADT API specifically for AI agents. adt-build is a dependency-free CLI built to be dropped directly into scripts or pipelines.

## Security

Standard HTTP transmits passwords in cleartext. Always prefer HTTPS or route traffic through an SSH tunnel / VPN, especially when working over the internet. Keep your credentials securely in `.env` (which is included in `.gitignore`). Never commit your `.env` file.

## License

MIT — See the [LICENSE](LICENSE) file for details.
