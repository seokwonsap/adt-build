#!/usr/bin/env bash
# build.sh <type> <NAME> <source_file> [run]      type = class | prog | cds
#
# raw-REST ABAP builder: CSRF → CREATE → LOCK → PUT source → UNLOCK
#   → ACTIVATE (fresh session/token) → optional classrun (class only).
# Primary tool is ./abap (auto-detect type+name); this bash engine is the transparent reference. See README.md.
#
# Config — all from ../.env (gitignored), nothing system-specific hardcoded:
#   SAP_URL · SAP_USER · SAP_PASSWORD · SAP_PACKAGE  (required)
#   SAP_CLIENT (optional; omitted = server logon default) · SAP_TRANSPORT (optional; omit = no corrNr, local pkgs).
# `tools/abap` is the primary (auto-detect) builder; this bash engine is the transparent reference/fallback.
set -uo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
[ -f "$HERE/.env" ] && { set -a; . "$HERE/.env"; set +a; }
B="${SAP_URL:?set SAP_URL=http://host:port in .env}"
U="${SAP_USER:?set SAP_USER in .env}:${SAP_PASSWORD:?set SAP_PASSWORD in .env}"
PKG="${SAP_PACKAGE:?set SAP_PACKAGE in .env}"
TR="${SAP_TRANSPORT:-}"; CORR=""; [ -n "$TR" ] && CORR="corrNr=$TR&"   # corrNr only when a transport is set
C=""; [ -n "${SAP_CLIENT:-}" ] && C="sap-client=$SAP_CLIENT"   # unset -> omit, server uses logon default client
ST='X-sap-adt-sessiontype: stateful'

