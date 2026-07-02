# adt-build

[English](README.md) · **한국어**

![adt-build — ADT REST API 기반 헤드리스 ABAP 빌더](assets/banner.jpg)

> **ADT REST API로 ABAP 객체를 헤드리스(Headless)로 빌드합니다.**
> 온프레미스 SAP 시스템에 ADT REST + basic auth로 붙어 AI 기반 ABAP 개발(이른바 '바이브 코딩')을 구현하기 위해 만들었습니다. 생성·활성화·publish는 물론 검증(ABAP Unit · ATC · ABAP Doc)까지, Eclipse도 바이너리도 MCP도 없이 처리합니다.


Eclipse나 SAP GUI 없이, 소스 파일 하나만으로 ABAP 객체를 생성하고 활성화할 수 있는 도구입니다. ADT REST API를 직접 호출하기 때문에 명령어 한 줄이면 객체 타입과 이름을 자동으로 파악합니다. 생성, 잠금(Lock), 소스 업로드, 활성화는 물론 필요한 경우 Publish나 실행(Run)까지 한 번에 처리합니다.

활성화 직후 검증 루프 — ABAP Unit(`--test`), ATC(`--atc`), ABAP Doc 커버리지(`--doc`) — 까지 HTTP(S)로 돌립니다. 이 크기의 도구에선 흔치 않은 부분입니다. 총 16종의 ABAP 객체를 지원하며, RAP 서비스를 즉시 호출 가능한 OData V4로 배포하는 작업도 완벽히 지원합니다.

```bash
tools/abap zcl_demo.abap           # class ZCL_DEMO로 인식 → 생성 및 활성화
tools/abap zcl_demo.abap --run     # 활성화 후 classrun 실행
tools/abap zi_orders.asddls        # CDS view ZI_ORDERS로 인식
tools/abap --type srvb --name ZUI_ORDERS_O4 --srvd ZUI_ORDERS   # OData V4 바인딩 + 자동 publish
tools/abap zcl_demo.abap --test --atc --doc   # 빌드 후 ABAP Unit + ATC + ABAP Doc 커버리지
```

## 📚 가이드 & 함정 카탈로그

도구뿐 아니라, 실제 ABAP 바이브코딩 랩의 현장 노트 — ADT REST만으로 ABAP을 짓는 *방법*과 *함정* — 을 함께 담았습니다.

- **[docs/guide.html](docs/guide.html)** — 다이어그램 있는 시각 가이드(빌드 플로우·검증 루프·오브젝트 타입 맵·주요 함정 10선). 브라우저로 열어보세요.
- **[docs/PLAYBOOK.md](docs/PLAYBOOK.md)** — 운영 매뉴얼: 연결·정확한 빌드 레시피·검증 루프·타입별 media type·검증된 기법 카탈로그.
- **[docs/LEARNINGS.md](docs/LEARNINGS.md)** — *symptom → cause → fix* 카탈로그(A–P 수십 건): VSP 메커닉·RAP·OData V4·ABAP Unit·클래식 ABAP·DDIC·재사용 유틸 라이브러리.

## 💡 만든 이유

보통 ABAP 객체 생성 및 활성화는 Eclipse ADT나 SAP GUI를 통해 이루어집니다. 하지만 다음과 같은 상황에서는 이런 GUI 기반 방식이 꽤 번거롭습니다.

- CI/CD 파이프라인에서 객체 생성을 자동화(스크립트)하고 싶을 때
- AI 에이전트에게 ABAP 개발 작업을 온전히 위임할 때
- 사내망 외부에서 시스템에 빠르게 접근해야 할 때
- 무거운 IDE 설치 없이 가볍게 작업하고 싶을 때 (Python 표준 라이브러리만 사용)

ADT의 내부 동작은 결국 REST API입니다. adt-build는 이 API를 직접 호출하여 미디어 타입 처리, 생성 페이로드 구성, 서비스 바인딩 Publish, RAP 대량 활성화(Mass-activation) 등 타입별로 까다롭고 문서화가 부족한 작업들을 알아서 처리해 줍니다. (상세한 API 스펙과 주의사항은 [REFERENCE.md](REFERENCE.md)에 정리해 두었습니다.)

