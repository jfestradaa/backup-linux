#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="Backup Linux"
APP_DIR="$HOME/.local/opt/backup-linux"
BIN_DIR="$HOME/.local/bin"
APP_MENU_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
ICON_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor/scalable/apps"
INSTALLER="$(readlink -f -- "$0" 2>/dev/null || printf '%s' "$0")"

show_message() {
    local title="$1" message="$2" kind="${3:-info}"
    if command -v zenity >/dev/null 2>&1; then
        if [[ "$kind" == error ]]; then zenity --error --title="$title" --text="$message" 2>/dev/null || true
        else zenity --info --title="$title" --text="$message" 2>/dev/null || true; fi
    elif command -v kdialog >/dev/null 2>&1; then
        if [[ "$kind" == error ]]; then kdialog --error "$message" --title "$title" 2>/dev/null || true
        else kdialog --msgbox "$message" --title "$title" 2>/dev/null || true; fi
    elif command -v python3 >/dev/null 2>&1 && python3 -c 'import tkinter' >/dev/null 2>&1; then
        python3 -c 'import sys, tkinter as tk; from tkinter import messagebox; root=tk.Tk(); root.withdraw(); (messagebox.showerror if sys.argv[3] == "error" else messagebox.showinfo)(sys.argv[1], sys.argv[2]); root.destroy()' "$title" "$message" "$kind" 2>/dev/null || printf '%s: %s\n' "$title" "$message" >&2
    else
        printf '%s: %s\n' "$title" "$message" >&2
    fi
}

ask_yes_no() {
    local title="$1" message="$2"
    if command -v zenity >/dev/null 2>&1; then
        zenity --question --title="$title" --text="$message" 2>/dev/null
    elif command -v kdialog >/dev/null 2>&1; then
        kdialog --yesno "$message" --title "$title" 2>/dev/null
    elif command -v python3 >/dev/null 2>&1 && python3 -c 'import tkinter' >/dev/null 2>&1; then
        python3 -c 'import sys, tkinter as tk; from tkinter import messagebox; root=tk.Tk(); root.withdraw(); answer=messagebox.askyesno(sys.argv[1], sys.argv[2]); root.destroy(); sys.exit(0 if answer else 1)' "$title" "$message"
    elif [[ -t 0 ]]; then
        printf '%s\n' "$message"
        read -r -p '¿Continuar? [s/N] ' answer
        [[ "$answer" =~ ^([sS]|[sS][iI])$ ]]
    else
        return 2
    fi
}

die() { show_message "$1" "$2" error; exit "${3:-1}"; }

package_plan() {
    local id=""
    if [[ -r /etc/os-release ]]; then . /etc/os-release; id="${ID:-}"; fi
    case "$id" in
        debian|ubuntu|linuxmint|pop)
            PKG_MANAGER="apt-get"; PKG_ARGS=(install -y)
            PACKAGES=(python3 python3-gi gir1.2-gtk-4.0 rsync tar pkexec polkitd systemd curl)
            ;;
        fedora|rhel|centos|rocky|almalinux)
            PKG_MANAGER="dnf"; PKG_ARGS=(install -y)
            PACKAGES=(python3 python3-gobject gtk4 rsync tar polkit systemd curl)
            ;;
        arch|manjaro|endeavouros)
            PKG_MANAGER="pacman"; PKG_ARGS=(-S --needed --noconfirm)
            PACKAGES=(python python-gobject gtk4 rsync tar polkit systemd curl)
            ;;
        opensuse*|sles)
            PKG_MANAGER="zypper"; PKG_ARGS=(--non-interactive install)
            PACKAGES=(python3 python3-gobject-Gtk4 gtk4 rsync tar polkit systemd curl)
            ;;
        *)
            if command -v apt-get >/dev/null 2>&1; then
                PKG_MANAGER="apt-get"; PKG_ARGS=(install -y)
                PACKAGES=(python3 python3-gi gir1.2-gtk-4.0 rsync tar pkexec polkitd systemd curl)
            elif command -v dnf >/dev/null 2>&1; then
                PKG_MANAGER="dnf"; PKG_ARGS=(install -y)
                PACKAGES=(python3 python3-gobject gtk4 rsync tar polkit systemd curl)
            elif command -v pacman >/dev/null 2>&1; then
                PKG_MANAGER="pacman"; PKG_ARGS=(-S --needed --noconfirm)
                PACKAGES=(python python-gobject gtk4 rsync tar polkit systemd curl)
            else
                PKG_MANAGER=""; PACKAGES=()
            fi
            ;;
    esac
}

