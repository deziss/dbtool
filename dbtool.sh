#!/usr/bin/env bash
#
# dbtool.sh — PostgreSQL / MySQL backup, restore and server-to-server migration
#
# Description: Config-driven (YAML or JSON) dump / restore / migrate tool that
#              version-matches the client to the server, so any server version
#              can be handled from one box.
# Usage:       ./dbtool.sh <command> [options]     (run with -h for full help)
# Prereqs:     bash 4+, python3, and either native pg/mysql clients or docker.
#              Optional: zstd or pigz, mc or aws (off-box copy), curl (webhook).
#
# Copyright (C) 2026 Anshu Kushwaha
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of the GNU Affero General Public License as published by the Free
# Software Foundation, either version 3 of the License, or (at your option) any
# later version.
#
# This program is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
# FOR A PARTICULAR PURPOSE.  See the GNU Affero General Public License for more
# details: <https://www.gnu.org/licenses/>.
#
set -Eeuo pipefail

readonly DBTOOL_VERSION="1.1.0"
readonly SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ===========================================================================
#  Embedded config parser (YAML + JSON, no hard dependency on PyYAML)
# ===========================================================================
read -r -d '' DBTOOL_CFG_PY <<'PYEOF' || true
#!/usr/bin/env python3
# dbtool config/URL parser. Emits shell-evalable assignments.
# Modes: defaults|s3|notify|names|entry|url
import sys, os, re, json, urllib.parse

# ---------- minimal YAML subset parser (used only when PyYAML is absent) ----------
def _split_flow(s):
    out, buf, q, depth = [], '', None, 0
    for ch in s:
        if q:
            buf += ch
            if ch == q:
                q = None
        elif ch in '"\'':
            q = ch; buf += ch
        elif ch in '[{':
            depth += 1; buf += ch
        elif ch in ']}':
            depth -= 1; buf += ch
        elif ch == ',' and depth == 0:
            out.append(buf); buf = ''
        else:
            buf += ch
    if buf.strip():
        out.append(buf)
    return out

def _scalar(s):
    s = s.strip()
    if len(s) >= 2 and s[0] == s[-1] and s[0] in '"\'':
        return s[1:-1]
    if s in ('', '~', 'null', 'Null', 'NULL'):
        return None
    if s in ('true', 'True', 'TRUE', 'yes', 'on'):
        return True
    if s in ('false', 'False', 'FALSE', 'no', 'off'):
        return False
    if re.fullmatch(r'-?\d+', s):
        return int(s)
    if re.fullmatch(r'-?\d+\.\d+', s):
        return float(s)
    if s.startswith('[') and s.endswith(']'):
        inner = s[1:-1].strip()
        return [_scalar(x) for x in _split_flow(inner)] if inner else []
    return s

def _strip_comment(line):
    q = None
    for i, ch in enumerate(line):
        if q:
            if ch == q:
                q = None
        elif ch in '"\'':
            q = ch
        elif ch == '#' and (i == 0 or line[i-1] in ' \t'):
            return line[:i]
    return line

def _tokens(text):
    out = []
    for raw in text.splitlines():
        line = _strip_comment(raw).rstrip()
        if not line.strip() or line.strip() in ('---', '...'):
            continue
        indent = len(line) - len(line.lstrip(' '))
        out.append((indent, line.strip()))
    return out

def _parse(lines, i, indent):
    if i >= len(lines):
        return None, i
    _, first = lines[i]
    if first == '-' or first.startswith('- '):
        arr = []
        while i < len(lines):
            ind, content = lines[i]
            if ind != indent or not (content == '-' or content.startswith('- ')):
                break
            rest = content[2:].strip() if content.startswith('- ') else ''
            if rest == '':
                i += 1
                if i < len(lines) and lines[i][0] > ind:
                    child, i = _parse(lines, i, lines[i][0])
                    arr.append(child)
                else:
                    arr.append(None)
            elif re.match(r'^[^:\[{]+:(\s|$)', rest):
                sub = [(ind + 2, rest)]
                j = i + 1
                while j < len(lines) and lines[j][0] > ind:
                    sub.append(lines[j]); j += 1
                obj, _ = _parse(sub, 0, ind + 2)
                arr.append(obj); i = j
            else:
                arr.append(_scalar(rest)); i += 1
        return arr, i
    d = {}
    while i < len(lines):
        ind, content = lines[i]
        if ind < indent:
            break
        if ind > indent:
            i += 1; continue
        m = re.match(r'^("[^"]*"|\'[^\']*\'|[^:]+):\s*(.*)$', content)
        if not m:
            i += 1; continue
        k = m.group(1).strip().strip('"\'')
        v = m.group(2).strip()
        if v == '':
            nxt = i + 1
            if nxt < len(lines) and (lines[nxt][0] > ind or
                                     (lines[nxt][0] == ind and (lines[nxt][1] == '-' or lines[nxt][1].startswith('- ')))):
                child, i = _parse(lines, nxt, lines[nxt][0])
                d[k] = child
            else:
                d[k] = None; i += 1
        else:
            d[k] = _scalar(v); i += 1
    return d, i

def mini_yaml(text):
    obj, _ = _parse(_tokens(text), 0, 0)
    return obj if obj is not None else {}

def load_cfg(path):
    with open(path, 'r', encoding='utf-8') as fh:
        text = fh.read()
    stripped = text.lstrip()
    if stripped.startswith('{') or stripped.startswith('['):
        return json.loads(text)
    if path.endswith(('.json', '.jsn')):
        return json.loads(text)
    try:
        import yaml  # noqa
        return yaml.safe_load(text) or {}
    except ImportError:
        return mini_yaml(text)

# ---------- env handling ----------
ENVRE = re.compile(r'\$\{([A-Za-z_][A-Za-z0-9_]*)(?::-([^}]*))?\}|\$([A-Za-z_][A-Za-z0-9_]*)')

def load_env_file(path):
    if not os.path.isfile(path):
        print('dbtool: env_file not found: %s' % path, file=sys.stderr)
        return
    with open(path, 'r', encoding='utf-8') as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith('#'):
                continue
            if line.startswith('export '):
                line = line[7:].strip()
            if '=' not in line:
                continue
            k, v = line.split('=', 1)
            k = k.strip(); v = v.strip()
            if len(v) >= 2 and v[0] == v[-1] and v[0] in '"\'':
                v = v[1:-1]
            os.environ.setdefault(k, v)

def expand(val):
    if not isinstance(val, str):
        return val
    def sub(m):
        name = m.group(1) or m.group(3)
        default = m.group(2)
        if name in os.environ:
            return os.environ[name]
        if default is not None:
            return default
        print('dbtool: warning: ${%s} is not set (expanded to empty)' % name, file=sys.stderr)
        return ''
    return ENVRE.sub(sub, val)

def deep_expand(o):
    if isinstance(o, dict):
        return {k: deep_expand(v) for k, v in o.items()}
    if isinstance(o, list):
        return [deep_expand(v) for v in o]
    return expand(o)

# ---------- shell emission ----------
def q(v):
    if v is None:
        return "''"
    if isinstance(v, bool):
        v = 'true' if v else 'false'
    return "'" + str(v).replace("'", "'\\''") + "'"

def emit(name, value):
    if isinstance(value, list):
        print('%s=(%s)' % (name, ' '.join(q(x) for x in value)))
    else:
        print('%s=%s' % (name, q(value)))

# ---------- engine / url ----------
def norm_engine(e):
    if not e:
        return ''
    e = str(e).lower().split('+')[0]
    if e in ('postgres', 'postgresql', 'pgsql', 'pg', 'psql'):
        return 'postgres'
    if e in ('mysql', 'mariadb', 'maria'):
        return 'mysql'
    return e

