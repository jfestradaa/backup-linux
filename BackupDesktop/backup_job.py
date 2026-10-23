#!/usr/bin/env python3
"""Ejecutor sin interfaz para el timer systemd del sistema (se ejecuta como root)."""
import json
import os
import subprocess
import sys
from pathlib import Path

BACKEND = Path(__file__).with_name("backup.sh")


def main():
    config_dir = Path(sys.argv[1]).expanduser().resolve() if len(sys.argv) > 1 else Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config")) / "backup-desktop"
    profiles_file = config_dir / "profiles.json"
    schedule_file = config_dir / "schedule.json"
    try:
        schedule = json.loads(schedule_file.read_text(encoding="utf-8"))
        profiles = json.loads(profiles_file.read_text(encoding="utf-8"))
        profile = profiles[schedule["profile"]]
        sources = [str(Path(path).expanduser().resolve()) for path in profile["sources"]]
        destination = str(Path(profile["destination"]).expanduser().resolve())
        last_profile = config_dir / "last-profile"
        last_profile.write_text(schedule["profile"] + "\n", encoding="utf-8")
        if os.geteuid() == 0 and "uid" in schedule:
            os.chown(last_profile, int(schedule["uid"]), int(schedule.get("gid", schedule["uid"])))
        last_profile.chmod(0o600)
    except (OSError, KeyError, TypeError, ValueError) as error:
        print(f"No se pudo leer la configuración programada: {error}", file=sys.stderr)
        return 2
    if not BACKEND.is_file():
        print(f"No se encuentra el motor de backup: {BACKEND}", file=sys.stderr)
        return 2
    mode = profile.get("mode", "rsync")
    command = [str(BACKEND), "-y", "-C", str(config_dir), "-o", destination,
               "-m", mode, "-r", str(int(profile.get("retention", 0))),
               "-n", "Programado", "-p"]
    for source in sources:
        command.extend(("-d", source))
    if profile.get("snapshot"):
        command.append("-s")
    for pattern in profile.get("excludes", []):
        if pattern:
            command.extend(("-x", pattern))
    try:
        return subprocess.run(command, check=False).returncode
    except OSError as error:
        print(f"No se pudo iniciar el motor de backup: {error}", file=sys.stderr)
        return 127


if __name__ == "__main__":
    raise SystemExit(main())