check_dependencies() {
    MISSING=()
    command -v python3 >/dev/null 2>&1 || MISSING+=("Python 3")
    if command -v python3 >/dev/null 2>&1; then
        python3 -c 'import gi; gi.require_version("Gtk", "4.0"); from gi.repository import Gtk' >/dev/null 2>&1 || MISSING+=("GTK 4 / PyGObject")
    else
        MISSING+=("GTK 4 / PyGObject")
    fi
    command -v rsync >/dev/null 2>&1 || MISSING+=(rsync)
    command -v tar >/dev/null 2>&1 || MISSING+=(tar)
    command -v pkexec >/dev/null 2>&1 || MISSING+=(PolicyKit/pkexec)
    command -v systemctl >/dev/null 2>&1 || MISSING+=(systemd)
    command -v curl >/dev/null 2>&1 || MISSING+=(curl)
}

install_dependencies() {
    package_plan
    if [[ -z "$PKG_MANAGER" || ${#PACKAGES[@]} -eq 0 ]]; then
        die "No se pudo detectar el gestor de paquetes" \
            "Faltan dependencias (${MISSING[*]}). Instálalas con el gestor de paquetes de tu distribución y vuelve a ejecutar este instalador."
    fi
    if ! command -v "$PKG_MANAGER" >/dev/null 2>&1; then
        die "Gestor de paquetes no disponible" "No se encontró $PKG_MANAGER para instalar: ${PACKAGES[*]}"
    fi
    local missing_text package_text prompt
    missing_text="$(printf '• %s\n' "${MISSING[@]}")"
    package_text="$(printf '%s ' "${PACKAGES[@]}")"
    prompt="$(printf 'Faltan dependencias para Backup Linux:\n\n%s\nSe instalarán los paquetes:\n%s\n\n¿Deseas instalarlos ahora? Se solicitará autorización de administrador.' "$missing_text" "$package_text")"
    if ask_yes_no "Dependencias necesarias" "$prompt"; then
        :
    else
        local answer=$?
        if ((answer == 2)); then
            die "Abre el instalador desde una terminal" \
                "No hay un diálogo gráfico para confirmar la instalación. Ejecuta este archivo desde una terminal para revisar e instalar las dependencias."
        fi
        exit 0
    fi
    if command -v pkexec >/dev/null 2>&1; then
        pkexec "$PKG_MANAGER" "${PKG_ARGS[@]}" "${PACKAGES[@]}" || die "No se instalaron las dependencias" "La instalación fue cancelada o el gestor de paquetes informó un error."
    elif [[ -t 0 ]] && command -v sudo >/dev/null 2>&1; then
        sudo "$PKG_MANAGER" "${PKG_ARGS[@]}" "${PACKAGES[@]}" || die "No se instalaron las dependencias" "La instalación fue cancelada o el gestor de paquetes informó un error."
    else
        local deps_script quoted arg
        deps_script="$(mktemp "${TMPDIR:-/tmp}/backup-linux-deps.XXXXXX.sh")"
        {
            printf '#!/usr/bin/env bash\nset -e\n'
            printf 'sudo'
            for arg in "$PKG_MANAGER" "${PKG_ARGS[@]}" "${PACKAGES[@]}"; do
                printf -v quoted '%q' "$arg"
                printf ' %s' "$quoted"
            done
            printf ' && '
            printf -v quoted '%q' "$INSTALLER"
            printf '%s install\n' "$quoted"
        } > "$deps_script"
        chmod 700 "$deps_script"
        if command -v gnome-terminal >/dev/null 2>&1; then
            gnome-terminal -- bash "$deps_script" >/dev/null 2>&1 &
        elif command -v konsole >/dev/null 2>&1; then
            konsole -e bash "$deps_script" >/dev/null 2>&1 &
        elif command -v xfce4-terminal >/dev/null 2>&1; then
            xfce4-terminal --command "bash '$deps_script'" >/dev/null 2>&1 &
        elif command -v xterm >/dev/null 2>&1; then
            xterm -e bash "$deps_script" >/dev/null 2>&1 &
        else
            rm -f "$deps_script"
            die "Falta pkexec" "No se encontró un terminal gráfico para pedir la contraseña de sudo. Instala PolicyKit/pkexec o ejecuta este instalador desde una terminal."
        fi
        show_message "Instalación de dependencias iniciada" "Se abrió una terminal para instalar los paquetes. Backup Linux se instalará automáticamente al terminar."
        exit 0
    fi
    check_dependencies
    ((${#MISSING[@]} == 0)) || die "Aún faltan dependencias" "No se detectaron correctamente: ${MISSING[*]}. Revisa la instalación e inténtalo de nuevo."
}

extract_payload() {
    local line
    line="$(awk '/^__BACKUP_LINUX_PAYLOAD__$/ {print NR + 1; exit}' "$INSTALLER")"
    [[ -n "$line" ]] || die "Instalador dañado" "No se encontró el contenido de la aplicación."
    mkdir -p "$APP_DIR"
    tail -n +"$line" "$INSTALLER" | base64 -d | tar -xz -C "$APP_DIR" || die "No se pudo extraer la aplicación" "El archivo de instalación puede estar incompleto."
}

install_app() {
    check_dependencies
    if ((${#MISSING[@]})); then install_dependencies; fi
    mkdir -p "$BIN_DIR" "$APP_MENU_DIR" "$ICON_DIR"
    extract_payload
    chmod 755 "$APP_DIR/backup-desktop" "$APP_DIR/backup.sh" "$APP_DIR/backup_gtk.py" "$APP_DIR/backup_job.py" "$APP_DIR/uninstall-backup-linux"
    install -m 644 "$APP_DIR/backup-linux.svg" "$ICON_DIR/backup-linux.svg"
    install -m 755 "$APP_DIR/uninstall-backup-linux" "$BIN_DIR/uninstall-backup-linux"

    cat > "$BIN_DIR/backup-desktop" <<EOF
#!/usr/bin/env sh
exec python3 "$APP_DIR/backup_gtk.py" "\$@"
EOF
    chmod 755 "$BIN_DIR/backup-desktop"

    cat > "$APP_MENU_DIR/backup-linux.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Backup Linux
Comment=Create and manage backups
Comment[es]=Crear y gestionar copias de seguridad
Exec="$BIN_DIR/backup-desktop"
Icon=backup-linux
Terminal=false
Categories=System;Utility;GTK;
StartupNotify=true
EOF
    chmod 644 "$APP_MENU_DIR/backup-linux.desktop"

    cat > "$APP_MENU_DIR/backup-linux-uninstall.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Uninstall Backup Linux
Name[es]=Desinstalar Backup Linux
Comment=Remove Backup Linux and all its settings
Comment[es]=Eliminar Backup Linux y toda su configuración
Exec="$BIN_DIR/uninstall-backup-linux"
Icon=backup-linux
Terminal=false
Categories=System;Utility;
EOF
    chmod 644 "$APP_MENU_DIR/backup-linux-uninstall.desktop"

    command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$APP_MENU_DIR" >/dev/null 2>&1 || true
    command -v gtk-update-icon-cache >/dev/null 2>&1 && gtk-update-icon-cache -f -t "${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor" >/dev/null 2>&1 || true
    show_message "Instalación completada" \
        "Backup Linux quedó instalado. Puedes abrirlo desde el menú de aplicaciones. Para desinstalar la aplicación y borrar toda su configuración, usa «Desinstalar Backup Linux» en el menú o ejecuta: $BIN_DIR/uninstall-backup-linux"
}

run_uninstaller() {
    if [[ -x "$BIN_DIR/uninstall-backup-linux" ]]; then
        exec "$BIN_DIR/uninstall-backup-linux"
    fi
    local temp line result
    temp="$(mktemp -d "${TMPDIR:-/tmp}/backup-linux-uninstall.XXXXXX")"
    line="$(awk '/^__BACKUP_LINUX_PAYLOAD__$/ {print NR + 1; exit}' "$INSTALLER")"
    if [[ -z "$line" ]] || ! tail -n +"$line" "$INSTALLER" | base64 -d | tar -xz -C "$temp" uninstall-backup-linux; then
        rm -rf -- "$temp"
        die "Instalador dañado" "No se pudo extraer el desinstalador."
    fi
    if bash "$temp/uninstall-backup-linux"; then result=0; else result=$?; fi
    rm -rf -- "$temp"
    exit "$result"
}

case "${1:-install}" in
    install) install_app ;;
    --uninstall|uninstall) run_uninstaller ;;
    *) echo "Uso: $0 [install|--uninstall]" >&2; exit 2 ;;
esac

exit 0

__BACKUP_LINUX_PAYLOAD__