def parse_url(url):
    url = url.strip()
    scheme, sep, rest = url.partition('://')
    if not sep:
        raise SystemExit('dbtool: not a database URL: %s' % url)
    engine = norm_engine(scheme)
    userinfo, _, hostpart = rest.rpartition('@') if '@' in rest else ('', '', rest)
    hostportdb, _, query = hostpart.partition('?')
    hostport, _, dbname = hostportdb.partition('/')
    user = password = ''
    if userinfo:
        u, _, p = userinfo.partition(':')
        user = urllib.parse.unquote(u)
        password = urllib.parse.unquote(p)
    if hostport.startswith('['):
        host, _, port = hostport[1:].partition(']')
        port = port.lstrip(':')
    else:
        host, _, port = hostport.partition(':')
    params = dict(urllib.parse.parse_qsl(query)) if query else {}
    return {
        'engine': engine,
        'host': host or '127.0.0.1',
        'port': port or ('5432' if engine == 'postgres' else '3306'),
        'user': user,
        'password': password,
        'database': urllib.parse.unquote(dbname.split('/')[0]),
        'sslmode': params.get('sslmode') or params.get('ssl_mode') or '',
        'charset': params.get('charset', ''),
    }

FIELD_ALIASES = {
    'user': ('user', 'username', 'uname', 'login'),
    'password': ('password', 'pass', 'passwd', 'pwd'),
    'database': ('database', 'db', 'dbname', 'db_name', 'schema'),
    'host': ('host', 'hostname', 'server', 'addr'),
    'port': ('port',),
    'engine': ('engine', 'type', 'driver', 'kind'),
    'sslmode': ('sslmode', 'ssl_mode', 'ssl'),
}

def pick(d, key):
    for a in FIELD_ALIASES.get(key, (key,)):
        if a in d and d[a] not in (None, ''):
            return d[a]
    return None

def resolve_secret(entry, base):
    pw = pick(entry, 'password')
    if entry.get('password_env'):
        pw = os.environ.get(entry['password_env'], pw)
    if entry.get('password_file'):
        pf = expand(entry['password_file'])
        if os.path.isfile(pf):
            with open(pf, 'r', encoding='utf-8') as fh:
                pw = fh.read().strip()
        else:
            print('dbtool: password_file not found: %s' % pf, file=sys.stderr)
    return pw if pw is not None else base.get('password', '')

def build_entry(entry):
    base = {}
    url = entry.get('url') or entry.get('dsn') or entry.get('database_url')
    if url:
        base = parse_url(expand(str(url)))
    eng = norm_engine(pick(entry, 'engine') or base.get('engine'))
    out = {
        'ENGINE': eng,
        'HOST': pick(entry, 'host') or base.get('host') or '127.0.0.1',
        'PORT': pick(entry, 'port') or base.get('port') or ('5432' if eng == 'postgres' else '3306'),
        'USER': pick(entry, 'user') or base.get('user') or '',
        'PASS': resolve_secret(entry, base),
        'DB': pick(entry, 'database') or base.get('database') or '',
        'SSLMODE': pick(entry, 'sslmode') or base.get('sslmode') or '',
        'CHARSET': entry.get('charset') or base.get('charset') or '',
        'LABEL': entry.get('name') or entry.get('label') or '',
        'FORMAT': entry.get('format') or '',
        'JOBS': entry.get('jobs') or '',
        'SCHEMA_ONLY': entry.get('schema_only', False),
        'DATA_ONLY': entry.get('data_only', False),
        'NO_OWNER': entry.get('no_owner', True),
        'CLEAN': entry.get('clean', False),
        'CREATE_DB': entry.get('create', False),
        'IMAGE': entry.get('image') or '',
        'ENABLED': entry.get('enabled', True),
    }
    for key, name in (('exclude_tables', 'EXCLUDE'), ('include_tables', 'INCLUDE'),
                      ('exclude_schemas', 'EXCLUDE_SCHEMA'), ('schemas', 'SCHEMA'),
                      ('dump_args', 'DUMP_ARGS'), ('restore_args', 'RESTORE_ARGS')):
        v = entry.get(key) or []
        if isinstance(v, str):
            v = [v]
        out[name] = v
    return out

def find_entry(cfg, section, name):
    node = cfg.get(section)
    if node is None:
        raise SystemExit('dbtool: no "%s" section in config' % section)
    if isinstance(node, dict):
        if name not in node:
            raise SystemExit('dbtool: "%s" not found in %s' % (name, section))
        e = dict(node[name] or {})
        e.setdefault('name', name)
        return e
    for e in node:
        if isinstance(e, dict) and (e.get('name') == name or e.get('label') == name):
            return dict(e)
    raise SystemExit('dbtool: "%s" not found in %s' % (name, section))

def entry_names(cfg, section):
    node = cfg.get(section) or []
    if isinstance(node, dict):
        return [k for k, v in node.items() if (v or {}).get('enabled', True) is not False]
    return [e.get('name') for e in node
            if isinstance(e, dict) and e.get('name') and e.get('enabled', True) is not False]

def main():
    mode = sys.argv[1]
    if mode == 'url':
        d = parse_url(sys.argv[2])
        pfx = sys.argv[3] if len(sys.argv) > 3 else 'DB_'
        for k in ('engine', 'host', 'port', 'user', 'database', 'sslmode'):
            emit(pfx + ('DB' if k == 'database' else k.upper()), d[k])
        emit(pfx + 'PASS', d['password'])
        return
    cfg = load_cfg(sys.argv[2])
    if not isinstance(cfg, dict):
        raise SystemExit('dbtool: config root must be a mapping')
    envf = cfg.get('env_file')
    if envf:
        for p in ([envf] if isinstance(envf, str) else envf):
            load_env_file(os.path.expanduser(expand(p)))
    if mode in ('defaults', 's3', 'notify'):
        key = {'defaults': 'defaults', 's3': 's3', 'notify': 'notify'}[mode]
        node = cfg.get(key) or (cfg.get('remote') if mode == 's3' else None) or {}
        for k, v in deep_expand(node).items():
            emit(sys.argv[3] + k.upper(), v)
    elif mode == 'names':
        for n in entry_names(cfg, sys.argv[3]):
            print(n)
    elif mode == 'entry':
        section, name, pfx = sys.argv[3], sys.argv[4], sys.argv[5]
        for k, v in build_entry(deep_expand(find_entry(cfg, section, name))).items():
            emit(pfx + k, v)
    else:
        raise SystemExit('dbtool: unknown parser mode %s' % mode)

main()
PYEOF

# ===========================================================================
#  Globals / defaults
# ===========================================================================
CONFIG="${DBTOOL_CONFIG:-}"
DRY_RUN=false
ASSUME_YES=false
QUIET=false
NO_UPLOAD=false

CFG_BACKUP_DIR="/var/backups/dbtool"
CFG_LOG_FILE=""
CFG_RETENTION_DAYS=14
CFG_RETENTION_MIN_KEEP=3
CFG_COMPRESSION="zstd"
CFG_PG_COMPRESS_LEVEL=6
CFG_FORMAT="custom"
CFG_JOBS=4
CFG_DOCKER="auto"
CFG_DOCKER_NETWORK="host"
CFG_TIMEOUT=7200
CFG_TIMESTAMP_FORMAT="%Y%m%d-%H%M%S"

PG_PROBE_IMAGE="${PG_PROBE_IMAGE:-postgres:17-alpine}"
MY_PROBE_IMAGE="${MY_PROBE_IMAGE:-mysql:8.4}"

RUNDIR="$(mktemp -d "${TMPDIR:-/tmp}/dbtool.XXXXXXXX")"
PY="$RUNDIR/cfg.py"
MY_CNF="$RUNDIR/my.cnf"
declare -a DOCKER_EXTRA=()
declare -a CLEAN_PATHS=()

cleanup() { rm -rf "$RUNDIR" ${CLEAN_PATHS[@]+"${CLEAN_PATHS[@]}"} 2>/dev/null || true; }
trap cleanup EXIT
trap 'err "aborted (signal)"; exit 130' INT TERM

# ===========================================================================
#  Logging
# ===========================================================================
if [[ -t 1 ]]; then C_R=$'\e[31m'; C_G=$'\e[32m'; C_Y=$'\e[33m'; C_B=$'\e[36m'; C_0=$'\e[0m'
else C_R=''; C_G=''; C_Y=''; C_B=''; C_0=''; fi

