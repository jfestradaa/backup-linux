#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "$0")" && pwd)"
OUTPUT="$ROOT/BackupLinux-Installer.run"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FILES=(backup-desktop backup-linux.desktop backup-linux.svg backup.sh backup_gtk.py backup_job.py i18n.py uninstall-backup-linux)
for file in "${FILES[@]}"; do
    [[ -f "$ROOT/$file" ]] || { printf 'Falta el archivo requerido: %s\n' "$ROOT/$file" >&2; exit 1; }
done

tar -czf "$TMP/payload.tar.gz" -C "$ROOT" "${FILES[@]}"
cat "$ROOT/installer-template.sh" > "$OUTPUT"
base64 < "$TMP/payload.tar.gz" >> "$OUTPUT"
chmod 755 "$OUTPUT"
printf 'Instalador generado: %s\n' "$OUTPUT"
