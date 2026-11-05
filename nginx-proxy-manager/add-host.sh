#!/usr/bin/env bash
# Manage Nginx Proxy Manager (NPM) proxy hosts from the shell, via NPM's REST
# API - the same API the web UI (LAN :81) uses. Only the NPM_* keys are read
# from ../.env (never printed); the admin password is prompted for with hidden
# input when NPM_ADMIN_PASSWORD is not set. Fresh JWT per run, no token files.
set -euo pipefail
D=$(cd "$(dirname "$0")" && pwd)
ENVFILE="$D/../.env"
API_URL="http://127.0.0.1:81/api"

usage() {
  cat <<'EOF'
Manage NPM proxy hosts (create / update / list / delete) from the shell.

  add-host.sh <domain> <forward_host>:<forward_port> [options]    create
  add-host.sh --list                                               list hosts
  add-host.sh --delete <domain|id> [-y]                            delete a host

Options:
  --scheme http|https     forwarding scheme (default: http)
  --no-ssl                skip Let's Encrypt + force SSL (SSL is ON by
                          default; needs DNS + ports 80/443 reaching NPM)
  --cert <id>             attach this existing NPM certificate instead of
                          the default lookup (see --list / NPM UI cert list)
  --new-cert              skip certificate reuse: request a dedicated
                          Let's Encrypt cert (create only; conflicts with
                          --cert / --no-ssl)
  --hsts                  enable HSTS (default: off)
  --no-websocket          WebSockets support (default: on)
  --no-http2              HTTP/2 support (default: on)
  --no-block-exploits     "block common exploits" (default: on)
  --caching               Cache Assets (default: off)
  --authelia              Advanced config := include /snippets/authelia.conf;
  --advanced '<nginx>'    custom Advanced config (this or --authelia, not both)
  --update                update if the domain exists (flags are the source of
                          truth; an attached certificate is always kept)
  --dry-run               print the API payloads, change nothing
  -y                      assume yes (e.g. for --delete)

Forward to the CONTAINER name (NPM shares the compose proxy-net). Examples:
  add-host.sh books.ftoralesacosta.me bindery:8787 --authelia
  add-host.sh kavita.ftoralesacosta.me kavita:5000
  add-host.sh new.ftoralesacosta.me service:1234 --cert 7   # reuse wildcard

An --authelia host only gets the nginx include; who may pass the gate is set by
access_control in authelia/configuration.yml (then: docker restart authelia).

Login: NPM_ADMIN_EMAIL comes from ../.env; the admin password is prompted
(hidden input) unless NPM_ADMIN_PASSWORD is in the environment or ../.env.
EOF
}

die() { echo "ERROR: $*" >&2; exit 1; }

confirm() {
  if [ "$ASSUME_YES" = true ]; then return 0; fi
  local a
  read -r -p "$1 [y/N] " a || return 1
  case $a in [yY]) return 0 ;; *) return 1 ;; esac
}

# --- credentials: runtime env overrides ../.env, prompt is the last resort -----
# (only the NPM_* keys are ever read from the .env file - never sourced whole)
env_get() {
  local line
  line=$(grep -E "^$1=" "$ENVFILE" 2>/dev/null | head -n1) || true
  printf '%s' "${line#*=}" | tr -d '\r'
}
NPM_ADMIN_EMAIL=${NPM_ADMIN_EMAIL:-$(env_get NPM_ADMIN_EMAIL)}
NPM_ADMIN_PASSWORD=${NPM_ADMIN_PASSWORD:-$(env_get NPM_ADMIN_PASSWORD)}
NPM_LE_EMAIL=${NPM_LE_EMAIL:-$(env_get NPM_LE_EMAIL)}
NPM_API_URL=${NPM_API_URL:-$(env_get NPM_API_URL)}
if [ -n "$NPM_API_URL" ]; then API_URL=${NPM_API_URL%/}; fi