_ts() { date '+%Y-%m-%d %H:%M:%S'; }
_write_log() { [[ -n $CFG_LOG_FILE ]] && printf '[%s] %s\n' "$(_ts)" "$1" >>"$CFG_LOG_FILE" 2>/dev/null || true; }
log()  { $QUIET || printf '%s[%s]%s %s\n' "$C_B" "$(_ts)" "$C_0" "$*"; _write_log "$*"; }
ok()   { $QUIET || printf '%s[%s] OK%s %s\n' "$C_G" "$(_ts)" "$C_0" "$*"; _write_log "OK: $*"; }
warn() { printf '%s[%s] WARN%s %s\n' "$C_Y" "$(_ts)" "$C_0" "$*" >&2; _write_log "WARN: $*"; }
err()  { printf '%s[%s] ERROR%s %s\n' "$C_R" "$(_ts)" "$C_0" "$*" >&2; _write_log "ERROR: $*"; }
die()  { err "$*"; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
gv()   { eval "printf '%s' \"\${$1-}\""; }

confirm() {
    $ASSUME_YES && return 0
    local reply
    printf '%s%s%s [y/N] ' "$C_Y" "$1" "$C_0" >&2
    read -r reply </dev/tty || return 1
    [[ $reply =~ ^[Yy]([Ee][Ss])?$ ]]
}

# ===========================================================================
#  Config loading
# ===========================================================================
cfgpy() { python3 "$PY" "$@"; }

find_config() {
    [[ -n $CONFIG ]] && { [[ -f $CONFIG ]] || die "config not found: $CONFIG"; return; }
    local c
    for c in ./dbtool.yml ./dbtool.yaml ./dbtool.json \
             "$SCRIPT_DIR/dbtool.yml" "$SCRIPT_DIR/dbtool.yaml" "$SCRIPT_DIR/dbtool.json" \
             /etc/dbtool/dbtool.yml /etc/dbtool/dbtool.yaml /etc/dbtool/dbtool.json; do
        [[ -f $c ]] && { CONFIG="$c"; return; }
    done
    die "no config found. Pass -c <file> or create ./dbtool.yml (see dbtool.example.yml)"
}

load_config() {
    have python3 || die "python3 is required to parse the config"
    printf '%s\n' "$DBTOOL_CFG_PY" >"$PY"
    find_config
    CONFIG="$(cd "$(dirname "$CONFIG")" && pwd)/$(basename "$CONFIG")"
    eval "$(cfgpy defaults "$CONFIG" CFG_)"
    eval "$(cfgpy s3 "$CONFIG" S3_)"
    eval "$(cfgpy notify "$CONFIG" NOTIFY_)"
    S3_ENABLED="$(gv S3_ENABLED)"; S3_PROVIDER="${S3_PROVIDER:-mc}"
    mkdir -p "$CFG_BACKUP_DIR" 2>/dev/null || die "cannot create backup_dir: $CFG_BACKUP_DIR"
    if [[ -n ${CFG_LOG_FILE:-} ]]; then
        mkdir -p "$(dirname "$CFG_LOG_FILE")" 2>/dev/null || true
        touch "$CFG_LOG_FILE" 2>/dev/null || { warn "cannot write $CFG_LOG_FILE — logging to stdout only"; CFG_LOG_FILE=""; }
    fi
    # compressor availability
    case "$CFG_COMPRESSION" in
        zstd) have zstd || { warn "zstd not installed — falling back to gzip"; CFG_COMPRESSION=gzip; } ;;
        gzip|none) : ;;
        *) warn "unknown compression '$CFG_COMPRESSION' — using gzip"; CFG_COMPRESSION=gzip ;;
    esac
}

# Copy a PREFIX_* entry into the CTX_* namespace the runners use.
use_ctx() {
    local p="$1" k
    for k in ENGINE HOST PORT USER PASS DB SSLMODE CHARSET LABEL FORMAT JOBS \
             SCHEMA_ONLY DATA_ONLY NO_OWNER CLEAN CREATE_DB IMAGE; do
        eval "CTX_$k=\"\$(gv ${p}${k})\""
    done
    for k in EXCLUDE INCLUDE EXCLUDE_SCHEMA SCHEMA DUMP_ARGS RESTORE_ARGS; do
        eval "CTX_$k=(\${${p}${k}[@]+\"\${${p}${k}[@]}\"})"
    done
    [[ -n $CTX_FORMAT ]] || CTX_FORMAT="$CFG_FORMAT"
    [[ -n $CTX_JOBS   ]] || CTX_JOBS="$CFG_JOBS"
    [[ -n $CTX_ENGINE ]] || die "entry '$CTX_LABEL': engine could not be determined"
    [[ -n $CTX_DB     ]] || die "entry '$CTX_LABEL': database name is empty"
    [[ $CTX_ENGINE == postgres || $CTX_ENGINE == mysql ]] || die "unsupported engine: $CTX_ENGINE"
}

load_entry() { eval "$(cfgpy entry "$CONFIG" "$1" "$2" "$3")"; }

# ===========================================================================
#  Client resolution (native vs version-matched docker image)
# ===========================================================================
PG_MODE=""; PG_IMAGE=""; PG_SERVER_VER=""; PG_SERVER_MAJOR=""
MY_MODE=""; MY_IMAGE=""; MY_SERVER_VER=""; MY_SERVER_MAJOR=""; MY_FLAVOR="mysql"

_docker_ok() { have docker && docker info >/dev/null 2>&1; }

_pg_query() {  # _pg_query <dbname> <sql>  -> value on stdout, via any available client
    local db="$1" sql="$2" out=""
    if have psql; then
        out="$(env PGPASSWORD="$CTX_PASS" ${CTX_SSLMODE:+PGSSLMODE="$CTX_SSLMODE"} PGCONNECT_TIMEOUT=10 \
              psql -h "$CTX_HOST" -p "$CTX_PORT" -U "$CTX_USER" -d "$db" -tAX -c "$sql" 2>/dev/null)" || out=""
    fi
    if [[ -z $out ]] && _docker_ok; then
        out="$(docker run --rm --network "$CFG_DOCKER_NETWORK" \
              -e PGPASSWORD="$CTX_PASS" ${CTX_SSLMODE:+-e PGSSLMODE="$CTX_SSLMODE"} -e PGCONNECT_TIMEOUT=10 \
              "$PG_PROBE_IMAGE" psql -h "$CTX_HOST" -p "$CTX_PORT" -U "$CTX_USER" -d "$db" -tAX -c "$sql" 2>/dev/null)" || out=""
    fi
    printf '%s' "$(printf '%s' "$out" | tr -d '[:space:]')"
}

_my_query() {  # _my_query <sql>
    write_my_cnf
    local out=""
    if have mysql; then
        out="$(mysql --defaults-extra-file="$MY_CNF" --connect-timeout=10 -N -B -e "$1" 2>/dev/null)" || out=""
    fi
    if [[ -z $out ]] && _docker_ok; then
        out="$(docker run --rm --network "$CFG_DOCKER_NETWORK" -v "$MY_CNF":/tmp/dbtool.cnf:ro \
              "$MY_PROBE_IMAGE" mysql --defaults-extra-file=/tmp/dbtool.cnf --connect-timeout=10 -N -B -e "$1" 2>/dev/null)" || out=""
    fi
    printf '%s' "$(printf '%s' "$out" | tr -d '[:space:]')"
}

_native_major() {  # _native_major <binary>  -> major version of local client
    local v
    v="$("$1" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)" || true
    [[ -z $v ]] && return 1
    printf '%s' "${v%%.*}"
}

