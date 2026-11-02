# Backup Linux

GTK 4 desktop application for creating backups. The window runs in the regular user session; PolicyKit elevates only backup operations and administrative tasks.

The interface detects the language configured in the Linux session. It currently displays Spanish when the locale starts with `es` and English for all other languages.

## Easy installation

Download the single file `BackupLinux-Installer.run`, mark it as **Allow executing file as a program** in its properties if your browser did not do so, and open it. The installer:

- checks for GTK 4, PyGObject, Python 3, and the backup, permissions, and scheduling tools;
- offers to install dependencies using the detected package manager (Debian/Ubuntu, Fedora, Arch, or openSUSE), requesting administrator authorization;
- installs the application in `~/.local/opt/backup-linux`, without requiring the desktop app to be installed as root;
- creates an application menu entry and the `~/.local/bin/backup-desktop` launcher;
- includes an uninstaller in the application menu that removes the application, profiles, email settings, and schedules. Backups are kept.

The downloaded installer can also start the uninstall process with `--uninstall`.

## Building the installer

From this directory, run `./build-installer.sh`. It generates `BackupLinux-Installer.run`, the single file distributed to users. It includes the application source files and installer, while downloading dependencies from the distribution's repositories to keep GTK, Python, and PolicyKit compatible with the system.

## Command-line usage (CLI)

The `backup.sh` file can also be run from a terminal without opening GTK. Messages and help are shown in Spanish when the session locale starts with `es`, and in English for other languages. The script checks `LC_ALL`, `LC_MESSAGES`, `LANG`, and then `LANGUAGE`. When installed, it is located at `~/.local/opt/backup-linux/backup.sh`; when running from source, run the examples from the `BackupDesktop` directory.

To view the installed CLI help, run `~/.local/opt/backup-linux/backup.sh -h`. In the examples below, replace `./backup.sh` with that path when running an installed copy.

```bash
# Open the text interface (requires dialog or whiptail)
./backup.sh

# Run a backup directly, without the interface
./backup.sh -y -d "$HOME/Documents" -d "$HOME/Pictures" \
  -o "/mnt/backups" -m rsync -r 30

# Use tar and keep all backups
./backup.sh -y -d "$HOME/Documents" -o "/mnt/backups" -m tar -r 0

# List CLI profiles, or load one and run it without the interface
./backup.sh -l
./backup.sh -y -c server

# Send a test email using the CLI email settings
./backup.sh -t
```

The main options are:

| Option | Description |
| --- | --- |
| `-d DIR` | Source directory; can be repeated. |
| `-o DIR` | Backup destination. |
| `-m MODE` | Backup mode: `rsync` or `tar`. |
| `-r DAYS` | Retention period in days; `0` keeps all backups. |
| `-s` | Try to use an LVM/btrfs snapshot. |
| `-x PATTERN` | Exclude a pattern; repeat for multiple exclusions. Replaces the default list. `-x ""` clears the list. |
| `-c NAME` | Load a saved CLI profile. With `-y`, run it directly. |
| `-l` | List saved CLI profiles. |
| `-y` | Run without the text interface. |
| `-e` | Email the log when finished, even if the policy is set not to send. |
| `-t` | Send a test email and exit. |
| `-C DIR` | Use another CLI configuration directory. |
| `-n NAME` | Label the configuration in the log. |
| `-p` | Emit rsync progress lines for graphical integrations. |
| `-k FILE` | Cancel the backup if the specified file appears. |
| `-h` | Show the full help. |

The text interface requires `dialog` or `whiptail`; direct execution with `-y` does not require these packages. The CLI stores its profiles in `~/.config/backup-tui/` (or `/etc/backup-tui/` when run as root), separately from GTK profiles in `~/.config/backup-desktop/`. You can specify another location with `-C DIR` or `BACKUP_CONFIG_DIR`.

Use administrator privileges only if the backup needs to read protected files; for example, `sudo ./backup.sh -y ...`. When using `sudo`, the default configuration directory belongs to root. The GTK application, by contrast, requests privileges through PolicyKit to run the backup engine.

## Using the application

1. Add source folders and select or create a destination folder.
2. Choose `rsync` for incremental backups or `tar` for a compressed archive.
3. Click **Start backup** and authorize the operation when prompted by PolicyKit.
4. Check the live progress and log. You can cancel the operation.
5. Under **Schedule…**, choose every N hours, daily, or weekly. A system timer is created and can run even when the window is closed.
6. Under **Email / SMTP…**, configure local or external SMTP, or `sendmail/msmtp`, along with log delivery preferences.

Profiles are stored in `$XDG_CONFIG_HOME/backup-desktop/` or, by default, in `~/.config/backup-desktop/`. The application restores the last profile used.

## Technical requirements

Linux desktop with GTK 4, Python 3, and PyGObject. Systemd and a graphical PolicyKit agent are recommended. The installer also detects and attempts to install `rsync`, `tar`, `pkexec`, `systemctl`, and `curl`. Scheduling requires systemd; direct SMTP uses curl.