[ $# -ge 2 ] || { echo "usage: build.sh <class|prog|cds|tabl|doma|dtel|intf|fugr|fm|stru|typegrp|xslt|dcl|bdef|srvd|srvb> <NAME> [src_file] [run]   (fm: FUGR=<group> env; srvb: SRVD=<def> env)"; exit 2; }
TYPE="$1"; NAME="$2"; SRC="${3:-}"; RUN="${4:-}"
nl="$(echo "$NAME" | tr 'A-Z' 'a-z')"
MODE="src"   # "xml" = object-XML types (doma/dtel): PUT the whole object XML to the object URI, not /source/main

# per-type: collection endpoint · adtcore type · create media type · create XML
case "$TYPE" in
  class)
    COLL="/sap/bc/adt/oo/classes"; ATYPE="CLAS/OC"
    MEDIA="application/vnd.sap.adt.oo.classes.v4+xml"
    CRE=$(printf '<?xml version="1.0" encoding="UTF-8"?><class:abapClass xmlns:class="http://www.sap.com/adt/oo/classes" xmlns:adtcore="http://www.sap.com/adt/core" adtcore:description="%s" adtcore:name="%s" class:final="true" class:visibility="public" class:category="generalObjectType"><adtcore:packageRef adtcore:name="'"$PKG"'"/></class:abapClass>' "$NAME" "$NAME") ;;
  prog)
    COLL="/sap/bc/adt/programs/programs"; ATYPE="PROG/P"
    MEDIA="application/vnd.sap.adt.programs.programs.v2+xml"
    CRE=$(printf '<?xml version="1.0" encoding="UTF-8"?><program:abapProgram xmlns:program="http://www.sap.com/adt/programs/programs" xmlns:adtcore="http://www.sap.com/adt/core" adtcore:description="%s" adtcore:name="%s" adtcore:type="PROG/P" program:lockedByEditor="false" program:programType="executableProgram"><adtcore:packageRef adtcore:name="'"$PKG"'"/></program:abapProgram>' "$NAME" "$NAME") ;;
  cds)
    COLL="/sap/bc/adt/ddic/ddl/sources"; ATYPE="DDLS/DF"
    MEDIA="application/vnd.sap.adt.ddlSource+xml"
    CRE=$(printf '<?xml version="1.0" encoding="UTF-8"?><ddl:ddlSource xmlns:ddl="http://www.sap.com/adt/ddic/ddlsources" xmlns:adtcore="http://www.sap.com/adt/core" adtcore:description="%s" adtcore:name="%s" adtcore:type="DDLS/DF"><adtcore:packageRef adtcore:name="'"$PKG"'"/></ddl:ddlSource>' "$NAME" "$NAME") ;;
  tabl)
    COLL="/sap/bc/adt/ddic/tables"; ATYPE="TABL/DT"
    MEDIA="application/vnd.sap.adt.tables.v2+xml"
    CRE=$(printf '<?xml version="1.0" encoding="UTF-8"?><blue:blueSource xmlns:blue="http://www.sap.com/wbobj/blue" xmlns:abapsource="http://www.sap.com/adt/abapsource" xmlns:adtcore="http://www.sap.com/adt/core" adtcore:description="%s" adtcore:name="%s" adtcore:type="TABL/DT" abapsource:fixPointArithmetic="false" abapsource:activeUnicodeCheck="false"><adtcore:packageRef adtcore:name="'"$PKG"'"/></blue:blueSource>' "$NAME" "$NAME") ;;
  doma)
    COLL="/sap/bc/adt/ddic/domains"; ATYPE="DOMA/DD"; MODE="xml"
    MEDIA="application/vnd.sap.adt.domains.v2+xml"
    CRE=$(printf '<?xml version="1.0" encoding="UTF-8"?><doma:domain xmlns:doma="http://www.sap.com/dictionary/domain" xmlns:adtcore="http://www.sap.com/adt/core" adtcore:name="%s" adtcore:type="DOMA/DD" adtcore:description="%s"><adtcore:packageRef adtcore:name="'"$PKG"'"/></doma:domain>' "$NAME" "$NAME") ;;
  dtel)
    COLL="/sap/bc/adt/ddic/dataelements"; ATYPE="DTEL/DE"; MODE="xml"
    MEDIA="application/vnd.sap.adt.dataelements.v2+xml"
    CRE=$(printf '<?xml version="1.0" encoding="UTF-8"?><blue:wbobj xmlns:blue="http://www.sap.com/wbobj/dictionary/dtel" xmlns:adtcore="http://www.sap.com/adt/core" adtcore:name="%s" adtcore:type="DTEL/DE" adtcore:description="%s"><adtcore:packageRef adtcore:name="'"$PKG"'"/></blue:wbobj>' "$NAME" "$NAME") ;;
  intf)
    COLL="/sap/bc/adt/oo/interfaces"; ATYPE="INTF/OI"
    MEDIA="application/vnd.sap.adt.oo.interfaces.v5+xml"
    CRE=$(printf '<?xml version="1.0" encoding="UTF-8"?><intf:abapInterface xmlns:intf="http://www.sap.com/adt/oo/interfaces" xmlns:adtcore="http://www.sap.com/adt/core" adtcore:name="%s" adtcore:type="INTF/OI" adtcore:description="%s"><adtcore:packageRef adtcore:name="'"$PKG"'"/></intf:abapInterface>' "$NAME" "$NAME") ;;
  fugr)
    COLL="/sap/bc/adt/functions/groups"; ATYPE="FUGR/F"; MODE="createonly"
    MEDIA="application/vnd.sap.adt.functions.groups.v3+xml"
    CRE=$(printf '<?xml version="1.0" encoding="UTF-8"?><group:abapFunctionGroup xmlns:group="http://www.sap.com/adt/functions/groups" xmlns:adtcore="http://www.sap.com/adt/core" adtcore:name="%s" adtcore:type="FUGR/F" adtcore:description="%s" group:lockedByEditor="false"><adtcore:packageRef adtcore:name="'"$PKG"'"/></group:abapFunctionGroup>' "$NAME" "$NAME") ;;
  fm)
    [ -n "${FUGR:-}" ] || { echo "fm needs FUGR=<group> env (use build_fm.sh <GROUP> <FM> <src>)"; exit 2; }
    fgl=$(echo "$FUGR" | tr 'A-Z' 'a-z')
    COLL="/sap/bc/adt/functions/groups/$fgl/fmodules"; ATYPE="FUGR/FF"
    MEDIA="application/vnd.sap.adt.functions.fmodules.v3+xml"
    CRE=$(printf '<?xml version="1.0" encoding="UTF-8"?><fmodule:abapFunctionModule xmlns:fmodule="http://www.sap.com/adt/functions/fmodules" xmlns:adtcore="http://www.sap.com/adt/core" adtcore:name="%s" adtcore:type="FUGR/FF" adtcore:description="%s" fmodule:processingType="normal" fmodule:releaseState="notReleased"/>' "$NAME" "$NAME") ;;
  stru)
    COLL="/sap/bc/adt/ddic/structures"; ATYPE="TABL/DS"
    MEDIA="application/vnd.sap.adt.structures.v2+xml"
    CRE=$(printf '<?xml version="1.0" encoding="UTF-8"?><blue:blueSource xmlns:blue="http://www.sap.com/wbobj/blue" xmlns:adtcore="http://www.sap.com/adt/core" adtcore:name="%s" adtcore:type="TABL/DS" adtcore:description="%s"><adtcore:packageRef adtcore:name="'"$PKG"'"/></blue:blueSource>' "$NAME" "$NAME") ;;
  typegrp)
    COLL="/sap/bc/adt/ddic/typegroups"; ATYPE="TYPE/DG"
    MEDIA="application/vnd.sap.adt.ddic.typegroups.v2+xml"
    CRE=$(printf '<?xml version="1.0" encoding="UTF-8"?><atypgr:abapTypeGroup xmlns:atypgr="http://www.sap.com/adt/ddic/typegroups" xmlns:adtcore="http://www.sap.com/adt/core" adtcore:name="%s" adtcore:type="TYPE/DG" adtcore:description="%s"><adtcore:packageRef adtcore:name="'"$PKG"'"/></atypgr:abapTypeGroup>' "$NAME" "$NAME") ;;
  xslt)
    COLL="/sap/bc/adt/xslt/transformations"; ATYPE="XSLT/VT"
    MEDIA="application/vnd.sap.adt.transformations+xml"
    CRE=$(printf '<?xml version="1.0" encoding="UTF-8"?><trans:transformation xmlns:trans="http://www.sap.com/adt/transformation" xmlns:adtcore="http://www.sap.com/adt/core" adtcore:name="%s" adtcore:type="XSLT/VT" adtcore:description="%s" trans:transformationType="XSLTProgram"><adtcore:packageRef adtcore:name="'"$PKG"'"/></trans:transformation>' "$NAME" "$NAME") ;;
  dcl)
    COLL="/sap/bc/adt/acm/dcl/sources"; ATYPE="DCLS/DL"
    MEDIA="application/vnd.sap.adt.dclSource+xml"
    CRE=$(printf '<?xml version="1.0" encoding="UTF-8"?><dcl:dclSource xmlns:dcl="http://www.sap.com/adt/acm/dclsources" xmlns:adtcore="http://www.sap.com/adt/core" adtcore:name="%s" adtcore:type="DCLS/DL" adtcore:description="%s"><adtcore:packageRef adtcore:name="'"$PKG"'"/></dcl:dclSource>' "$NAME" "$NAME") ;;
  bdef)
    COLL="/sap/bc/adt/bo/behaviordefinitions"; ATYPE="BDEF/BDO"
    MEDIA="application/vnd.sap.adt.blues.v1+xml"
    CRE=$(printf '<?xml version="1.0" encoding="UTF-8"?><blue:blueSource xmlns:blue="http://www.sap.com/wbobj/blue" xmlns:adtcore="http://www.sap.com/adt/core" adtcore:name="%s" adtcore:type="BDEF/BDO" adtcore:description="%s"><adtcore:packageRef adtcore:name="'"$PKG"'"/></blue:blueSource>' "$NAME" "$NAME") ;;
  srvd)
    COLL="/sap/bc/adt/ddic/srvd/sources"; ATYPE="SRVD/SRV"
    MEDIA="application/vnd.sap.adt.ddic.srvd.v1+xml"
    CRE=$(printf '<?xml version="1.0" encoding="UTF-8"?><srvd:srvdSource xmlns:srvd="http://www.sap.com/adt/ddic/srvdsources" xmlns:adtcore="http://www.sap.com/adt/core" adtcore:name="%s" adtcore:type="SRVD/SRV" adtcore:description="%s" srvd:srvdSourceType="S"><adtcore:packageRef adtcore:name="'"$PKG"'"/></srvd:srvdSource>' "$NAME" "$NAME") ;;
  srvb)
    [ -n "${SRVD:-}" ] || { echo "srvb needs SRVD=<service def> env (use build_srvb.sh <BINDING> <SRVD>)"; exit 2; }
    sdl=$(echo "$SRVD" | tr 'A-Z' 'a-z')
    COLL="/sap/bc/adt/businessservices/bindings"; ATYPE="SRVB/SVB"; MODE="createonly"
    MEDIA="application/vnd.sap.adt.businessservices.servicebinding.v2+xml"
    CRE=$(printf '<?xml version="1.0" encoding="UTF-8"?><srvb:serviceBinding xmlns:srvb="http://www.sap.com/adt/ddic/ServiceBindings" xmlns:adtcore="http://www.sap.com/adt/core" srvb:contract="C1" adtcore:name="%s" adtcore:type="SRVB/SVB" adtcore:description="%s"><adtcore:packageRef adtcore:name="'"$PKG"'"/><srvb:services srvb:name="%s"><srvb:content srvb:version="0001" srvb:releaseState="NOT_RELEASED"><srvb:serviceDefinition adtcore:uri="/sap/bc/adt/ddic/srvd/sources/%s" adtcore:type="SRVD/SRV" adtcore:name="%s"/></srvb:content></srvb:services><srvb:binding srvb:type="ODATA" srvb:version="V4" srvb:category="0"><srvb:implementation adtcore:name="%s"/></srvb:binding></srvb:serviceBinding>' "$NAME" "$NAME" "$NAME" "$sdl" "$SRVD" "$NAME") ;;
  *) echo "unknown type '$TYPE' (class|prog|cds|tabl|doma|dtel|intf|fugr|fm|stru|typegrp|xslt|dcl|bdef|srvd|srvb)"; exit 2 ;;