resolve_pg_client() {
    PG_SERVER_VER="$(_pg_query "$CTX_DB" 'SHOW server_version')"
    [[ -n $PG_SERVER_VER ]] || PG_SERVER_VER="$(_pg_query postgres 'SHOW server_version')"
    [[ -n $PG_SERVER_VER ]] || die "cannot reach PostgreSQL at $CTX_HOST:$CTX_PORT as '$CTX_USER' (check host/port/user/password/pg_hba)"
    PG_SERVER_VER="${PG_SERVER_VER%%(*}"
    local maj="${PG_SERVER_VER%%.*}"
    (( maj < 10 )) && maj="$(printf '%s' "$PG_SERVER_VER" | cut -d. -f1,2)"
    PG_SERVER_MAJOR="$maj"
    local want="${CTX_IMAGE:-postgres:${maj}-alpine}"
    local nat=""
    have pg_dump && nat="$(_native_major pg_dump || true)"
    case "$CFG_DOCKER" in
        never)
            [[ -n $nat ]] || die "docker=never but pg_dump is not installed"
            PG_MODE=native
            [[ ${nat%%.*} -lt ${maj%%.*} ]] && warn "local pg_dump $nat is older than server $PG_SERVER_MAJOR — dump may fail"
            ;;
        always)
            _docker_ok || die "docker=always but docker is unavailable"
            PG_MODE=docker; PG_IMAGE="$want" ;;
        *)
            if [[ -n $nat && ${nat%%.*} -ge ${maj%%.*} ]]; then PG_MODE=native
            elif _docker_ok; then PG_MODE=docker; PG_IMAGE="$want"
            elif [[ -n $nat ]]; then PG_MODE=native; warn "no docker; using older local pg_dump $nat against server $PG_SERVER_MAJOR"
            else die "no pg_dump and no usable docker — install postgresql-client or docker"
            fi ;;
    esac
    if [[ $PG_MODE == docker ]]; then
        docker image inspect "$PG_IMAGE" >/dev/null 2>&1 || {
            log "pulling $PG_IMAGE ..."
            docker pull -q "$PG_IMAGE" >/dev/null 2>&1 || {
                PG_IMAGE="postgres:${maj}"
                docker pull -q "$PG_IMAGE" >/dev/null || die "cannot pull a postgres:$maj client image"
            }
        }
    fi
    log "postgres server ${PG_SERVER_VER} — client: ${PG_MODE}${PG_IMAGE:+ ($PG_IMAGE)}"
}

resolve_my_client() {
    MY_SERVER_VER="$(_my_query 'SELECT VERSION()')"
    [[ -n $MY_SERVER_VER ]] || die "cannot reach MySQL/MariaDB at $CTX_HOST:$CTX_PORT as '$CTX_USER' (check host/port/user/password/grants)"
    local majmin="${MY_SERVER_VER%%-*}"
    majmin="$(printf '%s' "$majmin" | cut -d. -f1,2)"
    MY_SERVER_MAJOR="${majmin%%.*}"
    if [[ ${MY_SERVER_VER,,} == *mariadb* ]]; then MY_FLAVOR=mariadb; else MY_FLAVOR=mysql; fi
    local want="${CTX_IMAGE:-${MY_FLAVOR}:${majmin}}"
    local nat=""
    have mysqldump && nat="$(_native_major mysqldump || true)"
    case "$CFG_DOCKER" in
        never)
            [[ -n $nat ]] || die "docker=never but mysqldump is not installed"
            MY_MODE=native ;;
        always)
            _docker_ok || die "docker=always but docker is unavailable"
            MY_MODE=docker; MY_IMAGE="$want" ;;
        *)
            if [[ -n $nat && $nat == "$MY_SERVER_MAJOR" ]]; then MY_MODE=native
            elif _docker_ok; then MY_MODE=docker; MY_IMAGE="$want"
            elif [[ -n $nat ]]; then MY_MODE=native; warn "local mysqldump $nat vs server $MY_SERVER_VER — version mismatch"
            else die "no mysqldump and no usable docker — install mysql-client/mariadb-client or docker"
            fi ;;
    esac
    if [[ $MY_MODE == docker ]]; then
        docker image inspect "$MY_IMAGE" >/dev/null 2>&1 || {
            log "pulling $MY_IMAGE ..."
            docker pull -q "$MY_IMAGE" >/dev/null 2>&1 || {
                MY_IMAGE="${MY_FLAVOR}:${MY_SERVER_MAJOR}"
                docker pull -q "$MY_IMAGE" >/dev/null || die "cannot pull a ${MY_FLAVOR}:${majmin} client image"
            }
        }
    fi
    log "${MY_FLAVOR} server ${MY_SERVER_VER} — client: ${MY_MODE}${MY_IMAGE:+ ($MY_IMAGE)}"
}

resolve_client() {
    case "$CTX_ENGINE" in
        postgres) resolve_pg_client ;;
        mysql)    resolve_my_client ;;
    esac
}

write_my_cnf() {
    umask 077
    { printf '[client]\nhost=%s\nport=%s\nuser=%s\n' "$CTX_HOST" "$CTX_PORT" "$CTX_USER"
      [[ -n $CTX_PASS ]] && printf 'password="%s"\n' "${CTX_PASS//\"/\\\"}"
      [[ -n $CTX_CHARSET ]] && printf 'default-character-set=%s\n' "$CTX_CHARSET"
      case "$CTX_SSLMODE" in
        ''|prefer) : ;;
        disable|DISABLED) printf 'ssl-mode=DISABLED\n' ;;
        require|REQUIRED) printf 'ssl-mode=REQUIRED\n' ;;
        *) printf 'ssl-mode=%s\n' "${CTX_SSLMODE^^}" ;;
      esac
    } >"$MY_CNF"
    chmod 600 "$MY_CNF"
}

# ---------------------------------------------------------------------------
#  Command runners — identical interface whether native or containerised
# ---------------------------------------------------------------------------
_timeout_prefix() { have timeout && printf 'timeout\n%s\n' "$CFG_TIMEOUT"; }

pg_run() {  # pg_run <binary> [args...]   (stdin/stdout pass through)
    local bin="$1"; shift
    local -a tp=(); mapfile -t tp < <(_timeout_prefix)
    if $DRY_RUN; then printf '  + [%s] %s %s\n' "$PG_MODE" "$bin" "$*" >&2; return 0; fi
    if [[ $PG_MODE == docker ]]; then
        ${tp[@]+"${tp[@]}"} docker run --rm -i --network "$CFG_DOCKER_NETWORK" \
            -e PGPASSWORD="$CTX_PASS" ${CTX_SSLMODE:+-e PGSSLMODE="$CTX_SSLMODE"} \
            ${DOCKER_EXTRA[@]+"${DOCKER_EXTRA[@]}"} "$PG_IMAGE" "$bin" "$@"
    else
        ${tp[@]+"${tp[@]}"} env PGPASSWORD="$CTX_PASS" ${CTX_SSLMODE:+PGSSLMODE="$CTX_SSLMODE"} "$bin" "$@"
    fi
}

my_run() {  # my_run <binary> [args...]
    local bin="$1"; shift
    write_my_cnf
    local -a tp=(); mapfile -t tp < <(_timeout_prefix)
    if $DRY_RUN; then printf '  + [%s] %s %s\n' "$MY_MODE" "$bin" "$*" >&2; return 0; fi
    if [[ $MY_MODE == docker ]]; then
        ${tp[@]+"${tp[@]}"} docker run --rm -i --network "$CFG_DOCKER_NETWORK" \
            -v "$MY_CNF":/tmp/dbtool.cnf:ro ${DOCKER_EXTRA[@]+"${DOCKER_EXTRA[@]}"} \
            "$MY_IMAGE" "$bin" --defaults-extra-file=/tmp/dbtool.cnf "$@"
    else
        ${tp[@]+"${tp[@]}"} "$bin" --defaults-extra-file="$MY_CNF" "$@"
    fi
}

# ===========================================================================
#  Compression helpers
# ===========================================================================
comp_ext() { case "$CFG_COMPRESSION" in zstd) echo ".zst";; gzip) echo ".gz";; *) echo "";; esac; }
compress_stream() {
    case "$CFG_COMPRESSION" in
        zstd) zstd -T0 -3 -q -c ;;
        gzip) if have pigz; then pigz -c; else gzip -c; fi ;;
        *)    cat ;;
    esac
}
decompress_stream() {  # decompress_stream <file>
    case "$1" in
        *.zst|*.zstd) have zstd || die "zstd needed to read $1"; zstd -dc "$1" ;;
        *.gz)         if have pigz; then pigz -dc "$1"; else gzip -dc "$1"; fi ;;
        *.bz2)        bzip2 -dc "$1" ;;
        *.xz)         xz -dc "$1" ;;
        *)            cat "$1" ;;
    esac
}
test_archive() {
    case "$1" in
        *.zst|*.zstd) zstd -t -q "$1" ;;
        *.gz)         gzip -t "$1" ;;
        *)            [[ -s $1 ]] ;;
    esac
}
human() { local b=${1:-0}; awk -v b="$b" 'BEGIN{u="B KB MB GB TB";split(u,a," ");i=1;while(b>=1024&&i<5){b/=1024;i++}printf "%.1f%s",b,a[i]}'; }
sha256_of() { if have sha256sum; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi; }

