#!/usr/bin/env bash
# =============================================================================
# backup.sh - Backup en Linux con interfaz de terminal (TUI)
#
# Requiere: dialog (recomendado) o whiptail, y rsync para el modo rsync.
#   Debian/Ubuntu: sudo apt install dialog rsync
#   Fedora/RHEL:   sudo dnf install dialog rsync
#   Arch:          sudo pacman -S dialog rsync
#
# Uso:
#   sudo ./backup.sh                       -> interfaz interactiva
#   sudo ./backup.sh -c servidor           -> abre la UI con la config "servidor"
#   sudo ./backup.sh -y -c servidor        -> ejecuta sin UI (ideal para cron)
#   sudo ./backup.sh -y -d /etc -o /mnt/backup
#
# Opciones:
#   -d DIR     Directorio a respaldar (repetible)
#   -o DIR     Destino del backup
#   -m MODO    rsync | tar
#   -s         Usar snapshot LVM/btrfs (consistencia con archivos en uso)
#   -r DIAS    Retención: borrar backups con más de DIAS días (0 = conservar todo)
#   -c NOMBRE  Cargar una configuración guardada
#   -C DIR     Usar DIR como carpeta de configuraciones (solo esta ejecución)
#   -l         Listar configuraciones guardadas
#   -e         Enviar el log por correo al terminar (aunque esté en "nunca")
#   -y         Ejecutar directamente sin interfaz
#   -x PATRON  Patrón a excluir (repetible; reemplaza la lista de la config).
#              Con -x "" se usa una lista vacía
#   -n NOMBRE  Nombre de la configuración que se muestra en el log
#   -p         Mostrar progreso de rsync (para interfaces gráficas)
#   -k ARCHIVO Cancelar el backup en curso cuando ese archivo exista
#   -t         Enviar un correo de prueba con la configuración de correo y salir
#   -h         Esta ayuda
#
# Configuraciones: por defecto se guardan en /etc/backup-tui (root) o en
# ~/.config/backup-tui (otros usuarios). Podés elegir otra carpeta desde el menú
# (Guardar / cargar configuración > Cambiar la carpeta), con la opción -C DIR o
# con la variable BACKUP_CONFIG_DIR. Lo elegido en el menú se recuerda en un
# archivo "ubicacion" dentro de la carpeta por defecto.
# La última configuración usada se recuerda y se carga sola al abrir la UI.
#
# Unidades: en los logs los tamaños van en MB y las velocidades en KB/s
# (1 KB = 1024 bytes, 1 MB = 1024 x 1024 bytes).
#
# Log: cada backup genera backup_FECHA.log en el destino con el detalle de
# archivos NUEVOS y MODIFICADOS. En modo tar también se guarda la lista
# completa de archivos incluidos (backup_FECHA.lista.txt).
#
# Retención: tras cada backup exitoso se eliminan los backups del destino más
# viejos que la cantidad de días elegida (se guarda en cada configuración). Nunca
# se borra el backup más reciente ni el que apunta "latest", y no se borra nada
# si el backup falla. Solo se tocan archivos backup_AAAA-MM-DD_HH-MM-SS*.
#
# Correo: el menú "Correo electrónico" configura el envío del log (destinatarios,
# cuándo enviar y método: sendmail/msmtp/mail locales o SMTP directo con curl).
# El mensaje lleva un resumen y el log adjunto. La configuración queda en
# correo.conf y la contraseña SMTP en smtp.pass (permisos 600).
#
# Archivos en uso: Linux no bloquea archivos abiertos, así que se copian sin
# problema. Si uno cambia durante la lectura se avisa pero el backup continúa.
# Para bases de datos usá snapshot o un dump previo.
# =============================================================================

set -uo pipefail

DEST=""
MODE="rsync"
SNAPSHOT=0
RETENCION=0     # días a conservar; 0 = sin límite
NOUI=0
SHOW_PROGRESS=0
DIRS=()
EXCLUDES=("*.tmp" "*.swp" ".cache/" "node_modules/" "/proc/*" "/sys/*" "/dev/*" "/run/*" "lost+found")
LOG_FILE=""
TS=""
ERRMSG=""
UI=""
CURRENT_CFG=""
SNAP_CLEANUP=()

# Carpeta de configuraciones. Prioridad: -C / BACKUP_CONFIG_DIR > elegida en el
# menú (puntero "ubicacion") > carpeta por defecto.
if (( EUID == 0 )); then
  DEFAULT_CONFIG_DIR="/etc/backup-tui"
else
  DEFAULT_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/backup-tui"
fi
POINTER_FILE="$DEFAULT_CONFIG_DIR/ubicacion"
CONFIG_DIR="$DEFAULT_CONFIG_DIR"
CONFIG_FIJA=0        # 1 si la ubicación viene de -C o de BACKUP_CONFIG_DIR
CONFIG_AVISO=""      # aviso si la carpeta elegida ya no está disponible
MSG_UBIC=""
MAIL_FILE=""
PASS_FILE=""

actualizar_rutas_config() {
  MAIL_FILE="$CONFIG_DIR/correo.conf"
  PASS_FILE="$CONFIG_DIR/smtp.pass"
}

