# adt-build

[English](README.md) · **한국어**

> **ADT REST API로 ABAP 객체를 헤드리스로 빌드합니다 — 공식 툴(ABAP Cloud 전용)이 아직 닿지 않는 온프레미스 SAP에서, AI 기반 ABAP 개발(이른바 '바이브 코딩')을 위해 만들었습니다.**

Eclipse나 SAP GUI 없이, 소스 파일 하나만으로 ABAP 객체를 생성하고 활성화할 수 있는 도구입니다. ADT REST API를 직접 호출하기 때문에 명령어 한 줄이면 객체 타입과 이름을 자동으로 파악합니다. 생성, 잠금(Lock), 소스 업로드, 활성화, 그리고 필요한 경우 Publish나 실행까지 한 번에 처리합니다.

총 16종의 ABAP 객체를 지원하며, RAP 서비스를 즉시 호출 가능한 OData V4로 배포하는 작업도 지원합니다.

```bash
tools/abap zcl_demo.abap --run     # class ZCL_DEMO로 인식 → 생성·활성화·classrun 실행
tools/abap zi_orders.asddls        # CDS view ZI_ORDERS로 인식
tools/abap --type srvb --name ZUI_ORDERS_O4 --srvd ZUI_ORDERS   # OData V4 바인딩 + 자동 publish
```

## 만든 이유

보통 ABAP 객체 생성 및 활성화는 Eclipse ADT나 SAP GUI를 통해 이루어집니다. 하지만 다음과 같은 상황에서는 이런 방식이 꽤 번거롭습니다.

- CI/CD 파이프라인에서 객체 생성을 자동화(스크립트)하고 싶을 때
- AI 에이전트에게 ABAP 개발 작업을 위임할 때
- 사내망 외부에서 시스템에 접근해야 할 때
- 무거운 프로그램 설치 없이 가볍게 작업하고 싶을 때 (Python 표준 라이브러리만 사용)

ADT의 내부 동작은 결국 REST API입니다. adt-build는 이 API를 직접 호출하여 미디어 타입 처리, 생성 페이로드 구성, 서비스 바인딩 Publish, RAP 대량 활성화(Mass-activation) 등 타입별로 까다롭고 문서화가 부족한 작업들을 대신 처리해 줍니다. 상세한 API 스펙과 주의사항은 [REFERENCE.md](REFERENCE.md)에 정리해 두었습니다.

**제맛은 온프레미스 AS ABAP입니다.** SAP 공식 ADT-for-VS-Code/MCP는 ABAP Cloud 전용이라, 온프레미스 시스템에서 AI 에이전트가 객체를 직접 만들고 활성화할 'write' 수단은 아직 이게 거의 유일합니다. Eclipse도, Cloud도, MCP도 필요 없습니다.

## 설치 방법

별도의 패키지 설치(pip) 없이 Python 3만 있으면 됩니다. (bash와 curl은 폴백 엔진인 `build.sh`를 사용할 때만 필요합니다.)

```bash
git clone <this-repo> && cd adt-build
cp .env.example .env      # 시스템 환경에 맞게 값을 수정합니다.
```

`.env` 설정 예시:

```ini
SAP_URL=http://your-host:50000
SAP_USER=DEVELOPER
SAP_PASSWORD=...
SAP_CLIENT=001
SAP_PACKAGE=ZLOCAL
SAP_TRANSPORT=            # 로컬($TMP) 패키지인 경우 비워둡니다.
```

**계정 조건:** 초기 비밀번호가 변경 완료된 SU01 사용자여야 합니다. (GUI로 한 번 로그인하여 "최초 로그온 시 변경" 상태를 해제해 주세요.)

**시스템 조건:** 트랜잭션 `SICF`에서 `/sap/bc/adt` 노드가 활성화되어 있어야 합니다.

### 시스템 포트 설정

`SAP_URL`에 입력할 포트는 고정된 값이 아니라 접속할 시스템의 ICM 설정을 따릅니다. 인스턴스 번호가 `nn`일 경우, 일반적으로 다음 값을 사용합니다.

