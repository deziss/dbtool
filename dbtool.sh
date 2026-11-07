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

readonly DBTOOL_VERSION="1.2.0"
readonly SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The file itself, with symlinks resolved: /usr/local/bin/dbtool is normally a
# link to /opt/dbtool/dbtool.sh, and self-update has to replace the latter.
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s/%s' "$SCRIPT_DIR" "$SCRIPT_NAME")"
DBTOOL_UPDATE_URL="${DBTOOL_UPDATE_URL:-https://raw.githubusercontent.com/deziss/dbtool/main/dbtool.sh}"

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
        # treat this entry as a whole server: enumerate its databases at run time
        'ALL_DATABASES': entry.get('all_databases',
                         entry.get('include_all', entry.get('all_dbs', entry.get('all', False)))),
    }
    for key, name in (('exclude_tables', 'EXCLUDE'), ('include_tables', 'INCLUDE'),
                      ('exclude_schemas', 'EXCLUDE_SCHEMA'), ('schemas', 'SCHEMA'),
                      ('dump_args', 'DUMP_ARGS'), ('restore_args', 'RESTORE_ARGS'),
                      ('exclude_databases', 'EXCLUDE_DB'), ('include_databases', 'INCLUDE_DB')):
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
CFG_MAINTENANCE_DB="postgres"     # database used to enumerate / create / drop
CFG_VERIFY="full"                 # full | header | none"
CFG_INCLUDE_GLOBALS=true          # dump cluster roles/grants alongside 'backup all'
CFG_LOCK=true                     # refuse to run while another dbtool holds the lock

PG_PROBE_IMAGE="${PG_PROBE_IMAGE:-postgres:17-alpine}"
MY_PROBE_IMAGE="${MY_PROBE_IMAGE:-mysql:8.4}"

RUNDIR="$(mktemp -d "${TMPDIR:-/tmp}/dbtool.XXXXXXXX")"
PY="$RUNDIR/cfg.py"
# Fixed paths, set once in the parent: _pg_query runs inside a command
# substitution, so anything it assigns to a variable — including the name of a
# file — is gone by the time the caller looks.
PG_ERR_FILE="$RUNDIR/pg.lasterr"
MY_ERR_FILE="$RUNDIR/my.lasterr"
MY_CNF="$RUNDIR/my.cnf"
declare -a DOCKER_EXTRA=()
declare -a CLEAN_PATHS=()

cleanup() {
    rm -rf "$RUNDIR" 2>/dev/null || true
    local p
    for p in ${CLEAN_PATHS[@]+"${CLEAN_PATHS[@]}"}; do
        # only ever remove our own in-progress artifacts, never a device or a root
        case "$p" in
            *.part|*.dir) rm -rf "$p" 2>/dev/null || true ;;
        esac
    done
}
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

# A nightly timer and a manual run must not dump or prune the same directory at
# once: the loser can rename a .part the winner is still writing.
acquire_lock() {
    [[ ${CFG_LOCK:-true} == true ]] || return 0
    have flock || { warn "flock not found — running without a lock"; return 0; }
    LOCK_FILE="${CFG_BACKUP_DIR}/.dbtool.lock"
    # Braces, not a bare `exec ... 2>/dev/null`: an exec without a command applies
    # its redirections to the shell permanently, which would silence every warning.
    { exec 9>"$LOCK_FILE"; } 2>/dev/null || { warn "cannot open $LOCK_FILE — running without a lock"; return 0; }
    flock -n 9 || die "another dbtool run holds $LOCK_FILE — refusing to run concurrently"
}

# Copy a PREFIX_* entry into the CTX_* namespace the runners use.
use_ctx() {
    local p="$1" k
    for k in ENGINE HOST PORT USER PASS DB SSLMODE CHARSET LABEL FORMAT JOBS \
             SCHEMA_ONLY DATA_ONLY NO_OWNER CLEAN CREATE_DB IMAGE ALL_DATABASES; do
        eval "CTX_$k=\"\$(gv ${p}${k})\""
    done
    for k in EXCLUDE INCLUDE EXCLUDE_SCHEMA SCHEMA DUMP_ARGS RESTORE_ARGS EXCLUDE_DB INCLUDE_DB; do
        eval "CTX_$k=(\${${p}${k}[@]+\"\${${p}${k}[@]}\"})"
    done
    [[ -n $CTX_FORMAT ]] || CTX_FORMAT="$CFG_FORMAT"
    [[ -n $CTX_JOBS   ]] || CTX_JOBS="$CFG_JOBS"
    [[ -n $CTX_ENGINE ]] || die "entry '$CTX_LABEL': engine could not be determined"
    # A whole-server entry needs no database of its own: it connects to the
    # maintenance database to enumerate the rest.
    if [[ -z $CTX_DB ]]; then
        if [[ ${CTX_ALL_DATABASES:-false} == true ]]; then
            [[ $CTX_ENGINE == postgres ]] && CTX_DB="${CFG_MAINTENANCE_DB:-postgres}" || CTX_DB=""
        else
            die "entry '$CTX_LABEL': database name is empty"
        fi
    fi
    [[ $CTX_ENGINE == postgres || $CTX_ENGINE == mysql ]] || die "unsupported engine: $CTX_ENGINE"
}

load_entry() { eval "$(cfgpy entry "$CONFIG" "$1" "$2" "$3")"; }

# ===========================================================================
#  Client resolution (native vs version-matched docker image)
# ===========================================================================
PG_MODE=""; PG_IMAGE=""; PG_SERVER_VER=""; PG_SERVER_MAJOR=""
# Text of the last failed probe. "Connection refused", "password authentication
# failed" and "database does not exist" need different fixes, so never swallow
# them. It goes through a file, not a variable: every caller reads the probe with
# v="$(_pg_query ...)", which runs the function in a subshell whose variables die
# with it.
probe_err() {  # probe_err <file> <fallback>
    if [[ -n ${1:-} && -s ${1:-} ]]; then tr -d '\000' <"$1"; else printf '%s' "${2:-no error text from the client}"; fi
}
pg_err() { probe_err "${PG_ERR_FILE:-}" "no error text from psql (is it installed? try docker: always)"; }
my_err() { probe_err "${MY_ERR_FILE:-}" "no error text from mysql (is it installed? try docker: always)"; }
MY_MODE=""; MY_IMAGE=""; MY_SERVER_VER=""; MY_SERVER_MAJOR=""; MY_FLAVOR="mysql"

