#!/usr/bin/env bash
# ICKAB Module Manager v2.2.0
# Odoo 18 - Instalacion y actualizacion de modulos
set -Eeuo pipefail
umask 077

VERSION_MANAGER="2.2.1"

BASE="${ICKAB_ODOO_BASE:-/opt/odoo18}"
REPO="${ICKAB_GITHUB_REPO:-Ickab/ickab_modules}"
BRANCH="${ICKAB_GITHUB_BRANCH:-main}"
SOURCE_INSTANCE="${ICKAB_SOURCE_INSTANCE:-demo}"
BACKUP_ROOT="${ICKAB_BACKUP_ROOT:-/opt/odoo18/module-backups}"
LOG_ROOT="${ICKAB_LOG_ROOT:-/var/log/ickab-updates}"

INSTANCE=""
MODULE=""
MODE=""
VERSION=""
INSTALLED_VERSION=""
DISK_VERSION=""
DB=""
CFG=""
SERVICE=""
USERNAME=""
USERGROUP=""
DEST=""
SRC=""
WORK=""
LOG=""
ODOO_LOG=""
ACTION=""
SERVICE_STOPPED=0
CHANGES_STARTED=0
LOCK_FD=""
BACKUP_DIR=""

die() {
    printf '\nERROR: %s\n' "$*" >&2
    exit 1
}

say() {
    printf '%s\n' "$*"
}

cleanup() {
    local rc=$?
    trap - EXIT

    if (( rc != 0 && SERVICE_STOPPED )); then
        if (( CHANGES_STARTED == 0 )); then
            say ""
            say "Intentando restablecer $SERVICE..."

            if systemctl start "$SERVICE" &&
               systemctl is-active --quiet "$SERVICE"; then
                say "Servicio restablecido."
                SERVICE_STOPPED=0
            else
                say "ALERTA: No se pudo restablecer $SERVICE."
            fi
        else
            say ""
            say "ALERTA: La operacion no termino correctamente."
            say "El codigo o la base de datos pudieron cambiar."
            say "No se intentara una restauracion automatica."
            say "Revisar logs y respaldos antes de intervenir."
        fi
    fi

    if [[ -n "$WORK" && -d "$WORK" ]]; then
        rm -rf -- "$WORK"
    fi

    exit "$rc"
}

trap cleanup EXIT
trap 'echo "Fallo en linea $LINENO: $BASH_COMMAND" >&2' ERR

ask_sn() {
    local prompt="$1"
    local answer

    while true; do
        read -r -p "$prompt [S/N]: " answer ||
            die "Entrada interrumpida"

        case "${answer^^}" in
            S|N)
                REPLY="${answer^^}"
                return 0
                ;;
        esac

        say "Escribe S o N."
    done
}

ask_name() {
    local prompt="$1"
    local answer

    while true; do
        read -r -p "$prompt: " answer ||
            die "Entrada interrumpida"

        if [[ "$answer" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]]; then
            REPLY="$answer"
            return 0
        fi

        say "Utiliza el nombre tecnico, sin espacios."
    done
}

config_value() {
    python3 - "$CFG" "$1" <<'PY'
import configparser
import sys

cfg = configparser.ConfigParser(
    interpolation=None,
    strict=False
)

if not cfg.read(sys.argv[1]):
    raise SystemExit("No se pudo leer configuracion")

print(cfg.get(
    "options",
    sys.argv[2],
    fallback=""
).strip())
PY
}

manifest_version() {
    python3 - "$1" <<'PY'
import ast
import sys

with open(sys.argv[1], encoding="utf-8") as f:
    data = ast.literal_eval(f.read())

if not isinstance(data, dict):
    raise SystemExit("Manifiesto invalido")

version = str(data.get("version", ""))

if not version:
    raise SystemExit("Manifiesto sin version")

print(version)
PY
}

validate_version() {
    python3 - "$1" <<'PY'
import re
import sys

v = sys.argv[1]

if not re.fullmatch(r"18\.0(?:\.\d+)+", v):
    raise SystemExit("Version incompatible con Odoo 18: " + v)
PY
}