# ===========================================================================
#  Off-box copy
# ===========================================================================
upload_file() {
    local f="$1"
    [[ ${S3_ENABLED:-false} == true ]] || return 0
    $NO_UPLOAD && { log "skipping upload (--no-upload)"; return 0; }
    local key="${S3_PREFIX:+$S3_PREFIX/}$(basename "$f")"
    if $DRY_RUN; then log "would upload -> $key"; return 0; fi
    case "${S3_PROVIDER}" in
        mc)
            have mc || { warn "mc not installed — skipping upload"; return 0; }
            mc cp --quiet "$f" "${S3_ALIAS}/${S3_BUCKET}/${key}" >/dev/null \
                && ok "uploaded to ${S3_ALIAS}/${S3_BUCKET}/${key}" || warn "upload failed: $f" ;;
        aws)
            have aws || { warn "aws cli not installed — skipping upload"; return 0; }
            aws ${S3_PROFILE:+--profile "$S3_PROFILE"} ${S3_ENDPOINT:+--endpoint-url "$S3_ENDPOINT"} \
                s3 cp "$f" "s3://${S3_BUCKET}/${key}" >/dev/null \
                && ok "uploaded to s3://${S3_BUCKET}/${key}" || warn "upload failed: $f" ;;
        *) warn "unknown s3 provider '${S3_PROVIDER}'" ;;
    esac
}

notify_failure() {
    [[ -n ${NOTIFY_WEBHOOK:-} ]] || return 0
    have curl || return 0
    curl -fsS -m 15 -X POST -H 'Content-Type: application/json' \
        -d "{\"host\":\"$(hostname)\",\"tool\":\"dbtool\",\"status\":\"failed\",\"detail\":$(printf '%s' "$1" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read()))')}" \
        "$NOTIFY_WEBHOOK" >/dev/null 2>&1 || true
}

# ===========================================================================
#  Dump argument builders
# ===========================================================================
build_pg_dump_args() {  # populates DUMPARGS
    DUMPARGS=(-h "$CTX_HOST" -p "$CTX_PORT" -U "$CTX_USER" -d "$CTX_DB" --no-password)
    [[ $CTX_NO_OWNER == true ]] && DUMPARGS+=(--no-owner --no-acl)
    [[ $CTX_SCHEMA_ONLY == true ]] && DUMPARGS+=(--schema-only)
    [[ $CTX_DATA_ONLY   == true ]] && DUMPARGS+=(--data-only)
    local t
    for t in ${CTX_EXCLUDE[@]+"${CTX_EXCLUDE[@]}"};        do DUMPARGS+=(--exclude-table="$t"); done
    for t in ${CTX_INCLUDE[@]+"${CTX_INCLUDE[@]}"};        do DUMPARGS+=(--table="$t"); done
    for t in ${CTX_SCHEMA[@]+"${CTX_SCHEMA[@]}"};          do DUMPARGS+=(--schema="$t"); done
    for t in ${CTX_EXCLUDE_SCHEMA[@]+"${CTX_EXCLUDE_SCHEMA[@]}"}; do DUMPARGS+=(--exclude-schema="$t"); done
    DUMPARGS+=(${CTX_DUMP_ARGS[@]+"${CTX_DUMP_ARGS[@]}"})
}

build_my_dump_args() {  # populates DUMPARGS
    DUMPARGS=(--single-transaction --quick --hex-blob --no-tablespaces
              --routines --triggers --events --skip-lock-tables)
    [[ -n $CTX_CHARSET ]] && DUMPARGS+=(--default-character-set="$CTX_CHARSET")
    [[ $CTX_SCHEMA_ONLY == true ]] && DUMPARGS+=(--no-data)
    [[ $CTX_DATA_ONLY   == true ]] && DUMPARGS+=(--no-create-info)
    if [[ $MY_FLAVOR == mysql ]]; then
        DUMPARGS+=(--set-gtid-purged=OFF)
        [[ ${MY_SERVER_MAJOR:-8} -lt 8 ]] && DUMPARGS+=(--column-statistics=0)
    fi
    local t
    for t in ${CTX_EXCLUDE[@]+"${CTX_EXCLUDE[@]}"}; do
        [[ $t == *.* ]] && DUMPARGS+=(--ignore-table="$t") || DUMPARGS+=(--ignore-table="${CTX_DB}.${t}")
    done
    DUMPARGS+=(${CTX_DUMP_ARGS[@]+"${CTX_DUMP_ARGS[@]}"})
    DUMPARGS+=("$CTX_DB")
    DUMPARGS+=(${CTX_INCLUDE[@]+"${CTX_INCLUDE[@]}"})
}

# ===========================================================================
#  BACKUP
# ===========================================================================
write_meta() {  # write_meta <file> <engine> <serverver> <format>
    local f="$1" sum size
    sum="$(sha256_of "$f")"; size="$(stat -c %s "$f" 2>/dev/null || stat -f %z "$f")"
    printf '%s  %s\n' "$sum" "$(basename "$f")" >"${f}.sha256"
    cat >"${f}.meta.json" <<JSON
{
  "file": "$(basename "$f")",
  "label": "$CTX_LABEL",
  "engine": "$2",
  "server_version": "$3",
  "format": "$4",
  "source": "$CTX_HOST:$CTX_PORT/$CTX_DB",
  "created_at": "$(date -Iseconds)",
  "created_on": "$(hostname)",
  "size_bytes": $size,
  "sha256": "$sum",
  "dbtool_version": "$DBTOOL_VERSION"
}
JSON
}

backup_one() {
    local name="$1"
    load_entry databases "$name" SRC_
    use_ctx SRC_
    resolve_client

    local ts base tmp final start elapsed size
    ts="$(date +"$CFG_TIMESTAMP_FORMAT")"
    base="${CFG_BACKUP_DIR}/${name}_${CTX_ENGINE}_${CTX_DB}_${ts}"
    start=$SECONDS

    if [[ $CTX_ENGINE == postgres ]]; then
        build_pg_dump_args
        case "$CTX_FORMAT" in
            custom)
                final="${base}.dump"; tmp="${final}.part"; CLEAN_PATHS+=("$tmp")
                log "dumping $name (pg custom, level $CFG_PG_COMPRESS_LEVEL) -> $(basename "$final")"
                pg_run pg_dump "${DUMPARGS[@]}" -Fc -Z "$CFG_PG_COMPRESS_LEVEL" >"$tmp"
                ;;
            plain)
                final="${base}.sql$(comp_ext)"; tmp="${final}.part"; CLEAN_PATHS+=("$tmp")
                log "dumping $name (pg plain, $CFG_COMPRESSION) -> $(basename "$final")"
                pg_run pg_dump "${DUMPARGS[@]}" -Fp | compress_stream >"$tmp"
                ;;
            directory)
                local dumpdir="${RUNDIR}/${name}_${ts}.dir"
                final="${base}.dir.tar$(comp_ext)"; tmp="${final}.part"; CLEAN_PATHS+=("$tmp")
                log "dumping $name (pg directory, -j $CTX_JOBS) -> $(basename "$final")"
                DOCKER_EXTRA=(-v "$RUNDIR":"$RUNDIR" --user "$(id -u):$(id -g)")
                pg_run pg_dump "${DUMPARGS[@]}" -Fd -j "$CTX_JOBS" -f "$dumpdir"
                DOCKER_EXTRA=()
                $DRY_RUN || tar -C "$RUNDIR" -cf - "$(basename "$dumpdir")" | compress_stream >"$tmp"
                ;;
            *) die "unknown postgres format '$CTX_FORMAT' (custom|plain|directory)" ;;
        esac
    else
        build_my_dump_args
        final="${base}.sql$(comp_ext)"; tmp="${final}.part"; CLEAN_PATHS+=("$tmp")
        log "dumping $name (mysqldump, $CFG_COMPRESSION) -> $(basename "$final")"
        my_run mysqldump "${DUMPARGS[@]}" | compress_stream >"$tmp"
    fi

    $DRY_RUN && { ok "dry-run: $name"; return 0; }
    [[ -s $tmp ]] || { rm -f "$tmp"; die "dump produced an empty file for $name"; }
    mv "$tmp" "$final"
    chmod 640 "$final"

    # verify
    if [[ $final == *.dump ]]; then
        pg_run pg_restore -l "$final" >/dev/null 2>&1 || {
            DOCKER_EXTRA=(-v "$CFG_BACKUP_DIR":"$CFG_BACKUP_DIR":ro)
            pg_run pg_restore -l "$final" >/dev/null || { DOCKER_EXTRA=(); die "dump verification failed: $final"; }
            DOCKER_EXTRA=()
        }
    else
        test_archive "$final" || die "archive verification failed: $final"
    fi

    write_meta "$final" "$CTX_ENGINE" "${PG_SERVER_VER:-$MY_SERVER_VER}" "$CTX_FORMAT"
    elapsed=$((SECONDS - start))
    size="$(stat -c %s "$final" 2>/dev/null || stat -f %z "$final")"
    ok "$name -> $(basename "$final")  $(human "$size")  in ${elapsed}s"
    upload_file "$final"
    upload_file "${final}.meta.json"
    printf '%s' "$final" >"$RUNDIR/last_backup"
}

