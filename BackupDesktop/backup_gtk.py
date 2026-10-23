#!/usr/bin/env python3
"""Interfaz GTK 4 para el motor backup.sh."""
import json
import os
import queue
import shutil
import subprocess
import sys
import threading
from pathlib import Path

import gi

gi.require_version("Gtk", "4.0")
from gi.repository import Gio, GLib, Gtk, Pango

APP_ID = "org.codex.BackupLinux"
APP_NAME = "Backup Linux"
CONFIG_DIR = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config")) / "backup-desktop"
PROFILES = CONFIG_DIR / "profiles.json"
LAST_PROFILE = CONFIG_DIR / "last-profile"
SCHEDULE_FILE = CONFIG_DIR / "schedule.json"
MAIL_FILE = CONFIG_DIR / "correo.conf"
PASS_FILE = CONFIG_DIR / "smtp.pass"
BACKEND = Path(__file__).with_name("backup.sh")
JOB_RUNNER = Path(__file__).with_name("backup_job.py")
DEFAULT_EXCLUDES = "*.tmp\n*.swp\n.cache/\nnode_modules/\n/proc/*\n/sys/*\n/dev/*\n/run/*\nlost+found"


class BackupWindow(Gtk.ApplicationWindow):
    def __init__(self, app):
        super().__init__(application=app, title=APP_NAME)
        self.set_default_size(980, 760)
        self.set_size_request(760, 570)
        self.sources = []
        self.events = queue.Queue()
        self.proc = None
        self.running = False
        self.exit_after_backup = False
        self.stopfile = None
        self.profiles = self.read_profiles()
        self.mail = self.read_mail_settings()
        self.schedule = self.read_schedule()
        self.build_ui()
        self.refresh_profiles()
        self.load_last_profile()
        self.update_schedule_status()
        GLib.timeout_add(100, self.poll_events)

    def read_profiles(self):
        try:
            data = json.loads(PROFILES.read_text(encoding="utf-8"))
            return data if isinstance(data, dict) else {}
        except (OSError, ValueError):
            return {}

    def save_profiles(self):
        CONFIG_DIR.mkdir(mode=0o700, parents=True, exist_ok=True)
        PROFILES.write_text(json.dumps(self.profiles, ensure_ascii=False, indent=2), encoding="utf-8")
        PROFILES.chmod(0o600)

    def read_mail_settings(self):
        values = {"MAIL_ENVIAR": "nunca", "MAIL_A": "", "MAIL_DE": "", "MAIL_METODO": "smtp",
                  "SMTP_HOST": "localhost", "SMTP_PORT": "25", "SMTP_TLS": "none", "SMTP_USER": ""}
        try:
            for line in MAIL_FILE.read_text(encoding="utf-8").splitlines():
                if "=" in line and not line.lstrip().startswith("#"):
                    key, value = line.split("=", 1)
                    if key in values:
                        values[key] = value
            values["SMTP_PASS_SET"] = PASS_FILE.is_file() and PASS_FILE.stat().st_size > 0
        except OSError:
            values["SMTP_PASS_SET"] = False
        return values

    def save_mail_settings(self, settings, password=None):
        CONFIG_DIR.mkdir(mode=0o700, parents=True, exist_ok=True)
        allowed = ("MAIL_ENVIAR", "MAIL_A", "MAIL_DE", "MAIL_METODO", "SMTP_HOST", "SMTP_PORT", "SMTP_TLS", "SMTP_USER")
        for key in allowed:
            value = str(settings.get(key, ""))
            if "\n" in value or "\r" in value:
                raise ValueError("Los campos de correo no pueden contener saltos de línea.")
        content = "# Configuración de correo de backup.sh\n" + "".join(f"{key}={settings.get(key, '')}\n" for key in allowed)
        MAIL_FILE.write_text(content, encoding="utf-8")
        MAIL_FILE.chmod(0o600)
        if password:
            PASS_FILE.write_text(password, encoding="utf-8")
            PASS_FILE.chmod(0o600)
        self.mail = self.read_mail_settings()

    def read_schedule(self):
        try:
            data = json.loads(SCHEDULE_FILE.read_text(encoding="utf-8"))
            return data if isinstance(data, dict) else {}
        except (OSError, ValueError):
            return {}

    def load_last_profile(self):
        try:
            name = LAST_PROFILE.read_text(encoding="utf-8").strip()
        except OSError:
            name = ""
        if name not in self.profiles and self.profiles:
            name = self.selected_profile_name()
        if name in self.profiles:
            for i in range(self.profile_model.get_n_items()):
                if self.profile_model.get_string(i) == name:
                    self.profile_dropdown.set_selected(i)
                    break
            self.apply_profile(self.profiles[name])
            self.status.set_text(f"Última configuración cargada: {name}")

    def remember_last_profile(self, name):
        CONFIG_DIR.mkdir(mode=0o700, parents=True, exist_ok=True)
        LAST_PROFILE.write_text(name + "\n", encoding="utf-8")
        LAST_PROFILE.chmod(0o600)

    def persist_current_profile(self, remember=True):
        name = self.selected_profile_name() or "Último backup"
        self.profiles[name] = self.current_profile()
        self.save_profiles()
        if remember:
            self.remember_last_profile(name)
        self.refresh_profiles()
        for i in range(self.profile_model.get_n_items()):
            if self.profile_model.get_string(i) == name:
                self.profile_dropdown.set_selected(i)
                break
        return name

    def build_ui(self):
        root = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
        root.set_margin_top(16)
        root.set_margin_bottom(16)
        root.set_margin_start(18)
        root.set_margin_end(18)
        self.set_child(root)

        header = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        root.append(header)
        title = Gtk.Label(label=APP_NAME)
        title.add_css_class("title-1")
        title.set_xalign(0)
        title.set_hexpand(True)
        header.append(title)
        header.append(Gtk.Label(label="Perfil"))
        self.profile_model = Gtk.StringList.new([])
        self.profile_dropdown = Gtk.DropDown(model=self.profile_model)
        self.profile_dropdown.set_size_request(190, -1)
        header.append(self.profile_dropdown)
        load_btn = Gtk.Button(label="Cargar perfil")
        load_btn.connect("clicked", self.load_profile)
        header.append(load_btn)
        save_btn = Gtk.Button(label="Guardar como…")
        save_btn.connect("clicked", self.ask_save_profile)
        header.append(save_btn)
        mail_btn = Gtk.Button(label="Correo / SMTP…")
        mail_btn.connect("clicked", self.open_mail_settings)
        header.append(mail_btn)
        schedule_btn = Gtk.Button(label="Programación…")
        schedule_btn.connect("clicked", self.open_schedule_settings)
        header.append(schedule_btn)

        sources_frame = Gtk.Frame(label="Carpetas de origen")
        sources_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        sources_box.set_margin_top(8)
        sources_box.set_margin_bottom(10)
        sources_box.set_margin_start(10)
        sources_box.set_margin_end(10)
        sources_frame.set_child(sources_box)
        root.append(sources_frame)
        scroller = Gtk.ScrolledWindow()
        scroller.set_min_content_height(115)
        scroller.set_max_content_height(190)
        scroller.set_policy(Gtk.PolicyType.AUTOMATIC, Gtk.PolicyType.AUTOMATIC)
        self.source_list = Gtk.ListBox()
        self.source_list.set_selection_mode(Gtk.SelectionMode.MULTIPLE)
        self.source_list.add_css_class("boxed-list")
        scroller.set_child(self.source_list)
        sources_box.append(scroller)
        source_buttons = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        sources_box.append(source_buttons)
        add_btn = Gtk.Button(label="Agregar carpeta…")
        add_btn.connect("clicked", self.choose_source)
        source_buttons.append(add_btn)
        remove_btn = Gtk.Button(label="Quitar seleccionadas")
        remove_btn.connect("clicked", self.remove_sources)
        source_buttons.append(remove_btn)
        clear_btn = Gtk.Button(label="Vaciar lista")
        clear_btn.connect("clicked", self.clear_sources)
        source_buttons.append(clear_btn)

        options = Gtk.Frame(label="Destino y opciones")
        grid = Gtk.Grid(column_spacing=10, row_spacing=9)
        grid.set_margin_top(12)
        grid.set_margin_bottom(12)
        grid.set_margin_start(12)
        grid.set_margin_end(12)
        options.set_child(grid)
        root.append(options)
        grid.attach(Gtk.Label(label="Destino", xalign=0), 0, 0, 1, 1)
        self.destination = Gtk.Entry()
        self.destination.set_hexpand(True)
        self.destination.set_placeholder_text("Ruta donde se guardarán los backups")
        grid.attach(self.destination, 1, 0, 2, 1)
        browse_dest = Gtk.Button(label="Examinar…")
        browse_dest.connect("clicked", self.choose_destination)
        grid.attach(browse_dest, 3, 0, 1, 1)
        create_dest = Gtk.Button(label="Crear carpeta…")
        create_dest.connect("clicked", self.create_destination_dialog)
        grid.attach(create_dest, 4, 0, 1, 1)
        grid.attach(Gtk.Label(label="Modo", xalign=0), 0, 1, 1, 1)
        self.mode = Gtk.DropDown.new_from_strings(["rsync", "tar"])
        grid.attach(self.mode, 1, 1, 1, 1)
        mode_help = Gtk.Label(label="rsync: incremental y navegable · tar: archivo .tar.gz")
        mode_help.set_xalign(0)
        mode_help.add_css_class("dim-label")
        grid.attach(mode_help, 2, 1, 2, 1)
        self.snapshot = Gtk.CheckButton(label="Intentar snapshot LVM/btrfs (requiere soporte y permisos del sistema)")
        grid.attach(self.snapshot, 0, 2, 4, 1)
        grid.attach(Gtk.Label(label="Retención (días; 0 conserva todos)", xalign=0), 0, 3, 1, 1)
        self.retention = Gtk.SpinButton.new_with_range(0, 36500, 1)
        self.retention.set_numeric(True)
        self.retention.set_value(0)
        grid.attach(self.retention, 1, 3, 1, 1)
        grid.attach(Gtk.Label(label="Exclusiones (un patrón por línea)", xalign=0, yalign=0), 0, 4, 1, 1)
        self.excludes = Gtk.TextView()
        self.excludes.set_wrap_mode(Gtk.WrapMode.WORD_CHAR)
        self.excludes.get_buffer().set_text(DEFAULT_EXCLUDES)
        exclude_scroll = Gtk.ScrolledWindow()
        exclude_scroll.set_min_content_height(82)
        exclude_scroll.set_child(self.excludes)
        grid.attach(exclude_scroll, 1, 4, 3, 1)

        log_frame = Gtk.Frame(label="Registro de ejecución")
        log_frame.set_vexpand(True)
        root.append(log_frame)
        self.log_view = Gtk.TextView()
        self.log_view.set_editable(False)
        self.log_view.set_cursor_visible(False)
        self.log_view.set_monospace(True)
        self.log_view.set_wrap_mode(Gtk.WrapMode.NONE)
        self.log_buffer = self.log_view.get_buffer()
        log_scroll = Gtk.ScrolledWindow()
        log_scroll.set_policy(Gtk.PolicyType.AUTOMATIC, Gtk.PolicyType.AUTOMATIC)
        log_scroll.set_child(self.log_view)
        log_frame.set_child(log_scroll)

        footer = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        root.append(footer)
        self.status = Gtk.Label(label="Listo", xalign=0)
        self.status.set_hexpand(True)
        footer.append(self.status)
        self.progress = Gtk.ProgressBar()
        self.progress.set_size_request(190, -1)
        self.progress.set_show_text(True)
        footer.append(self.progress)
        self.run_button = Gtk.Button(label="Iniciar backup")
        self.run_button.add_css_class("suggested-action")
        self.run_button.connect("clicked", self.start_backup)
        footer.append(self.run_button)
        self.cancel_button = Gtk.Button(label="Cancelar")
        self.cancel_button.set_sensitive(False)
        self.cancel_button.connect("clicked", self.cancel_backup)
        footer.append(self.cancel_button)
        exit_button = Gtk.Button(label="Salir")
        exit_button.connect("clicked", self.exit_app)
        footer.append(exit_button)

    def refresh_profiles(self):
        self.profile_model.splice(0, self.profile_model.get_n_items(), sorted(self.profiles))
        self.profile_dropdown.set_selected(0 if self.profiles else Gtk.INVALID_LIST_POSITION)

    def selected_profile_name(self):
        item = self.profile_dropdown.get_selected_item()
        return item.get_string() if item else ""

    def choose_directory(self, title, callback):
        chooser = Gtk.FileChooserNative.new(title, self, Gtk.FileChooserAction.SELECT_FOLDER, "Seleccionar", "Cancelar")
        chooser.connect("response", lambda dialog, response: self.on_directory_chosen(dialog, response, callback))
        chooser.show()

    def on_directory_chosen(self, dialog, response, callback):
        if response == Gtk.ResponseType.ACCEPT:
            file = dialog.get_file()
            if file and file.get_path():
                callback(str(Path(file.get_path()).resolve()))
        dialog.destroy()

    def choose_source(self, _button):
        self.choose_directory("Seleccionar carpeta de origen", self.add_source)

    def add_source(self, path):
        if path not in self.sources:
            self.sources.append(path)
            self.render_sources()

    def render_sources(self):
        child = self.source_list.get_first_child()
        while child:
            next_child = child.get_next_sibling()
            self.source_list.remove(child)
            child = next_child
        for path in self.sources:
            row = Gtk.ListBoxRow()
            label = Gtk.Label(label=path, xalign=0)
            label.set_margin_top(7)
            label.set_margin_bottom(7)
            label.set_margin_start(9)
            label.set_margin_end(9)
            label.set_ellipsize(Pango.EllipsizeMode.END)
            row.set_child(label)
            self.source_list.append(row)

    def remove_sources(self, _button):
        selected_rows = self.source_list.get_selected_rows()
        indices = sorted((row.get_index() for row in selected_rows), reverse=True)
        for index in indices:
            del self.sources[index]
        self.render_sources()

    def clear_sources(self, _button):
        self.sources.clear()
        self.render_sources()

    def choose_destination(self, _button):
        dialog = Gtk.Dialog(title="Seleccionar destino", transient_for=self, modal=True)
        dialog.set_default_size(850, 560)
        dialog.add_button("Cancelar", Gtk.ResponseType.CANCEL)
        dialog.add_button("Nueva carpeta…", 1001)
        dialog.add_button("Seleccionar", Gtk.ResponseType.ACCEPT)
        dialog.set_default_response(Gtk.ResponseType.ACCEPT)
        chooser = Gtk.FileChooserWidget.new(Gtk.FileChooserAction.SELECT_FOLDER)
        chooser.set_hexpand(True)
        chooser.set_vexpand(True)
        current = self.destination.get_text().strip()
        initial = Path(current).expanduser() if current else Path.home()
        if initial.is_dir():
            chooser.set_current_folder(Gio.File.new_for_path(str(initial)))
        dialog.get_content_area().append(chooser)
        dialog.connect("response", self.destination_chooser_response, chooser)
        dialog.present()

    def destination_chooser_response(self, dialog, response, chooser):
        if response == 1001:
            self.prompt_new_destination_folder(dialog, chooser)
            return
        if response == Gtk.ResponseType.ACCEPT:
            selected = chooser.get_file()
            if selected and selected.get_path():
                self.destination.set_text(str(Path(selected.get_path()).resolve()))
        dialog.destroy()

    def prompt_new_destination_folder(self, chooser_dialog, chooser):
        current = chooser.get_current_folder()
        parent = Path(current.get_path()) if current and current.get_path() else Path.home()
        dialog = Gtk.Dialog(title="Crear carpeta", transient_for=chooser_dialog, modal=True)
        dialog.add_button("Cancelar", Gtk.ResponseType.CANCEL)
        dialog.add_button("Crear", Gtk.ResponseType.ACCEPT)
        dialog.set_default_response(Gtk.ResponseType.ACCEPT)
        box = dialog.get_content_area()
        box.set_spacing(8)
        box.set_margin_top(14)
        box.set_margin_bottom(14)
        box.set_margin_start(14)
        box.set_margin_end(14)
        box.append(Gtk.Label(label=f"Nueva carpeta dentro de:\n{parent}", xalign=0))
        entry = Gtk.Entry()
        entry.set_placeholder_text("Nombre de la carpeta")
        entry.set_activates_default(True)
        box.append(entry)
        dialog.connect("response", self.new_destination_folder_response, chooser_dialog, chooser, parent, entry)
        dialog.present()

    def new_destination_folder_response(self, dialog, response, chooser_dialog, chooser, parent, entry):
        name = entry.get_text().strip()
        dialog.destroy()
        if response != Gtk.ResponseType.ACCEPT:
            return
        if not name or name in {".", ".."} or Path(name).name != name:
            self.show_message("Nombre no válido", "Escribe un nombre de carpeta sencillo, sin rutas.", Gtk.MessageType.WARNING)
            return
        path = parent / name
        try:
            path.mkdir(mode=0o700)
            self.probe_destination(path)
            chooser.set_file(Gio.File.new_for_path(str(path)))
        except FileExistsError:
            self.show_message("La carpeta ya existe", f"Ya existe una carpeta con este nombre:\n{path}", Gtk.MessageType.WARNING)
        except PermissionError:
            self.offer_destination_access(
                path, create=True,
                continuation=lambda: chooser.set_file(Gio.File.new_for_path(str(path))))
        except OSError as error:
            self.show_message("No se pudo crear la carpeta", f"{path}\n\n{error}", Gtk.MessageType.ERROR)

    def create_destination_dialog(self, _button):
        dialog = Gtk.Dialog(title="Crear carpeta de destino", transient_for=self, modal=True)
        dialog.add_button("Cancelar", Gtk.ResponseType.CANCEL)
        dialog.add_button("Crear carpeta", Gtk.ResponseType.ACCEPT)
        dialog.set_default_response(Gtk.ResponseType.ACCEPT)
        box = dialog.get_content_area()
        box.set_spacing(8)
        box.set_margin_top(14)
        box.set_margin_bottom(14)
        box.set_margin_start(14)
        box.set_margin_end(14)
        box.append(Gtk.Label(label="Escribe la ruta completa que quieres crear:", xalign=0))
        entry = Gtk.Entry()
        entry.set_hexpand(True)
        entry.set_placeholder_text("/ruta/al/destino")
        entry.set_text(self.destination.get_text().strip())
        entry.set_activates_default(True)
        box.append(entry)
        dialog.connect("response", self.create_destination_response, entry)
        dialog.present()

    def create_destination_response(self, dialog, response, entry):
        path_text = entry.get_text().strip()
        dialog.destroy()
        if response != Gtk.ResponseType.ACCEPT:
            return
        if not path_text:
            self.show_message("Falta la ruta", "Indica la carpeta que quieres crear.", Gtk.MessageType.WARNING)
            return
        path = Path(path_text).expanduser().resolve()
        try:
            path.mkdir(parents=True, exist_ok=True, mode=0o700)
            self.probe_destination(path)
            self.destination.set_text(str(path))
            self.status.set_text("Carpeta de destino creada y escribible")
        except PermissionError:
            self.offer_destination_access(path, create=True, continuation=lambda: self.destination.set_text(str(path)))
        except OSError as error:
            self.show_message("No se pudo crear el destino", str(error), Gtk.MessageType.ERROR)

    @staticmethod
    def probe_destination(path):
        if not path.is_dir():
            raise NotADirectoryError(f"La ruta no es una carpeta: {path}")

    def offer_destination_access(self, path, create, continuation):
        detail = (f"No tienes permiso para crear esta carpeta:\n{path}\n\n"
                  "¿Quieres autorizar con el diálogo de administrador la creación de la carpeta? "
                  "La carpeta nueva quedará privada y asignada a tu usuario.")
        self.confirm(detail, lambda accepted: self.apply_destination_access(path, create, continuation) if accepted else None)

    def apply_destination_access(self, path, create, continuation):
        pkexec = shutil.which("pkexec")
        install = shutil.which("install")
        if not pkexec or not install:
            self.show_message("No se puede crear el destino", "Se necesitan pkexec y el comando install de GNU coreutils.", Gtk.MessageType.ERROR)
            return
        try:
            if create and not path.exists():
                result = subprocess.run([pkexec, install, "-d", "-m", "0700", "-o", str(os.getuid()),
                                         "-g", str(os.getgid()), "--", str(path)],
                                        capture_output=True, text=True, timeout=120)
                if result.returncode:
                    raise RuntimeError((result.stderr or result.stdout).strip() or "No se pudo crear la carpeta con permisos administrativos.")
            self.probe_destination(path)
            continuation()
            self.status.set_text("Destino creado con autorización administrativa")
        except (OSError, subprocess.SubprocessError, RuntimeError) as error:
            self.show_message("No se pudo preparar el destino", str(error), Gtk.MessageType.ERROR)

    def get_excludes(self):
        buffer = self.excludes.get_buffer()
        return buffer.get_text(buffer.get_start_iter(), buffer.get_end_iter(), True).splitlines()

    def current_profile(self):
        destination = self.destination.get_text().strip()
        if destination:
            destination = str(Path(destination).expanduser().resolve())
        return {"sources": self.sources[:], "destination": destination,
                "mode": "rsync" if self.mode.get_selected() == 0 else "tar",
                "snapshot": self.snapshot.get_active(), "retention": str(self.retention.get_value_as_int()),
                "excludes": self.get_excludes()}

    def ask_save_profile(self, _button):
        dialog = Gtk.Dialog(title="Guardar perfil", transient_for=self, modal=True)
        dialog.add_button("Cancelar", Gtk.ResponseType.CANCEL)
        dialog.add_button("Guardar", Gtk.ResponseType.ACCEPT)
        dialog.set_default_response(Gtk.ResponseType.ACCEPT)
        entry = Gtk.Entry()
        entry.set_placeholder_text("Nombre del perfil")
        current = self.selected_profile_name()
        if current:
            entry.set_text(current)
        entry.set_activates_default(True)
        box = dialog.get_content_area()
        box.set_spacing(8)
        box.set_margin_top(12)
        box.set_margin_bottom(12)
        box.set_margin_start(12)
        box.set_margin_end(12)
        box.append(Gtk.Label(label="Guardar la configuración actual con este nombre:", xalign=0))
        box.append(entry)
        dialog.connect("response", self.save_profile_response, entry)
        dialog.present()

    def save_profile_response(self, dialog, response, entry):
        name = entry.get_text().strip()
        dialog.destroy()
        if response != Gtk.ResponseType.ACCEPT or not name:
            return
        self.profiles[name] = self.current_profile()
        try:
            self.save_profiles()
        except OSError as error:
            self.show_message("No se pudo guardar el perfil", str(error), Gtk.MessageType.ERROR)
            return
        self.refresh_profiles()
        for i in range(self.profile_model.get_n_items()):
            if self.profile_model.get_string(i) == name:
                self.profile_dropdown.set_selected(i)
                break
        self.status.set_text(f"Perfil guardado: {name}")

    def load_profile(self, _button):
        name = self.selected_profile_name()
        if not name or name not in self.profiles:
            try:
                remembered = LAST_PROFILE.read_text(encoding="utf-8").strip()
            except OSError:
                remembered = ""
            name = remembered if remembered in self.profiles else ""
            if not name and self.profiles:
                name = sorted(self.profiles)[0]
            if name:
                for index in range(self.profile_model.get_n_items()):
                    if self.profile_model.get_string(index) == name:
                        self.profile_dropdown.set_selected(index)
                        break
        profile = self.profiles.get(name)
        if not profile:
            self.show_message("No hay perfiles guardados", "Guarda primero un perfil con el botón «Guardar como…».", Gtk.MessageType.INFO)
            return
        try:
            self.apply_profile(profile)
            self.remember_last_profile(name)
        except (OSError, TypeError, ValueError, AttributeError) as error:
            self.show_message("No se pudo cargar el perfil", f"El perfil «{name}» no contiene una configuración válida.\n\n{error}", Gtk.MessageType.ERROR)
            return
        self.status.set_text(f"Perfil cargado: {name}")

    def apply_profile(self, profile):
        self.sources = list(profile.get("sources", []))
        self.render_sources()
        self.destination.set_text(profile.get("destination", ""))
        self.mode.set_selected(0 if profile.get("mode", "rsync") == "rsync" else 1)
        self.snapshot.set_active(bool(profile.get("snapshot", False)))
        self.retention.set_value(int(profile.get("retention", 0)))
        self.excludes.get_buffer().set_text("\n".join(profile.get("excludes", [])))

    def open_mail_settings(self, _button):
        dialog = Gtk.Dialog(title="Configuración de correo y SMTP", transient_for=self, modal=True)
        dialog.add_button("Cancelar", Gtk.ResponseType.CANCEL)
        dialog.add_button("Probar envío", 1)
        dialog.add_button("Guardar", Gtk.ResponseType.ACCEPT)
        dialog.set_default_response(Gtk.ResponseType.ACCEPT)
        box = dialog.get_content_area()
        box.set_spacing(8)
        box.set_margin_top(14)
        box.set_margin_bottom(14)
        box.set_margin_start(14)
        box.set_margin_end(14)
        grid = Gtk.Grid(column_spacing=10, row_spacing=8)
        box.append(grid)
        def field(row, label, widget):
            grid.attach(Gtk.Label(label=label, xalign=0), 0, row, 1, 1)
            widget.set_hexpand(True)
            grid.attach(widget, 1, row, 1, 1)
        current = self.mail
        connection = Gtk.DropDown.new_from_strings([
            "SMTP local (localhost)", "SMTP externo", "sendmail / msmtp del sistema"
        ])
        if current.get("MAIL_METODO") == "local":
            connection.set_selected(2)
        elif current.get("SMTP_HOST", "localhost") in ("localhost", "127.0.0.1", "::1"):
            connection.set_selected(0)
        else:
            connection.set_selected(1)
        field(0, "Servidor de envío", connection)
        recipients = Gtk.Entry()
        recipients.set_placeholder_text("persona@ejemplo.com, otra@ejemplo.com")
        recipients.set_text(current.get("MAIL_A", ""))
        field(1, "Destinatarios", recipients)
        sender = Gtk.Entry()
        sender.set_placeholder_text("backup@este-equipo")
        sender.set_text(current.get("MAIL_DE", ""))
        field(2, "Remitente", sender)
        policy = Gtk.DropDown.new_from_strings(["No enviar", "Después de cada backup", "Solo si falla"])
        policy.set_selected({"nunca": 0, "siempre": 1, "error": 2}.get(current.get("MAIL_ENVIAR", "nunca"), 0))
        field(3, "Enviar los logs", policy)
        host = Gtk.Entry()
        host.set_text(current.get("SMTP_HOST", "localhost"))
        field(4, "Servidor SMTP", host)
        port = Gtk.Entry()
        port.set_input_purpose(Gtk.InputPurpose.DIGITS)
        port.set_text(current.get("SMTP_PORT", "25"))
        field(5, "Puerto", port)
        tls = Gtk.DropDown.new_from_strings(["Sin cifrado", "STARTTLS", "SSL/TLS"])
        tls.set_selected({"none": 0, "starttls": 1, "ssl": 2}.get(current.get("SMTP_TLS", "none"), 0))
        field(6, "Cifrado", tls)
        username = Gtk.Entry()
        username.set_text(current.get("SMTP_USER", ""))
        field(7, "Usuario (opcional)", username)
        password = Gtk.Entry()
        password.set_visibility(False)
        password.set_placeholder_text("Vacío = conservar contraseña guardada")
        field(8, "Contraseña", password)
        clear_password = Gtk.CheckButton(label="Eliminar contraseña SMTP guardada")
        grid.attach(clear_password, 1, 9, 1, 1)
        hint = Gtk.Label(label="Para SMTP local usa localhost:25 y sin cifrado. Para SMTP externo elige STARTTLS (587) o SSL/TLS (465). La contraseña se guarda con permisos de usuario 600.", xalign=0, wrap=True)
        hint.add_css_class("dim-label")
        box.append(hint)
        result_label = Gtk.Label(label="", xalign=0, wrap=True)
        box.append(result_label)
        controls = {"connection": connection, "recipients": recipients, "sender": sender, "policy": policy,
                    "host": host, "port": port, "tls": tls, "username": username, "password": password,
                    "clear_password": clear_password, "result_label": result_label}
        dialog.connect("response", self.mail_settings_response, controls)
        dialog.present()

    def mail_settings_from_controls(self, controls):
        external_type = controls["connection"].get_selected()
        host = controls["host"].get_text().strip()
        port = controls["port"].get_text().strip()
        username = controls["username"].get_text().strip()
        password = controls["password"].get_text()
        if external_type == 0:
            host, port, username = "localhost", "25", ""
            tls_value = "none"
        else:
            tls_value = ("none", "starttls", "ssl")[controls["tls"].get_selected()]
        if external_type != 2 and (not host or not port.isdigit() or not (1 <= int(port) <= 65535)):
            raise ValueError("Indica un servidor SMTP y un puerto entre 1 y 65535.")
        policy = ("nunca", "siempre", "error")[controls["policy"].get_selected()]
        return ({"MAIL_ENVIAR": policy, "MAIL_A": controls["recipients"].get_text().strip(),
                 "MAIL_DE": controls["sender"].get_text().strip(),
                 "MAIL_METODO": "local" if external_type == 2 else "smtp",
                 "SMTP_HOST": host, "SMTP_PORT": port, "SMTP_TLS": tls_value, "SMTP_USER": username}, password)

    def mail_settings_response(self, dialog, response, controls):
        if response not in (Gtk.ResponseType.ACCEPT, 1):
            dialog.destroy()
            return
        try:
            settings, password = self.mail_settings_from_controls(controls)
            self.save_mail_settings(settings, password)
            if controls["clear_password"].get_active():
                PASS_FILE.unlink(missing_ok=True)
                self.mail = self.read_mail_settings()
        except (OSError, ValueError) as error:
            self.show_message("No se pudo guardar la configuración", str(error), Gtk.MessageType.ERROR)
            if response == Gtk.ResponseType.ACCEPT:
                dialog.destroy()
            return
        if response == 1:
            self.test_mail(controls["result_label"])
        else:
            dialog.destroy()
            self.status.set_text("Configuración de correo guardada")

    def test_mail(self, result_label):
        result_label.set_text("Enviando prueba…")
        self.status.set_text("Enviando correo de prueba…")
        command = [str(BACKEND), "-C", str(CONFIG_DIR), "-t"]
        def worker():
            try:
                result = subprocess.run(command, capture_output=True, text=True, errors="replace", timeout=90)
                self.events.put(("mailtest", (result.returncode, result.stdout + result.stderr, result_label)))
            except Exception as error:
                self.events.put(("mailtest", (1, str(error), result_label)))
        threading.Thread(target=worker, daemon=True).start()

    def open_schedule_settings(self, _button):
        dialog = Gtk.Dialog(title="Programar copias automáticas", transient_for=self, modal=True)
        dialog.add_button("Cerrar", Gtk.ResponseType.CANCEL)
        dialog.add_button("Desactivar programación", 2)
        dialog.add_button("Guardar y activar", Gtk.ResponseType.ACCEPT)
        dialog.set_default_response(Gtk.ResponseType.ACCEPT)
        box = dialog.get_content_area()
        box.set_spacing(10)
        box.set_margin_top(14)
        box.set_margin_bottom(14)
        box.set_margin_start(14)
        box.set_margin_end(14)
        grid = Gtk.Grid(column_spacing=10, row_spacing=9)
        box.append(grid)
        frequency = Gtk.DropDown.new_from_strings(["Cada N horas", "Cada día", "Cada semana"])
        existing = self.schedule
        frequency.set_selected({"hours": 0, "daily": 1, "weekly": 2}.get(existing.get("frequency", "daily"), 1))
        grid.attach(Gtk.Label(label="Frecuencia", xalign=0), 0, 0, 1, 1)
        grid.attach(frequency, 1, 0, 2, 1)
        interval = Gtk.SpinButton.new_with_range(1, 168, 1)
        interval.set_value(int(existing.get("interval", 6)))
        grid.attach(Gtk.Label(label="Intervalo (para horas)", xalign=0), 0, 1, 1, 1)
        grid.attach(interval, 1, 1, 1, 1)
        weekday = Gtk.DropDown.new_from_strings(["Lunes", "Martes", "Miércoles", "Jueves", "Viernes", "Sábado", "Domingo"])
        weekday.set_selected(int(existing.get("weekday", 0)))
        grid.attach(Gtk.Label(label="Día (para semana)", xalign=0), 0, 2, 1, 1)
        grid.attach(weekday, 1, 2, 1, 1)
        hour = Gtk.SpinButton.new_with_range(0, 23, 1)
        minute = Gtk.SpinButton.new_with_range(0, 59, 1)
        hour.set_value(int(existing.get("hour", 2)))
        minute.set_value(int(existing.get("minute", 0)))
        time_row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=6)
        time_row.append(hour)
        time_row.append(Gtk.Label(label=":"))
        time_row.append(minute)
        grid.attach(Gtk.Label(label="Hora (para día/semana)", xalign=0), 0, 3, 1, 1)
        grid.attach(time_row, 1, 3, 1, 1)
        note = Gtk.Label(label="La programación instala un temporizador systemd del sistema para que los backups se ejecuten como root aunque la app esté cerrada. Requiere autorización administrativa.", xalign=0, wrap=True)
        note.add_css_class("dim-label")
        box.append(note)
        controls = {"frequency": frequency, "interval": interval, "weekday": weekday, "hour": hour, "minute": minute}
        dialog.connect("response", self.schedule_response, controls)
        dialog.present()

    def schedule_response(self, dialog, response, controls):
        dialog.destroy()
        if response == 2:
            self.disable_schedule()
            return
        if response != Gtk.ResponseType.ACCEPT:
            return
        if not self.sources or not self.destination.get_text().strip():
            self.show_message("Falta configuración", "Completa las carpetas y el destino antes de programar.", Gtk.MessageType.WARNING)
            return
        schedule = {"frequency": ("hours", "daily", "weekly")[controls["frequency"].get_selected()],
                    "interval": controls["interval"].get_value_as_int(),
                    "weekday": controls["weekday"].get_selected(), "hour": controls["hour"].get_value_as_int(),
                    "minute": controls["minute"].get_value_as_int(), "uid": os.getuid(), "gid": os.getgid()}
        self.activate_schedule(schedule)

    def activate_schedule(self, schedule):
        destination = Path(self.destination.get_text().strip()).expanduser().resolve()
        for source in self.sources:
            resolved_source = Path(source).resolve()
            if destination == resolved_source or resolved_source in destination.parents:
                self.show_message("Destino inválido", f"El destino programado no puede estar dentro del origen:\n{source}", Gtk.MessageType.ERROR)
                return
        try:
            destination.mkdir(parents=True, exist_ok=True, mode=0o700)
            self.probe_destination(destination)
        except PermissionError:
            self.offer_destination_access(destination, create=True,
                                          continuation=lambda: self.activate_schedule(schedule))
            return
        except OSError as error:
            self.show_message("Destino no disponible", f"No se pudo crear o escribir en:\n{destination}\n\n{error}", Gtk.MessageType.ERROR)
            return
        self.destination.set_text(str(destination))
        try:
            profile_name = self.persist_current_profile(remember=False)
            schedule["profile"] = profile_name
            self.install_schedule(schedule)
        except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
            self.show_message("No se pudo activar la programación", str(error), Gtk.MessageType.ERROR)

    def systemd_units(self):
        unit_dir = Path("/etc/systemd/system")
        return unit_dir, unit_dir / "backup-desktop.service", unit_dir / "backup-desktop.timer"

    @staticmethod
    def systemd_quote(value):
        return '"' + str(value).replace("\\", "\\\\").replace('"', '\\"').replace("%", "%%") + '"'

    def install_schedule(self, schedule):
        if not shutil.which("systemctl"):
            raise RuntimeError("No se encontró systemctl. La programación requiere systemd.")
        pkexec = shutil.which("pkexec")
        install = shutil.which("install")
        if os.geteuid() != 0 and (not pkexec or not install):
            raise RuntimeError("Se necesitan pkexec y GNU coreutils para instalar el timer con permisos administrativos.")
        if not JOB_RUNNER.exists():
            raise RuntimeError(f"No se encuentra el ejecutor programado: {JOB_RUNNER}")
        unit_dir, service_path, timer_path = self.systemd_units()
        self.systemctl_admin("disable", "--now", "backup-desktop.timer", check=False)
        SCHEDULE_FILE.write_text(json.dumps(schedule, ensure_ascii=False, indent=2), encoding="utf-8")
        SCHEDULE_FILE.chmod(0o600)
        command = f"{self.systemd_quote(sys.executable)} {self.systemd_quote(JOB_RUNNER)} {self.systemd_quote(CONFIG_DIR)}"
        service = "[Unit]\nDescription=Backup Linux programado\n\n[Service]\nType=oneshot\n" + f"ExecStart={command}\n"
        frequency = schedule["frequency"]
        if frequency == "hours":
            timer = f"OnStartupSec=5min\nOnUnitActiveSec={schedule['interval']}h\n"
        elif frequency == "daily":
            timer = f"OnCalendar=*-*-* {schedule['hour']:02d}:{schedule['minute']:02d}:00\nPersistent=true\n"
        else:
            days = ("Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun")
            timer = f"OnCalendar={days[schedule['weekday']]} *-*-* {schedule['hour']:02d}:{schedule['minute']:02d}:00\nPersistent=true\n"
        timer = "[Unit]\nDescription=Programación de Backup Linux\n\n[Timer]\n" + timer + "AccuracySec=1min\nUnit=backup-desktop.service\n\n[Install]\nWantedBy=timers.target\n"
        staged_service = CONFIG_DIR / "backup-desktop.service"
        staged_timer = CONFIG_DIR / "backup-desktop.timer"
        staged_service.write_text(service, encoding="utf-8")
        staged_timer.write_text(timer, encoding="utf-8")
        for staged in (staged_service, staged_timer):
            staged.chmod(0o600)
        if os.geteuid() == 0:
            shutil.copyfile(staged_service, service_path)
            shutil.copyfile(staged_timer, timer_path)
            service_path.chmod(0o644)
            timer_path.chmod(0o644)
        else:
            for staged, target in ((staged_service, service_path), (staged_timer, timer_path)):
                result = subprocess.run([pkexec, install, "-m", "0644", "--", str(staged), str(target)],
                                        capture_output=True, text=True, timeout=120)
                if result.returncode:
                    raise RuntimeError((result.stderr or result.stdout).strip() or "No se pudo instalar la tarea de systemd.")
        self.systemctl_admin("daemon-reload")
        self.systemctl_admin("enable", "--now", "backup-desktop.timer")
        self.schedule = schedule
        self.update_schedule_status()

    def systemctl_admin(self, *args, check=True):
        systemctl = shutil.which("systemctl")
        if not systemctl:
            if check:
                raise RuntimeError("No se encontró systemctl.")
            return None
        if os.geteuid() == 0:
            command = [systemctl, *args]
        else:
            pkexec = shutil.which("pkexec")
            if not pkexec:
                raise RuntimeError("Se necesita pkexec para administrar el timer de root.")
            command = [pkexec, systemctl, *args]
        result = subprocess.run(command, capture_output=True, text=True, timeout=120)
        if check and result.returncode:
            raise RuntimeError((result.stderr or result.stdout).strip() or f"systemctl {' '.join(args)} falló")
        return result

    def disable_schedule(self):
        unit_dir, service_path, timer_path = self.systemd_units()
        try:
            self.systemctl_admin("disable", "--now", "backup-desktop.timer", check=False)
            pkexec = shutil.which("pkexec")
            rm = shutil.which("rm")
            if os.geteuid() == 0:
                service_path.unlink(missing_ok=True)
                timer_path.unlink(missing_ok=True)
            else:
                if not pkexec or not rm:
                    raise RuntimeError("Se necesitan pkexec y rm para desactivar la programación del sistema.")
                result = subprocess.run([pkexec, rm, "-f", "--", str(service_path), str(timer_path)],
                                        capture_output=True, text=True, timeout=120)
                if result.returncode:
                    raise RuntimeError((result.stderr or result.stdout).strip() or "No se pudieron eliminar las unidades del timer.")
            self.systemctl_admin("daemon-reload", check=False)
            SCHEDULE_FILE.unlink(missing_ok=True)
            self.schedule = {}
            self.update_schedule_status()
            self.status.set_text("Programación desactivada")
        except (OSError, RuntimeError, subprocess.SubprocessError) as error:
            self.show_message("No se pudo desactivar", str(error), Gtk.MessageType.ERROR)

    def update_schedule_status(self):
        if not hasattr(self, "status"):
            return
        if not self.schedule:
            self.status.set_text("Listo · sin programación automática")
            return
        freq = self.schedule.get("frequency")
        if freq == "hours":
            description = f"cada {self.schedule.get('interval', 1)} h"
        else:
            description = f"{self.schedule.get('hour', 2):02d}:{self.schedule.get('minute', 0):02d}"
            if freq == "weekly":
                description = "semanal · " + description
            else:
                description = "diario · " + description
        self.status.set_text(f"Programación activa: {description}")

    def show_message(self, title, text, message_type=Gtk.MessageType.INFO):
        dialog = Gtk.Dialog(title=title, transient_for=self, modal=True)
        dialog.add_button("Aceptar", Gtk.ResponseType.OK)
        dialog.set_default_response(Gtk.ResponseType.OK)
        content = dialog.get_content_area()
        content.set_spacing(8)
        content.set_margin_top(14)
        content.set_margin_bottom(14)
        content.set_margin_start(16)
        content.set_margin_end(16)
        heading = Gtk.Label(label=title, xalign=0)
        heading.add_css_class("title-3")
        if message_type == Gtk.MessageType.ERROR:
            heading.add_css_class("error")
        elif message_type == Gtk.MessageType.WARNING:
            heading.add_css_class("warning")
        content.append(heading)
        details = Gtk.Label(label=text, xalign=0, wrap=True, selectable=True)
        details.set_max_width_chars(72)
        content.append(details)
        dialog.connect("response", lambda d, _r: d.destroy())
        dialog.present()

    def confirm(self, summary, callback):
        dialog = Gtk.Dialog(title="Confirmar backup", transient_for=self, modal=True)
        dialog.add_button("Cancelar", Gtk.ResponseType.NO)
        dialog.add_button("Iniciar backup", Gtk.ResponseType.YES)
        dialog.set_default_response(Gtk.ResponseType.NO)
        content = dialog.get_content_area()
        content.set_spacing(8)
        content.set_margin_top(14)
        content.set_margin_bottom(14)
        content.set_margin_start(16)
        content.set_margin_end(16)
        content.append(Gtk.Label(label="Confirma los parámetros antes de iniciar:", xalign=0))
        details = Gtk.Label(label=summary, xalign=0, wrap=True, selectable=True)
        details.set_max_width_chars(76)
        content.append(details)
        dialog.connect("response", lambda d, response: (d.destroy(), callback(response == Gtk.ResponseType.YES)))
        dialog.present()

    def start_backup(self, _button):
        if os.geteuid() != 0 and not shutil.which("pkexec"):
            self.show_message("Falta PolicyKit", "Instala pkexec para ejecutar el motor de copia con permisos de root.", Gtk.MessageType.ERROR)
            return
        sources = self.sources[:]
        dest = self.destination.get_text().strip()
        retention = self.retention.get_value_as_int()
        if not sources or not dest:
            self.show_message("Falta configuración", "Agrega al menos una carpeta de origen y define el destino.", Gtk.MessageType.WARNING)
            return
        for source in sources:
            if not Path(source).is_dir():
                self.show_message("Origen no disponible", f"La carpeta ya no existe:\n{source}", Gtk.MessageType.ERROR)
                return
        resolved_dest = Path(dest).expanduser().resolve()
        dest = str(resolved_dest)
        for source in sources:
            resolved_source = Path(source).resolve()
            if resolved_dest == resolved_source or resolved_source in resolved_dest.parents:
                self.show_message("Destino inválido", f"El destino no puede estar dentro del origen:\n{source}", Gtk.MessageType.ERROR)
                return
        mode = "rsync" if self.mode.get_selected() == 0 else "tar"
        summary = ("El motor de copia se ejecutará con permisos de root.\n\n"
                   "Se iniciará el backup de:\n\n" + "\n".join(sources) +
                   f"\n\nDestino: {dest}\nModo: {mode}\nRetención: {retention} días")
        self.confirm(summary, lambda accepted: self.run_confirmed_backup(accepted, sources, dest, retention, mode))

    def run_confirmed_backup(self, accepted, sources, dest, retention, mode):
        if not accepted:
            return
        destination = Path(dest).expanduser().resolve()
        try:
            destination.mkdir(parents=True, exist_ok=True, mode=0o700)
            self.probe_destination(destination)
        except PermissionError:
            self.offer_destination_access(
                destination, create=True,
                continuation=lambda: self.run_confirmed_backup(True, sources, str(destination), retention, mode))
            return
        except OSError as error:
            self.show_message("Destino no disponible", f"No se pudo crear o escribir en:\n{destination}\n\n{error}", Gtk.MessageType.ERROR)
            return
        self.destination.set_text(str(destination))
        CONFIG_DIR.mkdir(mode=0o700, parents=True, exist_ok=True)
        try:
            self.persist_current_profile()
        except OSError as error:
            self.show_message("No se pudo guardar la configuración", str(error), Gtk.MessageType.ERROR)
            return
        self.stopfile = str(CONFIG_DIR / f"stop-{os.getpid()}")
        try:
            os.unlink(self.stopfile)
        except FileNotFoundError:
            pass
        cmd = [str(BACKEND), "-y", "-C", str(CONFIG_DIR), "-o", dest, "-m", mode,
               "-r", str(retention), "-n", "Escritorio", "-p", "-k", self.stopfile]
        for source in sources:
            cmd.extend(("-d", source))
        if self.snapshot.get_active():
            cmd.append("-s")
        for pattern in self.get_excludes():
            if pattern:
                cmd.extend(("-x", pattern))
        if os.geteuid() != 0:
            cmd.insert(0, shutil.which("pkexec"))
        self.append_log("\n" + "=" * 70 + "\n")
        self.status.set_text("Ejecutando backup…")
        self.run_button.set_sensitive(False)
        self.cancel_button.set_sensitive(True)
        self.running = True
        self.progress.set_text("En curso")
        self.progress.pulse()
        GLib.timeout_add(120, self.pulse_progress)
        threading.Thread(target=self.run_process, args=(cmd,), daemon=True).start()

    def pulse_progress(self):
        if not self.running:
            self.progress.set_fraction(0)
            self.progress.set_text("")
            return GLib.SOURCE_REMOVE
        self.progress.pulse()
        return GLib.SOURCE_CONTINUE

    def run_process(self, cmd):
        try:
            self.proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                         text=True, encoding="utf-8", errors="replace", bufsize=1,
                                         env={**os.environ, "LC_ALL": "C"})
            for line in self.proc.stdout:
                self.events.put(("line", line))
            self.events.put(("done", self.proc.wait()))
        except Exception as error:
            self.events.put(("error", str(error)))

    def cancel_backup(self, _button):
        if self.running and self.stopfile:
            Path(self.stopfile).touch()
            self.status.set_text("Cancelando…")
            self.cancel_button.set_sensitive(False)

    def exit_app(self, _button):
        if not self.running:
            self.get_application().quit()
            return
        dialog = Gtk.Dialog(title="Backup en curso", transient_for=self, modal=True)
        dialog.add_button("Seguir con el backup", Gtk.ResponseType.CANCEL)
        dialog.add_button("Cancelar backup y salir", Gtk.ResponseType.ACCEPT)
        dialog.set_default_response(Gtk.ResponseType.CANCEL)
        content = dialog.get_content_area()
        content.set_spacing(8)
        content.set_margin_top(14)
        content.set_margin_bottom(14)
        content.set_margin_start(16)
        content.set_margin_end(16)
        content.append(Gtk.Label(label="Hay una copia ejecutándose. Puedes dejarla continuar o cancelarla antes de cerrar la aplicación.", xalign=0, wrap=True))
        def on_response(current, response):
            current.destroy()
            if response == Gtk.ResponseType.ACCEPT:
                self.exit_after_backup = True
                self.cancel_backup(None)
        dialog.connect("response", on_response)
        dialog.present()

    def append_log(self, text):
        end = self.log_buffer.get_end_iter()
        self.log_buffer.insert(end, text)
        mark = self.log_buffer.create_mark(None, self.log_buffer.get_end_iter(), False)
        self.log_view.scroll_mark_onscreen(mark)
        self.log_buffer.delete_mark(mark)

    def poll_events(self):
        try:
            while True:
                kind, value = self.events.get_nowait()
                if kind == "line":
                    self.append_log(value)
                elif kind == "done":
                    self.finish(value)
                elif kind == "error":
                    self.append_log(f"\nError al iniciar el motor: {value}\n")
                    self.finish(1)
                elif kind == "mailtest":
                    code, output, result_label = value
                    self.append_log("\n--- Prueba de correo ---\n" + output + "\n")
                    result_label.set_text("Envío de prueba correcto." if code == 0 else f"Falló la prueba: {output.strip()}")
                    result_label.add_css_class("success" if code == 0 else "error")
                    self.status.set_text("Prueba SMTP completada" if code == 0 else "Falló la prueba SMTP")
        except queue.Empty:
            pass
        return GLib.SOURCE_CONTINUE

    def finish(self, code):
        self.running = False
        self.progress.set_fraction(0)
        self.progress.set_text("")
        self.run_button.set_sensitive(True)
        self.cancel_button.set_sensitive(False)
        self.proc = None
        if self.stopfile:
            try:
                os.unlink(self.stopfile)
            except FileNotFoundError:
                pass
        if code == 0:
            self.status.set_text("Backup completado")
        elif code == 130:
            self.status.set_text("Backup cancelado")
        elif code == 126:
            self.status.set_text("No se concedió la autorización de administrador")
        else:
            self.status.set_text(f"Backup finalizado con errores (código {code})")
        if self.exit_after_backup:
            self.get_application().quit()


class BackupApplication(Gtk.Application):
    def __init__(self):
        super().__init__(application_id=APP_ID, flags=Gio.ApplicationFlags.DEFAULT_FLAGS)

    def do_activate(self):
        window = self.props.active_window
        if not window:
            window = BackupWindow(self)
        window.present()


def main():
    if not BACKEND.exists():
        raise SystemExit(f"No se encuentra el motor de backup: {BACKEND}")
    return BackupApplication().run(None)


if __name__ == "__main__":
    raise SystemExit(main())