compare_versions() {
    python3 - "$VERSION" "$INSTALLED_VERSION" "$DISK_VERSION" <<'PY'
import re
import sys

new, installed, disk = sys.argv[1:]

def parse(v):
    if not re.fullmatch(r"18\.0(?:\.\d+)+", v):
        return None
    return tuple(map(int, v.split(".")))

def normalized(v, length):
    return v + (0,) * (length - len(v))

new_v = parse(new)

if new_v is None:
    raise SystemExit("Version nueva invalida")

for label, current in (
    ("base de datos", installed),
    ("directorio del modulo", disk),
):
    old_v = parse(current)

    if old_v is None:
        if current and current not in ("No existe",):
            print(
                "ADVERTENCIA: No se pudo comparar "
                f"la version de {label}: {current}"
            )
        continue

    size = max(len(new_v), len(old_v))

    if normalized(new_v, size) < normalized(old_v, size):
        raise SystemExit(
            f"Actualizacion descendente bloqueada: "
            f"{label}={current}, nueva={new}"
        )

print("Comparacion de versiones: OK")
PY
}

check_dependencies() {
    local cmd

    for cmd in \
        python3 curl rsync tar pg_dump pg_restore \
        psql systemctl flock sudo sha256sum \
        realpath tee mktemp find grep getent
    do
        command -v "$cmd" >/dev/null 2>&1 ||
            die "Dependencia faltante: $cmd"
    done
}


detect_database() {
    local named filter exists

    named="$(config_value db_name)"
    filter="$(config_value dbfilter)"

    if [[ "$named" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        DB="$named"
    elif [[ "$filter" =~ ^\^([a-zA-Z0-9_-]+)\$$ ]]; then
        DB="${BASH_REMATCH[1]}"
    else
        die "No se identificó una base de datos única"
    fi

    exists="$(sudo -u postgres psql -X -At \
        -v db="$DB" postgres <<'SQL'
SELECT 1 FROM pg_database WHERE datname = :'db';
SQL
)" || die "Falló la consulta PostgreSQL"

    [[ "$exists" == 1 ]] ||
        die "La base de datos $DB no existe"
}


check_paths() {
    local addons path found=0
    local -a paths

    addons="$(config_value addons_path)"

    [[ -n "$addons" ]] ||
        die "addons_path no configurado"

    DEST="$BASE/$INSTANCE/extra-addons/extras/$MODULE"

    [[ -d "$(dirname "$DEST")" ]] ||
        die "No existe extra-addons/extras en la instancia"

    [[ ! -L "$DEST" ]] ||
        die "Destino simbólico no permitido"

    IFS=',' read -ra paths <<< "$addons"

    for path in "${paths[@]}"; do
        path="${path#"${path%%[![:space:]]*}"}"
        path="${path%"${path##*[![:space:]]}"}"

        [[ -n "$path" ]] || continue

        if [[ "$(realpath -m "$path")" == \
              "$(realpath -m "$(dirname "$DEST")")" ]]; then
            found=1
        fi

        if [[ "$(realpath -m "$path")" != \
              "$(realpath -m "$(dirname "$DEST")")" &&
              -f "$path/$MODULE/__manifest__.py" ]]; then
            die "Módulo duplicado en addons_path: $path/$MODULE"
        fi
    done

    (( found )) ||
        die "La carpeta extras no está declarada en addons_path"
}

check_service() {
    local service_cfg

    SERVICE="odoo18-$INSTANCE.service"

    systemctl cat "$SERVICE" >/dev/null 2>&1 ||
        die "Servicio inexistente: $SERVICE"

    USERNAME="$(systemctl show -p User --value "$SERVICE")"

    [[ -n "$USERNAME" && "$USERNAME" != root ]] ||
        die "El servicio debe declarar un usuario no privilegiado"

    id "$USERNAME" >/dev/null 2>&1 ||
        die "Usuario del servicio inexistente"

    USERGROUP="$(id -gn "$USERNAME")"

    [[ -x "$BASE/$INSTANCE/venv/bin/python" ]] ||
        die "No existe Python de la instancia"

    [[ -f "$BASE/odoo/odoo-bin" ]] ||
        die "No existe odoo-bin"

    service_cfg="$(systemctl show -p ExecStart --value "$SERVICE")"

    [[ "$service_cfg" == *"$CFG"* ]] ||
        die "El servicio no referencia la configuracion esperada"

    systemctl is-active --quiet "$SERVICE" ||
        die "El servicio debe estar activo antes de comenzar"
}

get_module_state() {
    local result

    result="$(sudo -u postgres psql -X -At \
        -v module="$MODULE" "$DB" <<'SQL'
SELECT COALESCE(
    (SELECT state || '|' || COALESCE(latest_version, '')
     FROM ir_module_module
     WHERE name = :'module'
     LIMIT 1),
    'uninstalled|'
);
SQL
)" || die "No se pudo consultar el modulo en PostgreSQL"

    local state="${result%%|*}"
    INSTALLED_VERSION="${result#*|}"

    case "$state" in
        installed)
            ACTION="ACTUALIZAR"
            ;;
        uninstalled)
            ACTION="INSTALAR"
            ;;
        *)
            die "Estado del modulo no permitido: $state"
            ;;
    esac
}