esac
OBJ="$COLL/$nl"
[ "$MODE" = "createonly" ] || [ -n "$SRC" ] || { echo "source file required for type '$TYPE'"; exit 2; }

WK="$(mktemp -d)"; JA="$WK/jA"; JB="$WK/jB"; trap 'rm -rf "$WK"' EXIT
tok()  { curl -s -m 20 -u "$U" -c "$JA" -b "$JA" -H "$ST" -H 'X-CSRF-Token: Fetch' -D - -o /dev/null "$B/sap/bc/adt/discovery?$C" | awk 'tolower($1)=="x-csrf-token:"{print $2}' | tr -d '\r'; }
tokf() { curl -s -m 20 -u "$U" -c "$JB" -b "$JB" -H 'X-CSRF-Token: Fetch' -D - -o /dev/null "$B/sap/bc/adt/discovery?$C" | awk 'tolower($1)=="x-csrf-token:"{print $2}' | tr -d '\r'; }

# 1) CREATE (400/409 if it already exists — PUT below still updates the source)
RC=0
echo "$CRE" > "$WK/cre.xml"; T=$(tok)
CRC=$(curl -s -m 30 -u "$U" -b "$JA" -H "$ST" -H "X-CSRF-Token: $T" -H "Content-Type: $MEDIA" \
  --data-binary @"$WK/cre.xml" "$B$COLL?${CORR}$C" -o "$WK/cre.out" -w '%{http_code}')