# --- argument parsing --------------------------------------------------------
DOMAIN=""; FORWARD=""
SCHEME=http; WEBSOCK=true; HTTP2=true; BLOCK=true; CACHING=false
HSTS=false; SSL=true; UPDATE=false; DRY=false; ASSUME_YES=false
NO_SSL_SET=0; CERT_ID=""; NEW_CERT=false
ADV=""; ADV_SET=0; AUTH_SET=0; CUSTOM_SET=0
MODE=host          # host | list | delete
DELETE_ARG=""

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --list)
      if [ "$MODE" != host ]; then die "use only one of --list / --delete"; fi
      MODE=list ;;
    --delete)
      if [ "$MODE" != host ]; then die "use only one of --list / --delete"; fi
      MODE=delete; shift
      [ $# -ge 1 ] || die "--delete needs a domain or host id"
      DELETE_ARG=$1 ;;
    --scheme)
      shift; [ $# -ge 1 ] || die "--scheme needs http or https"
      case "$1" in http|https) SCHEME=$1 ;; *) die "--scheme must be http or https" ;; esac ;;
    --no-ssl)          SSL=false; NO_SSL_SET=1 ;;
    --hsts)            HSTS=true ;;
    --no-websocket)    WEBSOCK=false ;;
    --no-http2)        HTTP2=false ;;
    --no-block-exploits) BLOCK=false ;;
    --caching)         CACHING=true ;;
    --cert)
      shift; [ $# -ge 1 ] || die "--cert needs an existing NPM certificate id (see --list)"
      [[ "$1" =~ ^[1-9][0-9]*$ ]] || die "--cert must be a positive numeric certificate id"
      CERT_ID=$1 ;;
    --new-cert)        NEW_CERT=true ;;
    --authelia)        ADV='include /snippets/authelia.conf;'; ADV_SET=1; AUTH_SET=1 ;;
    --advanced)
      shift; [ $# -ge 1 ] || die "--advanced needs a value (nginx directives)"
      ADV=$1; ADV_SET=1; CUSTOM_SET=1 ;;
    --update)          UPDATE=true ;;
    --dry-run)         DRY=true ;;
    -y)                ASSUME_YES=true ;;
    *)
      if [ -z "$DOMAIN" ]; then DOMAIN=${1,,}
      elif [ -z "$FORWARD" ]; then FORWARD=$1
      else usage >&2; exit 1; fi ;;
  esac
  shift
done

if [ "$AUTH_SET" = 1 ] && [ "$CUSTOM_SET" = 1 ]; then
  die "--authelia and --advanced are mutually exclusive"
fi
if [ "$NO_SSL_SET" = 1 ] && { [ -n "$CERT_ID" ] || [ "$NEW_CERT" = true ]; }; then
  die "--no-ssl cannot be combined with --cert / --new-cert"
fi
if [ -n "$CERT_ID" ] && [ "$NEW_CERT" = true ]; then
  die "--cert and --new-cert are mutually exclusive"
fi
if [ "$NEW_CERT" = true ] && [ "$UPDATE" = true ]; then
  die "--new-cert cannot be combined with --update (use --cert <id> to set a certificate)"
fi

if [ "$MODE" != host ]; then
  if [ -n "$DOMAIN" ] || [ -n "$FORWARD" ]; then die "unexpected arguments for $MODE mode"; fi