validate_source() {
    [[ -d "$SRC" ]] ||
        die "Directorio fuente inexistente: $SRC"

    [[ -f "$SRC/__manifest__.py" ]] ||
        die "El paquete no contiene __manifest__.py"

    if [[ -n "$(find "$SRC" -type l -print -quit)" ]]; then
        die "No se permiten enlaces simbolicos en el modulo"
    fi

    local actual

    actual="$(manifest_version "$SRC/__manifest__.py")" ||
        die "Manifiesto invalido"

    validate_version "$actual" ||
        die "Version no compatible"

    if [[ -n "$VERSION" && "$actual" != "$VERSION" ]]; then
        die "La version del manifiesto no coincide con el ZIP"
    fi

    VERSION="$actual"
}

github_download() {
    local api="$WORK/github.json"
    local selected="$WORK/selected.txt"
    local url gitsha actual
    local -a result

    say "Consultando repositorio GitHub..."

    curl -fsSL \
        --retry 2 \
        --connect-timeout 15 \
        --max-time 90 \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/$REPO/contents/18.0?ref=$BRANCH" \
        -o "$api" ||
        die "No se pudo consultar GitHub"

    python3 - "$api" "$MODULE" "$selected" <<'PY'
import json
import re
import sys

with open(sys.argv[1], encoding="utf-8") as f:
    items = json.load(f)

if not isinstance(items, list):
    raise SystemExit("Respuesta inesperada de GitHub")

module = sys.argv[2]
candidates = []

for item in items:
    if item.get("type") != "file":
        continue

    match = re.fullmatch(
        re.escape(module) + r"_(18\.0(?:\.\d+)+)\.zip",
        item.get("name", "")
    )

    if not match:
        continue

    version = match.group(1)
    key = tuple(map(int, version.split(".")))
    candidates.append((key, version, item))

if not candidates:
    raise SystemExit("No existe paquete para " + module)

_, version, item = max(candidates, key=lambda x: x[0])

url = item.get("download_url")
sha = item.get("sha")

if not url or not re.fullmatch(r"[0-9a-f]{40}", sha or ""):
    raise SystemExit("Metadatos incompletos")

if not url.startswith(
    "https://raw.githubusercontent.com/"
):
    raise SystemExit("URL de descarga inesperada")

with open(sys.argv[3], "w", encoding="utf-8") as f:
    f.write(version + "\n")
    f.write(url + "\n")
    f.write(sha + "\n")
PY

    mapfile -t result < "$selected"

    VERSION="${result[0]}"
    url="${result[1]}"
    gitsha="${result[2]}"

    say "Version publicada: $VERSION"
    say "Descargando ZIP..."

    curl -fsSL \
        --retry 2 \
        --connect-timeout 15 \
        --max-time 300 \
        "$url" \
        -o "$WORK/module.zip" ||
        die "Error al descargar ZIP"

    say "Validando integridad de GitHub..."

    python3 - "$WORK/module.zip" "$gitsha" <<'PY'
import hashlib
import sys

with open(sys.argv[1], "rb") as f:
    content = f.read()

header = b"blob " + str(len(content)).encode() + b"\0"
actual = hashlib.sha1(header + content).hexdigest()

if actual != sys.argv[2]:
    raise SystemExit("Hash de GitHub no coincide")

print("Integridad del objeto Git: OK")
PY

    SRC="$WORK/extracted"
    mkdir -p "$SRC"

    say "Validando y extrayendo ZIP..."

    python3 - "$WORK/module.zip" "$SRC" "$MODULE" <<'PY'
import pathlib
import shutil
import stat
import sys
import zipfile

archive, destination, module = sys.argv[1:]

with zipfile.ZipFile(archive) as z:
    entries = z.infolist()

    if not entries or len(entries) > 20000:
        raise SystemExit("Cantidad de archivos no permitida")

    if sum(i.file_size for i in entries) > 1024**3:
        raise SystemExit("Tamano descomprimido excesivo")

    if z.testzip() is not None:
        raise SystemExit("ZIP corrupto")

    names = set()
    paths = []

    for item in entries:
        name = item.filename
        path = pathlib.PurePosixPath(name)

        if (
            not name
            or name.startswith("/")
            or "\\" in name
            or ":" in name
            or ".." in path.parts
            or item.flag_bits & 1
        ):
            raise SystemExit("Entrada ZIP insegura")

        if str(path) in names:
            raise SystemExit("Archivo duplicado en ZIP")

        names.add(str(path))

        mode = item.external_attr >> 16
        kind = stat.S_IFMT(mode)

        if kind not in (0, stat.S_IFREG, stat.S_IFDIR):
            raise SystemExit("Tipo de archivo no permitido")

        paths.append(path)

    wrapped = all(
        p.parts and p.parts[0] == module
        for p in paths
    )

    for item, path in zip(entries, paths):
        parts = path.parts[1:] if wrapped else path.parts

        if not parts:
            continue

        target = pathlib.Path(destination).joinpath(*parts)

        if item.is_dir():
            target.mkdir(parents=True, exist_ok=True)
            continue

        target.parent.mkdir(parents=True, exist_ok=True)

        with z.open(item) as source:
            with open(target, "wb") as output:
                shutil.copyfileobj(source, output)

manifest = pathlib.Path(destination) / "__manifest__.py"

if not manifest.is_file():
    raise SystemExit("No se encontro __manifest__.py")

print("Extraccion segura: OK")
PY

    validate_source
}


