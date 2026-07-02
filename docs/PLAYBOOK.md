# PLAYBOOK — Headless ABAP Vibe-Coding over ADT REST

> 실제 바이브코딩 랩(SAP ABAP Platform 2023 / 758)의 운영 매뉴얼 — Eclipse·SAP GUI 없이 **ADT REST API만으로** ABAP을 빌드·검증한다. 세션이 초기화돼도 이 문서 + [`LEARNINGS.md`](LEARNINGS.md) 만 읽으면 바로 시니어처럼 붙는다.
> "어떻게 개발하는가"는 여기, "어떤 함정을 밟았나"는 [`LEARNINGS.md`](LEARNINGS.md). 빌드는 이 repo 의 `abap` CLI 로.
>
> _(랩 내부 매뉴얼을 adt-build repo 로 추출한 것. 홈 IP/개인정보는 `<HOME_LAN_IP>`/`<PUBLIC_IP>` placeholder 로 치환됨. SAP 사용자명 `DEV001`/`DEVELOPER` 는 예시로 유지.)_

---

## 0. 30초 요약 — 지금 당장 클래스 하나 만들기

```bash
# tools/abap — 소스 파일만 주면 타입·이름을 자동 추론해서 빌드 (+활성화, +classrun/publish)
tools/abap zcl_demo.abap --run      # 클래스 (classrun 실행). INTERFACE/REPORT/FUNCTION/TYPE-POOL도 자동 인식
tools/abap zi_view.asddls           # CDS (define view). .asddls는 첫 줄로 structure/table/cds 구분
tools/abap zs.asddls                # 구조 · zx.asdcls=DCL · zx.assrvd=서비스정의 · z.asbdef=behavior
tools/abap zdoma.xml                # 도메인/데이터요소(객체 XML)도 자동 (이름은 adtcore:name에서)
tools/abap z_fm.abap --group ZFG    # 함수모듈 (부모 그룹 지정)
tools/abap --type fugr --name ZFG               # 소스 없는 타입(함수그룹)
tools/abap --type srvb --name ZX_O4 --srvd ZX   # OData V4 바인딩 + 자동 publish → 라이브 OData
#   성공 = "activate=true" (+ class면 classrun 출력 / srvb면 "published locally")
#   라이브 OData V4 URL:  /sap/opu/odata4/sap/<binding_lc>/srvd/sap/<srvd_lc>/0001/<EntitySet>
```
- **한 명령 `tools/abap`** 이 16종 전부 처리 — 타입 레지스트리(데이터) + 자동추론, 의존성 0(urllib만). 추론이 애매하면 `--type`/`--name`으로 명시.
- 저수준 bash 엔진 `tools/build.sh <type> <NAME> [src]` 도 그대로 있음(투명한 참조/폴백). 둘 다 같은 REST 플로우(§3). (예전 16개 `build_*.sh` 래퍼는 `abap`으로 대체·삭제됨.)
- vsp MCP가 살아있으면 **read/edit/test는 MCP**, 그러나 **create는 raw REST(abap)** 가 안전 (이유는 §2).
- 활성화가 `false`로 실패하면 → §4 검증 루프로 에러 전문 받아 고친다.
- ⚠ **밖(공인망)에서는** `.env`의 LAN 주소에 못 닿으므로 매 명령에 `--host http://<PUBLIC_IP>:50000` 추가 (§1). 대상 확인은 `tools/abap probe` (host/client/package/transport 검증 — 객체 생성 전 권장).

---

## 1. 연결 (Connectivity) — 어디로 붙나

| 항목 | 값 |
|---|---|
| 시스템 | SID **A4H** · client **001** · user **DEV001** · ABAP **758** (Platform 2023) |
| 집 (LAN) | `http://<HOME_LAN_IP>:50000` |
| 밖 (공인) | `http://<PUBLIC_IP>:50000` (공유기 포트포워딩) |
| 포트 | **50000 HTTP · 50001 HTTPS** (ABAP Trial 도커) |
| 비밀번호 | `.env`의 `SAP_PASSWORD` (gitignored, 평문 — **절대 커밋 금지**) |
| 트랜스포트 | `A4HK900120`, `A4HK900121` (ZVIBE는 transportable) |