echo -n "create $CRC "
case "$CRC" in 4*|5*) grep -qi 'already exist' "$WK/cre.out" || RC=1;; esac   # "already exists" on rebuild is benign
if [ "$MODE" != "createonly" ]; then   # FUGR = create + activate only (no user source/main)
# 2) LOCK
T=$(tok); LH=$(curl -s -m 20 -u "$U" -b "$JA" -H "$ST" -H "X-CSRF-Token: $T" \
  -H 'Accept: application/vnd.sap.as+xml;dataname=com.sap.adt.lock.Result' \
  -X POST "$B$OBJ?_action=LOCK&accessMode=MODIFY&$C" | grep -oE '<LOCK_HANDLE>[^<]*' | sed 's/<LOCK_HANDLE>//')
[ -n "$LH" ] || { echo "lock FAILED (no handle — object locked / inactive / no permission)"; exit 1; }
# 3) PUT — text source/main for src types; whole object XML to the object URI for doma/dtel
if [ "$MODE" = "xml" ]; then PUT_URL="$B$OBJ?lockHandle=$LH&${CORR}$C"; PUT_CT="$MEDIA"
else PUT_URL="$B$OBJ/source/main?lockHandle=$LH&${CORR}$C"; PUT_CT="text/plain; charset=utf-8"; fi
tr -d '\r' < "$SRC" > "$WK/src.norm"   # normalize CRLF -> LF before upload (match tools/abap)
T=$(tok); PRC=$(curl -s -m 30 -u "$U" -b "$JA" -H "$ST" -H "X-CSRF-Token: $T" \
  -H "Content-Type: $PUT_CT" --data-binary @"$WK/src.norm" -X PUT "$PUT_URL" -o /dev/null -w '%{http_code}')