else
  if [ -z "$DOMAIN" ] || [ -z "$FORWARD" ]; then usage >&2; exit 1; fi
  [[ "$DOMAIN" =~ ^(\*\.)?([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$ ]] \
    || die "invalid domain: '$DOMAIN'"
  FHOST=${FORWARD%:*}; FPORT=${FORWARD##*:}
  if [ "$FHOST" = "$FORWARD" ] || [ -z "$FHOST" ]; then die "forward must be <host>:<port>"; fi
  [[ "$FPORT" =~ ^[0-9]+$ ]] || die "invalid port in '$FORWARD'"
  [[ "$FHOST" =~ [[:space:]] ]] && die "invalid host in '$FORWARD'" || true
fi

# --- API helpers -------------------------------------------------------------
TOKEN=""
STATUS=""; BODY=""
api() {  # api METHOD PATH [json]  -> sets STATUS and BODY
  local out
  if [ $# -ge 3 ]; then
    out=$(curl -sS -m 60 -X "$1" \
      -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
      -w '\n%{http_code}' --data "$3" "$API_URL$2") || die "request failed: $1 $2"
  else
    out=$(curl -sS -m 60 -X "$1" \
      -H "Authorization: Bearer $TOKEN" \
      -w '\n%{http_code}' "$API_URL$2") || die "request failed: $1 $2"
  fi
  STATUS=${out##*$'\n'}
  BODY=${out%$'\n'*}
}

login() {
  if [ -z "$NPM_ADMIN_EMAIL" ]; then
    die "NPM_ADMIN_EMAIL missing - set it in ../.env (see .env.example)"
  fi
  if [ -z "$NPM_ADMIN_PASSWORD" ]; then
    # password is never stored: hidden prompt (env var / .env only for scripts)
    if [ ! -e /dev/tty ]; then
      die "no terminal - set NPM_ADMIN_PASSWORD (environment or ../.env) for non-interactive use"
    fi
    printf 'NPM admin password: ' >&2
    IFS= read -rs NPM_ADMIN_PASSWORD </dev/tty \
      || die "could not read password - set NPM_ADMIN_PASSWORD for non-interactive use"
    printf '\n' >&2
    [ -n "$NPM_ADMIN_PASSWORD" ] || die "empty password"
  fi
  api POST /tokens "$(jq -cn --arg i "$NPM_ADMIN_EMAIL" --arg s "$NPM_ADMIN_PASSWORD" '{identity:$i, secret:$s}')"
  [ "$STATUS" = 200 ] || die "NPM login failed (HTTP $STATUS) - wrong NPM admin email or password"
  TOKEN=$(jq -r '.token // empty' <<<"$BODY")
  [ -n "$TOKEN" ] || die "NPM login returned no token"
}

# NPM < 2.13 needs meta.letsencrypt_* on cert requests; >= 2.13 rejects them.
# If the probe fails, assume < 2.13 (this stack runs 2.12.x).
npm_uses_legacy_le() {
  local v maj min
  v=$(curl -sS -m 10 "$API_URL/" 2>/dev/null) || v=""
  maj=$(jq -r '.version.major // 0' <<<"$v" 2>/dev/null) || maj=0
  min=$(jq -r '.version.minor // 0' <<<"$v" 2>/dev/null) || min=0
  case "$maj$min" in *[!0-9]*) return 0 ;; esac
  [ $((10#$maj * 1000 + 10#$min)) -lt 2013 ]
}

HOSTS=""
fetch_hosts() {
  api GET /nginx/proxy-hosts
  [ "$STATUS" = 200 ] || die "listing proxy hosts failed (HTTP $STATUS)"
  HOSTS=$BODY
}
host_id_for() {  # domain -> host id or empty
  jq -r --arg d "$1" \
    'map(select((.domain_names // []) | index($d))) | if length > 0 then .[0].id else empty end' \
    <<<"$HOSTS"
}

# --- modes -------------------------------------------------------------------
do_list() {
  fetch_hosts
  printf 'ID\tDOMAINS\tFORWARD\tSSL\tSTATE\tGATE\n'
  jq -r 'sort_by(.id)[] | [
    (.id|tostring),
    (.domain_names|join(",")),
    (.forward_scheme+"://"+.forward_host+":"+(.forward_port|tostring)),
    (if ((.certificate_id // 0) > 0) then "cert#"+(.certificate_id|tostring)+(if .ssl_forced then " forced" else "" end) else "-" end),
    (if .enabled then "on" else "OFF" end),
    (if ((.advanced_config // "") | contains("authelia.conf")) then "authelia" else "-" end)
  ] | @tsv' <<<"$HOSTS" | { command -v column >/dev/null && column -t -s$'\t' || cat; }
}

do_delete() {
  fetch_hosts
  local id=$DELETE_ARG
  if ! [[ "$id" =~ ^[0-9]+$ ]]; then
    id=$(host_id_for "$DELETE_ARG")
    [ -n "$id" ] || die "no proxy host found for '$DELETE_ARG'"
  fi
  api GET /nginx/proxy-hosts/$id
  [ "$STATUS" = 200 ] || die "host $id not found (HTTP $STATUS)"
  jq -r '"Deleting: \(.domain_names|join(", ")) -> \(.forward_scheme)://\(.forward_host):\(.forward_port)"' <<<"$BODY"
  if [ "$DRY" = true ]; then echo "[dry-run] would delete host $id"; exit 0; fi
  confirm "Really delete host $id?" || die "aborted"
  api DELETE /nginx/proxy-hosts/$id
  [ "$STATUS" = 200 ] || die "delete failed (HTTP $STATUS): $BODY"
  echo "Deleted host $id. (Its certificate, if any, stays in NPM's certificate list.)"
}

build_host_json() {
  jq -cn \
    --arg domain "$DOMAIN" --arg host "$FHOST" --argjson port "$FPORT" \
    --arg scheme "$SCHEME" --arg advanced "$ADV" \
    --argjson caching "$CACHING" --argjson block "$BLOCK" \
    --argjson ws "$WEBSOCK" --argjson http2 "$HTTP2" --argjson hsts "$HSTS" \
    '{domain_names:[$domain], forward_host:$host, forward_port:$port,
      forward_scheme:$scheme, access_list_id:null, certificate_id:null,
      ssl_forced:false, caching_enabled:$caching, block_exploits:$block,
      advanced_config:$advanced, allow_websocket_upgrade:$ws,
      http2_support:$http2, hsts_enabled:$hsts, hsts_subdomains:false,
      meta:{dns_challenge:null}, enabled:true, locations:[]}'
}

attach_cert() {  # attach_cert <host_id> <cert_id> - reuse an existing NPM cert
  local host_id=$1 cid=$2 nice expires
  api GET /nginx/certificates/$cid
  [ "$STATUS" = 200 ] || die "certificate id $cid not found in NPM (HTTP $STATUS) - see --list / the cert list in the NPM UI"
  nice=$(jq -r '.nice_name // empty' <<<"$BODY")
  expires=$(jq -r '.expires_on // empty' <<<"$BODY")
  echo "SSL: using existing certificate $cid${nice:+ ($nice)}${expires:+, expires $expires}"
  api PUT /nginx/proxy-hosts/$host_id "$(jq -cn --argjson cid "$cid" \
    '{certificate_id:$cid, ssl_forced:true}')"
  [ "$STATUS" = 200 ] || die "attaching certificate $cid failed (HTTP $STATUS): $BODY"
  echo "SSL: certificate $CERT_ID attached, Force SSL enabled"
}

find_covering_cert() {  # -> id of an existing NPM cert covering $DOMAIN, or empty
  api GET /nginx/certificates
  [ "$STATUS" = 200 ] || return 0   # non-fatal: fall back to issuing a new cert
  jq -r --arg d "$DOMAIN" '
    [ .[] | . as $c
      | ([ $c.domain_names[]? | . as $e | select($e == $d) ] | length) as $ex
      | ([ $c.domain_names[]? | . as $e
           | select(($e | startswith("*.")) and ($d | endswith($e[1:]))) ] | length) as $wl
      | select($ex + $wl > 0)
      | {id: $c.id, score: ($ex * 2 + $wl)} ]
    | sort_by(-.score, -.id) | .[0].id // empty' <<<"$BODY"
}

issue_and_attach() {  # issue_and_attach <host_id>
  local host_id=$1 email cert_json cert_id i expires
  if npm_uses_legacy_le; then
    email=${NPM_LE_EMAIL:-$NPM_ADMIN_EMAIL}
    cert_json=$(jq -cn --arg d "$DOMAIN" --arg e "$email" \
      '{provider:"letsencrypt", domain_names:[$d], meta:{letsencrypt_agree:true, letsencrypt_email:$e}}')
  else
    cert_json=$(jq -cn --arg d "$DOMAIN" \
      '{provider:"letsencrypt", domain_names:[$d], meta:{}}')
  fi
  echo "Requesting Let's Encrypt certificate for $DOMAIN ..."
  api POST /nginx/certificates "$cert_json"
  [ "$STATUS" = 201 ] || die "certificate request failed (HTTP $STATUS): $BODY"
  cert_id=$(jq -r '.id' <<<"$BODY")
  api PUT /nginx/proxy-hosts/$host_id "$(jq -cn \
    --argjson cid "$cert_id" --argjson http2 "$HTTP2" --argjson hsts "$HSTS" \
    '{certificate_id:$cid, ssl_forced:true, http2_support:$http2,
      hsts_enabled:$hsts, hsts_subdomains:false}')"
  [ "$STATUS" = 200 ] || die "attaching certificate failed (HTTP $STATUS): $BODY"
  echo "SSL: Let's Encrypt cert id $cert_id requested, Force SSL enabled"
  for i in $(seq 1 18); do
    sleep 5
    api GET /nginx/certificates/$cert_id
    if [ "$STATUS" = 200 ]; then
      expires=$(jq -r '.expires_on // empty' <<<"$BODY")
      if [ -n "$expires" ]; then
        echo "SSL: certificate issued (expires $expires)"
        return 0
      fi
    fi
  done
  echo "WARNING: certificate still pending after ~90s (attached as cert id $cert_id)."
  echo "  Check: docker exec nginx-proxy-manager tail -n 30 /data/logs/letsencrypt.log"
  echo "  NPM finishes/renews in the background; https works once issued."
}

do_host() {
  fetch_hosts
  local id; id=$(host_id_for "$DOMAIN")
  local method path body current patch
  if [ -z "$id" ]; then
    method=POST; path=/nginx/proxy-hosts
    body=$(build_host_json)
  elif [ "$UPDATE" = true ]; then
    method=PUT; path=/nginx/proxy-hosts/$id
    api GET "$path"
    [ "$STATUS" = 200 ] || die "fetching current host failed (HTTP $STATUS)"
    current=$BODY
    patch=$(build_host_json)
    if [ "$ADV_SET" = 0 ]; then patch=$(jq -c 'del(.advanced_config)' <<<"$patch"); fi
    if [ -n "$CERT_ID" ]; then
      patch=$(jq -c --argjson cid "$CERT_ID" \
        '.certificate_id=$cid | .ssl_forced=true' <<<"$patch")
    else
      patch=$(jq -c 'del(.certificate_id, .ssl_forced)' <<<"$patch")
    fi
    # merge, then keep only the properties NPM's PUT schema accepts
    # (GET adds read-only extras like id/created_on/owner - they cause HTTP 400)
    body=$(jq -c --argjson p "$patch" '. * $p |
      {domain_names, forward_scheme, forward_host, forward_port, access_list_id,
       certificate_id, ssl_forced, caching_enabled, block_exploits, advanced_config,
       allow_websocket_upgrade, http2_support, hsts_enabled, hsts_subdomains,
       meta, enabled, locations}' <<<"$current")
  else
    die "domain '$DOMAIN' already exists (host id $id) - add --update to change it"
  fi

  if [ "$DRY" = true ]; then
    if [ "$method" = POST ]; then echo "[dry-run] would CREATE host '$DOMAIN' -> $SCHEME://$FHOST:$FPORT"
    else echo "[dry-run] would UPDATE host $id '$DOMAIN' -> $SCHEME://$FHOST:$FPORT"; fi
    echo "[dry-run] $method $path"
    jq . <<<"$body"
    if [ "$SSL" = true ]; then
      if [ -n "$CERT_ID" ]; then
        echo "[dry-run] would attach certificate $CERT_ID and set ssl_forced:true"
      elif [ "$NEW_CERT" = true ]; then
        echo "[dry-run] would request a dedicated Let's Encrypt cert and set ssl_forced:true"
      else
        echo "[dry-run] would auto-attach an existing covering certificate (e.g. the"
        echo "[dry-run] wildcard) if one exists, else request a Let's Encrypt cert"
      fi
    fi
    exit 0
  fi

  api "$method" "$path" "$body"
  if [ "$method" = POST ]; then
    [ "$STATUS" = 201 ] || die "create failed (HTTP $STATUS): $BODY"
  else
    [ "$STATUS" = 200 ] || die "update failed (HTTP $STATUS): $BODY"
  fi
  local host_id
  host_id=$(jq -r '.id // empty' <<<"$BODY")
  echo "OK: host $host_id '$DOMAIN' -> $SCHEME://$FHOST:$FPORT"

  if [ "$AUTH_SET" = 1 ]; then
    echo "Gate enabled: add an access_control rule for $DOMAIN in authelia/configuration.yml,"
    echo "then: docker restart authelia (who may pass: see SSO section in README.md)."
  fi

  if [ "$SSL" = true ]; then
    local cur_cert auto
    cur_cert=$(jq -r '(.certificate_id // 0)' <<<"$BODY")
    if [ "$cur_cert" != 0 ] && [ -n "$cur_cert" ]; then
      if [ -n "$CERT_ID" ] && [ "$cur_cert" = "$CERT_ID" ]; then
        echo "SSL: certificate $CERT_ID attached, Force SSL enabled"
      else
        echo "SSL: existing certificate id $cur_cert kept"
      fi
    elif [ "$NEW_CERT" = true ]; then
      issue_and_attach "$host_id"
    elif [ -n "$CERT_ID" ]; then
      attach_cert "$host_id" "$CERT_ID"
    else
      auto=$(find_covering_cert)
      if [ -n "$auto" ]; then
        echo "SSL: certificate $auto already covers $DOMAIN - attaching it"
        echo "     (use --new-cert to request a dedicated cert instead)"
        attach_cert "$host_id" "$auto"
      else
        issue_and_attach "$host_id"
      fi
    fi
  fi
}

case "$MODE" in
  list)   login; do_list ;;
  delete) login; do_delete ;;
  host)   login; do_host ;;
esac