**⚠ 이 셸(Bash/curl)은 홈 LAN에 직접 못 닿는다.** `<HOME_LAN_IP>`는 connection-refused(curl exit 7), **공인 IP `<PUBLIC_IP>`만 도달**(인증 없으면 401). 그래서 **raw REST는 공인 IP로** 돌린다(`--host` 오버라이드). ⚠ vsp MCP도 `.mcp.json`에 LAN(`<HOME_LAN_IP>`)으로 고정돼 있어 **집 LAN에서만 붙는다** — 밖에서는 MCP도 못 닿으니 공인 IP/터널로 재지정해야 함(집에서도 큰 표준 클래스 `read`는 타임아웃).
→ 평문 HTTP over 인터넷이므로 상시 작업엔 **SSH 터널** 권장: `ssh -L 50000:<HOME_LAN_IP>:50000 <home>` 후 `localhost:50000`.

---

## 2. 두 도구 — 언제 무엇을

**A) vsp MCP** — `mcp__vsp-a4h__SAP`, `action = read|edit|create|search|query|grep|test|analyze|debug|system|help`
- 잘 됨: `search`(객체 목록), `read CLAS/DDLS/…`(작은 객체), `test`(ABAP Unit·ATC), `system INFO`.
- 막힘/주의:
  - `create`가 패키지 존재 체크(`repository/nodestructure`)에서 **타임아웃 → "package ZVIBE does not exist" 오판** (ZVIBE 90+ 객체 + 서버 메모리압 90%대). 재시도해도 같음.
  - `$TMP`는 안전설정(`SAP_ALLOWED_PACKAGES=ZVIBE`)으로 차단됨.
  - 큰 표준 클래스(`CL_ABAP_PARALLEL` 등) `read`도 타임아웃.
- 문법: `system`은 `target="INFO"`, `test`는 `params={"object_url":"…"}`, `read/edit`는 `target="CLAS ZCL_X"`.

**B) raw ADT REST** — curl / `tools/abap` (저수준 엔진 `tools/build.sh`). create/activate/run의 **신뢰 경로**. MCP가 막히면 항상 이걸로 떨어진다 (= 우리가 문서에 쓴 "MCP 막히면 raw REST").

권장 조합: **build(create+activate+run)는 raw REST**, 이후 read/edit/test는 vsp 또는 raw REST 둘 다.

---

## 3. raw-REST 빌드 플로우 (정확한 레시피 — `tools/abap`가 자동 수행)

1. **CSRF fetch** — `GET /sap/bc/adt/discovery` + `X-CSRF-Token: Fetch`, stateful 쿠키 저장.
2. **CREATE** — `POST /sap/bc/adt/oo/classes?corrNr=<TR>` · `Content-Type: application/vnd.sap.adt.oo.classes.v4+xml` · body = class XML(`<adtcore:packageRef name="ZVIBE"/>`). 이미 있으면 **400** — 무시하고 진행하면 PUT으로 소스가 갱신된다.
3. **LOCK** — `POST …/classes/<cl>?_action=LOCK&accessMode=MODIFY` (stateful) → `<LOCK_HANDLE>`.
4. **PUT 소스** — `PUT …/classes/<cl>/source/main?lockHandle=<LH>&corrNr=<TR>` · `text/plain` · body = **전체 클래스 소스**(DEFINITION + IMPLEMENTATION 한 덩어리).
5. **UNLOCK** — `POST …/classes/<cl>?_action=UNLOCK&lockHandle=<LH>`.
6. **ACTIVATE — ★새 세션/새 토큰** — lock·PUT이 CSRF를 회전시키므로 **새 쿠키잼 + 새로 fetch한 토큰**으로 `POST /sap/bc/adt/activation?method=activate&preauditRequested=false` · body = objectReferences. **`/activation` (bare)** 이지 `/activation/inactiveobjects` 아님 (후자는 list-only 304 no-op).
7. (선택) **RUN classrun** — 새 토큰 + `POST /sap/bc/adt/oo/classrun/<cl>` · `Accept: text/plain`.