- HTTP: `50000` (= `5nn00`) 또는 `8000` (= `80nn`)
- HTTPS: `50001` (= `5nn01`) 또는 `44300` (= `443nn`)

정확한 포트는 트랜잭션 `SMICM` → Goto → Services에서 확인하거나, 인스턴스 프로파일의 `icm/server_port_*` 파라미터에서 조회할 수 있습니다. 인터넷 망을 거쳐 접속한다면 평문 HTTP 대신 HTTPS 포트를 사용하세요. (Self-signed 인증서를 사용하는 개발 시스템이라면 `--insecure` 플래그를 추가하면 됩니다.)

## 사용 방법

`tools/abap <파일명>` 형식으로 실행하면, 파일 확장자와 소스의 첫 줄을 분석해 객체 타입을 알아내고 선언부에서 이름을 자동으로 추출합니다.

| 소스 코드 (예시) | 파일 확장자 | 인식 결과 |
|---|---|---|
| `CLASS zcl_x DEFINITION ...` | `.abap` | 클래스 `ZCL_X` |
| `INTERFACE zif_x ...` | `.abap` | 인터페이스 `ZIF_X` |
| `REPORT zr_x.` | `.abap` | 프로그램 `ZR_X` |
| `define view entity ZI_X ...` | `.asddls` | CDS 뷰 `ZI_X` |
| `define structure zs_x ...` | `.asddls` | DDIC 구조 `ZS_X` |
| `define behavior for ZI_X ...` | `.asbdef` | Behavior 정의 |
| `define service ZUI_X { ... }` | `.assrvd` | 서비스 정의 |
| `<doma:domain ...>` | `.xml` | 도메인 |

**주요 플래그:**

- `--run`: 클래스를 classrun으로 실행합니다.
- `--group ZFG`: 함수 모듈이 속할 함수 그룹을 지정합니다.
- `--srvd ZX`: 서비스 바인딩 생성 시 사용할 서비스 정의를 명시합니다.
- `--type` / `--name`: 소스 코드에서 추론하는 대신 직접 객체 타입과 이름을 지정합니다. (소스가 없는 타입 생성 시 유용)
- `--src`: 업로드할 소스 파일을 명시합니다.
- `--host` / `--user` / `--client` / `--package` / `--transport`: `.env` 파일의 설정을 덮어씁니다.
- `--insecure`: TLS 인증서 검증을 생략합니다. (Self-signed 인증서를 쓰는 개발 환경 전용)
- `--verbose`: 에러 발생 시 서버의 원본 응답 바디를 출력합니다. (비-XML 에러를 디버깅할 때 유용)

### 지원하는 객체 유형 (총 16종)

| 분류 | 지원 객체 |
|---|---|
| OO / 절차형 | 클래스, 인터페이스, 프로그램, 함수 그룹, 함수 모듈 |
| DDIC | 테이블, 구조, 데이터 요소, 도메인, 타입 그룹 |
| CDS / 권한 | CDS 뷰, DCL 접근 제어 |
| 변환(Transformation) | XSLT |
| RAP | Behavior 정의, 서비스 정의, 서비스 바인딩 (OData V4) |

### 예시: CDS 뷰에서 OData V4까지 한 번에 배포하기

```bash
tools/abap zi_orders.asddls                                    # 1. CDS 뷰 생성
tools/abap zui_orders.assrvd                                   # 2. 서비스 정의 생성
tools/abap --type srvb --name ZUI_ORDERS_O4 --srvd ZUI_ORDERS  # 3. 바인딩 생성 및 자동 publish

# 결과: GET /sap/opu/odata4/sap/zui_orders_o4/srvd/sap/zui_orders/0001/Orders 경로로 JSON 응답 확인 가능
```

## 환경값 임의 추측 배제 (No Guessing)

이 도구는 포트, Client, 패키지, 트랜스포트(TR)처럼 시스템마다 다른 중요 설정값을 코드에 하드코딩하거나 임의의 기본값으로 때우지 않습니다.

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