**이 도구의 진가는 온프레미스 AS ABAP 환경에서 발휘됩니다.** SAP의 *공식* ADT-for-VS-Code / MCP는 ABAP Cloud 전용이라 온프레미스에는 닿지 않습니다. 다만 커뮤니티 도구는 닿습니다 — 특히 VSP MCP 서버는 온프레미스에서도 객체 생성·활성화·publish를 합니다. 그러니 adt-build의 차별점은 "유일한 Write 수단"이라서가 아니라 *형태*입니다: 의존성 0의 단일 Python 파일(표준 라이브러리만, 설치·검증할 바이너리 없음, 한자리에서 읽히는 수백 줄)이라 AI 에이전트나 CI 스텝이 바로 호출할 수 있다는 점입니다. Eclipse도, Cloud도, MCP도 필요 없습니다.

## 🚀 설치 방법

별도의 패키지 설치(pip install) 없이 Python 3만 있으면 즉시 실행 가능합니다. (Bash와 Curl은 폴백 엔진인 `build.sh`를 사용할 때만 필요합니다.)

```bash
git clone <this-repo> && cd adt-build
cp .env.example .env      # 시스템 환경에 맞게 값을 수정합니다.
```

**.env 설정 예시**

```ini
SAP_URL=http://your-host:50000
SAP_USER=DEVELOPER
SAP_PASSWORD=...
SAP_CLIENT=001
SAP_PACKAGE=ZLOCAL
SAP_TRANSPORT=            # 로컬($TMP) 패키지인 경우 비워둡니다.
```

- **계정 조건:** 초기 비밀번호가 변경 완료된 SU01 사용자여야 합니다. (GUI로 한 번 로그인하여 "최초 로그온 시 변경" 상태를 해제해 주세요.)
- **시스템 조건:** 트랜잭션 `SICF`에서 `/sap/bc/adt` 노드가 활성화되어 있어야 합니다.

### ⚙️ 시스템 포트 설정

`SAP_URL`에 입력할 포트는 고정된 값이 아니라 접속할 시스템의 ICM 설정을 따릅니다. 인스턴스 번호가 `nn`일 경우, 일반적으로 다음 값을 사용합니다.

- HTTP: `50000` (= `5nn00`) 또는 `8000` (= `80nn`)
- HTTPS: `50001` (= `5nn01`) 또는 `44300` (= `443nn`)

> **Tip:** 정확한 포트는 트랜잭션 `SMICM` → Goto → Services에서 확인하거나, 인스턴스 프로파일의 `icm/server_port_*` 파라미터에서 조회할 수 있습니다. 인터넷 망을 거쳐 접속한다면 평문 HTTP 대신 HTTPS 포트를 사용하세요. (Self-signed 인증서를 사용하는 개발 시스템이라면 `--insecure` 플래그를 추가하면 됩니다.)

## 💻 사용 방법

`tools/abap <파일명>` 형식으로 실행하면, 파일 확장자와 소스의 첫 줄을 분석해 객체 타입을 알아내고 선언부에서 이름을 자동으로 추출합니다.

### 📦 지원 객체 및 인식 예시 (총 16종)

| 분류 | 소스 코드 (예시) | 파일 확장자 | 인식 결과 |
|---|---|---|---|
| OO / 절차형 | `CLASS zcl_x DEFINITION ...` | `.abap` | 클래스 `ZCL_X` |
| | `INTERFACE zif_x ...` | `.abap` | 인터페이스 `ZIF_X` |
| | `REPORT zr_x.` | `.abap` | 프로그램 `ZR_X` |
| DDIC | `define structure zs_x ...` | `.asddls` | DDIC 구조 `ZS_X` |
| | `<doma:domain ...>` | `.xml` | 도메인 |
| CDS / 권한 | `define view entity ZI_X ...` | `.asddls` | CDS 뷰 `ZI_X` |
| RAP | `define behavior for ZI_X ...` | `.asbdef` | Behavior 정의 |
| | `define service ZUI_X { ... }` | `.assrvd` | 서비스 정의 |

