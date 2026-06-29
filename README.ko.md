# adt-build

[English](README.md) · **한국어**

Eclipse도 SAP GUI도 없이 **소스 파일 하나로 ABAP 객체를 만들어 활성화**합니다. ADT REST API를 직접 두드려서, 명령 한 줄이면 타입과 이름을 알아서 파악하고 생성·잠금·소스 업로드·활성화(필요하면 publish나 실행)까지 끝냅니다. 객체 **16종**을 지원하고, RAP 서비스를 **바로 호출되는 OData V4**로 띄우는 것까지 됩니다.

```bash
tools/abap zcl_demo.abap --run     # class ZCL_DEMO 로 인식 → 생성·활성화·classrun 실행
tools/abap zi_orders.asddls        # CDS view ZI_ORDERS 로 인식
tools/abap --type srvb --name ZUI_ORDERS_O4 --srvd ZUI_ORDERS   # OData V4 바인딩 + publish
```

## 왜 만들었나

ABAP 객체를 만들고 활성화하는 정식 경로는 Eclipse ADT, 아니면 SAP GUI입니다. 그런데 이게 다음 같은 상황에선 발목을 잡습니다.

- CI/CD에서 객체 생성을 스크립트로 돌리고 싶을 때
- AI 에이전트한테 ABAP 개발을 맡기고 싶을 때
- 사내망 밖에서 시스템에 붙어야 할 때
- 아무것도 설치하기 싫을 때 (Python 파일 하나, 표준 라이브러리만)

ADT는 속을 보면 결국 REST API입니다. 이 도구는 그걸 직접 호출하고, 타입마다 제각각인 까다로운 부분(미디어 타입, 생성 페이로드, 서비스 바인딩 publish, RAP mass-activation)을 미리 처리해둡니다. 보통은 여기저기 흩어져 있고 문서도 변변치 않은 것들입니다. 자세한 내용은 **[REFERENCE.md](REFERENCE.md)** 에 정리해뒀습니다.

## 설치

필요한 건 **Python 3** 하나입니다 (표준 라이브러리만 쓰니 pip 설치가 없습니다). bash와 curl은 폴백 엔진(`build.sh`)을 쓸 때만 필요합니다.

```bash
git clone <this-repo> && cd adt-build
cp .env.example .env      # 그리고 본인 시스템 정보를 채웁니다
```

`.env`:

```
SAP_URL=http://your-host:50000
SAP_USER=DEVELOPER
SAP_PASSWORD=...
SAP_CLIENT=001
SAP_PACKAGE=ZLOCAL
SAP_TRANSPORT=            # 로컬($TMP) 패키지면 비웁니다
```

계정은 **초기 비밀번호가 풀린** SU01 사용자여야 합니다 (GUI로 한 번 로그인해서 "최초 로그온 시 변경" 상태를 없애둡니다). 그리고 `SICF`에서 `/sap/bc/adt` 가 켜져 있어야 합니다.

### 포트는 시스템마다 다릅니다

`SAP_URL`의 포트는 정해진 값이 아니라 그 시스템의 ICM 설정을 따릅니다. 인스턴스 번호를 `nn`이라 하면 흔한 값은 이렇습니다.

- HTTP: `50000` (= `5nn00`) 또는 `8000` (= `80nn`)
- HTTPS: `50001` (= `5nn01`) 또는 `44300` (= `443nn`)

본인 시스템 값은 트랜잭션 `SMICM` → Goto → Services 에서 보거나, 인스턴스 프로파일의 `icm/server_port_*` 파라미터로 확인합니다. 인터넷을 넘어 다닐 거라면 평문 HTTP 대신 HTTPS 포트를 `SAP_URL`에 넣으세요 (self-signed 인증서면 `--insecure`).

## 사용법

`tools/abap <파일>` 은 확장자와 첫 소스 줄로 타입을 알아내고, 선언부에서 이름을 뽑아냅니다.

| 이렇게 쓰면 | 이렇게 인식 |
|---|---|
| `CLASS zcl_x DEFINITION ...` | 클래스 `ZCL_X` |
| `INTERFACE zif_x ...` | 인터페이스 |
| `REPORT zr_x.` | 프로그램 |
| `define view entity ZI_X ...` (`.asddls`) | CDS 뷰 |
| `define structure zs_x` (`.asddls`) | DDIC 구조 |
| `define behavior for ZI_X ...` (`.asbdef`) | behavior 정의 |
| `define service ZUI_X { ... }` (`.assrvd`) | 서비스 정의 |
| `<doma:domain ...>` (`.xml`) | 도메인 |

플래그: `--run`(클래스를 classrun으로 실행), `--group ZFG`(함수모듈의 그룹), `--srvd ZX`(바인딩의 서비스 정의), `--type` / `--name`(추론 대신 직접 지정, 또는 소스 없는 타입), `--src`(소스 파일 명시), `--host` / `--user` / `--client` / `--package` / `--transport`(`.env` 덮어쓰기), `--insecure`(TLS 인증서 검증 생략 — self-signed 개발 시스템 전용).

### 지원 객체 16종

| 묶음 | 타입 |
|---|---|
| OO / 절차형 | 클래스, 인터페이스, 프로그램, 함수그룹, 함수모듈 |
| DDIC | 테이블, 구조, 데이터요소, 도메인, 타입그룹 |
| CDS / 접근제어 | CDS 뷰, DCL 접근제어 |
| 변환 | XSLT |
| RAP | behavior 정의, 서비스 정의, 서비스 바인딩 → OData V4 |

### CDS 뷰 하나를 OData V4로 (처음부터 끝까지)

