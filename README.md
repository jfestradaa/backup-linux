# Linux Backup

A desktop application for creating backups using GTK 4. The application window runs in the regular user session, while PolicyKit elevates privileges only for backup operations and administrative tasks.
<img width="2055" height="1126" alt="image" src="https://github.com/user-attachments/assets/5aa74852-e0b8-44d0-8182-4b3421de21bf" />



The interface detects the language configured in the Linux session. It currently displays Spanish when the locale starts with `es` and English for all other languages.

## Easy Installation

Download the single file `BackupLinux-Installer.run`, enable **Allow executing file as a program** in its properties if your browser has not already done so, and open it. The installer:

- Checks for GTK 4, PyGObject, Python 3, and the required backup, permission, and scheduling tools.
- Offers to install dependencies using the detected package manager (Debian/Ubuntu, Fedora, Arch, or openSUSE), requesting administrative authorization.
- Installs the application in `~/.local/opt/backup-linux`, without requiring the application window to run as root.
- Creates an entry in the applications menu and the launcher `~/.local/bin/backup-desktop`.
- Includes an uninstaller in the applications menu that removes the application, profiles, email settings, and scheduled tasks. Backups are preserved.

The downloaded installer can also start the uninstallation process using `--uninstall`.

## Building the Installer

From this directory, run `./build-installer.sh`. It generates `BackupLinux-Installer.run`, the single file distributed to users. It includes the application source code and installer, but downloads dependencies from the distribution's repositories to ensure compatibility between GTK, Python, PolicyKit, and the host system.

## Usage

1. Add the source folders and select or create a destination folder.
2. Choose `rsync` for incremental backups or `tar` to create a compressed archive.
3. Click **Start Backup** and authorize the operation when prompted by PolicyKit.
4. Monitor progress and view the live log. You can cancel the operation at any time.
5. Under **Scheduling…**, choose an interval of every N hours, daily, or weekly. A system timer is created, allowing backups to run even when the application window is closed.
6. Under **Email / SMTP…**, configure a local or external SMTP server, or `sendmail/msmtp`, and set your log delivery preferences.

Profiles are stored in `$XDG_CONFIG_HOME/backup-desktop/` or, by default, in `~/.config/backup-desktop/`. The application restores the last-used profile.

## Technical Requirements

A Linux desktop environment with GTK 4, Python 3, and PyGObject. systemd and a graphical PolicyKit authentication agent are recommended. The installer detects and attempts to install `rsync`, `tar`, `pkexec`, `systemctl`, and `curl` as well. Scheduling requires systemd; direct SMTP delivery uses curl.