_docker_ok() { have docker && docker info >/dev/null 2>&1; }

# _pg_query collapses whitespace, which is right for a single value and wrong
# for a list; _pg_rows keeps one row per line.
_pg_rows() { _pg_query_raw "$@"; }
_pg_query() { _pg_query_raw "$@" | tr -d '[:space:]'; }

_pg_query_raw() {  # _pg_query_raw <dbname> <sql>  -> rows on stdout, via any available client
    local db="$1" sql="$2" out="" errf="$RUNDIR/pg.err"
    : >"$errf" 2>/dev/null || true; : >"$PG_ERR_FILE" 2>/dev/null || true
    if have psql; then
        out="$(env PGPASSWORD="$CTX_PASS" ${CTX_SSLMODE:+PGSSLMODE="$CTX_SSLMODE"} PGCONNECT_TIMEOUT=10 \
              psql -h "$CTX_HOST" -p "$CTX_PORT" -U "$CTX_USER" -d "$db" -tAX -c "$sql" 2>>"$errf")" || out=""
    fi
    if [[ -z $out ]] && _docker_ok; then
        out="$(docker run --rm --network "$CFG_DOCKER_NETWORK" \
              -e PGPASSWORD="$CTX_PASS" ${CTX_SSLMODE:+-e PGSSLMODE="$CTX_SSLMODE"} -e PGCONNECT_TIMEOUT=10 \
              "$PG_PROBE_IMAGE" psql -h "$CTX_HOST" -p "$CTX_PORT" -U "$CTX_USER" -d "$db" -tAX -c "$sql" 2>>"$errf")" || out=""
    fi
    if [[ -z $out && -s $errf ]]; then
        # psql retries SSL then plaintext and prints the same failure twice
        sed -e 's/^psql: *//' -e 's/^error: *//' -e '/^$/d' "$errf" | tr '\t' ' ' \
            | awk '!seen[$0]++' | tail -2 | tr '\n' ' ' | sed 's/  */ /g;s/ *$//' \
            >"$PG_ERR_FILE" 2>/dev/null || true
    fi
    rm -f "$errf"
    printf '%s\n' "$out"
}

_my_rows() { _my_query_raw "$@"; }
_my_query() { _my_query_raw "$@" | tr -d '[:space:]'; }

