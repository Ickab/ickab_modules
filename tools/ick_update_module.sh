#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

ROOT="/var/backups/ickab-module-manager"
REPO="Ickab/ickab_modules"
WORK=""
SERVICE=""
BACKUP=""
STOPPED=0

die() {
    printf '\nERROR: %s\n' "$*" >&2
    exit 1
}

confirm() {
    local answer
    read -r -p "$1 [escribe SI]: " answer || die "Cancelado"
    [[ "$answer" == SI ]] || die "Cancelado"
}

choose() {
    local answer
    while true; do
        read -r -p "$1 [1-$2]: " answer || die "Cancelado"
        if [[ "$answer" =~ ^[0-9]+$ ]] &&
           (( 10#$answer >= 1 && 10#$answer <= $2 )); then
            REPLY=$((10#$answer))
            return
        fi
        echo "Opcion invalida"
    done
}

cleanup() {
    local rc=$?
    trap - EXIT
    if (( STOPPED )); then
        echo "ATENCION: $SERVICE permanece detenido." >&2
        echo "Respaldo: $BACKUP" >&2
    fi
    [[ -z "$WORK" ]] || rm -rf -- "$WORK"
    exit "$rc"
}
trap cleanup EXIT

[[ "$EUID" -eq 0 ]] || die "Ejecutar con sudo"

for cmd in python3 systemctl runuser psql pg_dump tar flock curl sha256sum; do
    command -v "$cmd" >/dev/null || die "Falta dependencia: $cmd"
done

parse_unit() {
    python3 - "$1" <<'PY'
import re, shlex, sys
s = sys.argv[1]
m = re.search(
    r'argv\[\]=(.*?)(?:\s;\s(?:ignore_errors|start_time|stop_time|pid)=|\s*\})',
    s
)
if not m:
    sys.exit(1)
a = shlex.split(m.group(1))
b = next((i for i, x in enumerate(a) if x.endswith('/odoo-bin')), None)
if b is None:
    sys.exit(1)
cfg = ''
for i, x in enumerate(a):
    if x in ('-c', '--config') and i + 1 < len(a):
        cfg = a[i + 1]
    elif x.startswith('--config='):
        cfg = x.split('=', 1)[1]
print(a[b])
print(cfg)
print(a[b-1] if b and a[b-1].startswith('/') else '')
PY
}

conf() {
    python3 - "$1" "$2" <<'PY'
import configparser, sys
p = configparser.ConfigParser(interpolation=None, strict=False)
if not p.read(sys.argv[1]):
    sys.exit(1)
print(p.get('options', sys.argv[2], fallback='').strip())
PY
}

manifest_version() {
    python3 - "$1" <<'PY'
import ast, sys
with open(sys.argv[1], encoding='utf8') as f:
    data = ast.literal_eval(f.read())
print(data.get('version', ''))
PY
}

echo
echo "=========================================================="
echo "              ICKAB MODULE MANAGER 1.0"
echo "=========================================================="
echo "Detectando instancias Odoo..."

declare -a UNITS=() CONFIGS=() BINS=() PYS=() OWNERS=() STATES=()

while IFS= read -r unit; do
    [[ "$unit" == *odoo*.service ]] || continue

    raw=$(systemctl show "$unit" -p ExecStart --value 2>/dev/null || true)
    [[ "$raw" == *odoo-bin* ]] || continue

    mapfile -t parts < <(parse_unit "$raw" 2>/dev/null || true)
    ((${#parts[@]} == 3)) || continue

    [[ -f "${parts[0]}" && -f "${parts[1]}" ]] || continue

    owner=$(systemctl show "$unit" -p User --value)
    [[ -n "$owner" && "$owner" != root ]] || continue

    UNITS+=("$unit")
    CONFIGS+=("${parts[1]}")
    BINS+=("${parts[0]}")
    PYS+=("${parts[2]}")
    OWNERS+=("$owner")
    STATES+=("$(systemctl is-active "$unit" || true)")
done < <(
    systemctl list-unit-files --type=service --no-legend --no-pager |
    awk '{print $1}' | sort -u
)

((${#UNITS[@]} > 0)) || die "No se encontraron instancias compatibles"

echo
printf '%-4s %-42s %-12s\n' "N" "SERVICIO" "ESTADO"
echo "------------------------------------------------------------"

for i in "${!UNITS[@]}"; do
    printf '%-4s %-42s %-12s\n' \
        "$((i+1))" "${UNITS[i]}" "${STATES[i]}"
done

echo
choose "Selecciona la instancia" "${#UNITS[@]}"
i=$((REPLY-1))

SERVICE="${UNITS[i]}"
CFG="${CONFIGS[i]}"
BIN="${BINS[i]}"
PY="${PYS[i]}"
OWNER="${OWNERS[i]}"
STATE="${STATES[i]}"

[[ -x "$PY" ]] || PY=$(command -v python3)

[[ "$STATE" == active || "$STATE" == inactive ]] ||
    die "Estado de servicio no permitido: $STATE"

VER=$(
    python3 - "$BIN" <<'PY'
import pathlib, re, sys
root = pathlib.Path(sys.argv[1]).resolve().parent
file = root / 'odoo' / 'release.py'
if file.exists():
    text = file.read_text(errors='replace')
    m = re.search(
        r'^version_info\s*=\s*\((\d+)\s*,\s*(\d+)',
        text, re.M
    )
    if m:
        print(f'{m.group(1)}.{m.group(2)}')
PY
)

[[ "$VER" =~ ^[0-9]+\.[0-9]+$ ]] ||
    die "No se pudo identificar la version real de Odoo"

DBNAME=$(conf "$CFG" db_name)
DBFILTER=$(conf "$CFG" dbfilter)
HOST=$(conf "$CFG" db_host)
PORT=$(conf "$CFG" db_port)
PGUSER=$(conf "$CFG" db_user)
PASS=$(conf "$CFG" db_password)

PG=()
[[ -z "$HOST" || "${HOST,,}" == false ]] || PG+=(-h "$HOST")
[[ -z "$PORT" || "${PORT,,}" == false ]] || PG+=(-p "$PORT")
[[ -z "$PGUSER" || "${PGUSER,,}" == false ]] || PG+=(-U "$PGUSER")

export PGPASSWORD=""
[[ -z "$PASS" || "${PASS,,}" == false ]] || PGPASSWORD="$PASS"

mapfile -t DBS < <(
    runuser -u "$OWNER" -- env PGPASSWORD="$PGPASSWORD" \
        psql -X "${PG[@]}" -d postgres -Atqc \
        "SELECT datname FROM pg_database
         WHERE datallowconn AND NOT datistemplate
         ORDER BY datname" 2>/dev/null || true
)

((${#DBS[@]} > 0)) ||
    die "No se pudieron consultar bases PostgreSQL"

if [[ -n "$DBNAME" && "${DBNAME,,}" != false ]]; then
    IFS=',' read -r -a REQUESTED <<< "$DBNAME"
else
    REQUESTED=()
fi

declare -a VALID=()

for db in "${DBS[@]}"; do
    [[ "$db" =~ ^[A-Za-z0-9_]+$ ]] || continue

    if ((${#REQUESTED[@]})); then
        found=0
        for candidate in "${REQUESTED[@]}"; do
            [[ "$candidate" == "$db" ]] && found=1
        done
        ((found)) || continue
    fi

    check=$(
        runuser -u "$OWNER" -- env PGPASSWORD="$PGPASSWORD" \
            psql -X "${PG[@]}" -d "$db" -Atqc \
            "SELECT to_regclass('public.ir_module_module') IS NOT NULL" \
            2>/dev/null || true
    )

    [[ "$check" == t ]] && VALID+=("$db")
done

((${#VALID[@]} > 0)) || die "No se encontraron bases Odoo accesibles"

echo
echo "Servicio: $SERVICE"
echo "Version Odoo: $VER"
echo "Estado: $STATE"
echo "Configuracion: $CFG"
echo "Filtro de base: ${DBFILTER:-no definido}"
echo
echo "BASES DE DATOS DISPONIBLES"

for i in "${!VALID[@]}"; do
    printf '%d) %s\n' "$((i+1))" "${VALID[i]}"
done

choose "Selecciona la base de datos" "${#VALID[@]}"
DB="${VALID[REPLY-1]}"

confirm "Confirmas servicio $SERVICE y base $DB?"

echo
read -r -p "Nombre tecnico del modulo: " MODULE

[[ "$MODULE" =~ ^[A-Za-z][A-Za-z0-9_]*$ ]] ||
    die "Nombre tecnico invalido"

CURRENT_STATE=$(
    runuser -u "$OWNER" -- env PGPASSWORD="$PGPASSWORD" \
        psql -X "${PG[@]}" -d "$DB" -Atqc \
        "SELECT state FROM ir_module_module
         WHERE name='$MODULE' LIMIT 1" 2>/dev/null
) || die "No se pudo consultar el estado del modulo"

if [[ "$CURRENT_STATE" == installed ]]; then
    ACTION="update"
    echo "Operacion: ACTUALIZAR"
elif [[ -z "$CURRENT_STATE" || "$CURRENT_STATE" == uninstalled ]]; then
    ACTION="install"
    echo "Operacion: INSTALAR"
else
    die "Estado del modulo incompatible: $CURRENT_STATE"
fi

WORK=$(mktemp -d /tmp/ickab-module.XXXXXXXX)

echo
echo "ORIGEN DEL MODULO"
echo "1) GitHub ICKAB"
echo "2) Carpeta local"
choose "Selecciona el origen" 2

if ((REPLY == 1)); then
    curl -fsSL --max-time 60 \
        "https://api.github.com/repos/$REPO/contents/$VER?ref=main" \
        -o "$WORK/index.json" ||
        die "No se pudo consultar GitHub"

    mapfile -t PACKAGES < <(
        python3 - "$WORK/index.json" "$MODULE" "$VER" <<'PY'
import json, re, sys
with open(sys.argv[1], encoding='utf8') as f:
    items = json.load(f)
pattern = re.compile(
    re.escape(sys.argv[2]) + '_' +
    re.escape(sys.argv[3]) +
    r'\.[0-9]+(?:\.[0-9]+)*\.zip'
)
if isinstance(items, list):
    for item in items:
        name = item.get('name', '')
        if item.get('type') == 'file' and pattern.fullmatch(name):
            print(name)
PY
    )

    ((${#PACKAGES[@]} > 0)) ||
        die "No existen paquetes compatibles en GitHub"

    for i in "${!PACKAGES[@]}"; do
        printf '%d) %s\n' "$((i+1))" "${PACKAGES[i]}"
    done

    choose "Selecciona el paquete" "${#PACKAGES[@]}"
    ZIP="${PACKAGES[REPLY-1]}"

    curl -fLsS --max-time 300 \
        "https://raw.githubusercontent.com/$REPO/main/$VER/$ZIP" \
        -o "$WORK/module.zip" ||
        die "Error descargando el paquete"

    python3 - "$WORK/module.zip" "$WORK/source" "$MODULE" <<'PY'
import os, stat, sys, zipfile
archive, dest, module = sys.argv[1:]
with zipfile.ZipFile(archive) as z:
    entries = z.infolist()
    if not entries or len(entries) > 10000:
        sys.exit('ZIP invalido')
    if sum(e.file_size for e in entries) > 500 * 1024 * 1024:
        sys.exit('ZIP demasiado grande')
    for e in entries:
        name = e.filename
        parts = name.rstrip('/').split('/')
        kind = (e.external_attr >> 16) & 0o170000
        if (
            name.startswith('/') or
            '\\' in name or
            any(p in ('', '.', '..') for p in parts) or
            parts[0] != module or
            kind not in (0, stat.S_IFREG, stat.S_IFDIR)
        ):
            sys.exit('ZIP inseguro')
    os.mkdir(dest)
    z.extractall(dest)
PY

    SOURCE="$WORK/source/$MODULE"
else
    read -r -p "Ruta absoluta del modulo: " SOURCE
    [[ "$SOURCE" == /* && -d "$SOURCE" ]] ||
        die "Ruta local invalida"
    SOURCE=$(realpath "$SOURCE")
fi

[[ -f "$SOURCE/__manifest__.py" ]] ||
    die "No existe __manifest__.py"

[[ -z "$(find "$SOURCE" -type l -print -quit)" ]] ||
    die "El paquete contiene enlaces simbolicos"

NEW=$(manifest_version "$SOURCE/__manifest__.py") ||
    die "Manifiesto invalido"

[[ "$NEW" == "$VER."* ]] ||
    die "Version $NEW incompatible con Odoo $VER"

ADDONS=$(conf "$CFG" addons_path)
IFS=',' read -r -a PATHS <<< "$ADDONS"

declare -a EXIST=() CUSTOM=()

for path in "${PATHS[@]}"; do
    path="${path#"${path%%[![:space:]]*}"}"
    path="${path%"${path##*[![:space:]]}"}"

    [[ -d "$path" ]] || continue

    [[ -d "$path/$MODULE" ]] && EXIST+=("$path/$MODULE")

    if [[ "$path" != */odoo/addons &&
          "$path" != */enterprise ]]; then
        CUSTOM+=("$path")
    fi
done

if [[ "$ACTION" == update ]]; then
    ((${#EXIST[@]} == 1)) ||
        die "No se encontro una unica carpeta del modulo"

    DEST="${EXIST[0]}"
    OLDVER=$(manifest_version "$DEST/__manifest__.py") ||
        die "Manifiesto anterior invalido"

    [[ "$NEW" != "$OLDVER" ]] ||
        die "La version ya esta instalada"

    lowest=$(
        printf '%s\n%s\n' "$OLDVER" "$NEW" |
        sort -V | head -n 1
    )

    [[ "$lowest" == "$OLDVER" ]] ||
        die "Retroceso de version bloqueado"
else
    ((${#EXIST[@]} == 0)) ||
        die "Ya existe codigo del modulo; revisar antes de instalar"

    ((${#CUSTOM[@]} > 0)) ||
        die "No hay directorio de addons personalizados"

    echo
    echo "DIRECTORIOS DE INSTALACION"

    for i in "${!CUSTOM[@]}"; do
        printf '%d) %s\n' "$((i+1))" "${CUSTOM[i]}"
    done

    choose "Selecciona directorio" "${#CUSTOM[@]}"
    DEST="${CUSTOM[REPLY-1]}/$MODULE"
    OLDVER="no instalado"
fi

[[ ! -L "$DEST" ]] || die "Destino simbolico no permitido"

declare -a SHARED=()

while IFS= read -r other; do
    [[ "$other" == "$SERVICE" || "$other" != *odoo*.service ]] &&
        continue

    raw=$(systemctl show "$other" -p ExecStart --value 2>/dev/null || true)
    mapfile -t op < <(parse_unit "$raw" 2>/dev/null || true)

    ((${#op[@]} == 3)) || continue
    [[ -f "${op[1]}" ]] || continue

    otherpaths=$(conf "${op[1]}" addons_path 2>/dev/null || true)
    IFS=',' read -r -a OTHER_PATHS <<< "$otherpaths"

    for path in "${OTHER_PATHS[@]}"; do
        path="${path#"${path%%[![:space:]]*}"}"
        path="${path%"${path##*[![:space:]]}"}"

        [[ "$DEST" == "$path/$MODULE" ]] && SHARED+=("$other")
    done
done < <(
    systemctl list-unit-files --type=service --no-legend --no-pager |
    awk '{print $1}' | sort -u
)

if ((${#SHARED[@]})); then
    echo
    echo "ADVERTENCIA: CODIGO COMPARTIDO CON:"
    printf ' - %s\n' "${SHARED[@]}"
    confirm "Autorizas modificar codigo compartido?"
fi

DATA=$(conf "$CFG" data_dir)

if [[ -z "$DATA" ]]; then
    HOMEOWNER=$(getent passwd "$OWNER" | cut -d: -f6)
    DATA="$HOMEOWNER/.local/share/Odoo"
fi

FILESTORE="$DATA/filestore/$DB"
[[ -d "$FILESTORE" ]] ||
    die "No existe filestore: $FILESTORE"

WAS_ACTIVE=0
[[ "$STATE" == active ]] && WAS_ACTIVE=1

echo
echo "=========================================================="
echo "                RESUMEN DE OPERACION"
echo "=========================================================="
echo "Servicio:       $SERVICE"
echo "Base de datos:  $DB"
echo "Odoo:           $VER"
echo "Modulo:         $MODULE"
echo "Operacion:      $ACTION"
echo "Version actual: $OLDVER"
echo "Version nueva:  $NEW"
echo "Destino:        $DEST"
echo "Estado inicial: $STATE"
echo "Respaldo:       OBLIGATORIO"
echo "=========================================================="
echo

confirm "Autorizas respaldo e instalacion/actualizacion?"

mkdir -p "$ROOT"

exec {LOCK}>"/run/lock/ickab-${SERVICE%.service}.lock"
flock -n "$LOCK" || die "Existe otra operacion en curso"

BACKUP="$ROOT/${SERVICE%.service}/${DB}/${MODULE}_$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$BACKUP"

if ((WAS_ACTIVE)); then
    systemctl stop "$SERVICE" ||
        die "No se pudo detener el servicio"
    STOPPED=1
fi

echo "Respaldando PostgreSQL..."

runuser -u "$OWNER" -- env PGPASSWORD="$PGPASSWORD" \
    pg_dump -Fc "${PG[@]}" -d "$DB" \
    > "$BACKUP/database.dump" ||
    die "Fallo el respaldo PostgreSQL"

[[ -s "$BACKUP/database.dump" ]] ||
    die "El respaldo PostgreSQL esta vacio"

echo "Respaldando filestore..."

tar -C "$(dirname "$FILESTORE")" \
    -czf "$BACKUP/filestore.tar.gz" \
    "$(basename "$FILESTORE")" ||
    die "Fallo el respaldo filestore"

if [[ "$ACTION" == update ]]; then
    echo "Respaldando codigo..."

    tar -C "$(dirname "$DEST")" \
        -czf "$BACKUP/code.tar.gz" "$MODULE" ||
        die "Fallo el respaldo del modulo"
fi

(
    cd "$BACKUP"
    sha256sum database.dump filestore.tar.gz \
        > SHA256SUMS
    if [[ -f code.tar.gz ]]; then
        sha256sum code.tar.gz >> SHA256SUMS
    fi
)

STAGE=$(mktemp -d "$(dirname "$DEST")/.ickab-${MODULE}.XXXXXXXX")

cp -a "$SOURCE/." "$STAGE/" ||
    die "No se pudo preparar el codigo"

chown -R "$OWNER:$(id -gn "$OWNER")" "$STAGE"

PREVIOUS=""

if [[ "$ACTION" == update ]]; then
    PREVIOUS="$(dirname "$DEST")/.ickab-${MODULE}.previous-$$"
    mv "$DEST" "$PREVIOUS" ||
        die "No se pudo retirar el codigo anterior"
fi

if ! mv "$STAGE" "$DEST"; then
    [[ -z "$PREVIOUS" ]] || mv "$PREVIOUS" "$DEST"
    die "No se pudo instalar el nuevo codigo"
fi

FLAG="-i"
[[ "$ACTION" == update ]] && FLAG="-u"

printf '%s %s %s %s %s %s -> %s\n' \
    "$(date -u +%FT%TZ)" \
    "$SERVICE" "$DB" "$MODULE" "$ACTION" "$OLDVER" "$NEW" \
    > "$BACKUP/operation.log"

echo "Ejecutando Odoo..."

if ! runuser -u "$OWNER" -- \
    "$PY" "$BIN" \
    -c "$CFG" \
    -d "$DB" \
    "$FLAG" "$MODULE" \
    --stop-after-init \
    --no-http \
    --workers=0 \
    --max-cron-threads=0 \
    > "$BACKUP/odoo.log" 2>&1; then

    echo "ERROR: Odoo no completo la operacion." |
        tee -a "$BACKUP/operation.log"

    die "Consultar $BACKUP/odoo.log. No restaurar BD automaticamente."
fi

FINALSTATE=$(
    runuser -u "$OWNER" -- env PGPASSWORD="$PGPASSWORD" \
        psql -X "${PG[@]}" -d "$DB" -Atqc \
        "SELECT state FROM ir_module_module
         WHERE name='$MODULE' LIMIT 1" 2>/dev/null || true
)

[[ "$FINALSTATE" == installed ]] ||
    die "Estado final inesperado: $FINALSTATE"

if ((WAS_ACTIVE)); then
    systemctl start "$SERVICE" ||
        die "No se pudo iniciar el servicio"

    systemctl is-active --quiet "$SERVICE" ||
        die "El servicio no quedo activo"

    STOPPED=0
fi

if [[ -n "$PREVIOUS" ]]; then
    mv "$PREVIOUS" "$BACKUP/previous-code"
fi

echo "OK" >> "$BACKUP/operation.log"

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