local_source() {
    local first second

    first="$BASE/$SOURCE_INSTANCE/extra-addons/extras/$MODULE"
    second="$BASE/$SOURCE_INSTANCE/extra-addons/$MODULE"

    if [[ -f "$first/__manifest__.py" ]]; then
        SRC="$first"
    elif [[ -f "$second/__manifest__.py" ]]; then
        SRC="$second"
    else
        die "No se encontró el módulo en DEMO"
    fi

    VERSION=""
    validate_source
}

prepare_backup() {
    local stamp data_dir filestore home_dir

    stamp="$(date -u +%Y%m%dT%H%M%SZ)"
    BACKUP_DIR="$BACKUP_ROOT/$INSTANCE/${MODULE}_${stamp}"

    install -d -m 700 "$BACKUP_DIR"

    say "Respaldo: $BACKUP_DIR"

    say "Respaldando PostgreSQL..."

    sudo -u postgres pg_dump -Fc "$DB" \
        > "$BACKUP_DIR/database.dump" ||
        die "Fallo pg_dump"

    [[ -s "$BACKUP_DIR/database.dump" ]] ||
        die "Dump vacio"

    pg_restore -l "$BACKUP_DIR/database.dump" \
        >/dev/null ||
        die "Dump PostgreSQL invalido"

    data_dir="$(config_value data_dir)"

    if [[ -n "$data_dir" ]]; then
        filestore="$data_dir/filestore/$DB"
    else
        home_dir="$(getent passwd "$USERNAME" | cut -d: -f6)"
        [[ -n "$home_dir" ]] ||
            die "No se pudo identificar HOME de Odoo"

        filestore="$home_dir/.local/share/Odoo/filestore/$DB"
    fi

    [[ -d "$filestore" ]] ||
        die "Filestore inexistente: $filestore"

    say "Respaldando filestore..."

    tar -C "$(dirname "$filestore")" \
        -czf "$BACKUP_DIR/filestore.tar.gz" \
        "$(basename "$filestore")" ||
        die "Fallo respaldo de filestore"

    tar -tzf "$BACKUP_DIR/filestore.tar.gz" \
        >/dev/null ||
        die "Respaldo de filestore invalido"

    say "Respaldando codigo del modulo..."

    if [[ -d "$DEST" ]]; then
        tar -C "$(dirname "$DEST")" \
            -czf "$BACKUP_DIR/module.tar.gz" \
            "$MODULE" ||
            die "Fallo respaldo del codigo"

        tar -tzf "$BACKUP_DIR/module.tar.gz" \
            >/dev/null ||
            die "Respaldo del codigo invalido"
    else
        echo "Modulo no existente previamente" \
            > "$BACKUP_DIR/module_not_present.txt"
    fi

    {
        printf 'instancia=%s\n' "$INSTANCE"
        printf 'modulo=%s\n' "$MODULE"
        printf 'database=%s\n' "$DB"
        printf 'version_nueva=%s\n' "$VERSION"
        printf 'version_previa=%s\n' "$INSTALLED_VERSION"
        printf 'fecha_utc=%s\n' "$stamp"
    } > "$BACKUP_DIR/metadata.txt"

    (
        cd "$BACKUP_DIR"

        sha256sum database.dump \
            filestore.tar.gz metadata.txt \
            > SHA256SUMS

        if [[ -f module.tar.gz ]]; then
            sha256sum module.tar.gz >> SHA256SUMS
        fi

        sha256sum -c SHA256SUMS ||
            exit 1
    ) || die "Fallo verificacion SHA256 del respaldo"

    say "RESPALDO COMPLETADO Y VERIFICADO"
}