resolver_config_dir() {
  local ptr=""
  CONFIG_DIR="$DEFAULT_CONFIG_DIR"
  if [[ -n ${BACKUP_CONFIG_DIR:-} ]]; then
    CONFIG_DIR="$BACKUP_CONFIG_DIR"; CONFIG_FIJA=1
  elif [[ -f $POINTER_FILE ]]; then
    IFS= read -r ptr < "$POINTER_FILE" || true
    if [[ $ptr == /* && -d $ptr ]]; then
      CONFIG_DIR="$ptr"
    elif [[ -n $ptr ]]; then
      CONFIG_AVISO="La carpeta de configuraciones elegida no está disponible:"$'\n'"$ptr"$'\n\n'"Se usa la ubicación por defecto:"$'\n'"$DEFAULT_CONFIG_DIR"
    fi
  fi
  actualizar_rutas_config
}
resolver_config_dir

# ---------- mensajes (van al log / terminal) ----------------------------------
info() { echo "[OK] $*"; }
warn() { echo "[AVISO] $*" >&2; }
err()  { echo "[ERROR] $*" >&2; }

# ---------- wrapper de dialog/whiptail ----------------------------------------
# El resultado de la selección sale por stdout; la interfaz se dibuja en la
# terminal (truco de intercambio de descriptores).
ui() { "$UI" --backtitle "Backup Linux" "$@" 3>&1 1>&2 2>&3; }

detectar_ui() {
  if command -v dialog >/dev/null 2>&1; then UI=dialog
  elif command -v whiptail >/dev/null 2>&1; then UI=whiptail
  else
    err "Necesitás instalar 'dialog' o 'whiptail' (ej: sudo apt install dialog)."
    exit 1
  fi
}

# ---------- configuraciones guardadas -----------------------------------------
# Formato simple CLAVE=valor (se parsea a mano, nunca se ejecuta como código).
guardar_config() {
  local nombre="$1" f d e
  f="$CONFIG_DIR/$nombre.conf"
  mkdir -p "$CONFIG_DIR" 2>/dev/null && chmod 700 "$CONFIG_DIR" 2>/dev/null
  {
    echo "# Configuración de backup.sh - guardada $(date '+%F %T')"
    echo "DEST=$DEST"
    echo "MODE=$MODE"
    echo "SNAPSHOT=$SNAPSHOT"
    echo "RETENCION=$RETENCION"
    for d in "${DIRS[@]:-}"; do [[ -n $d ]] && echo "DIR=$d"; done
    for e in "${EXCLUDES[@]:-}"; do [[ -n $e ]] && echo "EXCLUDE=$e"; done
  } > "$f" 2>/dev/null
}

cargar_config() {
  local f="$CONFIG_DIR/$1.conf" line k v
  local n_dest="$DEST" n_mode="$MODE" n_snap="$SNAPSHOT" n_ret="$RETENCION" n_dirs=() n_excl=()
  [[ -f $f ]] || return 1
  while IFS= read -r line || [[ -n $line ]]; do
    [[ -z $line || $line == \#* || $line != *=* ]] && continue
    k="${line%%=*}"; v="${line#*=}"
    case $k in
      DEST)     n_dest="$v" ;;
      MODE)     [[ $v == rsync || $v == tar ]] && n_mode="$v" ;;
      SNAPSHOT) [[ $v == 0 || $v == 1 ]] && n_snap="$v" ;;
      RETENCION) [[ $v =~ ^[0-9]+$ ]] && n_ret="$v" ;;
      DIR)      n_dirs+=("$v") ;;
      EXCLUDE)  n_excl+=("$v") ;;
    esac
  done < "$f"
  DEST="$n_dest"; MODE="$n_mode"; SNAPSHOT="$n_snap"; RETENCION="$n_ret"
  DIRS=("${n_dirs[@]:-}"); [[ ${#n_dirs[@]} -eq 0 ]] && DIRS=()
  EXCLUDES=("${n_excl[@]:-}"); [[ ${#n_excl[@]} -eq 0 ]] && EXCLUDES=()
  return 0
}

nombres_configs() {
  local f n
  for f in "$CONFIG_DIR"/*.conf; do
    [[ -e $f ]] || continue
    n="$(basename "$f" .conf)"
    [[ $n == ultimo || $n == correo ]] && continue
    echo "$n"
  done
}

elegir_config() {
  local titulo="$1" n f items=()
  while IFS= read -r n; do
    [[ -z $n ]] && continue
    f="$CONFIG_DIR/$n.conf"
    items+=("$n" "$(grep -c '^DIR=' "$f") carpetas -> $(grep -m1 '^DEST=' "$f" | cut -d= -f2-)")
  done < <(nombres_configs)
  if (( ${#items[@]} == 0 )); then
    ui --msgbox "No hay configuraciones guardadas en:\n$CONFIG_DIR" 8 60
    return 1
  fi
  ui --title "$titulo" --menu "Elegí una configuración:" 18 76 8 "${items[@]}"
}

# Cambia la carpeta de configuraciones. $1 = nueva ruta, $2 = copiar existentes (0/1)
# Deja el resultado en MSG_UBIC. Retorna 1 si no se pudo.
cambiar_ubicacion_config() {
  local nuevo="$1" copiar="$2" viejo="$CONFIG_DIR" f n=0
  if ! mkdir -p "$nuevo" 2>/dev/null || [[ ! -w $nuevo ]]; then
    MSG_UBIC="No se puede escribir en:"$'\n'"$nuevo"; return 1
  fi
  nuevo="$(realpath "$nuevo")"
  chmod 700 "$nuevo" 2>/dev/null
  local mismo=0
  [[ $nuevo == "$viejo" ]] && { mismo=1; copiar=0; }
  if (( copiar )); then
    for f in "$viejo"/*.conf "$viejo"/smtp.pass; do
      [[ -f $f && ! -e $nuevo/$(basename "$f") ]] || continue
      cp -p "$f" "$nuevo/" && n=$((n + 1))
    done
  fi
  CONFIG_DIR="$nuevo"
  actualizar_rutas_config
  # Se recuerda la elección: el puntero vive siempre en la carpeta por defecto
  if [[ $nuevo == "$DEFAULT_CONFIG_DIR" ]]; then
    rm -f "$POINTER_FILE"
  else
    mkdir -p "$DEFAULT_CONFIG_DIR" 2>/dev/null && chmod 700 "$DEFAULT_CONFIG_DIR" 2>/dev/null
    printf '%s\n' "$nuevo" > "$POINTER_FILE" 2>/dev/null ||
      MSG_UBIC="Aviso: no pude guardar la elección; volverá a la carpeta por defecto al reiniciar."$'\n\n'
  fi
  cargar_correo
  if (( mismo )); then
    MSG_UBIC+="Esa ya era la carpeta actual; la elección quedó guardada:"$'\n'"$nuevo"
  else
    MSG_UBIC+="Las configuraciones ahora se guardan en:"$'\n'"$nuevo"$'\n\n'"Archivos copiados: $n"
  fi
  return 0
}

menu_ubicacion() {
  local op nuevo copiar=0
  if (( CONFIG_FIJA )); then
    ui --title "Ubicación fija" --msgbox "La carpeta está fijada para esta ejecución (opción -C o variable BACKUP_CONFIG_DIR):"$'\n\n'"$CONFIG_DIR"$'\n\n'"Ejecutá el script sin ellas para poder cambiarla desde el menú." 13 72
    return
  fi
  op=$(ui --title "Carpeta de configuraciones" --cancel-button "Volver" \
    --menu "Carpeta actual:"$'\n'"$CONFIG_DIR"$'\n\n'"Por defecto: $DEFAULT_CONFIG_DIR" 18 76 3 \
    1 "Elegir con el navegador (permite crear carpetas)" \
    2 "Escribir la ruta a mano" \
    3 "Volver a la ubicación por defecto") || return
  case $op in
    1) nuevo=$(browse_dir "Carpeta para guardar las configuraciones" 1 "$CONFIG_DIR") || return ;;
    2) nuevo=$(ui --title "Carpeta de configuraciones" --inputbox "Ruta de la carpeta (absoluta):" 8 72 "$CONFIG_DIR") || return ;;
    3) nuevo="$DEFAULT_CONFIG_DIR" ;;
  esac
  if [[ $nuevo != /* ]]; then
    ui --msgbox "La ruta debe ser absoluta (empezar con /)." 7 56; return
  fi
  if ui --yesno "¿Copiar las configuraciones actuales a la nueva carpeta?"$'\n'"(las originales no se borran)" 8 64; then copiar=1; fi
  MSG_UBIC=""
  if cambiar_ubicacion_config "$nuevo" "$copiar"; then
    ui --title "Listo" --msgbox "$MSG_UBIC" 12 74
  else
    ui --title "Error" --msgbox "$MSG_UBIC" 9 70
  fi
}

menu_configs() {
  local op nombre
  while true; do
    op=$(ui --title "Configuraciones" --cancel-button "Volver" \
      --menu "Carpeta: $CONFIG_DIR"$'\nActual: '"${CURRENT_CFG:-(sin nombre)}" 17 76 4 \
      1 "Guardar la configuración actual" \
      2 "Cargar una guardada" \
      3 "Eliminar una guardada" \
      4 "Cambiar la carpeta donde se guardan") || return
    case $op in
      1) nombre=$(ui --title "Guardar" --inputbox "Nombre (letras, números, . _ -):" 8 60 "$CURRENT_CFG") || continue
         if [[ $nombre =~ ^[A-Za-z0-9._-]+$ && $nombre != ultimo && $nombre != correo ]]; then
           if guardar_config "$nombre"; then
             CURRENT_CFG="$nombre"; ui --msgbox "Configuración '$nombre' guardada." 7 50
           else
             ui --msgbox "No se pudo escribir en $CONFIG_DIR" 7 60
           fi
         else
           ui --msgbox "Nombre inválido." 7 40
         fi ;;
      2) nombre=$(elegir_config "Cargar configuración") || continue
         if cargar_config "$nombre"; then
           CURRENT_CFG="$nombre"; ui --msgbox "Configuración '$nombre' cargada." 7 50
         fi ;;
      3) nombre=$(elegir_config "Eliminar configuración") || continue
         if ui --yesno "¿Eliminar la configuración '$nombre'?" 7 50; then
           rm -f "$CONFIG_DIR/$nombre.conf"
           [[ $CURRENT_CFG == "$nombre" ]] && CURRENT_CFG=""
         fi ;;
      4) menu_ubicacion ;;
    esac
  done
}

# ---------- correo electrónico ------------------------------------------------
# Configuración global (no por perfil) en correo.conf. La contraseña SMTP va
# aparte, en smtp.pass, con permisos 600.
MAIL_ENVIAR="nunca"      # nunca | siempre | error
MAIL_A=""
MAIL_DE=""
MAIL_METODO="local"      # local (sendmail/msmtp/mail) | smtp (curl)
SMTP_HOST=""
SMTP_PORT="587"
SMTP_TLS="starttls"      # starttls | ssl | none
SMTP_USER=""
MAIL_ERR=""

guardar_correo() {
  mkdir -p "$CONFIG_DIR" 2>/dev/null && chmod 700 "$CONFIG_DIR" 2>/dev/null
  (
    umask 077
    {
      echo "# Configuración de correo de backup.sh"
      echo "MAIL_ENVIAR=$MAIL_ENVIAR"
      echo "MAIL_A=$MAIL_A"
      echo "MAIL_DE=$MAIL_DE"
      echo "MAIL_METODO=$MAIL_METODO"
      echo "SMTP_HOST=$SMTP_HOST"
      echo "SMTP_PORT=$SMTP_PORT"
      echo "SMTP_TLS=$SMTP_TLS"
      echo "SMTP_USER=$SMTP_USER"
    } > "$MAIL_FILE"
  ) 2>/dev/null
}

cargar_correo() {
  local line k v
  [[ -f $MAIL_FILE ]] || return 0
  while IFS= read -r line || [[ -n $line ]]; do
    [[ -z $line || $line == \#* || $line != *=* ]] && continue
    k="${line%%=*}"; v="${line#*=}"
    case $k in
      MAIL_ENVIAR) [[ $v == nunca || $v == siempre || $v == error ]] && MAIL_ENVIAR="$v" ;;
      MAIL_A)      MAIL_A="$v" ;;
      MAIL_DE)     MAIL_DE="$v" ;;
      MAIL_METODO) [[ $v == local || $v == smtp ]] && MAIL_METODO="$v" ;;
      SMTP_HOST)   SMTP_HOST="$v" ;;
      SMTP_PORT)   [[ $v =~ ^[0-9]+$ ]] && SMTP_PORT="$v" ;;
      SMTP_TLS)    [[ $v == starttls || $v == ssl || $v == none ]] && SMTP_TLS="$v" ;;
      SMTP_USER)   SMTP_USER="$v" ;;
    esac
  done < "$MAIL_FILE"
  return 0
}

direcciones() { tr ',; ' '\n\n\n' <<< "$1" | sed '/^$/d'; }

correo_valido() {
  local re='^[^@ ,;]+@[^@ ,;]+$'
  [[ $1 =~ $re ]]
}

destinatarios_validos() {
  local a n=0
  while IFS= read -r a; do
    [[ -z $a ]] && continue
    correo_valido "$a" || return 1
    n=$((n + 1))
  done < <(direcciones "$1")
  (( n > 0 ))
}

# Log sin las líneas de progreso de rsync
limpiar_log() { tr '\r' '\n' < "$1" | grep -v '[0-9]%  *[0-9.]*[kKMGT]\?B/s'; }

# Arma un mensaje MIME (texto + log adjunto) y lo imprime por stdout.
# $1=remitente $2=asunto $3=archivo cuerpo $4=archivo adjunto $5=nombre adjunto $6=content-type
construir_mensaje() {
  local de="$1" asunto="$2" cuerpo="$3" adj="$4" adjnom="$5" ctype="$6" b to
  b="=_backup_$(date +%s)_$RANDOM"
  to="$(direcciones "$MAIL_A" | paste -sd, - | sed 's/,/, /g')"
  printf 'From: %s\n' "$de"
  printf 'To: %s\n' "$to"
  printf 'Subject: =?UTF-8?B?%s?=\n' "$(printf '%s' "$asunto" | base64 -w0)"
  printf 'Date: %s\n' "$(date -R)"
  printf 'Message-ID: <%s.%s@%s>\n' "$(date +%s)" "$RANDOM" "$(hostname)"
  printf 'MIME-Version: 1.0\n'
  printf 'Content-Type: multipart/mixed; boundary="%s"\n\n' "$b"
  printf -- '--%s\nContent-Type: text/plain; charset=UTF-8\nContent-Transfer-Encoding: base64\n\n' "$b"
  base64 -w 76 "$cuerpo"
  printf -- '\n--%s\nContent-Type: %s; name="%s"\nContent-Transfer-Encoding: base64\nContent-Disposition: attachment; filename="%s"\n\n' \
    "$b" "$ctype" "$adjnom" "$adjnom"
  base64 -w 76 "$adj"
  printf -- '\n--%s--\n' "$b"
}

# Envío con sendmail / msmtp / mail (lo que haya instalado).
# $1=directorio temporal con msg.eml, cuerpo.txt y limpio.log  $2=remitente  $3=asunto
enviar_local() {
  local tmpd="$1" de="$2" asunto="$3" sm out dest=()
  sm="$(command -v sendmail 2>/dev/null || true)"
  [[ -z $sm && -x /usr/sbin/sendmail ]] && sm=/usr/sbin/sendmail
  if [[ -n $sm ]]; then
    out=$("$sm" -t -i -f "$de" < "$tmpd/msg.eml" 2>&1) || { MAIL_ERR="sendmail: $out"; return 1; }
  elif command -v msmtp >/dev/null 2>&1; then
    out=$(msmtp --from="$de" -t < "$tmpd/msg.eml" 2>&1) || { MAIL_ERR="msmtp: $out"; return 1; }
  elif command -v mail >/dev/null 2>&1 || command -v mailx >/dev/null 2>&1; then
    # 'mail' no permite adjuntos de forma portable: se envía el log en el cuerpo
    mapfile -t dest < <(direcciones "$MAIL_A")
    {
      cat "$tmpd/cuerpo.txt"
      printf '\n---------- LOG (últimas 300 líneas) ----------\n'
      tail -n 300 "$tmpd/limpio.log"
    } > "$tmpd/inline.txt"
    out=$( { command -v mail >/dev/null 2>&1 && mail -s "$asunto" "${dest[@]}" || mailx -s "$asunto" "${dest[@]}"; } < "$tmpd/inline.txt" 2>&1) \
      || { MAIL_ERR="mail: $out"; return 1; }
  else
    MAIL_ERR="No hay sendmail, msmtp ni mail instalados. Instalá uno (ej: sudo apt install msmtp-mta) o usá el método SMTP."
    return 1
  fi
  return 0
}

# Envío directo por SMTP usando curl (soporta STARTTLS y SSL).
# $1=directorio temporal  $2=remitente
enviar_smtp() {
  local tmpd="$1" de="$2" proto="smtp" args=() cfg pass="" a out esc_u esc_p
  [[ -n $SMTP_HOST ]] || { MAIL_ERR="Falta configurar el servidor SMTP."; return 1; }
  command -v curl >/dev/null 2>&1 || { MAIL_ERR="Falta curl (sudo apt install curl)."; return 1; }
  [[ $SMTP_TLS == ssl ]] && proto="smtps"
  [[ $SMTP_TLS == starttls ]] && args+=(--ssl-reqd)
  if [[ -n $SMTP_USER ]]; then
    [[ -f $PASS_FILE ]] && pass="$(<"$PASS_FILE")"
    esc_u="${SMTP_USER//\\/\\\\}"; esc_u="${esc_u//\"/\\\"}"
    esc_p="${pass//\\/\\\\}";      esc_p="${esc_p//\"/\\\"}"
    cfg="$tmpd/curl.cfg"
    ( umask 077; printf 'user = "%s:%s"\n' "$esc_u" "$esc_p" > "$cfg" )   # evita exponer la clave en 'ps'
    args+=(-K "$cfg")
  fi
  while IFS= read -r a; do [[ -n $a ]] && args+=(--mail-rcpt "$a"); done < <(direcciones "$MAIL_A")
  out=$(curl --silent --show-error --max-time 60 --crlf \
        --url "$proto://$SMTP_HOST:$SMTP_PORT" --mail-from "$de" \
        "${args[@]}" -T "$tmpd/msg.eml" 2>&1) || { MAIL_ERR="curl: $out"; return 1; }
  return 0
}

# Envía el log por correo.
# $1=archivo de log  $2=código de salida (vacío = deducirlo del log)  $3="prueba" (opcional)
# Retorna 0 si se envió; si falla deja el motivo en MAIL_ERR.
enviar_correo() {
  local log="$1" rc="${2:-}" tipo="${3:-}" host de estado asunto tmpd adj adjnom ctype res=0
  MAIL_ERR=""
  host="$(hostname)"
  [[ -f $log ]] || { MAIL_ERR="No existe el log: $log"; return 1; }
  destinatarios_validos "$MAIL_A" || { MAIL_ERR="Destinatario vacío o inválido."; return 1; }
  de="${MAIL_DE:-backup@$host}"
  correo_valido "$de" || { MAIL_ERR="Remitente inválido: $de"; return 1; }
  command -v base64 >/dev/null 2>&1 || { MAIL_ERR="Falta el comando base64."; return 1; }
  if [[ -z $rc ]]; then if grep -q '^\[ERROR\]' "$log"; then rc=1; else rc=0; fi; fi

  if [[ $tipo == prueba ]]; then estado="PRUEBA"
  elif (( rc == 0 )); then estado="OK"
  else estado="ERROR"; fi
  asunto="[Backup $estado] $host - $(date '+%F %H:%M')"

  tmpd="$(mktemp -d)" || { MAIL_ERR="No pude crear un directorio temporal."; return 1; }
  limpiar_log "$log" > "$tmpd/limpio.log"
  {
    echo "Servidor:  $host"
    echo "Resultado: $estado (código $rc)"
    echo "Fecha:     $(date '+%F %T')"
    echo "Log:       $(basename "$log") (adjunto)"
    echo
    grep -E '^(=== |Configuración:|Modo:|Destino:|Origen:|\[OK\]|\[AVISO\]|\[ERROR\]|Resumen:|Retención:|Duración:|Datos |Tamaño |Velocidad )' "$tmpd/limpio.log" | head -n 60
  } > "$tmpd/cuerpo.txt"

  adj="$tmpd/limpio.log"; adjnom="$(basename "$log")"; ctype="text/plain; charset=UTF-8"
  [[ $tipo == prueba ]] && adjnom="prueba.log"
  if (( $(stat -c %s "$adj") > 1048576 )) && gzip -c "$adj" > "$tmpd/limpio.log.gz"; then
    adj="$tmpd/limpio.log.gz"; adjnom="$adjnom.gz"; ctype="application/gzip"
  fi

  construir_mensaje "$de" "$asunto" "$tmpd/cuerpo.txt" "$adj" "$adjnom" "$ctype" > "$tmpd/msg.eml"
  case $MAIL_METODO in
    smtp) enviar_smtp  "$tmpd" "$de" || res=1 ;;
    *)    enviar_local "$tmpd" "$de" "$asunto" || res=1 ;;
  esac
  rm -rf "$tmpd"
  return $res
}

# ¿Corresponde enviar correo según la configuración? ($1 = código de salida)
debe_enviar_correo() {
  case $MAIL_ENVIAR in
    siempre) return 0 ;;
    error)   (( $1 != 0 )) ;;
    *)       return 1 ;;
  esac
}

ultimo_log() {
  [[ -d $DEST ]] || return 1
  local f
  f="$(ls -t "$DEST"/backup_*.log 2>/dev/null | head -1)"
  [[ -n $f ]] && echo "$f"
}

# ---- menús del correo ----
menu_smtp() {
  local v t pw
  v=$(ui --title "Servidor SMTP" --inputbox "Servidor (ej: smtp.gmail.com):" 8 64 "$SMTP_HOST") || return
  SMTP_HOST="$v"
  v=$(ui --title "Servidor SMTP" --inputbox "Puerto (587 = STARTTLS, 465 = SSL, 25 = sin cifrar):" 8 64 "$SMTP_PORT") || return
  [[ $v =~ ^[0-9]+$ ]] && SMTP_PORT="$v"
  t=$(ui --title "Cifrado" --radiolist "Cifrado de la conexión:" 12 66 3 \
    starttls "STARTTLS (puerto 587)"       "$([[ $SMTP_TLS == starttls ]] && echo on || echo off)" \
    ssl      "SSL/TLS directo (puerto 465)" "$([[ $SMTP_TLS == ssl ]] && echo on || echo off)" \
    none     "Sin cifrar (no recomendado)"  "$([[ $SMTP_TLS == none ]] && echo on || echo off)") || return
  SMTP_TLS="$t"
  v=$(ui --title "Autenticación" --inputbox "Usuario (vacío si el servidor no pide autenticación):" 8 66 "$SMTP_USER") || return
  SMTP_USER="$v"
  if [[ -n $SMTP_USER ]]; then
    pw=$(ui --title "Contraseña" --passwordbox \
      "Contraseña SMTP (vacío = no cambiar).\nSe guarda en $PASS_FILE con permisos 600.\nEn Gmail/Outlook usá una contraseña de aplicación." 11 72) || { guardar_correo; return; }
    if [[ -n $pw ]]; then
      mkdir -p "$CONFIG_DIR" 2>/dev/null
      ( umask 077; printf '%s' "$pw" > "$PASS_FILE" )
    fi
  fi
  guardar_correo
  ui --msgbox "Configuración SMTP guardada." 7 40
}

enviar_prueba() {
  local tmp
  tmp="$(mktemp)"
  {
    echo "=== Correo de prueba de backup.sh ==="
    echo "Fecha: $(date '+%F %T')"
    echo "[OK] Si recibís este mensaje, el envío de correos funciona."
  } > "$tmp"
  ui --infobox "Enviando correo de prueba a $MAIL_A ..." 5 70
  if enviar_correo "$tmp" 0 prueba; then
    ui --msgbox "Correo de prueba enviado a:\n$MAIL_A" 8 64
  else
    ui --title "No se pudo enviar" --msgbox "$MAIL_ERR" 12 74
  fi
  rm -f "$tmp"
}

enviar_ultimo_log() {
  local log
  log="$(ultimo_log)" || { ui --msgbox "No hay logs en el destino actual." 7 50; return; }
  ui --infobox "Enviando $(basename "$log") a $MAIL_A ..." 5 70
  if enviar_correo "$log" ""; then
    ui --msgbox "Log enviado a:\n$MAIL_A" 8 64
  else
    ui --title "No se pudo enviar" --msgbox "$MAIL_ERR" 12 74
  fi
}

menu_correo() {
  local op v
  while true; do
    op=$(ui --title "Correo electrónico" --cancel-button "Volver" \
      --menu "Envío del log del backup por email" 20 78 7 \
      1 "Cuándo enviar        [$MAIL_ENVIAR]" \
      2 "Destinatario(s)      [${MAIL_A:-sin definir}]" \
      3 "Remitente            [${MAIL_DE:-automático}]" \
      4 "Método de envío      [$MAIL_METODO]" \
      5 "Configurar servidor SMTP" \
      6 "Enviar correo de prueba" \
      7 "Enviar ahora el último log") || return
    case $op in
      1) v=$(ui --title "Cuándo enviar" --radiolist "Enviar el log por correo:" 12 66 3 \
           nunca   "No enviar"                   "$([[ $MAIL_ENVIAR == nunca ]] && echo on || echo off)" \
           siempre "Después de cada backup"      "$([[ $MAIL_ENVIAR == siempre ]] && echo on || echo off)" \
           error   "Solo si el backup falla"     "$([[ $MAIL_ENVIAR == error ]] && echo on || echo off)") || continue
         MAIL_ENVIAR="$v"; guardar_correo ;;
      2) v=$(ui --title "Destinatarios" --inputbox "Uno o varios correos separados por coma o espacio:" 8 72 "$MAIL_A") || continue
         if [[ -z $v ]] || destinatarios_validos "$v"; then MAIL_A="$v"; guardar_correo
         else ui --msgbox "Hay una dirección de correo inválida." 7 50; fi ;;
      3) v=$(ui --title "Remitente" --inputbox "Correo remitente (vacío = backup@$(hostname)):" 8 72 "$MAIL_DE") || continue
         if [[ -z $v ]] || correo_valido "$v"; then MAIL_DE="$v"; guardar_correo
         else ui --msgbox "Dirección de correo inválida." 7 40; fi ;;
      4) v=$(ui --title "Método de envío" --radiolist "¿Cómo se envía el correo?" 12 76 2 \
           local "sendmail / msmtp / mail ya instalados en este equipo" "$([[ $MAIL_METODO == local ]] && echo on || echo off)" \
           smtp  "Servidor SMTP directo (usa curl)"                    "$([[ $MAIL_METODO == smtp ]] && echo on || echo off)") || continue
         MAIL_METODO="$v"; guardar_correo
         [[ $v == smtp && -z $SMTP_HOST ]] && menu_smtp ;;
      5) menu_smtp ;;
      6) enviar_prueba ;;
      7) enviar_ultimo_log ;;
    esac
  done
}

# ---------- gestión de directorios seleccionados ------------------------------
agregar_dir() {
  local nuevo d
  nuevo="$(realpath "$1")"
  for d in "${DIRS[@]:-}"; do [[ $d == "$nuevo" ]] && return; done
  DIRS+=("$nuevo")
}

# Navegador de directorios.
# $1 = título, $2 = permitir crear carpetas (0/1), $3 = ruta inicial
# Imprime la ruta elegida; retorna 1 si se cancela.
browse_dir() {
  local titulo="$1" crear="${2:-0}" cur sel name d
  local entries=() items=()
  cur="$(realpath "${3:-/}" 2>/dev/null || echo /)"

  while true; do
    mapfile -t entries < <(find "$cur" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort)
    items=("." "[ OK: elegir esta carpeta ]")
    [[ $cur != "/" ]] && items+=(".." "[ subir un nivel ]")
    (( crear )) && items+=("+" "[ crear carpeta nueva aquí ]")
    for d in "${entries[@]:-}"; do [[ -n $d ]] && items+=("$d" "<dir>"); done

    sel=$(ui --title "$titulo" --cancel-button "Cancelar" \
      --menu $'Ubicación actual:\n'"$cur" 22 76 13 "${items[@]}") || return 1

    case $sel in
      .)  echo "$cur"; return 0 ;;
      ..) cur="$(dirname "$cur")" ;;
      +)  name=$(ui --title "Nueva carpeta" --inputbox "Nombre de la carpeta:" 8 60) || continue
          if [[ -n $name ]] && mkdir -p "$cur/$name" 2>/dev/null; then
            cur="$cur/$name"
          else
            ui --msgbox "No se pudo crear la carpeta." 7 40
          fi ;;
      *)  cur="${cur%/}/$sel" ;;
    esac
  done
}

menu_marcar_dirs() {
  local candidatos=(/home /etc /var/www /var/lib /opt /srv /root /usr/local)
  local todos=() items=() d estado sel
  for d in "${candidatos[@]}" "${DIRS[@]:-}"; do
    [[ -d $d ]] || continue
    [[ " ${todos[*]:-} " == *" $d "* ]] && continue
    todos+=("$d")
  done
  (( ${#todos[@]} )) || { ui --msgbox "No hay directorios para listar." 7 40; return; }

  for d in "${todos[@]}"; do
    estado=off
    [[ " ${DIRS[*]:-} " == *" $d "* ]] && estado=on
    items+=("$d" "dir" "$estado")
  done

  sel=$(ui --title "Directorios sugeridos" --separate-output \
    --checklist "Espacio = marcar/desmarcar, Enter = aceptar" 20 72 12 "${items[@]}") || return
  DIRS=()
  while IFS= read -r d; do [[ -n $d ]] && DIRS+=("$d"); done <<< "$sel"
}

menu_dirs() {
  local op d lista
  while true; do
    lista="Seleccionados: ${#DIRS[@]}"
    for d in "${DIRS[@]:-}"; do [[ -n $d ]] && lista+=$'\n  - '"$d"; done
    op=$(ui --title "Directorios a respaldar" --cancel-button "Volver" \
      --menu "$lista" 22 74 4 \
      1 "Agregar carpeta con el navegador" \
      2 "Marcar / desmarcar de la lista" \
      3 "Quitar todos") || return
    case $op in
      1) d=$(browse_dir "Elegí la carpeta a respaldar" 0 "${HOME:-/}") && agregar_dir "$d" ;;
      2) menu_marcar_dirs ;;
      3) DIRS=() ;;
    esac
  done
}

menu_destino() {
  local op d
  op=$(ui --title "Destino" --cancel-button "Volver" \
    --menu "Destino actual: ${DEST:-<sin definir>}" 14 70 2 \
    1 "Elegir con el navegador (permite crear carpetas)" \
    2 "Escribir la ruta a mano") || return
  case $op in
    1) d=$(browse_dir "Elegí el destino del backup" 1 "${DEST:-/}") && DEST="$d" ;;
    2) d=$(ui --title "Destino" --inputbox "Ruta del destino:" 8 70 "$DEST") && DEST="$d" ;;
  esac
}

menu_modo() {
  local sel
  sel=$(ui --title "Modo de backup" --radiolist "Elegí el modo:" 14 74 2 \
    rsync "Incremental con hardlinks (carpetas navegables)" "$([[ $MODE == rsync ]] && echo on || echo off)" \
    tar   "Un único archivo .tar.gz comprimido"             "$([[ $MODE == tar ]] && echo on || echo off)") || return
  MODE="$sel"
}

menu_exclusiones() {
  local txt
  txt=$(ui --title "Exclusiones" --inputbox \
    "Patrones separados por espacio (se omiten en el backup):" 10 76 "${EXCLUDES[*]:-}") || return
  read -ra EXCLUDES <<< "$txt"
}

# ---------- validación -----------------------------------------------------------
validar() {
  local d
  ERRMSG=""
  (( ${#DIRS[@]} )) || { ERRMSG="No seleccionaste ningún directorio."; return 1; }
  [[ -n $DEST ]]    || { ERRMSG="No definiste el destino."; return 1; }
  for d in "${DIRS[@]}"; do
    [[ -d $d ]] || { ERRMSG="El directorio ya no existe: $d"; return 1; }
  done
  if [[ $MODE == rsync ]] && ! command -v rsync >/dev/null 2>&1; then
    ERRMSG="Falta rsync. Instalalo o usá el modo tar."; return 1
  fi
  mkdir -p -m 700 -- "$DEST" 2>/dev/null || { ERRMSG="No pude crear el destino: $DEST"; return 1; }
  DEST="$(realpath "$DEST")"
  for d in "${DIRS[@]}"; do
    if [[ $DEST == "$d" || $DEST == "$d"/* ]]; then
      ERRMSG="El destino ($DEST) no puede estar dentro de $d"; return 1
    fi
  done
  return 0
}

# ---------- snapshots ---------------------------------------------------------------
limpiar_snapshots() {
  local tipo ruta dispositivo
  for tipo in "${SNAP_CLEANUP[@]:-}"; do
    IFS='|' read -r tipo ruta dispositivo <<< "$tipo"
    case $tipo in
      btrfs) btrfs subvolume delete "$ruta" >/dev/null 2>&1 ;;
      lvm) umount "$ruta" >/dev/null 2>&1
           lvremove -f "$dispositivo" >/dev/null 2>&1
           rmdir "$ruta" >/dev/null 2>&1 ;;
    esac
  done
}

crear_snapshots() {
  local d fstype src mnt snap vg lv snapname snapmnt
  local nuevos=()
  for d in "${DIRS[@]}"; do
    fstype="$(findmnt -no FSTYPE -T "$d")"
    src="$(findmnt -no SOURCE -T "$d")"
    mnt="$(findmnt -no TARGET -T "$d")"
    if [[ $fstype == "btrfs" ]]; then
      snap="$mnt/.snap_backup_$TS"
      if btrfs subvolume snapshot -r "$mnt" "$snap" >/dev/null 2>&1; then
        SNAP_CLEANUP+=("btrfs|$snap|")
        nuevos+=("$snap${d#"$mnt"}"); info "Snapshot btrfs de $d"; continue
      fi
    elif command -v lvs >/dev/null 2>&1 && lvs "$src" >/dev/null 2>&1; then
      vg="$(lvs --noheadings -o vg_name "$src" | xargs)"
      lv="$(lvs --noheadings -o lv_name "$src" | xargs)"
      snapname="snap_backup_$TS"; snapmnt="/mnt/$snapname"
      if lvcreate -s -L 2G -n "$snapname" "/dev/$vg/$lv" >/dev/null 2>&1; then
        mkdir -p "$snapmnt" && mount -o ro "/dev/$vg/$snapname" "$snapmnt"
        SNAP_CLEANUP+=("lvm|$snapmnt|/dev/$vg/$snapname")
        nuevos+=("$snapmnt${d#"$mnt"}"); info "Snapshot LVM de $d"; continue
      fi
    fi
    warn "No se pudo crear snapshot para $d; se copia en vivo."
    nuevos+=("$d")
  done
  DIRS=("${nuevos[@]}")
}

# ---------- unidades: tamaños en MB y velocidades en KB/s ------------------------
# 1 KB = 1024 bytes, 1 MB = 1024 * 1024 bytes. Todo lo que se muestra en el log
# usa estas unidades (el progreso en vivo de rsync solo se ve en pantalla).
ahora_ms() { echo $(( $(date +%s%N) / 1000000 )); }

fmt_mb() { LC_ALL=C awk -v b="${1:-0}" 'BEGIN { printf "%.2f MB", b / 1048576 }'; }

fmt_kbs() {  # $1 = bytes, $2 = milisegundos
  LC_ALL=C awk -v b="${1:-0}" -v ms="${2:-0}" 'BEGIN { if (ms < 1) ms = 1; printf "%.1f KB/s", (b / 1024) / (ms / 1000) }'
}

fmt_dur() {  # $1 = milisegundos
  LC_ALL=C awk -v ms="${1:-0}" 'BEGIN { s = ms / 1000; printf "%02d:%02d:%02d (%.1f s)", s / 3600, (s % 3600) / 60, s % 60, s }'
}

# Resumen de transferencia. $1=rsync|tar $2=bytes de datos $3=bytes del backup $4=milisegundos
resumen_transferencia() {
  local modo="$1" datos="${2:-0}" tam="${3:-0}" ms="${4:-0}"
  [[ $datos =~ ^[0-9]+$ ]] || datos=0
  [[ $tam =~ ^[0-9]+$ ]]   || tam=0
  echo
  echo "---------- RESUMEN DE TRANSFERENCIA ----------"
  echo "Duración:            $(fmt_dur "$ms")"
  if [[ $modo == rsync ]]; then
    echo "Datos copiados:      $(fmt_mb "$datos")  (archivos nuevos o modificados)"
    echo "Tamaño del backup:   $(fmt_mb "$tam")  (incluye los archivos sin cambios)"
  else
    (( datos == 0 )) && datos="$tam"
    echo "Datos procesados:    $(fmt_mb "$datos")  (sin comprimir)"
    echo "Tamaño del .tar.gz:  $(fmt_mb "$tam")"
  fi
  echo "Velocidad promedio:  $(fmt_kbs "$datos" "$ms")"
}

# Suma de bytes realmente copiados según el log de rsync
suma_bytes_rsync() {
  [[ -s $1 ]] || { echo 0; return; }
  sed -n 's/^[^[]*\[[0-9]*\] \(.\{11\}\)|\([0-9]*\)|.*$/\1\t\2/p' "$1" |
    LC_ALL=C awk -F'\t' 'substr($1,1,1) == ">" && substr($1,2,1) == "f" { t += $2 } END { printf "%.0f\n", t }'
}

# ---------- detalle de archivos copiados / cambiados ---------------------------------
# rsync: interpreta el log de itemize ("%i|%n") y lo muestra legible.
listar_cambios_rsync() {
  local f="$1"
  echo
  echo "---------- ARCHIVOS COPIADOS / CAMBIADOS ----------"
  if [[ ! -s $f ]]; then
    echo "(no hubo archivos nuevos ni modificados)"
    return
  fi
  sed -n 's/^[^[]*\[[0-9]*\] \(.\{11\}\)|\([0-9]*\)|\(.*\)$/\1\t\2\t\3/p' "$f" | LC_ALL=C awk -F'\t' '
    BEGIN { split("contenido,tamaño,fecha,permisos,propietario,grupo,-,ACL,atributos", lab, ",") }
    function mb(b,   v) { v = b / 1048576; if (b > 0 && v < 0.01) return "<0.01"; return sprintf("%.2f", v) }
    {
      code = $1; len = $2; name = $3
      y = substr(code, 1, 1); t = substr(code, 2, 1); a = substr(code, 3)
      if (y == "*") next
      if (t == "L") len = 0
      nuevo = (a ~ /^[+]+$/)
      if (t == "d") { if (nuevo) { printf "NUEVO       %7s     /%s/ (carpeta)\n", "-", name; nd++ } next }
      if (y == "h" && !nuevo) next
      if (y == ">") tot += len
      if (nuevo) { printf "NUEVO       %7s MB  /%s\n", mb(len), name; nn++ }
      else {
        causa = ""
        for (i = 1; i <= 9; i++) {
          ch = substr(a, i, 1)
          if (i != 7 && ch != "." && ch != " " && ch != "") causa = causa (causa == "" ? "" : ", ") lab[i]
        }
        printf "MODIFICADO  %7s MB  /%s", mb(len), name
        if (causa != "") printf "   (cambió: %s)", causa
        printf "\n"; nm++
      }
    }
    END {
      if (nn + nm + nd == 0) print "(no hubo archivos nuevos ni modificados)"
      printf "\nResumen: %d archivos nuevos, %d modificados, %d carpetas nuevas (%.2f MB copiados)\n", nn, nm, nd, tot / 1048576
    }'
}

# tar: lista los archivos más nuevos que el marcador del backup anterior.
listar_cambios_tar() {
  local lista="$1" marker="$2" total tmp n mbtot
  echo
  echo "---------- ARCHIVOS COPIADOS / CAMBIADOS ----------"
  total=$(grep -vc '/$' "$lista" || true)
  echo "Archivos incluidos en el .tar.gz: $total"
  echo "Lista completa: $lista"
  if [[ ! -f $marker ]]; then
    echo "Es el primer backup tar en este destino: todos los archivos son nuevos."
    return
  fi
  tmp="$(mktemp)"
  ( cd / && grep -v '/$' "$lista" | tr '\n' '\0' |
    MARKER="$marker" xargs -0 -r sh -c \
      'find "$@" -maxdepth 0 \( -type f -o -type l \) -newer "$MARKER" -printf "%s\t%p\n"' _ ) > "$tmp" 2>/dev/null
  n=$(wc -l < "$tmp")
  echo
  echo "Nuevos o modificados desde el último backup tar:"
  if (( n == 0 )); then
    echo "(ninguno)"
    mbtot="0.00"
  else
    LC_ALL=C awk -F'\t' '{
      b = $1; v = b / 1048576
      s = (b > 0 && v < 0.01) ? "<0.01" : sprintf("%.2f", v)
      p = $2; sub(/^\/+/, "", p)
      printf "NUEVO/MODIF. %7s MB  /%s\n", s, p
    }' "$tmp"
    mbtot=$(LC_ALL=C awk -F'\t' '{ t += $1 } END { printf "%.2f", t / 1048576 }' "$tmp")
  fi
  echo
  echo "Resumen: $n archivos nuevos o modificados de $total ($mbtot MB)"
  rm -f "$tmp"
}

# ---------- retención de backups -----------------------------------------------
# Al terminar un backup EXITOSO se eliminan los backups del destino que sean más
# viejos que RETENCION días (0 = conservar todo). Solo se tocan archivos con el
# nombre exacto que crea este script (backup_AAAA-MM-DD_HH-MM-SS...).
texto_retencion() {
  if (( RETENCION > 0 )); then echo "$RETENCION días"; else echo "sin límite"; fi
}

# Marcas de tiempo (AAAA-MM-DD_HH-MM-SS) de los backups que hay en $DEST
marcas_backups() {
  local f n
  for f in "$DEST"/backup_*; do
    [[ -e $f || -L $f ]] || continue
    n="$(basename "$f")"
    if [[ $n =~ ^backup_([0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2})(\.tar\.gz|\.lista\.txt|\.log)?$ ]]; then
      echo "${BASH_REMATCH[1]}"
    fi
  done | sort -u
}

# Marcas de los backups que superan los $1 días. Nunca incluye: el backup en
# curso, el último backup existente ni al que apunta el enlace "latest".
marcas_expiradas() {
  local dias="$1" corte m ep latest="" newest
  corte=$(( $(date +%s) - dias * 86400 ))
  [[ -L $DEST/latest ]] && latest="$(basename "$(readlink -f "$DEST/latest")")"
  newest="$(marcas_backups | tail -1)"
  while IFS= read -r m; do
    [[ -z $m || $m == "${TS:-}" || $m == "$newest" || $latest == "backup_$m" ]] && continue
    ep=$(date -d "${m:0:10} ${m:11:2}:${m:14:2}:${m:17:2}" +%s 2>/dev/null) || continue
    (( ep < corte )) && echo "$m"
  done < <(marcas_backups)
}

aplicar_retencion() {
  local dias="$1" m f b sz total_bytes=0 borrados=0 restantes
  echo
  echo "---------- RETENCIÓN ----------"
  if (( dias <= 0 )); then
    echo "Retención: sin límite, no se eliminó ningún backup anterior."
    return 0
  fi
  if [[ -z $DEST || $DEST == "/" || ! -d $DEST ]]; then
    warn "Destino inválido; no se aplicó la retención."; return 1
  fi
  echo "Se conservan los backups de los últimos $dias días."
  while IFS= read -r m; do
    [[ -z $m ]] && continue
    sz=0
    for f in "$DEST/backup_$m" "$DEST/backup_$m.tar.gz" "$DEST/backup_$m.lista.txt" "$DEST/backup_$m.log"; do
      [[ -L $f ]] && continue
      [[ -e $f ]] || continue
      b=$(du -sb -- "$f" 2>/dev/null | cut -f1); sz=$((sz + ${b:-0}))
      if rm -rf -- "$f"; then :; else warn "No se pudo eliminar $f"; fi
    done
    echo "ELIMINADO   backup_$m   ($(fmt_mb "$sz"))"
    total_bytes=$((total_bytes + sz))
    borrados=$((borrados + 1))
  done < <(marcas_expiradas "$dias")
  restantes=$(marcas_backups | wc -l)
  echo
  echo "Retención: eliminados $borrados ($(fmt_mb "$total_bytes") de tamaño aparente), conservados $restantes backups."
}

vista_previa_retencion() {
  local tmp m total exp=0
  if [[ -z $DEST || ! -d $DEST ]]; then
    ui --msgbox "Definí primero un destino existente." 7 50; return
  fi
  if (( RETENCION <= 0 )); then
    ui --msgbox "La retención está en \"sin límite\": no se eliminaría nada." 8 60; return
  fi
  tmp="$(mktemp)"
  total=$(marcas_backups | wc -l)
  {
    echo "Destino:   $DEST"
    echo "Retención: $RETENCION días"
    echo "Backups encontrados: $total"
    echo
    echo "Se ELIMINARÍAN en el próximo backup exitoso:"
    while IFS= read -r m; do
      [[ -z $m ]] && continue
      echo "  backup_$m"; exp=$((exp + 1))
    done < <(marcas_expiradas "$RETENCION")
    (( exp == 0 )) && echo "  (ninguno)"
    echo
    echo "Se conservarían: $(( total - exp ))"
  } > "$tmp"
  ui --title "Vista previa de retención" --textbox "$tmp" 22 72
  rm -f "$tmp"
}

menu_retencion() {
  local op v
  while true; do
    op=$(ui --title "Retención de backups" --cancel-button "Volver" \
      --menu "Retención actual: $(texto_retencion)"$'\n\n'"Tras cada backup exitoso se eliminan los más viejos que ese plazo." 17 76 3 \
      1 "Elegir cantidad de días" \
      2 "Sin límite (conservar todo)" \
      3 "Vista previa: qué se eliminaría ahora") || return
    case $op in
      1) v=$(ui --title "Días de retención" --menu "Conservar los backups de los últimos:" 19 60 8 \
           7 "7 días" 14 "14 días" 30 "30 días" 60 "60 días" \
           90 "90 días" 180 "180 días" 365 "1 año" otro "Otro valor...") || continue
         if [[ $v == otro ]]; then
           v=$(ui --title "Días de retención" --inputbox "Cantidad de días (1 a 3650):" 8 50 "${RETENCION#0}") || continue
           if [[ ! $v =~ ^[0-9]+$ ]] || (( v < 1 || v > 3650 )); then
             ui --msgbox "Valor inválido. Ingresá un número entre 1 y 3650." 7 56; continue
           fi
         fi
         if ui --title "Confirmar" --yesno "Después de cada backup exitoso se ELIMINARÁN los backups con más de $v días en:"$'\n\n'"${DEST:-<destino sin definir>}"$'\n\n'"¿Confirmás?" 12 70; then
           RETENCION="$v"
         fi ;;
      2) RETENCION=0 ;;
      3) vista_previa_retencion ;;
    esac
  done
}

# ---------- el backup en sí ------------------------------------------------------------
# Se ejecuta en un subshell; su salida va al log (o a la terminal con -y).
hacer_backup() {
  local rc=0 e TARGET LATEST ARCHIVO cambios lista marker newmarker terr t0 t1 procesados
  trap limpiar_snapshots EXIT
  trap 'exit 143' TERM INT

  echo "=== Backup $TS ==="
  echo "Configuración: ${CURRENT_CFG:-(sin nombre)}"
  echo "Modo:          $MODE"
  echo "Destino:       $DEST"
  echo "Origen:        ${DIRS[*]}"
  echo "Retención:     $(texto_retencion)"
  (( EUID != 0 )) && warn "No sos root: algunos archivos podrían no poder leerse."
  (( SNAPSHOT )) && crear_snapshots

  case $MODE in
    rsync)
      TARGET="$DEST/backup_$TS"
      LATEST="$DEST/latest"
      cambios="$DEST/.cambios_$TS.tmp"
      local args=(-aHAXR --numeric-ids --no-inc-recursive
                  --log-file="$cambios" --log-file-format='%i|%l|%n')
      (( SHOW_PROGRESS )) && args+=(--info=progress2)
      for e in "${EXCLUDES[@]:-}"; do [[ -n $e ]] && args+=(--exclude="$e"); done
      [[ -L $LATEST ]] && args+=(--link-dest="$(readlink -f "$LATEST")")
      mkdir -p "$TARGET"
      t0=$(ahora_ms)
      rsync "${args[@]}" "${DIRS[@]}" "$TARGET/"
      rc=$?
      t1=$(ahora_ms)
      listar_cambios_rsync "$cambios"
      resumen_transferencia rsync "$(suma_bytes_rsync "$cambios")" "$(du -sb "$TARGET" 2>/dev/null | cut -f1)" $((t1 - t0))
      rm -f "$cambios"
      # 24 = archivos desaparecidos durante la copia (normal en vivo)
      if [[ $rc -eq 0 || $rc -eq 24 ]]; then
        ln -sfn "$TARGET" "$LATEST"
        [[ $rc -eq 24 ]] && warn "Algunos archivos desaparecieron durante la copia."
        info "Backup completo en $TARGET"; rc=0
      else
        err "rsync terminó con código $rc"
      fi
      ;;
    tar)
      ARCHIVO="$DEST/backup_$TS.tar.gz"
      lista="$DEST/backup_$TS.lista.txt"
      marker="$DEST/.ultimo_backup_tar"
      newmarker="$DEST/.marker_$TS.tmp"
      : > "$newmarker"
      local targs=(--warning=no-file-removed --totals --numeric-owner --xattrs --acls -cvzpf "$ARCHIVO")
      for e in "${EXCLUDES[@]:-}"; do [[ -n $e ]] && targs+=(--exclude="$e"); done
      terr="$DEST/.tar_err_$TS.tmp"
      t0=$(ahora_ms)
      tar "${targs[@]}" "${DIRS[@]}" > "$lista" 2> "$terr"
      rc=$?
      t1=$(ahora_ms)
      grep -v '^Total bytes written' "$terr" >&2
      procesados=$(sed -n 's/^Total bytes written: \([0-9]*\).*/\1/p' "$terr" | tail -1)
      rm -f "$terr"
      listar_cambios_tar "$lista" "$marker"
      resumen_transferencia tar "${procesados:-0}" "$(stat -c %s "$ARCHIVO" 2>/dev/null || echo 0)" $((t1 - t0))
      # tar devuelve 1 si un archivo cambió mientras se leía: copia utilizable
      if [[ $rc -eq 0 ]]; then
        info "Backup completo: $ARCHIVO"
      elif [[ $rc -eq 1 ]]; then
        warn "Hubo archivos modificados durante la lectura (en uso). Backup generado: $ARCHIVO"; rc=0
      else
        err "tar terminó con código $rc"
      fi
      if [[ $rc -eq 0 ]]; then mv -f "$newmarker" "$marker"; else rm -f "$newmarker"; fi
      ;;
  esac

  if (( RETENCION > 0 )); then
    if [[ $rc -eq 0 ]]; then
      aplicar_retencion "$RETENCION"
    else
      echo
      echo "Retención: omitida porque el backup falló (no se eliminó nada)."
    fi
  fi
  return $rc
}

# ---------- progreso + ejecución desde la UI ---------------------------------------------
barra_progreso() {
  local rcfile="$1" n=0 pct
  {
    until [[ -s $rcfile ]]; do
      pct=""
      if [[ $MODE == rsync && -f $LOG_FILE ]]; then
        pct=$(tail -c 4000 "$LOG_FILE" | tr '\r' '\n' |
              grep -o '[0-9]\+%  *[0-9.]*[kKMGT]\?B/s' | tail -1 | grep -o '^[0-9]\+')
      fi
      if [[ -z $pct ]]; then n=$(( (n + 5) % 95 )); pct=$n; fi
      printf 'XXX\n%s\nCopiando datos (modo %s)...\nXXX\n' "$pct" "$MODE"
      sleep 1
    done
    echo 100
  } | ui --title "Backup en curso" --gauge "Preparando..." 8 70 0
}

ver_log() {
  local log="$1" tmp
  [[ -f $log ]] || { ui --msgbox "No hay log para mostrar." 7 40; return; }
  tmp="$(mktemp)"
  limpiar_log "$log" | tail -n 3000 > "$tmp"
  ui --title "Log: $(basename "$log")" --textbox "$tmp" 22 76
  rm -f "$tmp"
}

ejecutar_desde_ui() {
  local rcfile rc resumen d mailmsg=""
  if ! validar; then ui --title "Error" --msgbox "$ERRMSG" 8 60; return; fi

  resumen="Configuración: ${CURRENT_CFG:-(sin nombre)}"$'\n'"Modo: $MODE   Snapshot: $( ((SNAPSHOT)) && echo SI || echo NO )   Retención: $(texto_retencion)"$'\n'"Destino: $DEST"$'\n\n'"Origen:"
  for d in "${DIRS[@]}"; do resumen+=$'\n'"  - $d"; done
  ui --title "Confirmar" --yesno "$resumen"$'\n\n'"¿Iniciar el backup?" 20 72 || return

  guardar_config ultimo
  TS="$(date +%F_%H-%M-%S)"
  LOG_FILE="$DEST/backup_$TS.log"
  SHOW_PROGRESS=1
  rcfile="$(mktemp)"; : > "$rcfile"

  ( hacer_backup; echo $? > "$rcfile" ) > "$LOG_FILE" 2>&1 &
  barra_progreso "$rcfile"
  wait
  rc="$(cat "$rcfile")"; rm -f "$rcfile"
  # El log definitivo no lleva las líneas de progreso en vivo (MB/s de rsync)
  limpiar_log "$LOG_FILE" > "$LOG_FILE.tmp" && mv -f "$LOG_FILE.tmp" "$LOG_FILE"

  if debe_enviar_correo "$rc"; then
    ui --infobox "Enviando el log por correo a $MAIL_A ..." 5 70
    if enviar_correo "$LOG_FILE" "$rc"; then
      mailmsg=$'\n\nCorreo enviado a: '"$MAIL_A"
    else
      mailmsg=$'\n\nNO se pudo enviar el correo:\n'"$MAIL_ERR"
    fi
  fi

  if [[ $rc -eq 0 ]]; then
    ui --title "Listo" --msgbox "Backup finalizado correctamente."$'\n\n'"Log: $LOG_FILE$mailmsg" 14 74
  else
    ui --title "Falló" --msgbox "El backup terminó con errores (código $rc)."$'\n\n'"Log: $LOG_FILE$mailmsg" 14 74
  fi
  ui --yesno "¿Querés ver el log (incluye los archivos copiados/cambiados)?" 8 60 && ver_log "$LOG_FILE"
}

ver_ultimo_log() {
  local ultimo
  [[ -d $DEST ]] || { ui --msgbox "Definí primero un destino existente." 7 50; return; }
  if ultimo="$(ultimo_log)"; then ver_log "$ultimo"; else ui --msgbox "No hay logs en $DEST." 7 50; fi
}

# ---------- menú principal -----------------------------------------------------------------
menu_principal() {
  local op nota=""
  (( EUID != 0 )) && nota=$'\n(Sin root: algunos archivos podrían no poder leerse)'
  while true; do
    op=$(ui --title "Backup Linux" --cancel-button "Salir" \
      --menu "Configuración actual: ${CURRENT_CFG:-(sin nombre)}$nota" 22 76 10 \
      1 "Directorios a respaldar  [${#DIRS[@]} seleccionados]" \
      2 "Destino                  [${DEST:-sin definir}]" \
      3 "Modo                     [$MODE]" \
      4 "Snapshot LVM/btrfs       [$( ((SNAPSHOT)) && echo SI || echo NO )]" \
      5 "Exclusiones              [${#EXCLUDES[@]} patrones]" \
      6 "Retención de backups     [$(texto_retencion)]" \
      7 "Guardar / cargar configuración" \
      8 "Correo electrónico       [$MAIL_ENVIAR]" \
      9 ">>> EJECUTAR BACKUP <<<" \
      10 "Ver último log" ) || { ui --yesno "¿Salir del programa?" 7 40 && break; continue; }
    case $op in
      1) menu_dirs ;;
      2) menu_destino ;;
      3) menu_modo ;;
      4) SNAPSHOT=$(( 1 - SNAPSHOT )) ;;
      5) menu_exclusiones ;;
      6) menu_retencion ;;
      7) menu_configs ;;
      8) menu_correo ;;
      9) ejecutar_desde_ui ;;
      10) ver_ultimo_log ;;
    esac
  done
  guardar_config ultimo
  clear
}