_my_query_raw() {  # _my_query_raw <sql>
    write_my_cnf
    local out="" errf="$RUNDIR/my.err"
    : >"$errf" 2>/dev/null || true; : >"$MY_ERR_FILE" 2>/dev/null || true
    if have mysql; then
        out="$(mysql --defaults-extra-file="$MY_CNF" --connect-timeout=10 -N -B -e "$1" 2>>"$errf")" || out=""
    fi
    if [[ -z $out ]] && _docker_ok; then
        out="$(docker run --rm --network "$CFG_DOCKER_NETWORK" -v "$MY_CNF":/tmp/dbtool.cnf:ro \
              "$MY_PROBE_IMAGE" mysql --defaults-extra-file=/tmp/dbtool.cnf --connect-timeout=10 -N -B -e "$1" 2>>"$errf")" || out=""
    fi
    if [[ -z $out && -s $errf ]]; then
        grep -v '^$' "$errf" | grep -v 'Using a password on the command line' | tr '\t' ' ' \
            | awk '!seen[$0]++' | tail -2 | tr '\n' ' ' | sed 's/  */ /g;s/ *$//' \
            >"$MY_ERR_FILE" 2>/dev/null || true
    fi
    rm -f "$errf"
    printf '%s\n' "$out"
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
    [[ -n $PG_SERVER_VER ]] || die "cannot reach PostgreSQL at $CTX_HOST:$CTX_PORT as '$CTX_USER': $(pg_err)"
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
    [[ -n $MY_SERVER_VER ]] || die "cannot reach MySQL/MariaDB at $CTX_HOST:$CTX_PORT as '$CTX_USER': $(my_err)"
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
#  Server enumeration — "back up every database behind this URL"
# ===========================================================================
PG_LIST_SQL="SELECT datname FROM pg_database
             WHERE datallowconn AND NOT datistemplate
               AND has_database_privilege(current_user, datname, 'CONNECT')
             ORDER BY datname"

list_ctx_databases() {  # every database this CTX_* server will let us read
    if [[ $CTX_ENGINE == postgres ]]; then
        _pg_rows "$CTX_DB" "$PG_LIST_SQL" | sed '/^$/d'
    else
        _my_rows 'SHOW DATABASES' | sed '/^$/d' \
            | grep -vxE 'information_schema|performance_schema|mysql|sys'
    fi
}

db_included() {  # db_included <dbname>   (CTX_INCLUDE_DB / CTX_EXCLUDE_DB are globs)
    local db="$1" p hit
    if (( ${#CTX_INCLUDE_DB[@]} )); then
        hit=false
        for p in "${CTX_INCLUDE_DB[@]}"; do [[ $db == $p ]] && hit=true; done
        $hit || return 1
    fi
    for p in ${CTX_EXCLUDE_DB[@]+"${CTX_EXCLUDE_DB[@]}"}; do [[ $db == $p ]] && return 1; done
    return 0
}

# One line per database this entry expands to. A normal entry is itself; an
# all_databases entry is whatever the server reports, minus the filters.
entry_databases() {  # entry_databases <entry-name>
    local name="$1"
    load_entry databases "$name" EXP_
    use_ctx EXP_
    if [[ ${CTX_ALL_DATABASES:-false} != true ]]; then printf '%s\n' "$CTX_DB"; return 0; fi
    local -a found=()
    mapfile -t found < <(list_ctx_databases)
    (( ${#found[@]} )) || { err "entry '$name': cannot list databases on ${CTX_HOST}:${CTX_PORT}: $(pg_err)"; return 1; }
    local db
    for db in "${found[@]}"; do db_included "$db" && printf '%s\n' "$db"; done
}

# Dumps are named <entry>_<engine>_<db>_<timestamp>.<ext>. Globbing "<entry>_*"
# also matches a longer sibling entry (app_db vs app_db_archive), which made
# --latest restore the wrong database and let prune delete the only copy of one.
# Anchor on the engine token that always follows the entry name.
# Where a dump is written while it runs. A dry run writes nowhere: the caller's
# redirection is set up by the shell before pg_run can decide to only print.
dump_target() {  # dump_target <final-path>  -> path to redirect the dump into
    if $DRY_RUN; then printf '/dev/null'; else printf '%s.part' "$1"; fi
}

# A .part can only survive a crash, a kill -9, or a dry run of an older build:
# CLEAN_PATHS is appended to inside a subshell, and subshells do not run the
# parent's EXIT trap. The lock guarantees nobody else is mid-dump right now, so
# anything left here is orphaned.
sweep_stale_parts() {
    local -a stale=()
    mapfile -t stale < <(find "$CFG_BACKUP_DIR" -maxdepth 1 -type f -name '*.part' 2>/dev/null)
    (( ${#stale[@]} )) || return 0
    local f
    for f in "${stale[@]}"; do
        $DRY_RUN && { log "would remove orphaned $(basename "$f")"; continue; }
        rm -f "$f" && warn "removed orphaned $(basename "$f") from an earlier interrupted run"
    done
}

backups_for() {  # backups_for <entry-name>  -> newest first, one path per line
    find "$CFG_BACKUP_DIR" -maxdepth 1 -type f \
         \( -name "$1_postgres_*" -o -name "$1_mysql_*" \) \
         ! -name '*.sha256' ! -name '*.meta.json' ! -name '*.part' \
         -printf '%T@ %p\n' 2>/dev/null | sort -rn | awk '{print $2}'
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

# pg_restore -l reads only the header and TOC, so it happily lists a dump whose
# data section was cut short (connection dropped, timeout, full disk). Read the
# whole archive unless the operator opts out.
verify_dump_artifact() {  # verify_dump_artifact <file>
    local f="$1" mode="${CFG_VERIFY:-full}" rc=0 tail_txt=""
    [[ $mode == none ]] && { warn "integrity check skipped (verify: none): $(basename "$f")"; return 0; }
    case "$f" in
        *.dump)
            local -a saved=(${DOCKER_EXTRA[@]+"${DOCKER_EXTRA[@]}"})
            DOCKER_EXTRA=(-v "$(dirname "$f")":"$(dirname "$f")":ro)
            if [[ $mode == header ]]; then pg_run pg_restore -l "$f" >/dev/null 2>&1 || rc=1
            else                           pg_run pg_restore -f /dev/null "$f" >/dev/null 2>&1 || rc=1
            fi
            DOCKER_EXTRA=(${saved[@]+"${saved[@]}"})
            return $rc ;;
        *.sql|*.sql.*)
            test_archive "$f" || return 1
            [[ $mode == header ]] && return 0
            # pg_dump -Fp and mysqldump both end with a completion marker; its
            # absence means the writer died mid-stream.
            tail_txt="$(decompress_stream "$f" 2>/dev/null | tail -5 || true)"
            case "$tail_txt" in
                *"PostgreSQL database dump complete"*|*"Dump completed"*|*"PostgreSQL database cluster dump complete"*) return 0 ;;
                *) err "no dump-completion marker at the end of $(basename "$f") (truncated, or --skip-comments in dump_args)"
                   return 1 ;;
            esac ;;
        *) test_archive "$f" || return 1; return 0 ;;
    esac
}

backup_one() {
    local name="$1" db_override="${2:-}"
    load_entry databases "$name" SRC_
    use_ctx SRC_
    # an all_databases entry produces one dump per database, labelled <entry>_<db>
    local label="$name"
    if [[ -n $db_override ]]; then
        CTX_DB="$db_override"
        [[ ${CTX_ALL_DATABASES:-false} == true ]] && label="${name}_${db_override}"
    fi
    CTX_LABEL="$label"
    resolve_client

    local ts base tmp final start elapsed size
    ts="$(date +"$CFG_TIMESTAMP_FORMAT")"
    base="${CFG_BACKUP_DIR}/${label}_${CTX_ENGINE}_${CTX_DB}_${ts}"
    start=$SECONDS

    if [[ $CTX_ENGINE == postgres ]]; then
        build_pg_dump_args
        case "$CTX_FORMAT" in
            custom)
                final="${base}.dump"; tmp="$(dump_target "$final")"
                log "dumping $label (pg custom, level $CFG_PG_COMPRESS_LEVEL) -> $(basename "$final")"
                pg_run pg_dump "${DUMPARGS[@]}" -Fc -Z "$CFG_PG_COMPRESS_LEVEL" >"$tmp" \
                    || { rm -f "$tmp"; die "pg_dump failed for $label"; }
                ;;
            plain)
                final="${base}.sql$(comp_ext)"; tmp="$(dump_target "$final")"
                log "dumping $label (pg plain, $CFG_COMPRESSION) -> $(basename "$final")"
                pg_run pg_dump "${DUMPARGS[@]}" -Fp | compress_stream >"$tmp" \
                    || { rm -f "$tmp"; die "pg_dump failed for $label"; }
                ;;
            directory)
                local STAGEDIR="${CFG_BACKUP_DIR}/.staging"
                $DRY_RUN || mkdir -p "$STAGEDIR" || die "cannot create staging dir $STAGEDIR"
                local dumpdir="${STAGEDIR}/${label}_${ts}.dir"
                $DRY_RUN || CLEAN_PATHS+=("$dumpdir")
                final="${base}.dir.tar$(comp_ext)"; tmp="$(dump_target "$final")"
                log "dumping $label (pg directory, -j $CTX_JOBS) -> $(basename "$final")"
                DOCKER_EXTRA=(-v "$STAGEDIR":"$STAGEDIR" --user "$(id -u):$(id -g)")
                pg_run pg_dump "${DUMPARGS[@]}" -Fd -j "$CTX_JOBS" -f "$dumpdir" \
                    || { DOCKER_EXTRA=(); rm -f "$tmp"; die "pg_dump failed for $label"; }
                DOCKER_EXTRA=()
                $DRY_RUN || tar -C "$STAGEDIR" -cf - "$(basename "$dumpdir")" | compress_stream >"$tmp" \
                    || { rm -f "$tmp"; die "packing the directory dump failed for $label"; }
                ;;
            *) die "unknown postgres format '$CTX_FORMAT' (custom|plain|directory)" ;;
        esac
    else
        build_my_dump_args
        final="${base}.sql$(comp_ext)"; tmp="$(dump_target "$final")"
        log "dumping $label (mysqldump, $CFG_COMPRESSION) -> $(basename "$final")"
        my_run mysqldump "${DUMPARGS[@]}" | compress_stream >"$tmp" \
            || { rm -f "$tmp"; die "mysqldump failed for $label"; }
    fi

    $DRY_RUN && { ok "dry-run: $label"; return 0; }
    [[ -s $tmp ]] || { rm -f "$tmp"; die "dump produced an empty file for $label"; }
    mv "$tmp" "$final"
    chmod 640 "$final"

    verify_dump_artifact "$final" || { rm -f "$final"; die "integrity check failed — discarded $(basename "$final")"; }

    write_meta "$final" "$CTX_ENGINE" "${PG_SERVER_VER:-$MY_SERVER_VER}" "$CTX_FORMAT"
    elapsed=$((SECONDS - start))
    size="$(stat -c %s "$final" 2>/dev/null || stat -f %z "$final")"
    ok "$label -> $(basename "$final")  $(human "$size")  in ${elapsed}s"
    upload_file "$final"
    upload_file "${final}.sha256"
    upload_file "${final}.meta.json"
    printf '%s' "$final" >"$RUNDIR/last_backup"
}

cmd_backup() {
    local -a names=()
    local target="${1:-all}"
    (( $# <= 1 )) || die "backup takes one argument: 'all' or a comma-separated list (got: $*)"
    if [[ $target == all ]]; then mapfile -t names < <(cfgpy names "$CONFIG" databases)
    else IFS=',' read -r -a names <<<"$target"; fi
    [[ ${#names[@]} -gt 0 ]] || die "no databases configured"
    sweep_stale_parts

    local n db failed=0 okc=0 rc=0 t0=$SECONDS
    for n in "${names[@]}"; do
        [[ -z $n ]] && continue
        local -a dbs=()
        mapfile -t dbs < <(entry_databases "$n")
        if (( ${#dbs[@]} == 0 )); then
            failed=$((failed+1)); err "backup failed: $n (no database to dump)"; continue
        fi
        (( ${#dbs[@]} > 1 )) && log "entry '$n' covers ${#dbs[@]} databases: ${dbs[*]}"
        for db in "${dbs[@]}"; do
            # `set -e` inside the subshell: running it as a plain conditional would
            # suppress errexit there and let a failed dump fall through as success.
            rc=0; ( set -e; backup_one "$n" "$db" ) || rc=$?
            if (( rc == 0 )); then okc=$((okc+1)); else failed=$((failed+1)); err "backup failed: $n/$db"; fi
        done
    done
    if [[ $target == all && ${CFG_INCLUDE_GLOBALS:-true} == true ]]; then
        rc=0; ( set -e; cmd_globals ) || rc=$?
        (( rc == 0 )) || { failed=$((failed+1)); err "globals dump failed"; }
    fi
    prune_backups
    log "summary: ${okc} succeeded, ${failed} failed, $((SECONDS - t0))s total"
    if (( failed > 0 )); then notify_failure "$failed database backup(s) failed on $(hostname)"; return 1; fi
}

# ===========================================================================
#  GLOBALS  (cluster roles and grants — not part of any per-database dump)
# ===========================================================================
dump_globals() {  # expects a CTX_* pointing at one postgres server
    resolve_pg_client
    local ts host_tag final tmp su size
    ts="$(date +"$CFG_TIMESTAMP_FORMAT")"
    host_tag="$(printf '%s' "${CTX_HOST}_${CTX_PORT}" | tr -c '[:alnum:]._-' '_')"
    final="${CFG_BACKUP_DIR}/globals_${host_tag}_postgres_globals_${ts}.sql$(comp_ext)"
    tmp="$(dump_target "$final")"

    local -a ga=(-h "$CTX_HOST" -p "$CTX_PORT" -U "$CTX_USER" --globals-only --no-password)
    [[ -n $CTX_DB ]] && ga+=(-l "$CTX_DB")
    # pg_authid is superuser-only; without it pg_dumpall aborts instead of
    # falling back, so ask pg_roles for the answer first.
    su="$(_pg_query "$CTX_DB" "SELECT rolsuper FROM pg_roles WHERE rolname=current_user")"
    if [[ $su != t ]]; then
        warn "'$CTX_USER' is not superuser on ${CTX_HOST}:${CTX_PORT} — globals dumped without role passwords"
        ga+=(--no-role-passwords)
    fi

    log "dumping globals from ${CTX_HOST}:${CTX_PORT}"
    $DRY_RUN && { ok "dry-run: globals ${CTX_HOST}:${CTX_PORT}"; return 0; }
    pg_run pg_dumpall "${ga[@]}" | compress_stream >"$tmp" \
        || { rm -f "$tmp"; die "pg_dumpall failed for ${CTX_HOST}:${CTX_PORT}"; }
    [[ -s $tmp ]] || { rm -f "$tmp"; die "globals dump is empty for ${CTX_HOST}:${CTX_PORT}"; }
    mv "$tmp" "$final"
    chmod 600 "$final"          # may contain role password hashes
    verify_dump_artifact "$final" || { rm -f "$final"; die "integrity check failed — discarded $(basename "$final")"; }
    decompress_stream "$final" | grep -q 'CREATE ROLE' || warn "no CREATE ROLE statements in $(basename "$final")"

    CTX_LABEL="globals_${host_tag}"      # must match the filename prefix for prune
    write_meta "$final" postgres "$PG_SERVER_VER" globals
    size="$(stat -c %s "$final" 2>/dev/null || stat -f %z "$final")"
    ok "globals ${CTX_HOST}:${CTX_PORT} -> $(basename "$final")  $(human "$size")"
    upload_file "$final"; upload_file "${final}.sha256"; upload_file "${final}.meta.json"
}

cmd_globals() {
    local -a names=(); mapfile -t names < <(cfgpy names "$CONFIG" databases)
    local -A seen=(); local n key rc=0
    for n in ${names[@]+"${names[@]}"}; do
        [[ -z $n ]] && continue
        load_entry databases "$n" G_
        [[ "$(gv G_ENGINE)" == postgres ]] || continue
        key="$(gv G_HOST):$(gv G_PORT)"
        [[ -n ${seen[$key]:-} ]] && continue
        seen[$key]=1
        local r=0; ( set -e; use_ctx G_; dump_globals ) || r=$?
        (( r == 0 )) || { rc=1; err "globals failed: $key"; }
    done
    (( ${#seen[@]} > 0 )) || warn "no postgres sources configured — nothing to dump"
    return $rc
}

# ===========================================================================
#  PRUNE
# ===========================================================================
prune_backups() {
    local days="${CFG_RETENTION_DAYS:-0}" keep="${CFG_RETENTION_MIN_KEEP:-0}"
    (( days > 0 )) || return 0
    # A whole-server entry never names a file itself: its dumps carry
    # <entry>_<db>, and the bare name would glob across all of them.
    local -a names=() cn=()
    mapfile -t cn < <(cfgpy names "$CONFIG" databases)
    local c
    for c in ${cn[@]+"${cn[@]}"}; do entry_is_all_databases "$c" || names+=("$c"); done
    # A config name is not the whole story: all_databases entries expand to
    # <entry>_<db>, and globals belong to a server. Every artifact records the
    # label its filename starts with, so take the groups from the sidecars.
    local -a lnames=()
    mapfile -t lnames < <(grep -ho '"label": *"[^"]*"' "$CFG_BACKUP_DIR"/*.meta.json 2>/dev/null \
                          | sed -E 's/.*"label": *"([^"]*)".*/\1/' | sort -u)
    names+=(${lnames[@]+"${lnames[@]}"})
    mapfile -t names < <(printf '%s\n' ${names[@]+"${names[@]}"} | sed '/^$/d' | sort -u)
    local n f removed=0
    for n in ${names[@]+"${names[@]}"}; do
        [[ -z $n ]] && continue
        local -a files=()
        mapfile -t files < <(backups_for "$n")
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
entry_is_all_databases() {  # entry_is_all_databases <entry-name>
    local v
    v="$(cfgpy entry "$CONFIG" databases "$1" ISALL_ 2>/dev/null | sed -n "s/^ISALL_ALL_DATABASES=//p" | tr -d "'")"
    [[ $v == true ]]
}

latest_backup_for() {
    # A whole-server entry owns no dumps of its own — its dumps are labelled
    # <entry>_<db>, and "<entry>_*" would match several databases at once.
    if entry_is_all_databases "$1"; then
        local -a have=()
        mapfile -t have < <(grep -ho '"label": *"[^"]*"' "$CFG_BACKUP_DIR"/*.meta.json 2>/dev/null \
                            | sed -E 's/.*"label": *"([^"]*)".*/\1/' | grep "^$1_" | sort -u)
        die "'$1' covers a whole server; restore one database by name${have:+ (${have[*]})}"
    fi
    backups_for "$1" | head -1
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

# Pick a pg client that can actually read this archive: it was written by a
# client matched to the source server, and an older pg_restore cannot read it.
pick_pg_client_for_dump() {  # pick_pg_client_for_dump <file>
    local f="$1" fdir want_maj="" nat=""
    fdir="$(dirname "$f")"
    [[ -f "${f}.meta.json" ]] && want_maj="$(sed -n 's/.*"server_version"[[:space:]]*:[[:space:]]*"\([0-9][0-9]*\).*/\1/p' "${f}.meta.json" | head -1)"
    have pg_restore && nat="$(_native_major pg_restore || true)"
    if [[ -n $nat && ( -z $want_maj || $nat -ge $want_maj ) ]]; then
        PG_MODE=native; return 0
    fi
    if _docker_ok; then
        PG_MODE=docker
        PG_IMAGE="${want_maj:+postgres:${want_maj}-alpine}"
        PG_IMAGE="${PG_IMAGE:-$PG_PROBE_IMAGE}"
        DOCKER_EXTRA=(-v "$fdir":"$fdir":ro)
        docker image inspect "$PG_IMAGE" >/dev/null 2>&1 || {
            log "pulling $PG_IMAGE ..."
            docker pull -q "$PG_IMAGE" >/dev/null 2>&1 || {
                PG_IMAGE="postgres:${want_maj}"
                docker pull -q "$PG_IMAGE" >/dev/null 2>&1 || die "cannot pull a postgres:${want_maj} client image"
            }
        }
        return 0
    fi
    [[ -n $nat ]] || die "no pg_restore and no usable docker — install postgresql-client or docker"
    PG_MODE=native
    warn "local pg_restore $nat is older than the dump's server ${want_maj:-?} — verify may fail"
}

cmd_verify() {
    local f="${1:-}"; [[ -n $f && -f $f ]] || die "usage: $SCRIPT_NAME verify <file>"
    local fdir; fdir="$(cd "$(dirname "$f")" && pwd)"
    f="${fdir}/$(basename "$f")"
    if [[ -f "${f}.sha256" ]]; then
        ( cd "$fdir" && sha256sum -c "$(basename "$f").sha256" ) || die "checksum failed"
    else warn "no .sha256 sidecar for $(basename "$f")"; fi
    case "$f" in
        *.dump)
            CTX_ENGINE=postgres; CTX_PASS=""; CTX_SSLMODE=""
            pick_pg_client_for_dump "$f"
            verify_dump_artifact "$f" \
                || die "unreadable custom-format dump — header may list fine while the data section is truncated"
            local toc
            DOCKER_EXTRA=(-v "$fdir":"$fdir":ro)
            toc="$(pg_run pg_restore -l "$f" 2>/dev/null | sed -n 's/^;[[:space:]]*TOC Entries:[[:space:]]*\([0-9][0-9]*\).*/\1/p' | head -1)"
            DOCKER_EXTRA=()
            ok "valid PostgreSQL custom-format dump (${toc:-?} TOC entries, ${CFG_VERIFY:-full} check)" ;;
        *)
            verify_dump_artifact "$f" || die "integrity check failed: $(basename "$f")"
            ok "archive integrity OK (${CFG_VERIFY:-full} check)" ;;
    esac
}

# ===========================================================================
#  TEST / PREFLIGHT
# ===========================================================================
pg_server_major() { local v="${1%%(*}"; v="${v%%.*}"; printf '%s' "$v"; }

# Can this host actually produce a dump of that server, and how?
check_pg_client() {  # check_pg_client <server-version>
    local maj nat=""
    maj="$(pg_server_major "$1")"
    have pg_dump && nat="$(_native_major pg_dump || true)"
    case "$CFG_DOCKER" in
        never)
            if [[ -n $nat && $nat -ge $maj ]]; then log "    client: native pg_dump $nat (docker: never) — OK"
            else err "    client: pg_dump ${nat:-missing} cannot dump a server $maj and docker is disabled"; return 1; fi ;;
        always)
            _docker_ok && { log "    client: container postgres:$maj (docker: always) — OK"; return 0; }
            err "    client: docker: always but docker is unavailable"; return 1 ;;
        *)
            if [[ -n $nat && $nat -ge $maj ]]; then log "    client: native pg_dump $nat >= server $maj — OK"
            elif _docker_ok; then log "    client: native pg_dump ${nat:-none} < server $maj — will use container postgres:$maj"
            else err "    client: pg_dump ${nat:-missing} cannot dump a server $maj and docker is unavailable"; return 1; fi ;;
    esac
}

check_my_client() {
    local nat=""
    have mysqldump && nat="$(_native_major mysqldump || true)"
    if [[ -n $nat && $nat == "${MY_SERVER_MAJOR:-$nat}" ]]; then log "    client: native mysqldump $nat — OK"
    elif _docker_ok; then log "    client: native mysqldump ${nat:-none} — will use a version-matched container"
    else err "    client: mysqldump ${nat:-missing} and no usable docker"; return 1; fi
}

# The real proof that a dump will work: ask the server for one.
check_dumpable() {  # check_dumpable <db>...
    local db rc=0 errf="$RUNDIR/dumpable.err"
    resolve_client >/dev/null 2>&1 || { err "    cannot resolve a client for ${CTX_HOST}:${CTX_PORT}"; return 1; }
    for db in "$@"; do
        if pg_run pg_dump -h "$CTX_HOST" -p "$CTX_PORT" -U "$CTX_USER" -d "$db" \
               --no-password --schema-only >/dev/null 2>"$errf"; then
            ok "    dumpable: $db"
        else
            err "    NOT dumpable: $db — $(sed -e 's/^pg_dump: *//' -e '/^$/d' "$errf" | tail -1)"; rc=1
        fi
    done
    rm -f "$errf"; return $rc
}

check_my_dumpable() {
    local db rc=0 errf="$RUNDIR/dumpable.err"
    resolve_client >/dev/null 2>&1 || { err "    cannot resolve a client for ${CTX_HOST}:${CTX_PORT}"; return 1; }
    for db in "$@"; do
        if my_run mysqldump --no-data --skip-lock-tables "$db" >/dev/null 2>"$errf"; then ok "    dumpable: $db"
        else err "    NOT dumpable: $db — $(grep -v 'Using a password' "$errf" | tail -1)"; rc=1; fi
    done
    rm -f "$errf"; return $rc
}

test_entry() {  # test_entry <name> <deep>   (CTX_* already loaded)
    local n="$1" deep="$2" rc=0
    if [[ $CTX_ENGINE == postgres ]]; then
        local v; v="$(_pg_query "$CTX_DB" 'SHOW server_version')"
        [[ -n $v ]] || { err "$n: connection FAILED — $(pg_err)"; return 1; }
        ok "$n: postgres $v at $CTX_HOST:$CTX_PORT/$CTX_DB"

        # the maintenance database gates enumeration, --create and --drop
        local maint="${CFG_MAINTENANCE_DB:-postgres}" m
        m="$(_pg_query "$maint" 'SELECT 1')"
        if [[ $m == 1 ]]; then log "    maintenance db '$maint': reachable (all_databases, --create, --drop)"
        else warn "    maintenance db '$maint': NOT reachable — all_databases/--create/--drop unavailable: $(pg_err)"; fi

        local su cdb
        su="$(_pg_query "$CTX_DB" "SELECT rolsuper FROM pg_roles WHERE rolname=current_user")"
        cdb="$(_pg_query "$CTX_DB" "SELECT rolcreatedb FROM pg_roles WHERE rolname=current_user")"
        if [[ $su == t ]]; then log "    role '$CTX_USER': superuser — globals include role passwords"
        else log "    role '$CTX_USER': not superuser (createdb=${cdb:-?}) — globals omit role passwords"; fi

        local -a dbs=()
        mapfile -t dbs < <(list_ctx_databases)
        if (( ${#dbs[@]} )); then log "    databases readable by this role (${#dbs[@]}): ${dbs[*]}"
        else warn "    cannot enumerate databases on this server"; fi

        check_pg_client "$v" || rc=1
        if [[ $deep == true ]] && (( ${#dbs[@]} )); then
            local -a want=()
            if [[ ${CTX_ALL_DATABASES:-false} == true ]]; then
                local d; for d in "${dbs[@]}"; do db_included "$d" && want+=("$d"); done
            else want=("$CTX_DB"); fi
            check_dumpable ${want[@]+"${want[@]}"} || rc=1
        fi
    else
        local v; v="$(_my_query 'SELECT VERSION()')"
        [[ -n $v ]] || { err "$n: connection FAILED — $(my_err)"; return 1; }
        ok "$n: mysql $v at $CTX_HOST:$CTX_PORT/${CTX_DB:-<server>}"
        MY_SERVER_MAJOR="${v%%.*}"
        local -a dbs=()
        mapfile -t dbs < <(list_ctx_databases)
        (( ${#dbs[@]} )) && log "    databases readable by this user (${#dbs[@]}): ${dbs[*]}" \
                         || warn "    cannot enumerate databases on this server"
        check_my_client || rc=1
        if [[ $deep == true ]] && (( ${#dbs[@]} )); then
            local -a want=()
            if [[ ${CTX_ALL_DATABASES:-false} == true ]]; then
                local d; for d in "${dbs[@]}"; do db_included "$d" && want+=("$d"); done
            else want=("$CTX_DB"); fi
            check_my_dumpable ${want[@]+"${want[@]}"} || rc=1
        fi
    fi
    return $rc
}

cmd_test() {
    local deep=false n rc=0
    while (( $# )); do
        case "$1" in
            --deep) deep=true; shift ;;
            *) die "test: unknown option $1 (only --deep)" ;;
        esac
    done
    while read -r n; do
        [[ -z $n ]] && continue
        load_entry databases "$n" SRC_; use_ctx SRC_
        test_entry "$n" "$deep" || rc=1
    done < <(cfgpy names "$CONFIG" databases)
    while read -r n; do
        [[ -z $n ]] && continue
        load_entry targets "$n" DST_; use_ctx DST_
        if [[ $CTX_ENGINE == postgres ]]; then
            local v; v="$(_pg_query postgres 'SHOW server_version')"
            [[ -n $v ]] && ok "target $n: postgres $v at $CTX_HOST:$CTX_PORT" || { err "target $n: connection FAILED — $(pg_err)"; rc=1; }
        else
            local v; v="$(_my_query 'SELECT VERSION()')"
            [[ -n $v ]] && ok "target $n: mysql $v at $CTX_HOST:$CTX_PORT" || { err "target $n: connection FAILED — $(my_err)"; rc=1; }
        fi
    done < <(cfgpy names "$CONFIG" targets 2>/dev/null || true)
    return $rc
}

# ===========================================================================
#  DISCOVER — what is on this server that the config does not mention?
# ===========================================================================
discover_ctx() {  # CTX_* loaded; <entry-label-for-yaml>
    local label="$1" v
    if [[ $CTX_ENGINE == postgres ]]; then
        v="$(_pg_query "$CTX_DB" 'SHOW server_version')"
        [[ -n $v ]] || { err "cannot reach ${CTX_HOST}:${CTX_PORT}: $(pg_err)"; return 1; }
    else
        v="$(_my_query 'SELECT VERSION()')"
        [[ -n $v ]] || { err "cannot reach ${CTX_HOST}:${CTX_PORT}: $(my_err)"; return 1; }
    fi
    printf '\n%s%s:%s%s  %s %s  as %s\n' "$C_B" "$CTX_HOST" "$CTX_PORT" "$C_0" "$CTX_ENGINE" "$v" "$CTX_USER"
    printf '  %-32s %10s  %s\n' DATABASE SIZE 'IN CONFIG'
    local -a rows=()
    if [[ $CTX_ENGINE == postgres ]]; then
        mapfile -t rows < <(_pg_rows "$CTX_DB" \
            "SELECT datname || '|' || pg_size_pretty(pg_database_size(datname))
               FROM pg_database
              WHERE datallowconn AND NOT datistemplate
                AND has_database_privilege(current_user, datname, 'CONNECT')
              ORDER BY datname" | sed '/^$/d')
    else
        mapfile -t rows < <(_my_rows \
            "SELECT table_schema || '|' || ROUND(SUM(data_length+index_length)/1024/1024,1) || ' MB'
               FROM information_schema.tables
              WHERE table_schema NOT IN ('information_schema','performance_schema','mysql','sys')
              GROUP BY table_schema ORDER BY table_schema" | sed '/^$/d')
    fi
    local r db size covered uncovered=0
    local -a missing=()
    for r in ${rows[@]+"${rows[@]}"}; do
        db="${r%%|*}"; size="${r#*|}"
        covered="$(covered_by_config "$CTX_HOST" "$CTX_PORT" "$db")"
        [[ -n $covered ]] || { covered="-- NOT BACKED UP"; uncovered=$((uncovered+1)); missing+=("$db"); }
        printf '  %-32s %10s  %s\n' "$db" "$size" "$covered"
    done
    (( ${#rows[@]} )) || warn "  no databases readable by '$CTX_USER' here"
    if (( uncovered > 0 )); then
        printf '\n  %s%d database(s) not covered by %s%s — add one entry for the whole server:%s\n' \
               "$C_Y" "$uncovered" "$(basename "$CONFIG")" "$C_0" "$C_0"
        cat <<YAML

  - name: ${label}
    engine: ${CTX_ENGINE}
    host: ${CTX_HOST}
    port: ${CTX_PORT}
    user: ${CTX_USER}
    password_env: YOUR_PASSWORD_VAR
    all_databases: true            # enumerate at run time; new databases are picked up
    # exclude_databases: ["template*", "postgres"]

YAML
    else
        ok "  every database here is covered by the config"
    fi
}

covered_by_config() {  # covered_by_config <host> <port> <db>  -> entry name, or empty
    local host="$1" port="$2" db="$3" n
    while read -r n; do
        [[ -z $n ]] && continue
        load_entry databases "$n" CHK_
        [[ "$(gv CHK_HOST)" == "$host" && "$(gv CHK_PORT)" == "$port" ]] || continue
        if [[ "$(gv CHK_ALL_DATABASES)" == true ]]; then
            # an all_databases entry still honours its include/exclude filters
            local pat inc_hit=true
            eval "local -a inc=(\${CHK_INCLUDE_DB[@]+\"\${CHK_INCLUDE_DB[@]}\"})"
            eval "local -a exc=(\${CHK_EXCLUDE_DB[@]+\"\${CHK_EXCLUDE_DB[@]}\"})"
            if (( ${#inc[@]} )); then
                inc_hit=false
                for pat in "${inc[@]}"; do [[ $db == $pat ]] && inc_hit=true; done
            fi
            if $inc_hit; then
                local excluded=false
                for pat in ${exc[@]+"${exc[@]}"}; do [[ $db == $pat ]] && excluded=true; done
                $excluded || { printf '%s (all_databases)' "$n"; return 0; }
            fi
            continue
        fi
        [[ "$(gv CHK_DB)" == "$db" ]] && { printf '%s' "$n"; return 0; }
    done < <(cfgpy names "$CONFIG" databases)
    printf ''
}

cmd_discover() {
    local url="" target="all" rc=0
    while (( $# )); do
        case "$1" in
            --url) url="$2"; shift 2 ;;
            -*) die "discover: unknown option $1" ;;
            *) target="$1"; shift ;;
        esac
    done
    if [[ -n $url ]]; then
        eval "$(cfgpy url "$url" DSN_)"
        CTX_ENGINE="$(gv DSN_ENGINE)"; CTX_HOST="$(gv DSN_HOST)"; CTX_PORT="$(gv DSN_PORT)"
        CTX_USER="$(gv DSN_USER)"; CTX_PASS="$(gv DSN_PASS)"; CTX_SSLMODE="$(gv DSN_SSLMODE)"
        CTX_CHARSET=""; CTX_DB="$(gv DSN_DB)"; CTX_ALL_DATABASES=true
        CTX_INCLUDE_DB=(); CTX_EXCLUDE_DB=()
        [[ -n $CTX_DB ]] || CTX_DB="${CFG_MAINTENANCE_DB:-postgres}"
        discover_ctx "server_${CTX_HOST//./_}" || rc=1
        return $rc
    fi
    local -a names=()
    if [[ $target == all ]]; then mapfile -t names < <(cfgpy names "$CONFIG" databases)
    else IFS=',' read -r -a names <<<"$target"; fi
    local n seen_key
    local -A seen=()
    for n in ${names[@]+"${names[@]}"}; do
        [[ -z $n ]] && continue
        load_entry databases "$n" DSC_; use_ctx DSC_
        seen_key="${CTX_HOST}:${CTX_PORT}"
        [[ -n ${seen[$seen_key]:-} ]] && continue
        seen[$seen_key]=1
        discover_ctx "server_${CTX_HOST//./_}" || rc=1
    done
    (( ${#seen[@]} )) || warn "no sources configured — try: $SCRIPT_NAME discover --url 'postgresql://user:pass@host:5432/postgres'"
    return $rc
}

cmd_parse_url() {
    printf '%s\n' "$DBTOOL_CFG_PY" >"$PY"
    cfgpy url "$1" "${2:-DB_}"
}

# ===========================================================================
#  SELF-UPDATE
# ===========================================================================
cmd_self_update() {
    local check_only=false force=false
    while (( $# )); do
        case "$1" in
            --check) check_only=true; shift ;;
            --force) force=true; shift ;;
            *) die "self-update: unknown option $1 (--check, --force)" ;;
        esac
    done
    have curl || die "self-update needs curl (or update with: git pull && sudo ./install.sh)"
    local tmp="$RUNDIR/dbtool.new"
    log "fetching $DBTOOL_UPDATE_URL"
    curl -fsSL --max-time 60 "$DBTOOL_UPDATE_URL" -o "$tmp" \
        || die "cannot download $DBTOOL_UPDATE_URL"

    # Never swap in something that is not a dbtool, and never one that does not
    # parse: this file is what runs every night.
    head -1 "$tmp" | grep -q '^#!/usr/bin/env bash' || die "downloaded file is not a shell script"
    local newv
    newv="$(sed -n 's/^readonly DBTOOL_VERSION="\([^"]*\)".*/\1/p' "$tmp" | head -1)"
    [[ -n $newv ]] || die "downloaded file carries no DBTOOL_VERSION — refusing"
    bash -n "$tmp" || die "downloaded file has a syntax error — refusing"

    if ! $force; then
        if [[ $newv == "$DBTOOL_VERSION" ]]; then
            ok "already up to date (v$DBTOOL_VERSION)"
            return 0
        fi
        # a remote that is behind this one is not an update — someone pointed
        # DBTOOL_UPDATE_URL at an older branch, or a release was rolled back
        local newest
        newest="$(printf '%s\n%s\n' "$newv" "$DBTOOL_VERSION" | sort -V | tail -1)"
        if [[ $newest == "$DBTOOL_VERSION" ]]; then
            ok "installed v$DBTOOL_VERSION is newer than v$newv at $DBTOOL_UPDATE_URL — nothing to do (--force to install it anyway)"
            return 0
        fi
    fi
    log "installed v$DBTOOL_VERSION — available v$newv"
    $check_only && { warn "update available: v$DBTOOL_VERSION -> v$newv (run: $SCRIPT_NAME self-update)"; return 10; }
    $DRY_RUN && { ok "dry-run: would replace $SCRIPT_PATH with v$newv"; return 0; }

    [[ -w $SCRIPT_PATH ]] || die "$SCRIPT_PATH is not writable — re-run with sudo"
    local bak="${SCRIPT_PATH}.v${DBTOOL_VERSION}.bak"
    cp -p "$SCRIPT_PATH" "$bak" || die "cannot keep a backup at $bak"
    # rename, not overwrite: the shell is still reading the running file
    cp "$tmp" "${SCRIPT_PATH}.new" && chmod 0755 "${SCRIPT_PATH}.new" \
        && mv -f "${SCRIPT_PATH}.new" "$SCRIPT_PATH" \
        || die "could not install the new version (old one untouched at $SCRIPT_PATH)"
    ok "updated $SCRIPT_PATH: v$DBTOOL_VERSION -> v$newv  (previous kept at $(basename "$bak"))"
}

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
  globals                        Dump cluster roles/grants for every postgres server
  discover [name|all]            List every database on the configured servers and
           [--url DSN]           show which ones the config does not cover
  list                           Show configured sources, targets and local backups
  prune                          Apply the retention policy now
  verify FILE                    Check checksum + full archive/dump integrity
  self-update [--check]          Replace this script with the latest release
                                 (--check only reports, exit 10 if one is due)
  test [--deep]                  Connectivity, maintenance-db access, privileges,
                                 client/server compatibility; --deep proves every
                                 database really dumps (schema-only trial run)
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
  ${SCRIPT_NAME} test --deep
  ${SCRIPT_NAME} discover --url 'postgresql://user:pass@10.0.0.5:5432/postgres'
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
    # deliberately before load_config: a config problem must not stand between
    # you and a fixed version of the tool
    if [[ $cmd == self-update || $cmd == selfupdate || $cmd == update ]]; then
        cmd_self_update ${rest[@]+"${rest[@]}"}; exit $?
    fi
    load_config
    case "$cmd" in
        backup)  acquire_lock; cmd_backup ${rest[@]+"${rest[@]}"} ;;
        globals) acquire_lock; cmd_globals ;;
        restore) cmd_restore ${rest[@]+"${rest[@]}"} ;;
        migrate) cmd_migrate ${rest[@]+"${rest[@]}"} ;;
        list)    cmd_list ;;
        prune)   acquire_lock; prune_backups ;;
        verify)  cmd_verify ${rest[@]+"${rest[@]}"} ;;
        test)    cmd_test ${rest[@]+"${rest[@]}"} ;;
        discover) cmd_discover ${rest[@]+"${rest[@]}"} ;;
        *) die "unknown command: $cmd (see -h)" ;;
    esac
}

main "$@"
