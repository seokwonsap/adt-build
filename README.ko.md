# adt-build

[English](README.md) · **한국어**

Eclipse도 SAP GUI도 없이 **소스 파일에서 ABAP 객체를 헤드리스로 빌드**합니다. ADT REST API를 직접 호출해서, 명령 하나로 객체의 타입과 이름을 자동 인식하고 생성 → 잠금 → 소스 PUT → 활성화(필요하면 publish/실행)까지 평문 HTTP(S)로 처리합니다. **16종 객체**를 지원하고, RAP 서비스를 **라이브 OData V4 엔드포인트**로 노출하는 것까지 됩니다.

```bash
tools/abap zcl_demo.abap --run     # class ZCL_DEMO 로 인식 → 생성·활성화·classrun 실행
tools/abap zi_orders.asddls        # CDS view ZI_ORDERS 로 인식
tools/abap --type srvb --name ZUI_ORDERS_O4 --srvd ZUI_ORDERS   # OData V4 바인딩 + publish
```

## 왜 만들었나

ABAP 객체를 생성하고 활성화하는 공식 경로는 Eclipse ADT(또는 SAP GUI)입니다. 그런데 다음 같은 걸 하려면 그게 벽이 됩니다.

- CI/CD에서 객체 생성을 스크립트로 돌리기
- AI 에이전트로 ABAP 개발 굴리기
- 사내 LAN 밖에서 작업하기
- 설치 없이 쓰기 (Python 파일 하나, 표준 라이브러리만)

ADT는 그 밑이 REST API입니다. 이 도구는 그걸 직접 호출하고, 타입마다 다른 까다로운 부분(미디어 타입, 생성 페이로드, 서비스 바인딩 publish 단계, RAP mass-activation)을 안에 담아뒀습니다. 이 정보들은 보통 여기저기 흩어져 있고 문서화도 잘 안 돼 있습니다. 자세한 내용은 **[REFERENCE.md](REFERENCE.md)**.

## 설치

**Python 3** 만 있으면 됩니다 (표준 라이브러리만 씁니다. pip 설치 없음). bash와 curl은 선택용 폴백 엔진에만 필요합니다.

```bash
git clone <this-repo> && cd adt-build
cp .env.example .env      # 그다음 시스템 정보와 인증정보를 채웁니다
```

`.env`:

```
SAP_URL=http://your-host:50000
SAP_USER=DEVELOPER
SAP_PASSWORD=...
SAP_CLIENT=001
SAP_PACKAGE=ZLOCAL
SAP_TRANSPORT=            # 로컬($TMP) 패키지면 비워둡니다
```

사용자는 **비초기(non-initial) SU01 비밀번호**가 필요합니다 (GUI로 한 번 로그인해서 "최초 로그온 시 변경" 상태를 풀어둡니다). 그리고 ADT가 켜져 있어야 합니다 (`SICF` → `/sap/bc/adt`).

## 사용법

`tools/abap <파일>` 은 확장자와 첫 소스 줄로 타입을 추론하고, 선언부에서 이름을 뽑습니다.

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

플래그: `--run`(클래스를 classrun으로 실행), `--group ZFG`(함수모듈의 그룹), `--srvd ZX`(바인딩의 서비스 정의), `--type` / `--name`(추론 무시, 또는 소스 없는 타입), `--src`(소스 파일 명시), `--host` / `--user` / `--client` / `--package` / `--transport`(`.env` 덮어쓰기), `--insecure`(TLS 인증서 검증 건너뛰기 — self-signed 개발 시스템 전용).

### 지원 객체 16종

| 묶음 | 타입 |
|---|---|
| OO / 절차형 | 클래스, 인터페이스, 프로그램, 함수그룹, 함수모듈 |
| DDIC | 테이블, 구조, 데이터요소, 도메인, 타입그룹 |
| CDS / 접근제어 | CDS 뷰, DCL 접근제어 |
| 변환 | XSLT |
| RAP | behavior 정의, 서비스 정의, 서비스 바인딩 → OData V4 |

### CDS 뷰 → 라이브 OData V4 (처음부터 끝까지)

```bash
tools/abap zi_orders.asddls                                    # CDS 뷰
tools/abap zui_orders.assrvd                                   # 그걸 노출하는 서비스 정의
tools/abap --type srvb --name ZUI_ORDERS_O4 --srvd ZUI_ORDERS  # 바인딩 + 자동 publish
# → GET /sap/opu/odata4/sap/zui_orders_o4/srvd/sap/zui_orders/0001/Orders  가 라이브 JSON 반환
```