# ---------- cancelación (usada por la aplicación de escritorio) -----------------
STOP_FILE=""
MAIN_PID=$$
WATCHER_PID=
CANCELADO=0

# Lista todos los descendientes de un proceso (se arma la lista completa antes de
# matar, para no perder a los hijos de un proceso que ya murió)
listar_descendientes() {
  local p
  for p in $(pgrep -P "$1" 2>/dev/null); do
    echo "$p"
    listar_descendientes "$p"
  done
}

# Envía TERM a todos los descendientes de un proceso
matar_descendientes() {
  local p
  for p in $(listar_descendientes "$1"); do kill -TERM "$p" 2>/dev/null; done
}

al_cancelar() {
  CANCELADO=1
  matar_descendientes "$MAIN_PID"
}

# Mira cada segundo si existe el archivo de parada y, si es así, se cancela solo.
# Termina por su cuenta si el script principal ya no existe y no hereda la salida.
iniciar_vigilante_parada() {
  (
    while sleep 1; do
      kill -0 "$MAIN_PID" 2>/dev/null || break
      if [[ -e $STOP_FILE ]]; then kill -TERM "$MAIN_PID" 2>/dev/null; break; fi
    done
  ) >/dev/null 2>&1 &
  WATCHER_PID=$!
}

# Borra lo que dejó a medias un backup cancelado
limpiar_cancelado() {
  [[ -n $DEST && -n $TS ]] || return 0
  rm -rf -- "$DEST/backup_$TS" "$DEST/backup_$TS.tar.gz" "$DEST/backup_$TS.lista.txt" \
            "$DEST/.cambios_$TS.tmp" "$DEST/.marker_$TS.tmp" "$DEST/.tar_err_$TS.tmp"
}

