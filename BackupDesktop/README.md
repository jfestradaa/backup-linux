# Backup Linux

Aplicación de escritorio en español para crear copias de seguridad con GTK 4. La ventana funciona en la sesión normal del usuario; PolicyKit eleva solamente las copias y las tareas administrativas.

## Instalación sencilla

Descarga el archivo único `BackupLinux-Installer.run`, marca la opción **Permitir ejecutar el archivo como programa** en sus propiedades si el navegador no lo hizo, y ábrelo. El instalador:

- comprueba GTK 4, PyGObject, Python 3 y las herramientas de backup, permisos y programación;
- ofrece instalar dependencias con el gestor de paquetes detectado (Debian/Ubuntu, Fedora, Arch o openSUSE), solicitando autorización administrativa;
- instala la aplicación en `~/.local/opt/backup-linux`, sin requerir instalar la ventana como root;
- crea el acceso en el menú de aplicaciones y el lanzador `~/.local/bin/backup-desktop`;
- incluye un desinstalador en el menú de aplicaciones que elimina la aplicación, perfiles, correo y programación. Las copias de seguridad se conservan.

El instalador descargado también puede iniciar la desinstalación con `--uninstall`.

## Crear el instalador

Desde esta carpeta, ejecuta `./build-installer.sh`. Genera `BackupLinux-Installer.run`, el único archivo que se distribuye a los usuarios. Incluye los fuentes de la aplicación y el instalador, pero descarga las dependencias de los repositorios de la distribución para mantener GTK, Python y PolicyKit compatibles con el sistema.

## Uso

1. Agrega las carpetas de origen y selecciona o crea una carpeta destino.
2. Elige `rsync` para copias incrementales o `tar` para un archivo comprimido.
3. Pulsa **Iniciar backup** y autoriza la operación cuando PolicyKit lo solicite.
4. Consulta el progreso y el registro en vivo. Puedes cancelar la ejecución.
5. En **Programación…**, elige cada N horas, diariamente o semanalmente. Se crea un timer de sistema que puede ejecutarse aunque la ventana esté cerrada.
6. En **Correo / SMTP…**, configura SMTP local, externo o `sendmail/msmtp` y las preferencias de envío de logs.

Los perfiles se guardan en `$XDG_CONFIG_HOME/backup-desktop/` o, por defecto, en `~/.config/backup-desktop/`. La aplicación restaura el último perfil utilizado.

## Requisitos técnicos

Linux de escritorio con GTK 4, Python 3 y PyGObject. Se recomienda systemd y un agente gráfico de PolicyKit. El instalador detecta e intenta instalar también `rsync`, `tar`, `pkexec`, `systemctl` y `curl`. La programación requiere systemd; SMTP directo usa curl.