성공 판정: 응답에 **`activationExecuted="true"`**. `false`면 §4.

---

## 4. 검증 루프 (verify loop)

1. **활성화 결과** 확인 — `activationExecuted="true"`?
2. **`false`면 에러 전문을 받아라** (`tools/abap`의 요약 출력은 짧게 잘리므로 직접 curl):
   ```bash
   curl -s -u "$U" -b jar -H "X-CSRF-Token: $T" -H 'Content-Type: application/xml' \
     --data-binary @act.xml "$B/sap/bc/adt/activation?method=activate&preauditRequested=false&sap-client=001" \
     | tr '>' '>\n' | grep -iE 'txt|msg objDescr'
   ```
   `<msg type="E"…><shortText><txt>…</txt>` 메시지 + `href=…#start=line,col` 으로 위치 파악 → 고쳐서 재빌드.
   - **⚠ `false`의 두 의미를 구분하라**: (a) **에러 메시지(`type="E"`)가 있으면** 문법/타입 오류 → 고친다. (b) **에러 없이 `false`면** 활성화할 게 없는 것 = 소스가 이미 active 버전과 **동일**(같은 소스 재빌드 시 흔함) → **정상이니 무시**. classrun이 제대로 출력되면 그 클래스는 active다. (즉 `false`≠실패. 에러 메시지 유무로 판단.)
3. **동작 검증** — classrun 출력 / **`tools/abap … --test`(ABAP Unit) · `--atc`(ATC)** — raw-REST, 빌드 직후 또는 단독(`--type class --name ZCL_X --test`, 소스 없으면 verify-only) / `SAP(action="test", params={object_url})`(vsp 대안) / OData·datapreview SELECT.
   - ⚠ `--test`의 빈 `<runResult/>`=무실행(통과 아님), `<options>`는 namespace 없이 — 정확한 레시피·함정은 `LEARNINGS.md` **E5/E6**.
   - **exit-code 게이트**: `tools/abap`가 단일 exit code 반환 → **0=PASS · 1=compile/activate · 2=unit · 3=atc** (ATC는 `--atc-max-prio` 기본 2, P3는 advisory; doc는 비게이트). 에이전트/CI가 `tools/abap x --test --atc && <다음>`로 분기 가능. `activationExecuted="false"`라도 `type="E"` 메시지 없으면 **PASS**(동일소스 no-op) — §4 step2(b)를 코드에 내장.
   - **Clean Core A~D 등급**: `--atc`가 findings를 **A/B/C/D**로 환산해 출력(최악 finding 기준: P1→D · P2→C · P3→B · 없음→A). 등급은 게이트와 무관(순수 리포트). **A4H 기본 variant가 이미 `ZABAP_CLOUD_DEVELOPMENT`(클라우드-readiness)라 그냥 `--atc`만으로 등급이 유효** — `--atc-variant` 불필요. (AWS 레포의 `CLEAN_CORE`는 A4H에 없음 → 404.) `--atc-variant`/env `ABAP_ATC_VARIANT`로 다른 variant 지정 가능하나, **없는 variant는 서버가 조용히 약한 fallback으로 돌려 가짜 clean을 냄** → `_atc`가 `GET /atc/checkvariants/{NAME}`로 사전 검증해 404면 경고+기본 variant로 fallback. 출처: AWS Kiro clean-core 레포 cherry-pick, LEARNINGS.md §P1/P1-live.