execute_update() {
    local op

    if [[ "$ACTION" == "INSTALAR" ]]; then
        op="-i"
    else
        op="-u"
    fi

    ODOO_LOG="$LOG_ROOT/${INSTANCE}_${MODULE}_odoo_$(date -u +%Y%m%dT%H%M%SZ).log"

    install -o "$USERNAME" -g "$USERGROUP" \
        -m 640 /dev/null "$ODOO_LOG"

    say "Sincronizando codigo..."

    # Desde este punto no se reinicia automaticamente
    # ante un error, pues pueden existir cambios parciales.
    CHANGES_STARTED=1

    install -d \
        -o "$USERNAME" \
        -g "$USERGROUP" \
        -m 755 "$DEST"

    rsync -a --delete -- "$SRC/" "$DEST/" ||
        die "Fallo rsync"

    chown -R "$USERNAME:$USERGROUP" "$DEST" ||
        die "No se pudieron asignar permisos"

    say "Ejecutando Odoo ($op $MODULE)..."

    sudo -u "$USERNAME" \
        "$BASE/$INSTANCE/venv/bin/python" \
        "$BASE/odoo/odoo-bin" \
        -c "$CFG" \
        -d "$DB" \
        "$op" "$MODULE" \
        --stop-after-init \
        --no-http \
        --logfile="$ODOO_LOG" ||
        die "La ejecucion de Odoo fallo"

    say "Iniciando servicio..."

    systemctl start "$SERVICE" ||
        die "No se pudo iniciar Odoo"

    SERVICE_STOPPED=0

    systemctl is-active --quiet "$SERVICE" ||
        die "El servicio no esta activo"

    local state

    state="$(sudo -u postgres psql -X -At \
        -v module="$MODULE" "$DB" <<'SQL'
SELECT COALESCE(
    (SELECT state
     FROM ir_module_module
     WHERE name = :'module'
     LIMIT 1),
    'missing'
);
SQL
)" || die "No se pudo verificar la base de datos"

    [[ "$state" == installed ]] ||
        die "Estado final inesperado: $state"

    say ""
    say "=========================================="
    say "         OPERACION COMPLETADA"
    say "=========================================="
    say "Instancia: $INSTANCE"
    say "Modulo: $MODULE"
    say "Version: $VERSION"
    say "Estado: $state"
    say "Log: $LOG"
    say "Log Odoo: $ODOO_LOG"

    if [[ -n "$BACKUP_DIR" ]]; then
        say "Respaldo: $BACKUP_DIR"
    fi
}

