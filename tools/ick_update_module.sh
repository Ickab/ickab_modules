#!/usr/bin/env bash
# ICKAB Module Manager 1.0
# Instalacion y actualizacion de modulos Odoo
set -Eeuo pipefail
umask 077
export LC_ALL=C

REPO="${ICKAB_REPO:-Ickab/ickab_modules}"
BRANCH="${ICKAB_BRANCH:-main}"
BACKUP_ROOT="${ICKAB_BACKUP_ROOT:-/var/backups/ickab-module-manager}"

WORK=""
BACKUP=""
SERVICE=""
OWNER=""
DB=""
MODULE=""
DEST=""
PREVIOUS=""
STOPPED=0
MUTATED=0
ORIGINAL_ACTIVE=0

fatal() {
    printf '\nERROR: %s\n' "$*" >&2
    exit 1
}

confirm() {
    local answer
    read -r -p "$1 [escribe SI]: " answer ||
        fatal "Operacion cancelada"
    [[ "$answer" == SI ]] || fatal "Operacion cancelada"
}

choose() {
    local answer
    while true; do
        read -r -p "$1 [1-$2]: " answer ||
            fatal "Seleccion cancelada"
        if [[ "$answer" =~ ^[0-9]+$ ]] &&
           (( 10#$answer >= 1 && 10#$answer <= $2 )); then
            REPLY=$((10#$answer))
            return
        fi
        echo "Numero invalido"
    done
}

record() {
    local message="$*"
    if [[ -n "$BACKUP" ]]; then
        printf '%s | %s\n' \
            "$(date -u +%FT%TZ)" "$message" \
            >> "$BACKUP/operation.log"
    fi
    printf '%s\n' "$message"
}

cleanup() {
    local rc=$?
    trap - EXIT

    if (( rc != 0 )); then
        record "ERROR codigo=$rc"

        if (( STOPPED && ! MUTATED && ORIGINAL_ACTIVE )); then
            echo "Restableciendo servicio sin cambios en BD/codigo..."
            if systemctl start "$SERVICE"; then
                STOPPED=0
            else
                echo "ALERTA: no se pudo iniciar $SERVICE" >&2
            fi
        fi

        if (( MUTATED )); then
            echo "ALERTA: operacion incompleta." >&2
            echo "No restaurar solamente el codigo ni iniciar sin revisar BD." >&2
            echo "Respaldo: $BACKUP" >&2
            echo "Codigo anterior: $PREVIOUS" >&2
        fi
    fi

    [[ -z "$WORK" ]] || rm -rf -- "$WORK"
    exit "$rc"
}
trap cleanup EXIT

[[ "$EUID" -eq 0 ]] ||
    fatal "Ejecuta como root (sudo)"

for cmd in systemctl python3 runuser psql pg_dump pg_restore \
           tar curl flock sha256sum realpath diff find; do
    command -v "$cmd" >/dev/null ||
        fatal "Falta dependencia: $cmd"
done

# Lectura de servicios systemd sin iniciar Odoo.
unit() {
    python3 - "$1" <<'PY_UNIT'
import re
import shlex
import sys

raw = sys.argv[1]
match = re.search(
    r'argv\[\]=(.*?)(?:\s;\s(?:ignore_errors|start_time|stop_time|pid)=|\s*\})',
    raw
)
if not match:
    sys.exit(1)

args = shlex.split(match.group(1))
index = next(
    (i for i, x in enumerate(args) if x.endswith('/odoo-bin')),
    None
)
if index is None:
    sys.exit(1)

cfg = ''
for i, value in enumerate(args):
    if value in ('-c', '--config') and i + 1 < len(args):
        cfg = args[i + 1]
    elif value.startswith('--config='):
        cfg = value.partition('=')[2]

python = (
    args[index - 1]
    if index > 0 and args[index - 1].startswith('/')
    else '/usr/bin/python3'
)

print(args[index])
print(cfg)
print(python)
PY_UNIT
}

conf() {
    python3 - "$1" "$2" <<'PY_CONFIG'
import configparser
import sys

parser = configparser.ConfigParser(
    interpolation=None,
    strict=False
)

if not parser.read(sys.argv[1]):
    sys.exit(1)

print(parser.get(
    'options',
    sys.argv[2],
    fallback=''
).strip())
PY_CONFIG
}

version() {
    python3 - "$1" <<'PY_VERSION'
import pathlib
import re
import sys

binary = pathlib.Path(sys.argv[1]).resolve()

candidates = (
    binary.parent / 'odoo/release.py',
    binary.parent / 'release.py',
    binary.parent.parent / 'odoo/release.py'
)

for file in candidates:
    if file.is_file():
        text = file.read_text(errors='replace')
        match = re.search(
            r'^version_info\s*=\s*\(\s*(\d+)\s*,\s*(\d+)',
            text,
            re.M
        )
        if match:
            print('.'.join(match.groups()))
            sys.exit(0)

sys.exit(1)
PY_VERSION
}

manifest() {
    python3 - "$1" <<'PY_MANIFEST'
import ast
import json
import sys

try:
    with open(sys.argv[1], encoding='utf8') as file:
        data = ast.literal_eval(file.read())

    assert isinstance(data, dict)

    version = data.get('version', '')
    depends = data.get('depends', ['base'])
    external = data.get('external_dependencies', {})

    assert isinstance(version, str)
    assert isinstance(depends, list)
    assert all(isinstance(x, str) for x in depends)
    assert isinstance(external, dict)
    assert all(
        isinstance(x, list) and
        all(isinstance(y, str) for y in x)
        for x in external.values()
    )

    print(json.dumps({
        'version': version,
        'depends': depends,
        'external': external
    }))

except Exception as exc:
    sys.exit('Manifiesto invalido: ' + str(exc))
PY_MANIFEST
}

field() {
    python3 - "$1" "$2" <<'PY_FIELD'
import json
import sys

with open(sys.argv[1]) as file:
    data = json.load(file)

value = data[sys.argv[2]]
print(value if isinstance(value, str) else '')
PY_FIELD
}

pg() {
    runuser -u "$OWNER" -- \
        env PGPASSWORD="$PGPASSWORD" PGCONNECT_TIMEOUT=8 \
        psql -X -w -v ON_ERROR_STOP=1 \
        "${PG_ARGS[@]}" "$@"
}

echo
echo "=========================================================="
echo "              ICKAB MODULE MANAGER 1.0"
echo "=========================================================="
echo "Detectando instancias Odoo..."
echo

declare -a UNITS=()
declare -a CFGS=()
declare -a BINS=()
declare -a PYS=()
declare -a OWNERS=()
declare -a STATES=()
declare -a VERS=()

while IFS= read -r service; do
    [[ "$service" == *odoo*.service ]] || continue

    raw="$(
        systemctl show "$service" \
            -p ExecStart --value 2>/dev/null || true
    )"

    [[ "$raw" == *odoo-bin* ]] || continue

    mapfile -t parts < <(
        unit "$raw" 2>/dev/null || true
    )

    ((${#parts[@]} == 3)) || continue

    [[ -f "${parts[0]}" &&
       -f "${parts[1]}" &&
       -x "${parts[2]}" ]] || continue

    owner="$(
        systemctl show "$service" -p User --value
    )"

    [[ -n "$owner" ]] || continue

    ver="$(version "${parts[0]}" 2>/dev/null || true)"
    [[ "$ver" =~ ^[0-9]+\.[0-9]+$ ]] || continue

    state="$(systemctl is-active "$service" || true)"
    [[ "$state" == active || "$state" == inactive ]] ||
        continue

    UNITS+=("$service")
    CFGS+=("${parts[1]}")
    BINS+=("${parts[0]}")
    PYS+=("${parts[2]}")
    OWNERS+=("$owner")
    STATES+=("$state")
    VERS+=("$ver")

done < <(
    systemctl list-unit-files \
        --type=service --no-legend --no-pager |
        awk '{print $1}' | sort -u
)

((${#UNITS[@]} > 0)) ||
    fatal "No se detectaron instancias compatibles"

printf '%-4s %-42s %-8s %s\n' \
    "N" "SERVICIO" "ODOO" "ESTADO"

for i in "${!UNITS[@]}"; do
    printf '%-4s %-42s %-8s %s\n' \
        "$((i+1))" \
        "${UNITS[i]}" \
        "${VERS[i]}" \
        "${STATES[i]}"
done

echo
choose "Selecciona instancia" "${#UNITS[@]}"
i=$((REPLY-1))

SERVICE="${UNITS[i]}"
CFG="${CFGS[i]}"
BIN="${BINS[i]}"
PY="${PYS[i]}"
OWNER="${OWNERS[i]}"
STATE="${STATES[i]}"
VER="${VERS[i]}"

[[ "$STATE" == active ]] && ORIGINAL_ACTIVE=1

echo
echo "Servicio:      $SERVICE"
echo "Configuracion: $CFG"
echo "Odoo:          $VER"
echo "Estado:        $STATE"
echo "Usuario:       $OWNER"

confirm "Confirmas instancia"

DBNAME="$(conf "$CFG" db_name)"
FILTER="$(conf "$CFG" dbfilter)"
HOST="$(conf "$CFG" db_host)"
PORT="$(conf "$CFG" db_port)"
PGUSER="$(conf "$CFG" db_user)"
PASS="$(conf "$CFG" db_password)"

PG_ARGS=()

[[ -z "$HOST" || "${HOST,,}" == false ]] ||
    PG_ARGS+=(-h "$HOST")

[[ -z "$PORT" || "${PORT,,}" == false ]] ||
    PG_ARGS+=(-p "$PORT")

[[ -z "$PGUSER" || "${PGUSER,,}" == false ]] ||
    PG_ARGS+=(-U "$PGUSER")

PGPASSWORD=""
[[ -z "$PASS" || "${PASS,,}" == false ]] ||
    PGPASSWORD="$PASS"

# Consultar bases reales de PostgreSQL.
all="$(
    pg -d postgres -Atqc \
        "SELECT datname FROM pg_database
         WHERE datallowconn AND NOT datistemplate
         ORDER BY datname" 2>/dev/null ||
    pg -d template1 -Atqc \
        "SELECT datname FROM pg_database
         WHERE datallowconn AND NOT datistemplate
         ORDER BY datname" 2>/dev/null
)" || fatal "No se puede listar PostgreSQL"

mapfile -t DATABASES <<< "$all"

# Aplicar db_name y dbfilter antes de mostrar bases.
mapfile -t CANDIDATES < <(
    python3 - "$DBNAME" "$FILTER" "${DATABASES[@]}" <<'PY_FILTER'
import re
import sys

name, dbfilter, *databases = sys.argv[1:]

allowed = (
    None
    if not name or name.lower() == 'false'
    else {x.strip() for x in name.split(',')}
)

if dbfilter and dbfilter.lower() != 'false':
    if '%d' in dbfilter or '%h' in dbfilter:
        sys.exit(
            'dbfilter dependiente del host: '
            'requiere configuracion fija db_name'
        )
    try:
        expression = re.compile(dbfilter)
    except re.error:
        sys.exit('dbfilter invalido')
else:
    expression = None

for db in databases:
    if not re.fullmatch(r'[A-Za-z0-9_]+', db):
        continue
    if allowed is not None and db not in allowed:
        continue
    if expression and not expression.match(db):
        continue
    print(db)
PY_FILTER
)

((${#CANDIDATES[@]} > 0)) ||
    fatal "No hay bases que cumplan db_name/dbfilter"

declare -a VALID=()

for db in "${CANDIDATES[@]}"; do
    exists="$(
        pg -d "$db" -Atqc \
            "SELECT to_regclass('public.ir_module_module')
                    IS NOT NULL" 2>/dev/null || true
    )"

    [[ "$exists" == t ]] && VALID+=("$db")
done

((${#VALID[@]} > 0)) ||
    fatal "No hay bases Odoo accesibles para esta instancia"

echo
echo "BASES PERMITIDAS"

for i in "${!VALID[@]}"; do
    printf '%d) %s\n' "$((i+1))" "${VALID[i]}"
done

choose "Selecciona base" "${#VALID[@]}"
DB="${VALID[REPLY-1]}"

confirm "Confirmas $SERVICE / $DB"

read -r -p "Nombre tecnico del modulo: " MODULE

[[ "$MODULE" =~ ^[A-Za-z][A-Za-z0-9_]*$ ]] ||
    fatal "Nombre de modulo invalido"

CURRENT="$(
    pg -d "$DB" -Atqc \
        "SELECT state FROM ir_module_module
         WHERE name='$MODULE' LIMIT 1"
)" || fatal "No se pudo consultar modulo"

case "$CURRENT" in
    installed)
        ACTION="update"
        ;;
    ""|uninstalled)
        ACTION="install"
        ;;
    *)
        fatal "Modulo en estado incompatible: $CURRENT"
        ;;
esac

WORK="$(mktemp -d /tmp/ickab-manager.XXXXXXXX)"

echo
echo "Operacion: $ACTION"
echo
echo "ORIGEN"
echo "1) GitHub ICKAB"
echo "2) Carpeta local"

choose "Selecciona origen" 2

if (( REPLY == 1 )); then
    curl -fsSL --retry 2 --max-time 60 \
        "https://api.github.com/repos/$REPO/contents/$VER?ref=$BRANCH" \
        -o "$WORK/index.json" ||
        fatal "Error consultando GitHub"

    mapfile -t PACKAGES < <(
        python3 - "$WORK/index.json" "$MODULE" "$VER" <<'PY_PACKAGES'
import json
import re
import sys

with open(sys.argv[1]) as file:
    items = json.load(file)

pattern = re.compile(
    re.escape(sys.argv[2]) + '_' +
    re.escape(sys.argv[3]) +
    r'\.[0-9]+(?:\.[0-9]+)*\.zip'
)

if isinstance(items, list):
    for item in items:
        name = item.get('name', '')
        if (
            item.get('type') == 'file'
            and pattern.fullmatch(name)
        ):
            print(name)
PY_PACKAGES
    )

    ((${#PACKAGES[@]} > 0)) ||
        fatal "No hay ZIP compatible en GitHub"

    for i in "${!PACKAGES[@]}"; do
        printf '%d) %s\n' \
            "$((i+1))" "${PACKAGES[i]}"
    done

    choose "Selecciona ZIP" "${#PACKAGES[@]}"
    ZIP="${PACKAGES[REPLY-1]}"

    curl -fLsS --retry 2 --max-time 300 \
        "https://raw.githubusercontent.com/$REPO/$BRANCH/$VER/$ZIP" \
        -o "$WORK/package.zip" ||
        fatal "No se pudo descargar ZIP"

    python3 - "$WORK/package.zip" "$WORK" "$MODULE" <<'PY_ZIP'
import stat
import sys
import zipfile

archive, destination, module = sys.argv[1:]

with zipfile.ZipFile(archive) as z:
    entries = z.infolist()
    seen = set()
    total = 0

    if not entries or len(entries) > 10000:
        sys.exit('ZIP invalido')

    for entry in entries:
        name = entry.filename
        parts = name.rstrip('/').split('/')
        mode = (entry.external_attr >> 16) & 0o170000

        if (
            name.startswith('/')
            or '\\' in name
            or any(p in ('', '..', '.') for p in parts)
            or parts[0] != module
            or name in seen
            or mode not in (
                0, stat.S_IFREG, stat.S_IFDIR
            )
        ):
            sys.exit('ZIP inseguro')

        seen.add(name)
        total += entry.file_size

        if total > 500 * 1024 * 1024:
            sys.exit('ZIP excede limite')

    z.extractall(destination)
PY_ZIP

    SOURCE="$WORK/$MODULE"

else
    read -r -p \
        "Ruta absoluta de la carpeta del modulo: " SOURCE

    [[ "$SOURCE" == /* &&
       -d "$SOURCE" &&
       ! -L "$SOURCE" ]] ||
        fatal "Ruta invalida"

    SOURCE="$(realpath "$SOURCE")"
fi

[[ -f "$SOURCE/__manifest__.py" ]] ||
    fatal "No existe manifiesto"

[[ -z "$(find "$SOURCE" -type l -print -quit)" ]] ||
    fatal "No se permiten enlaces simbolicos"

manifest "$SOURCE/__manifest__.py" \
    > "$WORK/manifest.json" ||
    fatal "Manifiesto invalido"

NEW="$(field "$WORK/manifest.json" version)"

[[ "$NEW" == "$VER."* ]] ||
    fatal "Version $NEW incompatible con Odoo $VER"

ADDONS="$(conf "$CFG" addons_path)"
IFS=',' read -r -a PATHS <<< "$ADDONS"

declare -a FOUND=()
declare -a CUSTOM=()

for path in "${PATHS[@]}"; do
    path="${path#"${path%%[![:space:]]*}"}"
    path="${path%"${path##*[![:space:]]}"}"

    [[ -d "$path" ]] || continue

    path="$(realpath "$path")"

    [[ -d "$path/$MODULE" ]] &&
        FOUND+=("$path/$MODULE")

    case "$path" in
        */odoo/addons|*/enterprise)
            ;;
        *)
            CUSTOM+=("$path")
            ;;
    esac
done

if [[ "$ACTION" == update ]]; then
    ((${#FOUND[@]} == 1)) ||
        fatal "Modulo instalado no tiene una unica ruta de codigo"

    DEST="${FOUND[0]}"

    [[ -f "$DEST/__manifest__.py" ]] ||
        fatal "Falta manifiesto anterior"

    manifest "$DEST/__manifest__.py" \
        > "$WORK/old.json" ||
        fatal "Manifiesto anterior invalido"

    OLD="$(field "$WORK/old.json" version)"

    [[ -n "$OLD" ]] ||
        fatal "Version anterior desconocida"

    lowest="$(
        printf '%s\n%s\n' "$OLD" "$NEW" |
            sort -V | head -n 1
    )"

    [[ "$lowest" == "$OLD" ]] ||
        fatal "Retroceso de version bloqueado"

    if [[ "$NEW" == "$OLD" ]]; then
        if diff -qr "$SOURCE" "$DEST" >/dev/null; then
            fatal "Misma version y mismo contenido: no hay cambios"
        fi

        echo
        echo "AVISO: misma version, pero el codigo es diferente."
        confirm "Autorizas reinstalar codigo con la misma version"
    fi

else
    ((${#FOUND[@]} == 0)) ||
        fatal "El modulo ya existe en addons: revisar instalacion"

    ((${#CUSTOM[@]} > 0)) ||
        fatal "No hay rutas de addons personalizados"

    echo
    echo "DESTINOS"

    for i in "${!CUSTOM[@]}"; do
        printf '%d) %s\n' "$((i+1))" "${CUSTOM[i]}"
    done

    choose "Selecciona destino" "${#CUSTOM[@]}"

    DEST="${CUSTOM[REPLY-1]}/$MODULE"
    OLD="no instalado"
fi

[[ ! -e "$DEST" || "$ACTION" == update ]] ||
    fatal "Destino ocupado"

[[ ! -L "$DEST" ]] ||
    fatal "Destino simbolico"

[[ "$(realpath "$SOURCE")" != "$(realpath -m "$DEST")" ]] ||
    fatal "Origen igual al destino"

# Validar dependencias Odoo y externas.
python3 - \
    "$WORK/manifest.json" \
    "$WORK/deps.txt" \
    "$WORK/python-deps.txt" \
    "$WORK/bin-deps.txt" <<'PY_DEPS'
import json
import sys

with open(sys.argv[1]) as file:
    data = json.load(file)

external = data['external']

for key in external:
    if key not in ('python', 'bin'):
        sys.exit('Dependencia externa no soportada: ' + key)

groups = (
    (sys.argv[2], data['depends']),
    (sys.argv[3], external.get('python', [])),
    (sys.argv[4], external.get('bin', []))
)

for path, items in groups:
    with open(path, 'w') as file:
        for value in items:
            if '\n' in value:
                sys.exit('Dependencia invalida')
            file.write(value + '\n')
PY_DEPS

while IFS= read -r dep; do
    [[ "$dep" =~ ^[A-Za-z][A-Za-z0-9_]*$ ]] ||
        fatal "Dependencia invalida: $dep"

    [[ "$dep" != "$MODULE" ]] ||
        fatal "Autodependencia en manifiesto"

    state="$(
        pg -d "$DB" -Atqc \
            "SELECT state FROM ir_module_module
             WHERE name='$dep' LIMIT 1"
    )" || fatal "Error verificando dependencias"

    [[ "$state" == installed ]] ||
        fatal "Dependencia Odoo no instalada: $dep"

done < "$WORK/deps.txt"

while IFS= read -r dep; do
    [[ -z "$dep" ]] && continue

    [[ "$dep" =~ ^[A-Za-z_][A-Za-z0-9_.]*$ ]] ||
        fatal "Dependencia Python invalida: $dep"

    runuser -u "$OWNER" -- "$PY" \
        -c 'import importlib.util,sys; sys.exit(0 if importlib.util.find_spec(sys.argv[1]) else 1)' \
        "$dep" ||
        fatal "Falta dependencia Python: $dep"

done < "$WORK/python-deps.txt"

while IFS= read -r dep; do
    [[ -z "$dep" ]] && continue

    command -v "$dep" >/dev/null ||
        fatal "Falta binario: $dep"

done < "$WORK/bin-deps.txt"

# Detectar codigo compartido.
while IFS= read -r other; do
    [[ "$other" == "$SERVICE" ]] && continue
    [[ "$other" == *odoo*.service ]] || continue

    raw="$(
        systemctl show "$other" \
            -p ExecStart --value 2>/dev/null || true
    )"

    mapfile -t otherparts < <(
        unit "$raw" 2>/dev/null || true
    )

    ((${#otherparts[@]} == 3)) || continue
    [[ -f "${otherparts[1]}" ]] || continue

    other_addons="$(
        conf "${otherparts[1]}" addons_path 2>/dev/null || true
    )"

    IFS=',' read -r -a OTHER_PATHS <<< "$other_addons"

    for path in "${OTHER_PATHS[@]}"; do
        path="${path#"${path%%[![:space:]]*}"}"
        path="${path%"${path##*[![:space:]]}"}"

        [[ -d "$path" ]] || continue

        if [[ "$(realpath "$path")/$MODULE" == "$DEST" ]]; then
            if systemctl is-active --quiet "$other"; then
                fatal "Codigo compartido con instancia activa $other"
            fi

            echo "AVISO: codigo compartido con instancia detenida $other"
            confirm "Autorizas cambiar codigo de esa instancia detenida"
        fi
    done

    other_name="$(
        conf "${otherparts[1]}" db_name 2>/dev/null || true
    )"

    if [[ "$other_name" == "$DB" ]] &&
       systemctl is-active --quiet "$other"; then
        fatal "La BD $DB tambien es utilizada por $other"
    fi

done < <(
    systemctl list-unit-files \
        --type=service --no-legend --no-pager |
        awk '{print $1}' | sort -u
)

DATA="$(conf "$CFG" data_dir)"

if [[ -z "$DATA" ]]; then
    OWNER_HOME="$(getent passwd "$OWNER" | cut -d: -f6)"
    DATA="$OWNER_HOME/.local/share/Odoo"
fi

FILESTORE="$DATA/filestore/$DB"

echo
echo "=========================================================="
echo "                 RESUMEN DE OPERACION"
echo "=========================================================="
echo "Servicio:       $SERVICE"
echo "Base:           $DB"
echo "Odoo:           $VER"
echo "Modulo:         $MODULE"
echo "Accion:         $ACTION"
echo "Version:        $OLD -> $NEW"
echo "Destino:        $DEST"
echo "Estado inicial: $STATE"
echo "Filestore:      $FILESTORE"
echo "Respaldo:       OBLIGATORIO"
echo "=========================================================="

confirm "AUTORIZAS respaldo obligatorio y cambio en esta instancia"

# Una operacion ICKAB por servidor.
exec {LOCK}>/run/lock/ickab-module-manager.lock

flock -n "$LOCK" ||
    fatal "Otra operacion ICKAB esta activa"

[[ "$(systemctl is-active "$SERVICE" || true)" == "$STATE" ]] ||
    fatal "Cambio el estado del servicio; repetir operacion"

BACKUP="$BACKUP_ROOT/${SERVICE%.service}/${DB}/${MODULE}_$(date -u +%Y%m%dT%H%M%SZ)_$$"

mkdir -p -m 700 "$BACKUP"

record "INICIO $SERVICE $DB $MODULE $ACTION $OLD -> $NEW"

# Detener la instancia antes del respaldo.
if (( ORIGINAL_ACTIVE )); then
    record "Deteniendo $SERVICE"

    systemctl stop "$SERVICE" ||
        fatal "No se pudo detener el servicio"

    STOPPED=1
fi

record "Respaldando PostgreSQL"

runuser -u "$OWNER" -- \
    env PGPASSWORD="$PGPASSWORD" PGCONNECT_TIMEOUT=8 \
    pg_dump -Fc -w "${PG_ARGS[@]}" -d "$DB" \
    > "$BACKUP/database.dump" ||
    fatal "Error en pg_dump"

[[ -s "$BACKUP/database.dump" ]] ||
    fatal "Dump vacio"

pg_restore -l "$BACKUP/database.dump" \
    > "$BACKUP/database.contents" ||
    fatal "Dump ilegible"

record "Respaldando filestore"

if [[ -d "$FILESTORE" ]]; then
    tar -C "$(dirname "$FILESTORE")" \
        -czf "$BACKUP/filestore.tar.gz" \
        "$(basename "$FILESTORE")" ||
        fatal "Error respaldando filestore"
else
    printf 'AUSENTE: %s\n' "$FILESTORE" \
        > "$BACKUP/filestore-absent.txt"
fi

if [[ "$ACTION" == update ]]; then
    record "Respaldando codigo anterior"

    tar -C "$(dirname "$DEST")" \
        -czf "$BACKUP/code.tar.gz" "$MODULE" ||
        fatal "Error respaldando codigo"
fi

(
    cd "$BACKUP"

    find . -maxdepth 1 -type f \
        ! -name SHA256SUMS \
        ! -name operation.log \
        -printf '%f\n' |
        sort |
        while IFS= read -r file; do
            sha256sum "$file"
        done > SHA256SUMS

    sha256sum -c SHA256SUMS >/dev/null
) || fatal "Error verificando respaldos"

record "RESPALDO OK: $BACKUP"

# Preparar codigo en el mismo sistema de archivos.
STAGE="$(
    mktemp -d "$(dirname "$DEST")/.ickab-${MODULE}.XXXXXXXX"
)"

cp -a "$SOURCE/." "$STAGE/" ||
    fatal "No se pudo preparar codigo"

chown -R "$OWNER:$(id -gn "$OWNER")" "$STAGE"

if [[ "$ACTION" == update ]]; then
    PREVIOUS="$(dirname "$DEST")/.ickab-${MODULE}.previous-$$"

    mv "$DEST" "$PREVIOUS" ||
        fatal "No se pudo apartar codigo anterior"
fi

if ! mv "$STAGE" "$DEST"; then
    if [[ -n "$PREVIOUS" ]]; then
        mv "$PREVIOUS" "$DEST" || true
    fi
    fatal "No se pudo instalar codigo nuevo"
fi

MUTATED=1

FLAG="-i"
[[ "$ACTION" == update ]] && FLAG="-u"

record "Ejecutando instalacion/actualizacion Odoo"

if ! runuser -u "$OWNER" -- \
    env PGPASSWORD="$PGPASSWORD" \
    "$PY" "$BIN" \
    -c "$CFG" \
    -d "$DB" \
    "$FLAG" "$MODULE" \
    --stop-after-init \
    --no-http \
    --workers=0 \
    --max-cron-threads=0 \
    > "$BACKUP/odoo.log" 2>&1; then

    fatal "Odoo fallo. Ver $BACKUP/odoo.log. BD/codigo NO restaurados automaticamente"
fi

FINAL="$(
    pg -d "$DB" -Atqc \
        "SELECT state FROM ir_module_module
         WHERE name='$MODULE' LIMIT 1"
)" || fatal "No se pudo verificar estado final"

[[ "$FINAL" == installed ]] ||
    fatal "Estado final inesperado: $FINAL"

record "Odoo termino y modulo instalado confirmado"

if (( ORIGINAL_ACTIVE )); then
    systemctl start "$SERVICE" ||
        fatal "No se pudo reiniciar servicio"

    systemctl is-active --quiet "$SERVICE" ||
        fatal "Servicio no quedo activo"

    STOPPED=0
fi

if [[ -n "$PREVIOUS" ]]; then
    mv "$PREVIOUS" "$BACKUP/previous-code" ||
        fatal "No se pudo conservar codigo anterior"
fi

MUTATED=0

record "EXITO"

echo
echo "=========================================================="
echo "                  OPERACION COMPLETADA"
echo "=========================================================="
echo "Servicio: $SERVICE"
echo "Base:     $DB"
echo "Modulo:   $MODULE"
echo "Version:  $NEW"
echo "Respaldo: $BACKUP"
echo "=========================================================="