cmd_backup() {
    local -a names=()
    local target="${1:-all}"
    if [[ $target == all ]]; then mapfile -t names < <(cfgpy names "$CONFIG" databases)
    else IFS=',' read -r -a names <<<"$target"; fi
    [[ ${#names[@]} -gt 0 ]] || die "no databases configured"

    local n failed=0 okc=0 t0=$SECONDS
    for n in "${names[@]}"; do
        [[ -z $n ]] && continue
        if ( backup_one "$n" ); then okc=$((okc+1)); else failed=$((failed+1)); err "backup failed: $n"; fi
    done
    prune_backups
    log "summary: ${okc} succeeded, ${failed} failed, $((SECONDS - t0))s total"
    if (( failed > 0 )); then notify_failure "$failed database backup(s) failed on $(hostname)"; return 1; fi
}

# ===========================================================================
#  PRUNE
# ===========================================================================
prune_backups() {
    local days="${CFG_RETENTION_DAYS:-0}" keep="${CFG_RETENTION_MIN_KEEP:-0}"
    (( days > 0 )) || return 0
    local -a names=(); mapfile -t names < <(cfgpy names "$CONFIG" databases)
    local n f removed=0
    for n in "${names[@]}"; do
        local -a files=()
        mapfile -t files < <(find "$CFG_BACKUP_DIR" -maxdepth 1 -type f -name "${n}_*" \
                             ! -name '*.sha256' ! -name '*.meta.json' -printf '%T@ %p\n' 2>/dev/null | sort -rn | awk '{print $2}')
        local idx=0
        for f in ${files[@]+"${files[@]}"}; do
            idx=$((idx+1))
            (( idx <= keep )) && continue
            if [[ -n $(find "$f" -mtime "+$((days-1))" -print -quit 2>/dev/null) ]]; then
                $DRY_RUN && { log "would prune $(basename "$f")"; continue; }
                rm -f "$f" "${f}.sha256" "${f}.meta.json"
                removed=$((removed+1))
            fi
        done
    done
    (( removed > 0 )) && log "pruned $removed old backup(s) (retention ${days}d, keep ${keep})"
    return 0
}

# ===========================================================================
#  RESTORE
# ===========================================================================
latest_backup_for() {
    find "$CFG_BACKUP_DIR" -maxdepth 1 -type f -name "$1_*" ! -name '*.sha256' ! -name '*.meta.json' \
        -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | awk '{print $2}'
}

pg_db_exists() { [[ "$(_pg_query postgres "SELECT 1 FROM pg_database WHERE datname='${CTX_DB}'")" == 1 ]]; }

pg_prepare_target() {  # <create> <drop>
    local create="$1" drop="$2"
    if [[ $drop == true ]]; then
        confirm "DROP DATABASE ${CTX_DB} on ${CTX_HOST}:${CTX_PORT}?" || die "aborted by user"
        log "dropping database $CTX_DB"
        $DRY_RUN || pg_run psql -h "$CTX_HOST" -p "$CTX_PORT" -U "$CTX_USER" -d postgres -v ON_ERROR_STOP=1 -qtAX \
            -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='${CTX_DB}' AND pid<>pg_backend_pid();" \
            -c "DROP DATABASE IF EXISTS \"${CTX_DB}\";" >/dev/null
        create=true
    fi
    if [[ $create == true ]] && ! $DRY_RUN && ! pg_db_exists; then
        log "creating database $CTX_DB"
        pg_run psql -h "$CTX_HOST" -p "$CTX_PORT" -U "$CTX_USER" -d postgres -v ON_ERROR_STOP=1 -qtAX \
            -c "CREATE DATABASE \"${CTX_DB}\";" >/dev/null
    fi
}

my_prepare_target() {  # <create> <drop>
    local create="$1" drop="$2"
    if [[ $drop == true ]]; then
        confirm "DROP DATABASE ${CTX_DB} on ${CTX_HOST}:${CTX_PORT}?" || die "aborted by user"
        log "dropping database $CTX_DB"
        $DRY_RUN || my_run mysql -e "DROP DATABASE IF EXISTS \`${CTX_DB}\`;"
        create=true
    fi
    if [[ $create == true ]] && ! $DRY_RUN; then
        local cs="${CTX_CHARSET:-utf8mb4}" coll
        if [[ $cs == utf8mb4 ]]; then coll="utf8mb4_unicode_ci"; else coll="${cs}_general_ci"; fi
        log "ensuring database $CTX_DB exists (charset $cs)"
        my_run mysql -e "CREATE DATABASE IF NOT EXISTS \`${CTX_DB}\` CHARACTER SET ${cs} COLLATE ${coll};"
    fi
}

restore_into_ctx() {  # restore_into_ctx <file> <create> <drop>
    local file="$1" create="$2" drop="$3" start=$SECONDS
    [[ -f $file ]] || die "backup file not found: $file"
    local fdir; fdir="$(cd "$(dirname "$file")" && pwd)"
    file="${fdir}/$(basename "$file")"

    if [[ -f "${file}.sha256" ]] && have sha256sum; then
        ( cd "$fdir" && sha256sum -c --status "$(basename "$file").sha256" ) \
            && log "checksum OK" || warn "checksum MISMATCH for $(basename "$file")"
    fi

    resolve_client
    if [[ $CTX_ENGINE == postgres ]]; then
        pg_prepare_target "$create" "$drop"
        local -a rargs=(-h "$CTX_HOST" -p "$CTX_PORT" -U "$CTX_USER" -d "$CTX_DB" --no-password)
        case "$file" in
            *.dump)
                DOCKER_EXTRA=(-v "$fdir":"$fdir":ro)
                local -a pr=("${rargs[@]}" --no-owner --no-acl --exit-on-error -j "$CTX_JOBS")
                [[ $CTX_CLEAN == true ]] && pr+=(--clean --if-exists)
                pr+=(${CTX_RESTORE_ARGS[@]+"${CTX_RESTORE_ARGS[@]}"} "$file")
                log "restoring custom-format dump into ${CTX_HOST}:${CTX_PORT}/${CTX_DB} (-j $CTX_JOBS)"
                pg_run pg_restore "${pr[@]}"
                DOCKER_EXTRA=() ;;
            *.dir.tar*)
                local xdir="$RUNDIR/restore.dir"; mkdir -p "$xdir"
                decompress_stream "$file" | tar -C "$xdir" -xf -
                local inner; inner="$(find "$xdir" -maxdepth 1 -mindepth 1 -type d | head -1)"
                DOCKER_EXTRA=(-v "$RUNDIR":"$RUNDIR":ro)
                log "restoring directory-format dump (-j $CTX_JOBS)"
                pg_run pg_restore "${rargs[@]}" --no-owner --no-acl --exit-on-error -j "$CTX_JOBS" \
                    ${CTX_RESTORE_ARGS[@]+"${CTX_RESTORE_ARGS[@]}"} -Fd "$inner"
                DOCKER_EXTRA=() ;;
            *)
                log "restoring plain SQL into ${CTX_HOST}:${CTX_PORT}/${CTX_DB}"
                decompress_stream "$file" | pg_run psql "${rargs[@]}" -v ON_ERROR_STOP=1 --quiet -f - ;;
        esac
    else
        my_prepare_target "$create" "$drop"
        log "restoring SQL into ${CTX_HOST}:${CTX_PORT}/${CTX_DB}"
        decompress_stream "$file" | my_run mysql --max-allowed-packet=1G -D "$CTX_DB"
    fi
    ok "restore finished in $((SECONDS - start))s"
}