main() {
    local backup_answer
    local stamp

    [[ $EUID -eq 0 ]] ||
        die "Ejecuta con sudo"

    check_dependencies

    say "=========================================="
    say "       ICKAB MODULE MANAGER"
    say "             v$VERSION_MANAGER"
    say "=========================================="
    say ""

    ask_name "¿Que instancia deseas actualizar?"
    INSTANCE="$REPLY"

    ask_name "¿Que modulo deseas instalar o actualizar?"
    MODULE="$REPLY"

    say ""
    say "Origen del modulo:"
    say "1) Local (DEMO)"
    say "2) GitHub"

    while true; do
        read -r -p "Selecciona 1 o 2: " MODE ||
            die "Entrada interrumpida"

        [[ "$MODE" == 1 || "$MODE" == 2 ]] && break

        say "Opcion no valida"
    done

    [[ -d "$BASE/$INSTANCE" ]] ||
        die "Instancia inexistente"

    CFG="$BASE/$INSTANCE/config/odoo18.conf"

    [[ -f "$CFG" ]] ||
        die "Configuracion inexistente"

    check_service
    check_paths
    detect_database

    install -d -m 700 "$BACKUP_ROOT"
    install -d -m 750 -o root -g "$USERGROUP" "$LOG_ROOT"

    stamp="$(date -u +%Y%m%dT%H%M%SZ)"
    LOG="$LOG_ROOT/${INSTANCE}_${MODULE}_${stamp}.log"

    exec > >(tee -a "$LOG") 2>&1

    exec {LOCK_FD}>"/run/lock/ick_update_${INSTANCE}.lock"

    flock -n "$LOCK_FD" ||
        die "Ya existe una operacion para esta instancia"

    WORK="$(mktemp -d /tmp/ickab-module.XXXXXXXX)"

    if [[ "$MODE" == 2 ]]; then
        github_download
    else
        local_source
    fi

    get_module_state

    DISK_VERSION="No existe"

    if [[ -f "$DEST/__manifest__.py" ]]; then
        DISK_VERSION="$(
            manifest_version "$DEST/__manifest__.py"
        )"
    fi

    compare_versions ||
        die "Version no permitida"

    [[ "$(realpath -m "$SRC")" != "$(realpath -m "$DEST")" ]] ||
        die "Origen y destino no pueden ser iguales"

    say ""
    say "=========================================="
    say "          RESUMEN DE OPERACION"
    say "=========================================="
    say "Instancia:          $INSTANCE"
    say "Base de datos:      $DB"
    say "Modulo:             $MODULE"
    say "Accion:             $ACTION"
    say "Version instalada:  ${INSTALLED_VERSION:-No registrada}"
    say "Version en disco:   $DISK_VERSION"
    say "Version nueva:      $VERSION"
    say "Destino:            $DEST"

    if [[ "$MODE" == 2 ]]; then
        say "Origen:             GitHub"
    else
        say "Origen:             DEMO"
    fi

    say ""
    say "Archivos que se modificaran:"

    rsync -ani --delete -- "$SRC/" "$DEST/" ||
        die "No se pudo generar simulacion"

    say ""
    ask_sn "¿Deseas generar respaldo?"
    backup_answer="$REPLY"

    say ""
    say "=========================================="
    say "          CONFIRMACION FINAL"
    say "=========================================="
    say "Instancia: $INSTANCE"
    say "Modulo: $MODULE"
    say "Operacion: $ACTION"
    say "Version: $VERSION"
    say "Respaldo: $backup_answer"

    if [[ "$backup_answer" == N ]]; then
        say ""
        say "ADVERTENCIA: No se generara respaldo nuevo."
    fi

    say ""
    ask_sn "¿Confirmas la actualizacion?"

    if [[ "$REPLY" == N ]]; then
        say "Operacion cancelada sin modificar Odoo."
        return 0
    fi

    say ""
    say "Deteniendo servicio $SERVICE..."

    systemctl stop "$SERVICE" ||
        die "No se pudo detener el servicio"

    SERVICE_STOPPED=1

    if [[ "$backup_answer" == S ]]; then
        prepare_backup
    else
        say "Continuando sin respaldo nuevo."
    fi

    execute_update
}

main "$@"