> 이 외에도 함수 그룹, 함수 모듈, 테이블, 데이터 요소, 타입 그룹, DCL, XSLT, 서비스 바인딩을 지원합니다.

### 🛠 주요 CLI 플래그

- `--run`: 클래스를 classrun으로 실행합니다.
- `--test`: 활성화 후 ABAP Unit을 실행합니다. (테스트 메서드 수 + 실패 보고)
- `--atc`: 활성화 후 ATC 정적 검사를 실행하고, 결과를 **Clean Core 등급 A–D**로 환산합니다. (최악 finding: P1→D · P2→C · P3→B · 없음→A)
- `--doc`: public API의 ABAP Doc 커버리지를 보고합니다. (어떤 메서드에 `"!` 문서가 없는지)
- `--group ZFG`: 함수 모듈이 속할 함수 그룹을 지정합니다.
- `--srvd ZX`: 서비스 바인딩 생성 시 사용할 서비스 정의를 명시합니다.
- `--type` / `--name`: 소스 코드 추론 대신 객체 타입과 이름을 직접 지정합니다. (소스 파일이 없는 타입 생성 시 유용)
- `--src`: 업로드할 소스 파일을 명시합니다.
- `--host` / `--user` / `--client` / `--package` / `--transport`: `.env` 파일의 설정을 덮어씁니다.
- `--insecure`: TLS 인증서 검증을 생략합니다. (Self-signed 인증서를 쓰는 개발 환경 전용)
- `--atc-max-prio N`: ATC 게이트 임계값 — priority 1..N findings에서 실패 처리 (기본 2; P3는 advisory).
- `--atc-variant NAME`: 사용할 ATC 체크 variant 지정 (기본값은 시스템 설정 variant이며 실존 여부를 먼저 검증 — 없는 variant는 서버가 조용히 약한 fallback으로 돌려 가짜 clean이 나오기 때문). 환경변수 `ABAP_ATC_VARIANT`.
- `--verbose`: 에러 발생 시 서버의 원본 응답 바디를 출력합니다. (XML이 아닌 에러를 디버깅할 때 유용)

**Exit code** (CI / 에이전트 루프): `0` 통과 · `1` compile/activate · `2` ABAP Unit · `3` ATC — 그래서 에이전트가 `tools/abap x --test --atc && <다음 단계>`로 분기할 수 있습니다. `--doc`는 advisory(게이트 안 함). `activationExecuted="false"`라도 에러 메시지가 **없으면** 동일 소스 = **통과**이지 실패가 아닙니다 (게이트가 내장한 A4H 뉘앙스).

### 🎯 예시: CDS 뷰에서 OData V4까지 한 번에 배포하기

```bash
# 1. CDS 뷰 생성
tools/abap zi_orders.asddls

# 2. 서비스 정의 생성
tools/abap zui_orders.assrvd

# 3. 바인딩 생성 및 자동 publish
tools/abap --type srvb --name ZUI_ORDERS_O4 --srvd ZUI_ORDERS

# 결과: GET /sap/opu/odata4/sap/zui_orders_o4/srvd/sap/zui_orders/0001/Orders 경로로 JSON 응답 확인 가능
```

## ✅ 라이브 실행 (실제 출력)

아래는 전부 실제 온프레미스 SAP 시스템에 adt-build를 돌려 나온 진짜 출력입니다. (호스트만 마스킹했습니다.)

![adt-build 라이브 실행 (실제 출력)](assets/live-run.png)

<details>
<summary>복사용 텍스트</summary>

```console
$ tools/abap probe
host     : http://a4h-dev:50000
user     : DEV001
client   : 001
connect  : discovery http=200  (ok)
package  : ZVIBE  exists (type=DEVC/K, responsible=DEVELOPER, softwareComponent=HOME)
           -> TRANSPORTABLE: a transport request is required
transport: A4HK900120  [Modifiable] owner=DEV001

$ tools/abap zcl_adt_hello.abap            # 헤드리스로 빌드
[class] ZCL_ADT_HELLO
create 200  put 200  activate=true

$ tools/abap zcl_adt_hello.abap --run      # 라이브 시스템에서 실행
--- RUN ---
Hello from headless ABAP.
Created, activated, and executed on a live on-premise SAP system via raw ADT REST.

$ curl '.../zui_vibe_ping_o4/srvd/sap/zui_vibe_ping/0001/Booking?$top=2&$format=json'
{
  "value": [
    { "CustomerName": "Alice", "Amount": 199.00, "CurrencyCode": "EUR", "Status": "A" },
    { "CustomerName": "Alice", "Amount": 199.00, "CurrencyCode": "EUR", "Status": "R" }
  ]
}
```