echo -n "put $PRC "
case "$PRC" in 4*|5*) RC=1;; esac
# 4) UNLOCK
T=$(tok); curl -s -m 20 -u "$U" -b "$JA" -H "$ST" -H "X-CSRF-Token: $T" \
  -X POST "$B$OBJ?_action=UNLOCK&lockHandle=$LH&$C" -o /dev/null
fi
# 5) ACTIVATE — fresh session + token (lock/PUT rotated the CSRF)
printf '<?xml version="1.0" encoding="UTF-8"?><adtcore:objectReferences xmlns:adtcore="http://www.sap.com/adt/core"><adtcore:objectReference adtcore:uri="%s" adtcore:type="%s" adtcore:name="%s"/></adtcore:objectReferences>' "$OBJ" "$ATYPE" "$NAME" > "$WK/act.xml"
TB=$(tokf); ACODE=$(curl -s -m 40 -u "$U" -b "$JB" -H "X-CSRF-Token: $TB" -H 'Content-Type: application/xml' \
  --data-binary @"$WK/act.xml" "$B/sap/bc/adt/activation?method=activate&preauditRequested=false&$C" -o "$WK/act.out" -w '%{http_code}')
A=$(cat "$WK/act.out")
echo "activate $(echo "$A" | grep -oE 'activationExecuted="[^"]*"' | head -1) (http=$ACODE)"
echo "$A" | tr '>' '>\n' | grep -iE 'type="[EA]"|<txt' | sed -E 's/<[^>]*>//g' | grep . | head -8
case "$ACODE" in 4*|5*|000) RC=1;; esac                       # activation request itself failed (conn/403/423/5xx)
echo "$A" | grep -qE 'type="[EA]"' && RC=1                     # E=error / A=abort = compile/type failure (match tools/abap)
# 5b) PUBLISH (srvb only) — make the OData V4 service live (activation alone leaves published=false)
if [ "$TYPE" = "srvb" ]; then
  printf '<?xml version="1.0" encoding="UTF-8"?><adtcore:objectReferences xmlns:adtcore="http://www.sap.com/adt/core"><adtcore:objectReference adtcore:uri="%s" adtcore:type="SRVB/SVB" adtcore:name="%s"/></adtcore:objectReferences>' "$OBJ" "$NAME" > "$WK/pub.xml"
  TP=$(tokf)
  PUB=$(curl -s -m 50 -u "$U" -b "$JB" -H "X-CSRF-Token: $TP" -H 'Content-Type: application/xml' --data-binary @"$WK/pub.xml" "$B/sap/bc/adt/businessservices/odatav4/publishjobs?servicename=$NAME&serviceversion=0001&$C")
  STXT=$(echo "$PUB" | grep -oE '<SHORT_TEXT>[^<]*' | sed 's/<SHORT_TEXT>//')
  echo "publish ${STXT:-<no SHORT_TEXT>}"
  [ -n "$STXT" ] || RC=1   # publish must produce a job result; activation alone leaves the OData service 404
fi
# 6) RUN (class only — reports/CDS have no classrun)
if [ "$RUN" = "run" ] && [ "$TYPE" = "class" ]; then
  echo "--- RUN ---"; TR2=$(tokf)
  curl -s -m 30 -u "$U" -b "$JB" -H "X-CSRF-Token: $TR2" -H 'Accept: text/plain' \
    -X POST "$B/sap/bc/adt/oo/classrun/$nl?$C"
fi
exit "${RC:-0}"   # non-zero on create/PUT/activation/publish failure (CI / agent loops) — matches tools/abap