4. 깨끗할 때까지 반복. (활성화가 컴파일이므로, `true`면 그 코드는 이 시스템에서 문법·타입 통과한 것.)

---

## 5. 오브젝트 타입별 (create endpoint / media type)

| 타입 | endpoint | media type | 비고 |
|---|---|---|---|
| CLAS | `/oo/classes` | `…oo.classes.v4+xml` | `source/main` = 전체 소스 |
| INTF | `/oo/interfaces` | `…oo.interfaces.v5+xml` | |
| PROG | `/programs/programs` | `…programs.programs.v2+xml` | `programType="executableProgram"`; **SE38 실행됨** |
| FUGR | `/functions/groups` | `…functions.groups.v3+xml` | |
| FM | `/functions/groups/<fg>/fmodules` | `…functions.fmodules.v3+xml` | 소스는 **인라인** IMPORTING/EXPORTING (`*"`블록 X); 활성화는 `FUGR/FF` ref |
| DDLS (CDS) | `/ddic/ddl/sources` | `…ddlSource+xml` | |
| DCL | `/acm/dcl/sources` | `…dclSource+xml` | |
| BDEF | `/bo/behaviordefinitions` | bdef source | root↔child 순환은 같이 활성화 |
| SRVD/SRVB | `/ddic/srvd`, `/businessservices/bindings` | | `tools/abap`는 **V4** 바인딩 생성(`srvb:version=V4`)+`odatav4/publishjobs`로 auto-publish. media의 `v2`는 ADT 페이로드 버전이지 OData 프로토콜 아님 |

미디어 타입은 버전 없는 `application/vnd.sap.adt.<x>Source+xml` 형태 — 정확한 값은 **discovery 문서 `<app:accept>`** 에서 확인.

---

## 6. 핵심 함정 (요약 — 전체·재현은 `LEARNINGS.md`)

- **활성화 = `/activation`** (bare). `/inactiveobjects`는 list-only 304.
- **CSRF 회전** — activate는 **새 세션/토큰**으로.
- **순환 의존**(DDLS↔class, root↔child)은 **한 `/activation` 호출에 같이**.
- **동적 `SELECT FROM (var)`엔 인라인 `@DATA()` 금지** → `CREATE DATA … TYPE TABLE OF (name)` + 필드심볼 (§7).
- **재정의 가시성 불변** — `… REDEFINITION`은 원본과 **같은 SECTION** (예: `cl_abap_parallel`의 `do`는 PUBLIC).
- **client-dependent AMDP 테이블함수**는 반환 구조 **첫 필드 = CLNT**.
- **classrun 클래스는 SE38 실행 불가** — ADT(F9)/REST(`/oo/classrun`)/web; 클래스는 SE24, 리포트(PROG)는 SE38.
- **dynpro 화면은 headless 불가** (Screen Painter = SAP GUI 전용) → `CL_GUI_DOCKING_CONTAINER`로 우회.
- **BAPI > BDC** (API 있으면): 요즘 트랜잭션은 화면 복잡해 BDC 깨짐. BAPI는 `bapiret2_t` + `BAPI_TRANSACTION_COMMIT`.

---

## 7. 기법 카탈로그 (검증된 패턴 + 정석 스니펫)

이미 ZVIBE에 살아있음 (vsp `search ZCL_VIBE_*`): **RAP** managed BO + param/factory 액션 · **CDS** 뷰/계층/AMDP/DCL · **OData V4** · **ALV**(`CL_SALV`, `CL_GUI_ALV_GRID`) · **FM/OO/예외/싱글톤** · **BAPI** 유저관리 · **BDC** · **RTTI 직렬화**.

**신규 (이 세션 — codezentrale + 병렬 처리):**