cmd_restore() {
    local file="" src_name="" tgt="" tgt_db="" create=false drop=false use_latest=false
    while (( $# )); do
        case "$1" in
            -f|--file)     file="$2"; shift 2 ;;
            --latest)      use_latest=true; src_name="$2"; shift 2 ;;
            -t|--to)       tgt="$2"; shift 2 ;;
            -d|--database) tgt_db="$2"; shift 2 ;;
            --create)      create=true; shift ;;
            --drop)        drop=true; shift ;;
            *) die "restore: unknown option $1" ;;
        esac
    done
    $use_latest && { file="$(latest_backup_for "$src_name")"; [[ -n $file ]] || die "no backups found for '$src_name'"; log "latest: $(basename "$file")"; }
    [[ -n $file ]] || die "restore needs -f <file> or --latest <name>"
    [[ -n $tgt  ]] || die "restore needs -t <target-or-database-name>"

    if cfgpy names "$CONFIG" targets 2>/dev/null | grep -qx "$tgt"; then
        load_entry targets "$tgt" DST_
    else
        load_entry databases "$tgt" DST_   # restore back onto a configured source
    fi
    use_ctx DST_
    [[ -n $tgt_db ]] && CTX_DB="$tgt_db"
    [[ $CTX_CREATE_DB == true ]] && create=true
    confirm "Restore $(basename "$file") into ${CTX_ENGINE} ${CTX_HOST}:${CTX_PORT}/${CTX_DB}?" || die "aborted by user"
    restore_into_ctx "$file" "$create" "$drop"
}

# ===========================================================================
#  MIGRATE  (server -> server, streaming by default)
# ===========================================================================
cmd_migrate() {
    local from="" to="" tgt_db="" create=false drop=false via_file=false
    while (( $# )); do
        case "$1" in
            -s|--from)     from="$2"; shift 2 ;;
            -t|--to)       to="$2"; shift 2 ;;
            -d|--target-db) tgt_db="$2"; shift 2 ;;
            --create)      create=true; shift ;;
            --drop)        drop=true; shift ;;
            --via-file)    via_file=true; shift ;;
            *) die "migrate: unknown option $1" ;;
        esac
    done
    [[ -n $from && -n $to ]] || die "migrate needs --from <source> --to <target>"

    load_entry databases "$from" SRC_
    load_entry targets   "$to"   DST_
    local s_engine d_engine
    s_engine="$(gv SRC_ENGINE)"; d_engine="$(gv DST_ENGINE)"
    [[ $s_engine == "$d_engine" ]] || die "cross-engine migration ($s_engine -> $d_engine) is not supported; use a dedicated ETL tool"

    if $via_file; then
        log "migrate via file: backing up '$from' first"
        backup_one "$from"
        local f; f="$(cat "$RUNDIR/last_backup")"
        use_ctx DST_
        [[ -n $tgt_db ]] && CTX_DB="$tgt_db"
        [[ $CTX_CREATE_DB == true ]] && create=true
        confirm "Restore $(basename "$f") into ${CTX_HOST}:${CTX_PORT}/${CTX_DB}?" || die "aborted by user"
        restore_into_ctx "$f" "$create" "$drop"
        return
    fi

    # ---- streaming path: dump on the source, pipe straight into the target ----
    use_ctx SRC_
    resolve_client
    local S_MODE="$PG_MODE$MY_MODE" S_IMG="$PG_IMAGE$MY_IMAGE"
    local -a S_HOSTARGS=()
    if [[ $s_engine == postgres ]]; then build_pg_dump_args; else build_my_dump_args; fi
    local -a S_DUMPARGS=("${DUMPARGS[@]}")
    local S_HOST="$CTX_HOST" S_PORT="$CTX_PORT" S_USER="$CTX_USER" S_PASS="$CTX_PASS" \
          S_DB="$CTX_DB" S_SSL="$CTX_SSLMODE" S_CHARSET="$CTX_CHARSET" S_VER="${PG_SERVER_VER}${MY_SERVER_VER}"
    local S_PGMODE="$PG_MODE" S_PGIMG="$PG_IMAGE" S_MYMODE="$MY_MODE" S_MYIMG="$MY_IMAGE" S_FLAVOR="$MY_FLAVOR"
    local S_CNF="$RUNDIR/src.cnf"
    [[ $s_engine == mysql ]] && { write_my_cnf; cp "$MY_CNF" "$S_CNF"; }

    use_ctx DST_
    [[ -n $tgt_db ]] && CTX_DB="$tgt_db"
    [[ $CTX_CREATE_DB == true ]] && create=true
    resolve_client

    log "migrating ${S_HOST}:${S_PORT}/${S_DB} (${S_VER})  ->  ${CTX_HOST}:${CTX_PORT}/${CTX_DB}"
    confirm "Proceed with streaming migration?" || die "aborted by user"

    local start=$SECONDS
    if [[ $s_engine == postgres ]]; then
        pg_prepare_target "$create" "$drop"
        local -a pr=(-h "$CTX_HOST" -p "$CTX_PORT" -U "$CTX_USER" -d "$CTX_DB" --no-password
                     --no-owner --no-acl --exit-on-error)
        [[ $CTX_CLEAN == true ]] && pr+=(--clean --if-exists)
        pr+=(${CTX_RESTORE_ARGS[@]+"${CTX_RESTORE_ARGS[@]}"})
        if $DRY_RUN; then
            log "would run: pg_dump [source] -Fc -Z0 | pg_restore [target]"; return 0
        fi
        (
          CTX_HOST="$S_HOST"; CTX_PORT="$S_PORT"; CTX_USER="$S_USER"; CTX_PASS="$S_PASS"
          CTX_SSLMODE="$S_SSL"; PG_MODE="$S_PGMODE"; PG_IMAGE="$S_PGIMG"
          pg_run pg_dump "${S_DUMPARGS[@]}" -Fc -Z 0
        ) | pg_run pg_restore "${pr[@]}"
    else
        my_prepare_target "$create" "$drop"
        if $DRY_RUN; then log "would run: mysqldump [source] | mysql [target]"; return 0; fi
        (
          CTX_HOST="$S_HOST"; CTX_PORT="$S_PORT"; CTX_USER="$S_USER"; CTX_PASS="$S_PASS"
          CTX_CHARSET="$S_CHARSET"; CTX_SSLMODE="$S_SSL"
          MY_MODE="$S_MYMODE"; MY_IMAGE="$S_MYIMG"; MY_FLAVOR="$S_FLAVOR"
          my_run mysqldump "${S_DUMPARGS[@]}"
        ) | my_run mysql --max-allowed-packet=1G -D "$CTX_DB"
    fi
    ok "migration finished in $((SECONDS - start))s"

    # post-check
    if [[ $s_engine == postgres ]]; then
        local cnt; cnt="$(_pg_query "$CTX_DB" "SELECT count(*) FROM information_schema.tables WHERE table_schema NOT IN ('pg_catalog','information_schema')")"
        log "target now has ${cnt:-?} tables"
    else
        local cnt; cnt="$(_my_query "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${CTX_DB}'")"
        log "target now has ${cnt:-?} tables"
    fi
}