## 추측하지 말고 확인한다

포트, client, 패키지, 트랜스포트 같은 값은 시스템마다 다릅니다. 이 도구는 그런 값을 하드코딩하거나 조용히 기본값으로 때우지 않습니다.

- **포트**는 `SAP_URL` 안에 있습니다. 본인 시스템 값 그대로 들어갑니다.
- **client**는 `SAP_CLIENT`를 설정하지 않으면 생략합니다. 그러면 서버가 로그온 기본 client를 씁니다.
- **패키지 / 트랜스포트**는 추측하지 않고 시스템에 대고 검증합니다.

빌드 전에 `abap probe` 로 도구가 실제로 무엇과 통신할지 확인할 수 있습니다.

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

**패키지와 트랜스포트는 변경이 어디에 어떻게 떨어질지를 결정합니다.** 그리고 `.env`에 적어둔 값은 미리 정해둔 기본 선택이지, 이번 작업의 의도와 꼭 같다는 보장은 없습니다. 그래서 도구는 이 값들을 명시적으로 요구하고(기본값 없음, 임의로 만들어내지 않습니다), AI로 굴릴 때는 에이전트가 **무언가 만들기 전에 범위를 먼저 확인**하는 게 좋습니다.

> 어느 패키지인가 · 로컬인가 이송가능인가 · 전체 권한인가 한정인가

그다음 `abap probe`로 라이브 상태를 보여주고, 명시한 값으로 빌드합니다. **확인하고, 합의하고, 그다음에 씁니다.** 미리 정해둔 설정이 새 작업에도 맞다고 가정하지 않습니다.

## 동작 방식

객체 하나당: CSRF 토큰 받기 → `POST` 생성(stateful 세션) → `LOCK` → 소스(또는 객체 XML) `PUT` → `UNLOCK` → **새 세션**에서 `POST` 활성화(lock/PUT이 토큰을 회전시키기 때문입니다). 서비스 바인딩은 publish가 추가되고, 클래스는 선택적으로 실행됩니다. 타입별 엔드포인트·미디어 타입·함정은 **[REFERENCE.md](REFERENCE.md)** 에 정리돼 있습니다.

구현은 둘인데 흐름은 같습니다.

- **`tools/abap`** — Python, 주력. 자동 인식 + 타입 레지스트리, 표준 라이브러리만 씁니다.
- **`tools/build.sh`** — bash/curl, 투명한 레퍼런스 겸 폴백: `build.sh <type> <NAME> <src>`.

**플랫폼.** `tools/abap`은 순수 Python 표준 라이브러리입니다 (pip 없음, curl 없음, 플랫폼 종속 호출 없음). macOS·Linux·Windows에서 돌아갑니다. Windows에서는 `py tools\abap ...` 로 실행하거나, 같이 들어있는 `abap.cmd`를 쓰면 `abap ...` 로 됩니다 (`py` 런처가 없으면 `python`으로 폴백). `tools/build.sh`는 Unix 전용입니다 (bash + curl, Windows면 WSL이나 Git Bash). macOS에서 검증했고, Windows는 설계상 지원되지만(표준 라이브러리만 쓰므로) 아직 Windows 호스트에서 실제로 테스트하지는 않았습니다.

## 다른 도구와 비교

- **abapGit** — *기존* 객체를 git으로 직렬화/이송합니다. 이 도구는 *소스 파일에서* ADT REST로 객체를 빌드하니 하는 일이 다릅니다.
- **SAP 공식 ADT-for-VS-Code MCP** (2026 GA) — ABAP Cloud 전용입니다. 이 도구는 온프렘 등 ADT가 켜진 어떤 시스템에서도 됩니다.
- **커뮤니티 ADT MCP 서버들** — 에이전트용으로 ADT API를 감쌉니다. 이 도구는 스크립트나 파이프라인에 바로 넣을 수 있는 의존성 없는 CLI입니다.

## 보안

평문 HTTP는 비밀번호를 그대로 흘려보냅니다. 특히 인터넷을 넘어갈 때는 `https://` 나 SSH 터널/VPN을 쓰는 게 좋습니다. 인증정보는 `.env`에만 두고, 그건 gitignore돼 있습니다. 절대 커밋하지 마세요.

## 라이선스

MIT — [LICENSE](LICENSE) 참고.