```abap
" XCO — CDS 엔티티 메타데이터 (존재·필드·키)               ZCL_VIBE_XCO_CDS / _XCO_DEEP
DATA(o) = xco_cds=>view_entity( 'ZC_VIBE_BOOKING' ).
IF o->exists( ).
  LOOP AT o->fields->all->get( ) INTO DATA(f).
    DATA(c) = f->content( )->get( ).   " c-key_indicator, c-alias, c-type(ref), c-virtual_indicator
    " f->name
  ENDLOOP.
ENDIF.

" 동적 콘텐츠 읽기 — 아무 엔티티 이름으로                    (동적 FROM엔 인라인 @DATA 금지!)
DATA r TYPE REF TO data.
CREATE DATA r TYPE TABLE OF ('ZC_VIBE_BOOKING').
ASSIGN r->* TO FIELD-SYMBOL(<t>).
SELECT * FROM ('ZC_VIBE_BOOKING') INTO TABLE @<t> UP TO 5 ROWS.

" JSON — xco_cp_json (양방향)                                ZCL_VIBE_JSON
DATA(json) = xco_cp_json=>data->from_abap( lt )->to_string( ).       " ABAP → JSON
xco_cp_json=>data->from_string( json )->write_to( REF #( lt2 ) ).    " JSON → ABAP

" 병렬 처리 — cl_abap_parallel                                ZCL_VIBE_PARALLEL
CLASS … INHERITING FROM cl_abap_parallel …
  PUBLIC SECTION. METHODS do REDEFINITION.        " ★ do는 PUBLIC (원본 가시성)
METHOD do.   " IMPORTING p_in TYPE xstring EXPORTING p_out TYPE xstring — 병렬 WP에서, self-contained
  … p_out = cl_abap_codepage=>convert_to( result ).
ENDMETHOD.
DATA(p) = NEW …( p_num_tasks = 4 ).
p->run( EXPORTING p_in_tab = lt_xstr IMPORTING p_out_tab = DATA(lt_out) ).  " lt_out: RESULT/INDEX/TIME(ms)/MESSAGE
```

---

## 8. 새 API를 정확히 따라하는 법 (시그니처를 먼저 읽어라)

추측 빌드 → 활성화 실패 반복을 피하려면, **빌드 전에 표준 클래스/인터페이스 소스를 raw GET** 해서 정확한 시그니처를 확보한다:

```bash
# 인터페이스
curl -s -u "$SAP_USER:$SAP_PASSWORD" \
  "http://<PUBLIC_IP>:50000/sap/bc/adt/oo/interfaces/<intf>/source/main?sap-client=001"
# 클래스
curl -s -u "$SAP_USER:$SAP_PASSWORD" \
  "http://<PUBLIC_IP>:50000/sap/bc/adt/oo/classes/<cls>/source/main?sap-client=001"
```

이번에 `cl_abap_parallel`의 `do`/`run` 시그니처, `if_xco_cds_field(_content)`의 `key_indicator`를 이 방법으로 확인했다.

---

## 9. 관련 문서 (이 repo)

- [`LEARNINGS.md`](LEARNINGS.md) — 함정/오류 카탈로그 (symptom → cause → fix, 핵심 deliverable)
- [`guide.html`](guide.html) — 다이어그램 있는 시각 가이드 (브라우저로 열기)
- [`../README.md`](../README.md) · [`../REFERENCE.md`](../REFERENCE.md) — `abap` CLI 사용법·플래그·타입 레퍼런스
- `../tools/abap` — **주력 빌더** (한 명령, 타입·이름 자동추론, 16종: class·prog·cds·tabl·doma·dtel·intf·fugr·fm·stru·typegrp·xslt·dcl·bdef·srvd·srvb; Python·urllib, 의존성 0). `../tools/build.sh <type> <NAME> [src]` — 동일 플로우의 bash 엔진/폴백. 소스형은 `source/main`에 텍스트 PUT, 객체 XML형(doma/dtel)은 객체 URI에 XML PUT. 새 타입 추가는 `tools/abap` 의 Python `TYPES` 레지스트리(dict)에 endpoint·media type·create 빌더를 추가.
