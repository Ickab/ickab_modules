#!/usr/bin/env bash
# ICKAB Module Manager 1.0
# Instalacion y actualizacion de modulos Odoo
set -Eeuo pipefail
umask 077

REPO="Ickab/ickab_modules"
BRANCH="main"
BACKUP_ROOT="/var/backups/ickab-module-manager"

WORK=""
BACKUP=""
SERVICE=""
STOPPED=0
MODIFIED=0
PREVIOUS=""
DEST=""
INITIAL_STATE=""

error() {
    printf '\nERROR: %s\n' "$*" >&2
    exit 1
}

confirm() {
    local answer
    read -r -p "$1 [escribe SI]: " answer ||
        error "Operacion cancelada"
    [[ "$answer" == "SI" ]] ||
        error "Operacion cancelada"
}

choose() {
    local answer
    while true; do
        read -r -p "$1 [1-$2]: " answer ||
            error "Seleccion cancelada"
        if [[ "$answer" =~ ^[0-9]+$ ]] &&
           ((10#$answer >= 1 && 10#$answer <= $2)); then
            REPLY=$((10#$answer))
            return
        fi
        echo "Seleccion invalida"
    done
}

log() {
    printf '%s | %s\n' "$(date -u +%FT%TZ)" "$*" |
        tee -a "${BACKUP}/operation.log"
}

cleanup() {
    local rc=$?
    trap - EXIT

    if (( rc != 0 )) && [[ -n "$BACKUP" ]]; then
        printf '%s | ERROR | exit=%s\n' \
            "$(date -u +%FT%TZ)" "$rc" \
            >> "$BACKUP/operation.log" || true
    fi

    if (( MODIFIED && rc != 0 )); then
        echo
        echo "ATENCION: la operacion fallo despues de cambiar archivos."
        echo "No se restaurara automaticamente la base de datos."
        echo "Respaldo: $BACKUP"
        echo "Codigo anterior: ${PREVIOUS:-no aplica}"
    fi

    if (( STOPPED )); then
        echo "El servicio $SERVICE permanece detenido."
    fi

    [[ -z "$WORK" ]] || rm -rf -- "$WORK"
    exit "$rc"
}
trap cleanup EXIT

[[ "$EUID" -eq 0 ]] ||
    error "Debes ejecutar el programa con sudo"

for cmd in systemctl python3 psql pg_dump pg_restore \
           runuser tar curl flock sha256sum realpath; do
    command -v "$cmd" >/dev/null ||
        error "Dependencia faltante: $cmd"
done

# Extrae ejecutable, configuracion y Python del servicio.
parse_unit() {
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
    (i for i, x in enumerate(args)
     if x.endswith('/odoo-bin')),
    None
)

if index is None:
    sys.exit(1)

binary = args[index]
cfg = ''

for i, value in enumerate(args):
    if value in ('-c', '--config') and i + 1 < len(args):
        cfg = args[i + 1]
    elif value.startswith('--config='):
        cfg = value.split('=', 1)[1]

python = (
    args[index - 1]
    if index > 0 and args[index - 1].startswith('/')
    else '/usr/bin/python3'
)

print(binary)
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

# Lee la version sin ejecutar Odoo.
odoo_version() {
    python3 - "$1" <<'PY_VERSION'
import ast
import pathlib
import re
import sys

binary = pathlib.Path(sys.argv[1]).resolve()

candidates = [
    binary.parent / 'odoo' / 'release.py',
    binary.parent / 'release.py',
    binary.parent.parent / 'odoo' / 'release.py'
]

for file in candidates:
    if not file.is_file():
        continue

    text = file.read_text(encoding='utf-8', errors='replace')

    match = re.search(
        r'^version_info\s*=\s*\(\s*(\d+)\s*,\s*(\d+)',
        text,
        re.M
    )

    if match:
        print(f'{match.group(1)}.{match.group(2)}')
        sys.exit(0)

sys.exit(1)
PY_VERSION
}

manifest_info() {
    python3 - "$1" <<'PY_MANIFEST'
import ast
import sys

with open(sys.argv[1], encoding='utf-8') as file:
    data = ast.literal_eval(file.read())

if not isinstance(data, dict):
    sys.exit(1)

version = data.get('version', '')
depends = data.get('depends', [])

if not isinstance(version, str):
    sys.exit(1)

if not isinstance(depends, list):
    sys.exit(1)

if not all(isinstance(x, str) for x in depends):
    sys.exit(1)

print(version)
print(','.join(depends))
PY_MANIFEST
}

pg() {
    runuser -u "$OWNER" -- \
        env PGPASSWORD="$PGPASSWORD" \
        psql -X -v ON_ERROR_STOP=1 "${PG_ARGS[@]}" "$@"
}

echo
echo "=========================================================="
echo "              ICKAB MODULE MANAGER 1.0"
echo "=========================================================="
echo "Detectando servicios Odoo..."
echo

declare -a UNITS=()
declare -a CONFIGS=()
declare -a BINARIES=()
declare -a PYTHONS=()
declare -a OWNERS=()
declare -a STATES=()
declare -a VERSIONS=()

while IFS= read -r unit; do
    [[ "$unit" == *odoo*.service ]] || continue

    raw="$(
        systemctl show "$unit" -p ExecStart --value 2>/dev/null ||
        true
    )"

    [[ "$raw" == *odoo-bin* ]] || continue

    mapfile -t parts < <(
        parse_unit "$raw" 2>/dev/null || true
    )

    ((${#parts[@]} == 3)) || continue

    binary="${parts[0]}"
    cfg="${parts[1]}"
    py="${parts[2]}"

    [[ -f "$binary" && -f "$cfg" && -x "$py" ]] ||
        continue

    owner="$(
        systemctl show "$unit" -p User --value
    )"

    [[ -n "$owner" ]] || continue

    version="$(odoo_version "$binary" 2>/dev/null || true)"
    [[ "$version" =~ ^[0-9]+\.[0-9]+$ ]] || continue

    UNITS+=("$unit")
    CONFIGS+=("$cfg")
    BINARIES+=("$binary")
    PYTHONS+=("$py")
    OWNERS+=("$owner")
    STATES+=("$(systemctl is-active "$unit" || true)")
    VERSIONS+=("$version")

done < <(
    systemctl list-unit-files \
        --type=service --no-legend --no-pager |
        awk '{print $1}' | sort -u
)

((${#UNITS[@]} > 0)) ||
    error "No se detectaron servicios Odoo compatibles"

printf '%-4s %-38s %-9s %-12s\n' \
    "N" "SERVICIO" "ODOO" "ESTADO"

for i in "${!UNITS[@]}"; do
    printf '%-4s %-38s %-9s %-12s\n' \
        "$((i+1))" "${UNITS[i]}" \
        "${VERSIONS[i]}" "${STATES[i]}"
done

echo
choose "Selecciona la instancia" "${#UNITS[@]}"
idx=$((REPLY-1))

SERVICE="${UNITS[idx]}"
CFG="${CONFIGS[idx]}"
BIN="${BINARIES[idx]}"
PY="${PYTHONS[idx]}"
OWNER="${OWNERS[idx]}"
INITIAL_STATE="${STATES[idx]}"
VERSION="${VERSIONS[idx]}"

[[ "$INITIAL_STATE" == active ||
   "$INITIAL_STATE" == inactive ]] ||
    error "El servicio presenta un estado incompatible"

echo
echo "INSTANCIA"
echo "Servicio:      $SERVICE"
echo "Version:       $VERSION"
echo "Estado:        $INITIAL_STATE"
echo "Configuracion: $CFG"
echo "Usuario:       $OWNER"

confirm "Confirmas la instancia?"

DBNAME="$(conf "$CFG" db_name)"
DBFILTER="$(conf "$CFG" dbfilter)"
DBHOST="$(conf "$CFG" db_host)"
DBPORT="$(conf "$CFG" db_port)"
DBUSER="$(conf "$CFG" db_user)"
DBPASS="$(conf "$CFG" db_password)"

PG_ARGS=()

if [[ -n "$DBHOST" && "${DBHOST,,}" != false ]]; then
    PG_ARGS+=(-h "$DBHOST")
fi

if [[ -n "$DBPORT" && "${DBPORT,,}" != false ]]; then
    PG_ARGS+=(-p "$DBPORT")
fi

if [[ -n "$DBUSER" && "${DBUSER,,}" != false ]]; then
    PG_ARGS+=(-U "$DBUSER")
fi

PGPASSWORD=""
if [[ -n "$DBPASS" && "${DBPASS,,}" != false ]]; then
    PGPASSWORD="$DBPASS"
fi

# Primero se consulta PostgreSQL.
# No se supone que el nombre del servicio sea el nombre de la BD.
mapfile -t ALL_DBS < <(
    pg -d postgres -Atqc \
        "SELECT datname FROM pg_database
         WHERE datallowconn AND NOT datistemplate
         ORDER BY datname" 2>/dev/null || true
)

((${#ALL_DBS[@]} > 0)) ||
    error "No se pudieron consultar las bases de PostgreSQL"

# db_name puede contener una o varias bases.
declare -a REQUESTED=()
if [[ -n "$DBNAME" && "${DBNAME,,}" != false ]]; then
    IFS=',' read -r -a REQUESTED <<< "$DBNAME"
fi

declare -a VALID_DBS=()

for db in "${ALL_DBS[@]}"; do
    [[ "$db" =~ ^[A-Za-z0-9_]+$ ]] || continue

    if ((${#REQUESTED[@]})); then
        allowed=0
        for item in "${REQUESTED[@]}"; do
            item="${item//[[:space:]]/}"
            [[ "$item" == "$db" ]] && allowed=1
        done
        ((allowed)) || continue
    fi

    # Se verifica que sea una BD Odoo.
    exists="$(
        pg -d "$db" -Atqc \
            "SELECT to_regclass('public.ir_module_module')
                    IS NOT NULL" 2>/dev/null || true
    )"

    [[ "$exists" == t ]] || continue

    VALID_DBS+=("$db")
done

((${#VALID_DBS[@]} > 0)) ||
    error "No se encontraron bases Odoo accesibles"

echo
echo "BASES DE DATOS ODOO"
for i in "${!VALID_DBS[@]}"; do
    printf '%d) %s\n' "$((i+1))" "${VALID_DBS[i]}"
done

choose "Selecciona la base de datos" "${#VALID_DBS[@]}"
DB="${VALID_DBS[REPLY-1]}"

echo
echo "Base seleccionada: $DB"
echo "dbfilter configurado: ${DBFILTER:-ninguno}"
confirm "Confirmas la base de datos?"

read -r -p "Nombre tecnico del modulo: " MODULE

[[ "$MODULE" =~ ^[A-Za-z][A-Za-z0-9_]*$ ]] ||
    error "Nombre tecnico invalido"

CURRENT_STATE="$(
    pg -d "$DB" -Atqc \
        "SELECT state FROM ir_module_module
         WHERE name='$MODULE' LIMIT 1"
)" || error "No se pudo consultar el modulo"

case "$CURRENT_STATE" in
    installed)
        ACTION="update"
        ;;
    ""|uninstalled)
        ACTION="install"
        ;;
    *)
        error "Estado del modulo no permitido: $CURRENT_STATE"
        ;;
esac

echo
echo "Operacion detectada: $ACTION"

WORK="$(mktemp -d /tmp/ickab-module.XXXXXXXX)"

echo
echo "ORIGEN DEL MODULO"
echo "1) GitHub ICKAB"
echo "2) Carpeta local"
choose "Selecciona el origen" 2

if ((REPLY == 1)); then
    curl -fsSL --max-time 60 \
        "https://api.github.com/repos/$REPO/contents/$VERSION?ref=$BRANCH" \
        -o "$WORK/index.json" ||
        error "No se pudo consultar GitHub"

    mapfile -t PACKAGES < <(
        python3 - "$WORK/index.json" "$MODULE" "$VERSION" <<'PY_PACKAGES'
import json
import re
import sys

with open(sys.argv[1], encoding='utf-8') as file:
    items = json.load(file)

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
PY_PACKAGES
    )

    ((${#PACKAGES[@]} > 0)) ||
        error "No hay paquetes compatibles en GitHub"

    echo
    for i in "${!PACKAGES[@]}"; do
        printf '%d) %s\n' "$((i+1))" "${PACKAGES[i]}"
    done

    choose "Selecciona el paquete" "${#PACKAGES[@]}"
    PACKAGE="${PACKAGES[REPLY-1]}"

    curl -fLsS --max-time 300 \
        "https://raw.githubusercontent.com/$REPO/$BRANCH/$VERSION/$PACKAGE" \
        -o "$WORK/package.zip" ||
        error "No se pudo descargar el paquete"

    python3 - "$WORK/package.zip" "$WORK/source" "$MODULE" <<'PY_ZIP'
import os
import stat
import sys
import zipfile

archive, destination, module = sys.argv[1:]

with zipfile.ZipFile(archive) as z:
    entries = z.infolist()

    if not entries or len(entries) > 10000:
        sys.exit('ZIP invalido')

    total = sum(x.file_size for x in entries)

    if total > 500 * 1024 * 1024:
        sys.exit('ZIP demasiado grande')

    seen = set()

    for entry in entries:
        name = entry.filename
        parts = name.rstrip('/').split('/')
        kind = (entry.external_attr >> 16) & 0o170000

        if (
            name.startswith('/') or
            '\\' in name or
            any(p in ('', '.', '..') for p in parts) or
            parts[0] != module or
            kind not in (0, stat.S_IFREG, stat.S_IFDIR) or
            name in seen
        ):
            sys.exit('ZIP inseguro')

        seen.add(name)

    os.makedirs(destination)
    z.extractall(destination)
PY_ZIP

    SOURCE="$WORK/source/$MODULE"
else
    read -r -p "Ruta absoluta del modulo: " SOURCE

    [[ "$SOURCE" == /* && -d "$SOURCE" ]] ||
        error "Ruta local invalida"

    SOURCE="$(realpath "$SOURCE")"
fi

[[ -f "$SOURCE/__manifest__.py" ]] ||
    error "No se encontro __manifest__.py"

[[ -z "$(find "$SOURCE" -type l -print -quit)" ]] ||
    error "El modulo contiene enlaces simbolicos"

mapfile -t INFO < <(
    manifest_info "$SOURCE/__manifest__.py"
)

((${#INFO[@]} == 2)) ||
    error "No se pudo interpretar el manifiesto"

NEW_VERSION="${INFO[0]}"
DEPENDENCIES="${INFO[1]}"

[[ "$NEW_VERSION" == "$VERSION."* ]] ||
    error "Version incompatible: $NEW_VERSION / Odoo $VERSION"

ADDONS="$(conf "$CFG" addons_path)"
IFS=',' read -r -a PATHS <<< "$ADDONS"

declare -a EXISTING=()
declare -a CUSTOM=()

for path in "${PATHS[@]}"; do
    path="${path#"${path%%[![:space:]]*}"}"
    path="${path%"${path##*[![:space:]]}"}"

    [[ -d "$path" ]] || continue

    path="$(realpath "$path")"

    [[ -d "$path/$MODULE" ]] &&
        EXISTING+=("$path/$MODULE")

    case "$path" in
        */odoo/addons|*/enterprise)
            ;;
        *)
            CUSTOM+=("$path")
            ;;
    esac
done

if [[ "$ACTION" == update ]]; then
    ((${#EXISTING[@]} == 1)) ||
        error "No existe una ruta unica del modulo instalado"

    DEST="${EXISTING[0]}"

    mapfile -t OLD_INFO < <(
        manifest_info "$DEST/__manifest__.py"
    )

    OLD_VERSION="${OLD_INFO[0]:-}"

    [[ -n "$OLD_VERSION" ]] ||
        error "No se pudo leer la version instalada"

    [[ "$NEW_VERSION" != "$OLD_VERSION" ]] ||
        error "La version ya esta instalada"

    first="$(
        printf '%s\n%s\n' "$OLD_VERSION" "$NEW_VERSION" |
        sort -V | head -n 1
    )"

    [[ "$first" == "$OLD_VERSION" ]] ||
        error "No se permiten retrocesos de version"
else
    ((${#EXISTING[@]} == 0)) ||
        error "El codigo ya existe; revisar el estado del modulo"

    ((${#CUSTOM[@]} > 0)) ||
        error "No se encontraron rutas de addons personalizados"

    echo
    echo "DESTINOS DISPONIBLES"

    for i in "${!CUSTOM[@]}"; do
        printf '%d) %s\n' "$((i+1))" "${CUSTOM[i]}"
    done

    choose "Selecciona el destino" "${#CUSTOM[@]}"
    DEST="${CUSTOM[REPLY-1]}/$MODULE"
    OLD_VERSION="no instalado"
fi

[[ ! -L "$DEST" ]] ||
    error "El destino es un enlace simbolico"

# Verificar dependencias Odoo ya instaladas.
if [[ -n "$DEPENDENCIES" ]]; then
    IFS=',' read -r -a DEPS <<< "$DEPENDENCIES"

    for dep in "${DEPS[@]}"; do
        [[ "$dep" =~ ^[A-Za-z][A-Za-z0-9_]*$ ]] ||
            error "Dependencia invalida: $dep"

        [[ "$dep" == "$MODULE" ]] && continue

        depstate="$(
            pg -d "$DB" -Atqc \
                "SELECT state FROM ir_module_module
                 WHERE name='$dep' LIMIT 1"
        )"

        [[ "$depstate" == installed ]] ||
            error "Dependencia Odoo no instalada: $dep"
    done
fi

# Verificar uso compartido entre servicios systemd.
declare -a SHARED=()
declare -a SHARED_ACTIVE=()

while IFS= read -r other; do
    [[ "$other" == "$SERVICE" ]] && continue
    [[ "$other" == *odoo*.service ]] || continue

    raw="$(
        systemctl show "$other" -p ExecStart --value 2>/dev/null ||
        true
    )"

    mapfile -t otherparts < <(
        parse_unit "$raw" 2>/dev/null || true
    )

    ((${#otherparts[@]} == 3)) || continue
    [[ -f "${otherparts[1]}" ]] || continue

    otheraddons="$(
        conf "${otherparts[1]}" addons_path 2>/dev/null || true
    )"

    IFS=',' read -r -a OTHER_PATHS <<< "$otheraddons"

    for path in "${OTHER_PATHS[@]}"; do
        path="${path#"${path%%[![:space:]]*}"}"
        path="${path%"${path##*[![:space:]]}"}"

        [[ -d "$path" ]] || continue

        path="$(realpath "$path")"

        if [[ "$DEST" == "$path/$MODULE" ]]; then
            SHARED+=("$other")

            if systemctl is-active --quiet "$other"; then
                SHARED_ACTIVE+=("$other")
            fi
        fi
    done
done < <(
    systemctl list-unit-files \
        --type=service --no-legend --no-pager |
        awk '{print $1}' | sort -u
)

if ((${#SHARED_ACTIVE[@]})); then
    echo
    echo "INSTANCIAS ACTIVAS QUE COMPARTEN CODIGO:"
    printf ' - %s\n' "${SHARED_ACTIVE[@]}"
    error "No se modificara codigo utilizado por otras instancias activas"
fi

if ((${#SHARED[@]})); then
    echo
    echo "Instancias detenidas que comparten el codigo:"
    printf ' - %s\n' "${SHARED[@]}"
    confirm "Autorizas continuar con este codigo compartido?"
fi

DATA_DIR="$(conf "$CFG" data_dir)"

if [[ -z "$DATA_DIR" ]]; then
    USER_HOME="$(getent passwd "$OWNER" | cut -d: -f6)"
    DATA_DIR="$USER_HOME/.local/share/Odoo"
fi

FILESTORE="$DATA_DIR/filestore/$DB"

echo
echo "=========================================================="
echo "                RESUMEN DE OPERACION"
echo "=========================================================="
echo "Servicio:        $SERVICE"
echo "Base de datos:   $DB"
echo "Odoo:            $VERSION"
echo "Modulo:          $MODULE"
echo "Operacion:       $ACTION"
echo "Version actual:  $OLD_VERSION"
echo "Version nueva:   $NEW_VERSION"
echo "Destino:         $DEST"
echo "Estado inicial:  $INITIAL_STATE"
echo "Filestore:       $FILESTORE"
echo "Respaldo:        OBLIGATORIO"
echo "=========================================================="

confirm "Autorizas ejecutar esta operacion?"

mkdir -p "$BACKUP_ROOT"

# Bloqueo global: una operacion de mantenimiento por servidor.
exec {LOCK}>/run/lock/ickab-module-manager.lock

flock -n "$LOCK" ||
    error "Otra operacion ICKAB Module Manager esta en curso"

BACKUP="$BACKUP_ROOT/${SERVICE%.service}/${DB}/${MODULE}_$(date -u +%Y%m%dT%H%M%SZ)"

mkdir -p "$BACKUP"

log "INICIO servicio=$SERVICE base=$DB modulo=$MODULE accion=$ACTION"
log "VERSION anterior=$OLD_VERSION nueva=$NEW_VERSION"

# Detener antes del respaldo para evitar escrituras Odoo
# concurrentes durante la copia de PostgreSQL y filestore.
if [[ "$INITIAL_STATE" == active ]]; then
    log "Deteniendo servicio $SERVICE"

    systemctl stop "$SERVICE" ||
        error "No se pudo detener el servicio"

    STOPPED=1

    systemctl is-active --quiet "$SERVICE" &&
        error "El servicio continua activo"
fi

log "Creando respaldo PostgreSQL"

runuser -u "$OWNER" -- \
    env PGPASSWORD="$PGPASSWORD" \
    pg_dump -Fc "${PG_ARGS[@]}" -d "$DB" \
    > "$BACKUP/database.dump" ||
    error "Fallo el respaldo PostgreSQL"

[[ -s "$BACKUP/database.dump" ]] ||
    error "El respaldo de PostgreSQL esta vacio"

pg_restore -l "$BACKUP/database.dump" \
    > "$BACKUP/database.contents" ||
    error "No se pudo verificar el dump PostgreSQL"

log "Respaldando filestore"

if [[ -d "$FILESTORE" ]]; then
    tar -C "$(dirname "$FILESTORE")" \
        -czf "$BACKUP/filestore.tar.gz" \
        "$(basename "$FILESTORE")" ||
        error "Fallo el respaldo filestore"
else
    log "AVISO: no existe filestore; se registra su ausencia"
    printf 'Filestore ausente: %s\n' "$FILESTORE" \
        > "$BACKUP/filestore-absent.txt"
fi

if [[ "$ACTION" == update ]]; then
    log "Respaldando codigo anterior"

    tar -C "$(dirname "$DEST")" \
        -czf "$BACKUP/code.tar.gz" "$MODULE" ||
        error "Fallo el respaldo de codigo"
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
) || error "No se pudo verificar el respaldo"

log "Respaldo completo: $BACKUP"

# Preparar codigo en el mismo sistema de archivos.
STAGE="$(
    mktemp -d "$(dirname "$DEST")/.ickab-${MODULE}.XXXXXXXX"
)"

cp -a "$SOURCE/." "$STAGE/" ||
    error "No se pudo preparar el codigo nuevo"

chown -R "$OWNER:$(id -gn "$OWNER")" "$STAGE"

if [[ "$ACTION" == update ]]; then
    PREVIOUS="$(dirname "$DEST")/.ickab-${MODULE}.previous-$$"

    mv "$DEST" "$PREVIOUS" ||
        error "No se pudo retirar el codigo anterior"
fi

if ! mv "$STAGE" "$DEST"; then
    if [[ -n "$PREVIOUS" ]]; then
        mv "$PREVIOUS" "$DEST" || true
    fi
    error "No se pudo colocar el codigo nuevo"
fi

MODIFIED=1

FLAG="-i"
[[ "$ACTION" == update ]] && FLAG="-u"

log "Ejecutando Odoo: $ACTION $MODULE"

# Usar el Python, binario y configuracion de la instancia.
# La contraseña PG se transmite por entorno, no por argumentos.
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

    log "FALLO: Odoo no completo la operacion"
    error "Revisar $BACKUP/odoo.log"
fi

FINAL_STATE="$(
    pg -d "$DB" -Atqc \
        "SELECT state FROM ir_module_module
         WHERE name='$MODULE' LIMIT 1"
)" || error "No se pudo verificar el estado final"

[[ "$FINAL_STATE" == installed ]] ||
    error "Estado final inesperado: $FINAL_STATE"

log "Modulo confirmado como instalado"

if [[ "$INITIAL_STATE" == active ]]; then
    log "Iniciando servicio $SERVICE"

    systemctl start "$SERVICE" ||
        error "No se pudo iniciar el servicio"

    systemctl is-active --quiet "$SERVICE" ||
        error "El servicio no quedo activo"

    STOPPED=0
fi

if [[ -n "$PREVIOUS" ]]; then
    mv "$PREVIOUS" "$BACKUP/previous-code" ||
        error "No se pudo conservar el codigo anterior"
fi

MODIFIED=0

log "OPERACION COMPLETADA"

echo
echo "=========================================================="
echo "                 OPERACION FINALIZADA"
echo "=========================================================="
echo "Servicio:   $SERVICE"
echo "Base:       $DB"
echo "Modulo:     $MODULE"
echo "Operacion:  $ACTION"
echo "Version:    $NEW_VERSION"
echo "Respaldo:   $BACKUP"
echo "=========================================================="