</details>

## 🛑 환경값 임의 추측 배제 (No Guessing)

이 도구는 포트, Client, 패키지, 트랜스포트(TR)처럼 시스템마다 다른 중요 설정값을 코드에 하드코딩하거나 임의의 기본값으로 넘겨짚지(Guessing) 않습니다.

- 포트는 `SAP_URL`에 명시된 값을 그대로 사용합니다.
- `SAP_CLIENT`를 생략하면 헤더에서 완전히 제외하여, 서버의 로그온 기본 Client를 사용하도록 합니다.
- 패키지와 트랜스포트는 추측하는 대신 시스템에 직접 쿼리하여 검증합니다.

작업을 시작하기 전 `abap probe` 명령어를 사용하면, 도구가 시스템과 어떻게 통신할지 미리 점검할 수 있습니다.

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

패키지와 트랜스포트는 내 코드가 어디에, 어떤 방식으로 저장될지를 결정하는 핵심 정보입니다. `.env`에 설정된 값이라도 현재 작업에 항상 적절하다는 보장은 없습니다. 따라서 AI 에이전트와 연동할 때는 본 생성 작업 전에 어느 패키지에 만들 것인지, 로컬 전용인지 이송(Transport)할 것인지 합의 과정을 거치는 것이 좋습니다. `abap probe`로 현재 상태를 확인하고 명시적으로 빌드를 진행하세요.

## 🔍 작동 원리

하나의 객체를 처리할 때 다음의 워크플로우를 거칩니다.

CSRF 토큰 발급 → POST 생성 (Stateful 세션) → LOCK → 소스(또는 XML) PUT → UNLOCK → 새로운 세션에서 POST 활성화 (LOCK/PUT 작업이 기존 토큰을 무효화하기 때문입니다).

서비스 바인딩의 경우 Publish 단계가 추가되며, 클래스는 옵션에 따라 실행(classrun)됩니다. `--test`/`--atc`/`--doc`를 주면 방금 활성화한 객체에 대해 ABAP Unit, ATC, ABAP Doc 커버리지 검사를 이어서 돌립니다. Eclipse에서 돌리던 검증 루프를 헤드리스로 옮긴 셈입니다. 각 타입별 정확한 엔드포인트와 미디어 타입은 [REFERENCE.md](REFERENCE.md)에 정리되어 있습니다.

**두 가지 구현체:**

- **`tools/abap` (주력):** 순수 Python 표준 라이브러리 기반. 자동 인식 및 타입 레지스트리를 제공합니다. 의존성 없이 macOS, Linux, Windows 모두에서 동작합니다. (Windows에서는 `py tools\abap ...` 또는 동봉된 `abap.cmd` 활용. macOS·Linux 검증 완료, Windows는 설계상 지원)
- **`tools/build.sh` (폴백):** Bash와 Curl 기반. API 호출 흐름을 투명하게 보여주는 레퍼런스 스크립트입니다. (Unix 환경 전용, Windows는 WSL 또는 Git Bash 필요)

## 🤝 다른 도구와 함께 활용하기 (Use Cases)

이 도구의 핵심 역할은 객체의 생성·활성화·배포(create·activate·publish)입니다. 단독으로도 강력하지만, 다른 도구와 결합하면 시너지가 납니다.