# ===========================================================================
#  Misc commands
# ===========================================================================
cmd_list() {
    printf '\n%sConfigured sources%s (%s)\n' "$C_B" "$C_0" "$CONFIG"
    printf '  %-22s %-10s %-28s %s\n' NAME ENGINE ENDPOINT DATABASE
    local n
    while read -r n; do
        [[ -z $n ]] && continue
        load_entry databases "$n" E_
        printf '  %-22s %-10s %-28s %s\n' "$n" "$(gv E_ENGINE)" "$(gv E_HOST):$(gv E_PORT)" "$(gv E_DB)"
    done < <(cfgpy names "$CONFIG" databases)

    printf '\n%sConfigured targets%s\n' "$C_B" "$C_0"
    while read -r n; do
        [[ -z $n ]] && continue
        load_entry targets "$n" E_
        printf '  %-22s %-10s %-28s %s\n' "$n" "$(gv E_ENGINE)" "$(gv E_HOST):$(gv E_PORT)" "$(gv E_DB)"
    done < <(cfgpy names "$CONFIG" targets 2>/dev/null || true)

    printf '\n%sLocal backups%s in %s\n' "$C_B" "$C_0" "$CFG_BACKUP_DIR"
    local f size
    while read -r f; do
        [[ -z $f ]] && continue
        size="$(stat -c %s "$f" 2>/dev/null || stat -f %z "$f")"
        printf '  %-58s %10s  %s\n' "$(basename "$f")" "$(human "$size")" "$(date -r "$f" '+%Y-%m-%d %H:%M' 2>/dev/null || true)"
    done < <(find "$CFG_BACKUP_DIR" -maxdepth 1 -type f ! -name '*.sha256' ! -name '*.meta.json' \
             ! -name '*.log' ! -name '*.part' -printf '%T@ %p\n' 2>/dev/null | sort -rn | awk '{print $2}')
    printf '\n'
}

cmd_verify() {
    local f="$1"; [[ -f $f ]] || die "no such file: $f"
    local fdir; fdir="$(cd "$(dirname "$f")" && pwd)"
    if [[ -f "${f}.sha256" ]]; then
        ( cd "$fdir" && sha256sum -c "$(basename "$f").sha256" ) || die "checksum failed"
    else warn "no .sha256 sidecar for $(basename "$f")"; fi
    case "$f" in
        *.dump)
            CTX_ENGINE=postgres; CTX_PASS=""; CTX_SSLMODE=""
            if have pg_restore; then PG_MODE=native; else PG_MODE=docker; PG_IMAGE="$PG_PROBE_IMAGE"; DOCKER_EXTRA=(-v "$fdir":"$fdir":ro); fi
            local toc; toc="$(pg_run pg_restore -l "$f" 2>/dev/null | grep -c '^[0-9]' || true)"
            [[ ${toc:-0} -gt 0 ]] && ok "valid PostgreSQL custom-format dump (${toc} TOC entries)" || die "not a readable custom-format dump" ;;
        *) test_archive "$f" && ok "archive integrity OK" ;;
    esac
}

cmd_test() {
    local n rc=0
    while read -r n; do
        [[ -z $n ]] && continue
        load_entry databases "$n" SRC_; use_ctx SRC_
        if [[ $CTX_ENGINE == postgres ]]; then
            local v; v="$(_pg_query "$CTX_DB" 'SHOW server_version')"
            [[ -n $v ]] && ok "$n: postgres $v at $CTX_HOST:$CTX_PORT/$CTX_DB" || { err "$n: connection FAILED"; rc=1; }
        else
            local v; v="$(_my_query 'SELECT VERSION()')"
            [[ -n $v ]] && ok "$n: mysql $v at $CTX_HOST:$CTX_PORT/$CTX_DB" || { err "$n: connection FAILED"; rc=1; }
        fi
    done < <(cfgpy names "$CONFIG" databases)
    while read -r n; do
        [[ -z $n ]] && continue
        load_entry targets "$n" DST_; use_ctx DST_
        if [[ $CTX_ENGINE == postgres ]]; then
            local v; v="$(_pg_query postgres 'SHOW server_version')"
            [[ -n $v ]] && ok "target $n: postgres $v at $CTX_HOST:$CTX_PORT" || { err "target $n: connection FAILED"; rc=1; }
        else
            local v; v="$(_my_query 'SELECT VERSION()')"
            [[ -n $v ]] && ok "target $n: mysql $v at $CTX_HOST:$CTX_PORT" || { err "target $n: connection FAILED"; rc=1; }
        fi
    done < <(cfgpy names "$CONFIG" targets 2>/dev/null || true)
    return $rc
}

cmd_parse_url() {
    printf '%s\n' "$DBTOOL_CFG_PY" >"$PY"
    cfgpy url "$1" "${2:-DB_}"
}

# ===========================================================================
#  Usage
# ===========================================================================
usage() {
cat <<EOF
${SCRIPT_NAME} v${DBTOOL_VERSION} — PostgreSQL / MySQL backup, restore, migrate

USAGE
  ${SCRIPT_NAME} <command> [options]

COMMANDS
  backup [name|all]              Dump one, several (comma-separated) or all databases
  restore -f FILE -t TARGET      Restore a dump into a target (or --latest NAME)
          [--database DB] [--create] [--drop]
  migrate --from SRC --to TGT    Stream a database to another server
          [--target-db DB] [--create] [--drop] [--via-file]
  list                           Show configured sources, targets and local backups
  prune                          Apply the retention policy now
  verify FILE                    Check checksum + archive/dump integrity
  test                           Connectivity + version check for every entry
  parse-url URL [PREFIX]         Print shell vars parsed from a DATABASE_URL

GLOBAL OPTIONS
  -c, --config FILE   Config file (default: ./dbtool.yml, /etc/dbtool/dbtool.yml, \$DBTOOL_CONFIG)
  -n, --dry-run       Show what would happen, change nothing
  -y, --yes           Assume yes for destructive prompts (required in cron)
  -q, --quiet         Only warnings and errors
      --no-upload     Skip the off-box copy for this run
  -h, --help          This help
  -V, --version       Print version

EXAMPLES
  ${SCRIPT_NAME} -c /etc/dbtool/dbtool.yml test
  ${SCRIPT_NAME} backup all
  ${SCRIPT_NAME} backup app_dev,crm_mysql
  ${SCRIPT_NAME} restore --latest app_dev -t staging_pg --create -y
  ${SCRIPT_NAME} restore -f /backup/db/app_dev_postgres_app_dev_20260907-0200.dump -t staging_pg --drop
  ${SCRIPT_NAME} migrate --from app_prod --to new_server_pg --create -y
  ${SCRIPT_NAME} parse-url 'postgresql+asyncpg://app_user:secret@db-primary.example.com:5432/app_dev'
EOF
}

# ===========================================================================
#  Entry point
# ===========================================================================
main() {
    local -a rest=()
    local cmd=""
    while (( $# )); do
        case "$1" in
            -c|--config)  CONFIG="$2"; shift 2 ;;
            -n|--dry-run) DRY_RUN=true; shift ;;
            -y|--yes)     ASSUME_YES=true; shift ;;
            -q|--quiet)   QUIET=true; shift ;;
            --no-upload)  NO_UPLOAD=true; shift ;;
            -h|--help)    usage; exit 0 ;;
            -V|--version) echo "$DBTOOL_VERSION"; exit 0 ;;
            -*)           if [[ -n $cmd ]]; then rest+=("$1"); shift
                          else die "unknown global option: $1 (see -h)"; fi ;;
            *)            if [[ -z $cmd ]]; then cmd="$1"; else rest+=("$1"); fi; shift ;;
        esac
    done
    [[ -n $cmd ]] || { usage; exit 1; }

    if [[ $cmd == parse-url ]]; then cmd_parse_url ${rest[@]+"${rest[@]}"}; exit $?; fi
    load_config
    case "$cmd" in
        backup)  cmd_backup ${rest[@]+"${rest[@]}"} ;;
        restore) cmd_restore ${rest[@]+"${rest[@]}"} ;;
        migrate) cmd_migrate ${rest[@]+"${rest[@]}"} ;;
        list)    cmd_list ;;
        prune)   prune_backups ;;
        verify)  cmd_verify ${rest[@]+"${rest[@]}"} ;;
        test)    cmd_test ;;
        *) die "unknown command: $cmd (see -h)" ;;
    esac
}

main "$@"