# ---------- main ------------------------------------------------------------------------------
main() {
  local OPTIND=1 opt d rc
  local CLI_DIRS=() CLI_DEST="" CLI_MODE="" CLI_SNAP=0 CFG_NAME="" FORCE_MAIL=0 CLI_CFGDIR="" LISTAR=0 CLI_RET="" CLI_EXCL=() CLI_EXCL_SET=0 CLI_NAME="" PRUEBA=0

  while getopts ":d:o:m:c:C:r:x:n:k:psyelth" opt; do
    case $opt in
      d) if [[ -d $OPTARG ]]; then CLI_DIRS+=("$(realpath "$OPTARG")"); else warn "No existe: $OPTARG"; fi ;;
      o) CLI_DEST="$OPTARG" ;;
      m) [[ $OPTARG == rsync || $OPTARG == tar ]] && CLI_MODE="$OPTARG" || { err "Modo inválido: $OPTARG"; exit 1; } ;;
      c) CFG_NAME="$OPTARG" ;;
      C) CLI_CFGDIR="$OPTARG" ;;
      r) if [[ $OPTARG =~ ^[0-9]+$ ]]; then CLI_RET="$OPTARG"; else err "Días de retención inválidos: $OPTARG"; exit 1; fi ;;
      x) CLI_EXCL_SET=1; [[ -n $OPTARG ]] && CLI_EXCL+=("$OPTARG") ;;
      n) CLI_NAME="$OPTARG" ;;
      p) SHOW_PROGRESS=1 ;;
      k) STOP_FILE="$OPTARG" ;;
      t) PRUEBA=1 ;;
      s) CLI_SNAP=1 ;;
      y) NOUI=1 ;;
      e) FORCE_MAIL=1 ;;
      l) LISTAR=1 ;;
      h) sed -n '2,/^$/{/^$/!p}' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
      *) err "Opción inválida. Usá -h para ayuda."; exit 1 ;;
    esac
  done

  if [[ -n $CLI_CFGDIR ]]; then
    [[ $CLI_CFGDIR == /* ]] || CLI_CFGDIR="$PWD/$CLI_CFGDIR"
    mkdir -p "$CLI_CFGDIR" 2>/dev/null || { err "No pude crear la carpeta $CLI_CFGDIR"; exit 1; }
    CONFIG_DIR="$(realpath "$CLI_CFGDIR")"; CONFIG_FIJA=1; CONFIG_AVISO=""
    actualizar_rutas_config
  fi
  if (( LISTAR )); then
    echo "Configuraciones en $CONFIG_DIR:"; nombres_configs | sed 's/^/  - /'; exit 0
  fi
  if [[ $CFG_NAME == ultimo || $CFG_NAME == correo ]]; then err "Nombre reservado: $CFG_NAME"; exit 1; fi
  (( NOUI )) && [[ -n $CONFIG_AVISO ]] && warn "${CONFIG_AVISO//$'\n'/ }"

  cargar_correo
  (( FORCE_MAIL )) && MAIL_ENVIAR=siempre

  if (( PRUEBA )); then
    local tmp_prueba
    tmp_prueba="$(mktemp)"
    printf '=== Correo de prueba de backup.sh ===\nFecha: %s\n[OK] Si recibís este mensaje, el envío de correos funciona.\n' "$(date '+%F %T')" > "$tmp_prueba"
    if enviar_correo "$tmp_prueba" 0 prueba; then
      rm -f "$tmp_prueba"; echo "Correo de prueba enviado a: $MAIL_A"; exit 0
    else
      rm -f "$tmp_prueba"; err "No se pudo enviar: $MAIL_ERR"; exit 1
    fi
  fi

  # Configuración base: la pedida con -c, o la última usada (solo en modo UI)
  if [[ -n $CFG_NAME ]]; then
    cargar_config "$CFG_NAME" || { err "No existe la configuración '$CFG_NAME' en $CONFIG_DIR"; exit 1; }
    CURRENT_CFG="$CFG_NAME"
  elif (( ! NOUI )) && (( ${#CLI_DIRS[@]} == 0 )) && [[ -z $CLI_DEST ]]; then
    cargar_config ultimo || true
  fi

  # Lo indicado por línea de comandos tiene prioridad
  if (( ${#CLI_DIRS[@]} )); then DIRS=(); for d in "${CLI_DIRS[@]}"; do agregar_dir "$d"; done; fi
  [[ -n $CLI_DEST ]] && DEST="$CLI_DEST"
  [[ -n $CLI_MODE ]] && MODE="$CLI_MODE"
  (( CLI_SNAP )) && SNAPSHOT=1
  [[ -n $CLI_RET ]] && RETENCION=$CLI_RET
  (( CLI_EXCL_SET )) && EXCLUDES=("${CLI_EXCL[@]}")
  [[ -n $CLI_NAME ]] && CURRENT_CFG="$CLI_NAME"

  if (( NOUI )); then
    validar || { err "$ERRMSG"; exit 1; }
    TS="$(date +%F_%H-%M-%S)"
    LOG_FILE="$DEST/backup_$TS.log"
    echo "Log: $LOG_FILE"

    local rcfile bgpid
    rcfile="$(mktemp)"
    trap al_cancelar TERM INT
    [[ -n $STOP_FILE ]] && iniciar_vigilante_parada
    { ( hacer_backup ) 2>&1 | tee "$LOG_FILE"; echo "${PIPESTATUS[0]}" > "$rcfile"; } &
    bgpid=$!
    # 'wait' se interrumpe con la señal de cancelación; se vuelve a esperar hasta que termine
    while kill -0 "$bgpid" 2>/dev/null; do wait "$bgpid" 2>/dev/null; done
    rc="$(cat "$rcfile" 2>/dev/null)"; rm -f "$rcfile"
    [[ $rc =~ ^[0-9]+$ ]] || rc=1
    [[ -n $WATCHER_PID ]] && kill "$WATCHER_PID" 2>/dev/null
    if (( CANCELADO )); then
      rc=130
      limpiar_cancelado
      echo "[AVISO] Backup cancelado por el usuario; se eliminaron los archivos incompletos." | tee -a "$LOG_FILE"
    fi
    # El log definitivo no lleva las líneas de progreso en vivo
    if (( SHOW_PROGRESS )) && [[ -f $LOG_FILE ]]; then
      limpiar_log "$LOG_FILE" > "$LOG_FILE.tmp" && mv -f "$LOG_FILE.tmp" "$LOG_FILE"
    fi
    if debe_enviar_correo "$rc"; then
      if enviar_correo "$LOG_FILE" "$rc"; then info "Log enviado por correo a $MAIL_A"
      else warn "No se pudo enviar el correo: $MAIL_ERR"; fi
    fi
    exit "$rc"
  fi

  detectar_ui
  [[ -n $CONFIG_AVISO ]] && ui --title "Aviso" --msgbox "$CONFIG_AVISO" 12 70
  menu_principal
}

# Solo ejecuta main si el archivo se corre directamente (no con "source")
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