- **AI 에이전트 (예: Claude Code, Cursor):** 에이전트가 코드를 작성한 후 CLI를 호출해 빌드하고 그 결과를 다시 피드백받는 자율 루프를 구축할 수 있습니다.
- **ADT MCP 서버와의 결합:** VSP 같은 풀 ADT MCP 서버는 생성·활성화·publish는 물론 읽기/수정/테스트/분석/디버그까지 라이프사이클 전체를 자체적으로 처리합니다. 즉 "adt-build가 빌드, MCP는 조회"라는 역할 분담이 아니라 둘 다 빌드할 수 있습니다. 그럼에도 결합이 유용한 경우는, 스크립트나 CI 루프 안에서는 설치 없는(no-MCP) 빌드 스텝으로 adt-build를 쓰고 대화형 조회는 MCP에 맡기고 싶을 때입니다. 시스템 제약으로 MCP가 막힌 환경에서는 이 Raw-REST 빌더가 그대로 동작하는 대안(Fallback)이 됩니다.

**기존 도구와의 차이점** — adt-build는 가장 강력한 도구가 아니라 가장 작은 도구입니다. 정직한 지형도:

| | **adt-build** | **VSP** (MCP) | **erpl-adt** | **SAP 공식** |
|---|---|---|---|---|
| 형태 | 단일 stdlib `.py` | Go 바이너리, 147툴 | C++ 바이너리(CLI+MCP) | VS Code 확장 + MCP |
| 생성·활성화·publish | ✓ | ✓ | ✓ | ✓ |
| RAP → 라이브 OData V4 원커맨드 | ✓ | ✓ | ✗ | 클라우드만 |
| 소스에서 타입+이름 자동감지 | ✓ | — | ✗ (full URI 요구) | 해당 없음 |
| 검증 루프 (Unit/ATC/Doc) | ✓ | ✓ (Unit/ATC) | ✓ (Unit/ATC) | ✓ |
| 온프레미스 basic auth, 바이너리 0 | ✓ | 바이너리 | 바이너리 | RFC |
| 한자리에서 감사 가능한 단일 파일 | ✓ | ✗ | ✗ | ✗ |

- **abapGit:** *기존* 객체를 Git으로 직렬화·이송하는 목적입니다. adt-build는 로컬 소스에서 ADT REST로 *생성*합니다. 결이 다릅니다.
- **SAP 공식 ADT-for-VS-Code + ABAP MCP (Sapphire 2026 GA):** 헤비급입니다. 확장은 온프레미스에 **RFC**, 클라우드에 HTTP로 붙고, MCP는 ABAP Cloud/RAP 중심입니다. adt-build는 온프레미스에 평문 **ADT REST/HTTP + basic auth**로 붙어, RFC가 안 통하는 포워딩 포트에서도 동작합니다.
- **VSP:** 기능상 **상위집합**입니다. adt-build가 하는 건 다 하고 그 이상(읽기/수정/디버그/분석, 147툴)입니다. AI 워크벤치 하나로 끝내려면 VSP를 쓰세요.
- **erpl-adt:** 가장 가까운 형제입니다. Eclipse/RFC/JVM 없는 헤드리스 CLI이고 ABAP Unit·ATC도 있습니다. 다만 컴파일된 바이너리이고, full 객체 URI를 요구하며, RAP → OData V4 E2E는 하지 않습니다.

**핵심은 기능이 아니라 형태입니다.** adt-build는 작고 손으로 검증한 도구입니다. 끝까지 읽히는 표준 라이브러리 Python이고, 아무 스크립트에나 넣을 수 있고, 보안팀에 "이게 전부입니다" 하고 통째로 보여줄 수 있습니다. slop 생성기가 아니라 프리미티브입니다. 대화형 작업은 VSP(또는 아무 MCP)와 페어링하고, 감사 가능하고 설치할 게 없는 빌드+검증 스텝이 필요할 때 adt-build를 쓰세요.

## 🛡️ 보안 및 라이선스

평문 HTTP 환경에서는 인증 정보가 암호화되지 않고 전송됩니다. 특히 외부 인터넷 망을 거칠 때는 반드시 HTTPS를 사용하거나 SSH 터널링 / VPN 환경에서 사용하세요.

계정 정보는 `.env`에만 저장하며, 이 파일은 `.gitignore`에 등록되어 있습니다. 절대 `.env` 파일을 저장소에 커밋하지 마세요.

본 프로젝트는 MIT 라이선스를 따릅니다. 자세한 내용은 [LICENSE](LICENSE) 파일을 참고하세요.