패키지와 트랜스포트는 내 코드가 어디에, 어떤 방식으로 저장될지를 결정하는 핵심 정보입니다. `.env`에 설정된 값이라도 현재 작업에 항상 적절하다는 보장은 없습니다. 따라서 AI 에이전트와 연동할 때는 본격적인 생성 작업 전에 어느 패키지에 만들 것인지, 로컬 전용인지 이송(Transport)할 것인지 합의 과정을 거치는 것이 좋습니다. `abap probe`로 현재 상태를 확인하고 명시적으로 빌드를 진행하세요.

## 작동 원리

하나의 객체를 처리할 때 다음의 워크플로우를 거칩니다.

CSRF 토큰 발급 → `POST` 생성 (Stateful 세션) → `LOCK` → 소스(또는 XML) `PUT` → `UNLOCK` → 새로운 세션에서 `POST` 활성화 (LOCK/PUT 작업이 기존 토큰을 무효화하기 때문입니다).

서비스 바인딩의 경우 Publish 단계가 추가되며, 클래스는 옵션에 따라 실행(classrun)됩니다. 각 타입별 정확한 엔드포인트와 미디어 타입은 [REFERENCE.md](REFERENCE.md)에 정리되어 있습니다.

구현체는 두 가지로 나뉩니다.

- **`tools/abap` (주력):** 순수 Python 표준 라이브러리 기반. 자동 인식 및 타입 레지스트리를 제공합니다. pip나 curl 같은 외부 의존성 없이 macOS, Linux, Windows 모두에서 동작합니다. (Windows에서는 `py tools\abap ...` 또는 동봉된 `abap.cmd` 활용) *macOS·Linux에서 검증했고, Windows는 설계상 지원하나 실제 Windows 호스트에서는 아직 검증하지 못했습니다.*
- **`tools/build.sh` (폴백):** Bash와 Curl 기반. API 호출 흐름을 투명하게 보여주는 레퍼런스 스크립트입니다. (Unix 환경 전용, Windows는 WSL 또는 Git Bash 필요)

## 다른 도구와 함께 활용하기 (Use Cases)

이 도구의 핵심 역할은 객체의 생성·활성화·배포(create·activate·publish)입니다. 단독으로도 강력하지만, 다른 도구와 결합하면 시너지가 납니다.

- **AI 에이전트 (예: Claude Code):** 에이전트가 코드를 작성한 후 CLI를 호출해 빌드하고 그 결과를 다시 피드백받는 루프를 구축할 수 있습니다.
- **ADT MCP 서버와의 결합:** adt-build는 빌드를 전담하고, 읽기/조회/대화형 수정은 커뮤니티 ADT MCP 서버(VSP 등)에 맡기면 역할을 깔끔하게 분리할 수 있습니다. 시스템 제약으로 MCP 사용이 막힌 환경에서는 이 raw-REST 빌더가 훌륭한 대안(Fallback)이 됩니다.

## 기존 도구와의 차이점

- **abapGit:** 기존에 존재하는 객체를 Git으로 직렬화하고 이송하는 목적입니다. adt-build는 로컬 소스 파일을 ADT REST를 통해 직접 시스템에 '빌드'하는 도구로 역할이 다릅니다.
- **SAP 공식 ADT-for-VS-Code MCP (2026 GA):** ABAP Cloud 환경 전용입니다. 반면 이 도구는 온프레미스를 포함해 ADT가 활성화된 모든 시스템에서 동작합니다.
- **기타 커뮤니티 ADT MCP 서버:** 에이전트와의 상호작용을 위해 API를 래핑합니다. adt-build는 별도의 의존성 없이 CI/CD 파이프라인이나 스크립트에 즉시 투입할 수 있는 가벼운 CLI입니다.

## 보안

평문 HTTP 환경에서는 인증 정보가 암호화되지 않고 전송됩니다. 특히 외부 인터넷 망을 거칠 때는 반드시 HTTPS를 사용하거나 SSH 터널링 / VPN 환경에서 사용하세요. 계정 정보는 `.env`에만 저장하며, 이 파일은 `.gitignore`에 등록되어 있습니다. 절대 `.env` 파일을 저장소에 커밋하지 마세요.

## 라이선스

MIT 라이선스를 따릅니다. 자세한 내용은 [LICENSE](LICENSE) 파일을 참고하세요.