```bash
tools/abap zi_orders.asddls                                    # CDS 뷰
tools/abap zui_orders.assrvd                                   # 그걸 노출하는 서비스 정의
tools/abap --type srvb --name ZUI_ORDERS_O4 --srvd ZUI_ORDERS  # 바인딩 + 자동 publish
# → GET /sap/opu/odata4/sap/zui_orders_o4/srvd/sap/zui_orders/0001/Orders  가 라이브 JSON 반환
```

## 추측하지 않고 확인합니다

포트·client·패키지·트랜스포트처럼 시스템마다 다른 값을, 이 도구는 코드에 박아넣거나 슬쩍 기본값으로 때우지 않습니다.

- **포트**는 `SAP_URL` 안에 있습니다. 본인 값 그대로 들어갑니다.
- **client**는 `SAP_CLIENT`를 안 주면 아예 빼고 보냅니다. 그러면 서버가 로그온 기본 client를 씁니다.
- **패키지·트랜스포트**는 추측 대신 시스템에 직접 물어 확인합니다.

빌드 전에 `abap probe` 로 도구가 실제로 무엇과 통신할지 미리 볼 수 있습니다.

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

**패키지와 트랜스포트는 내 변경이 어디에, 어떤 방식으로 떨어질지를 정합니다.** `.env`에 적어둔 값도 결국 미리 정해둔 선택이지, 지금 이 작업에 맞다는 보장은 아닙니다. 그래서 도구는 이 값을 꼭 명시하게 하고(기본값 없음, 알아서 만들어내지 않습니다), AI로 돌릴 땐 에이전트가 **뭘 만들기 전에 범위부터 합의**하는 게 좋습니다.

> 어느 패키지에? · 로컬인가 이송 대상인가? · 권한은 어디까지?

그다음 `abap probe`로 현재 상태를 보여주고, 명시한 값으로 빌드합니다. **확인하고, 합의하고, 그때 씁니다.** 정해둔 설정이 새 작업에도 맞겠거니 하고 넘기지 않습니다.

## 동작 방식

객체 하나마다: CSRF 토큰 받기 → `POST` 생성(stateful 세션) → `LOCK` → 소스(또는 객체 XML) `PUT` → `UNLOCK` → **새 세션**에서 `POST` 활성화(lock/PUT이 토큰을 회전시키기 때문입니다). 서비스 바인딩은 publish가 더 붙고, 클래스는 선택적으로 실행됩니다. 타입별 엔드포인트·미디어 타입·함정은 **[REFERENCE.md](REFERENCE.md)** 에 있습니다.

구현은 둘인데 흐름은 똑같습니다.

- **`tools/abap`** — Python, 주력. 자동 인식 + 타입 레지스트리, 표준 라이브러리만 씁니다.
- **`tools/build.sh`** — bash/curl, 흐름을 그대로 보여주는 레퍼런스 겸 폴백: `build.sh <type> <NAME> <src>`.

**플랫폼.** `tools/abap`은 순수 Python 표준 라이브러리입니다 (pip 없음, curl 없음, 플랫폼 종속 호출 없음). macOS·Linux·Windows에서 돌아갑니다. Windows에서는 `py tools\abap ...` 로 실행하거나, 같이 들어있는 `abap.cmd`를 쓰면 `abap ...` 로 됩니다 (`py` 런처가 없으면 `python`으로 폴백). `tools/build.sh`는 Unix 전용입니다 (bash + curl, Windows면 WSL이나 Git Bash). macOS에서 검증했고, Windows는 설계상 지원되지만(표준 라이브러리만 쓰므로) 실제 Windows 호스트에서는 아직 테스트하지 못했습니다.

## 뭐랑 같이 쓰나

이 도구가 맡는 건 **객체를 만들고 활성화하는 부분**입니다 (create·activate·publish). 단독으로도 돌아가지만, 실제 작업은 보통 이렇게 엮습니다.

- **AI 에이전트(예: Claude Code)** 가 이 CLI를 호출해 빌드를 돌립니다. 소스를 쓰고 → `tools/abap`으로 올리고 → 결과를 읽는 루프.
- **읽기·조회·실행**은 `abap probe`(시스템·패키지·트랜스포트 확인)와 `--run`(classrun)으로 어느 정도 됩니다. 대화형으로 객체를 읽고 고치고 테스트까지 하려면 **ADT MCP 서버**(커뮤니티 ADT MCP, VSP 등)를 같이 붙이면 편합니다. adt-build는 빌드, MCP는 read/edit/test 로 역할을 나누는 식입니다.
- MCP가 막히는 상황에서도 이 raw-REST 빌더는 그대로 도므로, **MCP의 폴백**으로도 씁니다.

## 다른 도구와 비교

- **abapGit** — *기존* 객체를 git으로 직렬화·이송합니다. 이 도구는 *소스 파일에서* ADT REST로 객체를 빌드하니 하는 일이 다릅니다.
- **SAP 공식 ADT-for-VS-Code MCP** (2026 GA) — ABAP Cloud 전용입니다. 이 도구는 온프렘 등 ADT가 켜진 어떤 시스템에서도 됩니다.
- **커뮤니티 ADT MCP 서버들** — 에이전트용으로 ADT API를 감쌉니다. 이 도구는 스크립트나 파이프라인에 바로 넣을 수 있는, 의존성 없는 CLI입니다.

## 보안

평문 HTTP는 비밀번호를 그대로 흘려보냅니다. 특히 인터넷을 넘어갈 때는 `https://` 나 SSH 터널/VPN을 쓰세요. 인증정보는 `.env`에만 두고, 그건 gitignore돼 있습니다. 절대 커밋하지 마세요.

## 라이선스

MIT — [LICENSE](LICENSE) 참고.
