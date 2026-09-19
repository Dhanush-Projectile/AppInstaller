/* window.vala
 *
 * Copyright 2026 Dhanush
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <https://www.gnu.org/licenses/>.
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

public enum PackageType {
    DEB,
    RPM,
    UNKNOWN;

    public string to_string () {
        switch (this) {
            case DEB:  return ".deb";
            case RPM:  return ".rpm";
            default:   return "unknown";
        }
    }
}

[GtkTemplate (ui = "/me/softwareinstaller/com/window.ui")]
public class SoftwareInstaller.Window : Adw.ApplicationWindow {
    [GtkChild]
    private unowned Adw.ToastOverlay toast_overlay;
    [GtkChild]
    private unowned Gtk.Stack main_stack;
    [GtkChild]
    private unowned Adw.StatusPage empty_page;
    [GtkChild]
    private unowned Gtk.Box staged_page;
    [GtkChild]
    private unowned Gtk.Image app_icon;
    [GtkChild]
    private unowned Gtk.Label app_label;
    [GtkChild]
    private unowned Gtk.Label install_hint;
    [GtkChild]
    private unowned Gtk.Button choose_button;
    [GtkChild]
    private unowned Gtk.Button change_button;
    [GtkChild]
    private unowned Gtk.Button install_button;

    private string? detected_pkg_manager = null;
    private string? staged_filepath = null;
    private PackageType staged_pkg_type = PackageType.UNKNOWN;
    private string? staged_pkg_name = null;
    private bool staged_pkg_installed = false;
    private string? icon_tmpdir = null;
    private Gdk.Texture? app_texture = null;
    private bool installing = false;

    public Window (Gtk.Application app) {
        Object (application: app);
    }

    construct {
        detect_package_manager ();
        setup_drop_target ();
        setup_drag_source ();
        choose_button.clicked.connect (on_choose_package);
        change_button.clicked.connect (on_choose_package);
        install_button.clicked.connect (on_install_clicked);
        apply_drop_zone_css ();
        close_request.connect (() => {
            cleanup_icon_tmpdir ();
            return false;
        });
    }

    private void detect_package_manager () {
        // First try to find the actual package manager binaries
        if (has_command ("dpkg")) {
            detected_pkg_manager = "dpkg";
            return;
        }

        if (has_command ("rpm")) {
            detected_pkg_manager = "rpm";
            return;
        }

        // Fall back to parsing /etc/os-release (works even in a sandbox
        // where host package manager binaries are not visible)
        var distro = detect_distro_from_os_release ();
        if (distro == "debian" || distro == "ubuntu") {
            detected_pkg_manager = "dpkg";
            return;
        }
        if (distro == "fedora" || distro == "rhel" || distro == "centos" || distro == "rocky") {
            detected_pkg_manager = "rpm";
            return;
        }

        detected_pkg_manager = null;
        empty_page.set_description (
            _("No supported package manager was found on this system. Packages cannot be installed.")
        );
        choose_button.sensitive = false;
    }

    private bool has_command (string command) {
        try {
            var proc = new SubprocessLauncher (SubprocessFlags.STDOUT_SILENCE | SubprocessFlags.STDERR_SILENCE);
            var p = proc.spawnv ({ "which", command });
            p.wait ();
            return p.get_exit_status () == 0;
        } catch (Error e) {
            return false;
        }
    }

    private string detect_distro_from_os_release () {
        // In a flatpak sandbox, /run/host/etc/os-release points to the host
        string[] paths = {
            "/run/host/etc/os-release",
            "/etc/os-release"
        };
        foreach (var path in paths) {
            try {
                string contents;
                FileUtils.get_contents (path, out contents);
                foreach (var line in contents.split ("\n")) {
                    if (line.has_prefix ("ID=")) {
                        var id = line.substring (3).strip ().replace ("\"", "");
                        if (id != "") {
                            return id;
                        }
                    }
                }
            } catch (Error e) {}
        }
        return "";
    }

    private void setup_drop_target () {
        empty_page.add_controller (create_drop_target (empty_page));
        staged_page.add_controller (create_drop_target (staged_page));
    }

    private Gtk.DropTarget create_drop_target (Gtk.Widget widget) {
        var drop_target = new Gtk.DropTarget (typeof (Gdk.FileList), Gdk.DragAction.COPY);
        // Accept both Gdk.FileList (from most file managers) and
        // text/uri-list (G_TYPE_STRV) drops for maximum compatibility.
        drop_target.set_gtypes ({ typeof (Gdk.FileList), typeof (string[]) });

        drop_target.enter.connect ((x, y) => {
            widget.add_css_class ("drop-zone-active");
            return Gdk.DragAction.COPY;
        });

        drop_target.leave.connect (() => {
            widget.remove_css_class ("drop-zone-active");
        });

        drop_target.drop.connect ((value, x, y) => {
            widget.remove_css_class ("drop-zone-active");

            if (installing) {
                return false;
            }

            if (detected_pkg_manager == null) {
                show_error (_("No supported package manager found."));
                return false;
            }

            string? filepath = null;

            if (value.holds (typeof (Gdk.FileList))) {
                var file_list = (Gdk.FileList) value.get_boxed ();
                var files = file_list.get_files ();
                if (!files.is_empty ()) {
                    filepath = files.nth_data (0).get_path ();
                }
            } else if (value.holds (typeof (string[]))) {
                var uris = (string[]) value.get_boxed ();
                if (uris[0] != null) {
                    var file = File.new_for_uri (uris[0]);
                    filepath = file.get_path ();
                }
            }

            if (filepath == null) {
                show_error (_("Could not read dropped file."));
                return false;
            }

            var pkg_type = get_package_type (filepath);
            if (pkg_type == PackageType.UNKNOWN) {
                show_error (_("Unsupported file. Please drop a .deb or .rpm package."));
                return false;
            }

            stage_package (filepath, pkg_type);
            return true;
        });

        return drop_target;
    }

    private void setup_drag_source () {
        var drag_source = new Gtk.DragSource ();
        drag_source.set_actions (Gdk.DragAction.COPY);

        drag_source.drag_begin.connect ((drag) => {
            if (app_texture != null) {
                drag_source.set_icon (app_texture, 0, 0);
            }
        });

        drag_source.prepare.connect ((x, y) => {
            if (staged_filepath == null) {
                return null;
            }
            var file_list = new Gdk.FileList.from_array ({ File.new_for_path (staged_filepath) });
            var value = Value (typeof (Gdk.FileList));
            value.set_boxed (file_list);
            return new Gdk.ContentProvider.for_value (value);
        });

        app_icon.add_controller (drag_source);
    }

    private PackageType get_package_type (string filepath) {
        var lower = filepath.down ();
        if (lower.has_suffix (".deb")) return PackageType.DEB;
        if (lower.has_suffix (".rpm")) return PackageType.RPM;
        return PackageType.UNKNOWN;
    }

    private void stage_package (string filepath, PackageType pkg_type) {
        staged_filepath = filepath;
        staged_pkg_type = pkg_type;
        staged_pkg_name = null;
        staged_pkg_installed = false;

        var basename = Path.get_basename (filepath);

        // Show a generic icon immediately, then replace with the real one
        app_icon.set_from_icon_name (pkg_type == PackageType.DEB ? "package-x-generic" : "application-x-rpm");
        app_label.set_label (basename);
        install_hint.set_label (_("Ready to install"));
        install_button.label = _("_Install");
        install_button.sensitive = false;
        change_button.sensitive = true;

        main_stack.set_visible_child (staged_page);

        // Extract the actual app icon from the package asynchronously
        extract_icon_from_package.begin (filepath, pkg_type);
        // Offer install or uninstall depending on whether the package is on the system
        check_if_installed.begin (filepath, pkg_type);
    }

    private async void check_if_installed (string filepath, PackageType pkg_type) {
        install_hint.set_label (_("Checking if already installed…"));
        install_button.label = _("_Install");
        install_button.sensitive = false;

        string? pkg_name;
        var installed = yield is_package_installed (filepath, pkg_type, out pkg_name);

        // The selection may have changed while we were checking
        if (staged_filepath != filepath) {
            return;
        }

        staged_pkg_name = pkg_name;
        staged_pkg_installed = installed;

        if (installed) {
            install_hint.set_label (_("This package is already installed"));
            install_button.label = _("_Uninstall");
            install_button.sensitive = true;
        } else {
            install_hint.set_label (_("Ready to install"));
            install_button.label = _("_Install");
            install_button.sensitive = true;
        }
        install_button.grab_focus ();
    }

    private async bool is_package_installed (string filepath, PackageType pkg_type, out string? pkg_name) {
        pkg_name = null;
        try {
            if (pkg_type == PackageType.DEB) {
                string output;
                yield run_shell_command_with_output (
                    "dpkg-deb -f '%s' Package".printf (filepath), out output);
                pkg_name = output.strip ();
            } else if (pkg_type == PackageType.RPM) {
                string output;
                yield run_shell_command_with_output (
                    "rpm -qp --queryformat '%%{NAME}' '%s'".printf (filepath), out output);
                pkg_name = output.strip ();
            }

            if (pkg_name == null || pkg_name == "") {
                return false;
            }

            var launcher = new SubprocessLauncher (
                SubprocessFlags.STDOUT_SILENCE | SubprocessFlags.STDERR_SILENCE
            );
            var args = (pkg_type == PackageType.DEB)
                ? new string[] { "dpkg", "-s", pkg_name }
                : new string[] { "rpm", "-q", pkg_name };
            var proc = launcher.spawnv (args);
            try {
                yield proc.wait_check_async ();
                return true; // package is installed
            } catch (Error e) {
                return false; // not installed or unknown
            }
        } catch (Error e) {
            return false;
        }
    }

    private void reset_to_empty () {
        staged_filepath = null;
        staged_pkg_type = PackageType.UNKNOWN;
        staged_pkg_name = null;
        staged_pkg_installed = false;
        app_texture = null;
        main_stack.set_visible_child (empty_page);
        choose_button.grab_focus ();
    }

    private void on_choose_package () {
        choose_package.begin ();
    }

    public async void choose_package () {
        if (detected_pkg_manager == null) {
            show_error (_("No supported package manager found."));
            return;
        }

        var filter = new Gtk.FileFilter ();
        filter.name = _("Package files");
        filter.add_suffix ("deb");
        filter.add_suffix ("rpm");

        var all_filter = new Gtk.FileFilter ();
        all_filter.name = _("All files");
        all_filter.add_pattern ("*");

        var file_dialog = new Gtk.FileDialog ();
        file_dialog.title = _("Select a Package");
        file_dialog.accept_label = _("_Install");
        file_dialog.default_filter = filter;

        var filters = new ListStore (typeof (Gtk.FileFilter));
        filters.append (filter);
        filters.append (all_filter);
        file_dialog.filters = filters;

        File? file = null;
        try {
            file = yield file_dialog.open (this, null);
        } catch (Error e) {
            // User cancelled or error - just ignore
            return;
        }

        if (file == null) {
            show_error (_("Could not read selected file."));
            return;
        }

        var filepath = file.get_path ();
        var pkg_type = get_package_type (filepath);
        if (pkg_type == PackageType.UNKNOWN) {
            show_error (_("Unsupported file type. Please choose a .deb or .rpm file."));
            return;
        }
        stage_package (filepath, pkg_type);
    }

    private void on_install_clicked () {
        if (staged_filepath == null) {
            return;
        }
        if (detected_pkg_manager == null) {
            show_error (_("No supported package manager found."));
            return;
        }
        if (staged_pkg_installed) {
            run_uninstall.begin (staged_pkg_name, staged_pkg_type);
        } else {
            run_install.begin (staged_filepath, staged_pkg_type);
        }
    }

    private async void run_install (string filepath, PackageType pkg_type) {
        var basename = Path.get_basename (filepath);

        installing = true;
        install_button.sensitive = false;
        change_button.sensitive = false;
        install_hint.set_label (_("Installing…"));

        bool success = false;
        try {
            // Delegate authentication to the system's polkit agent, as
            // required by the platform design guidelines: applications must
            // never ask for administrative passwords themselves.
            string[] argv;
            if (pkg_type == PackageType.DEB) {
                argv = { "/usr/bin/pkexec", "/bin/sh", "-c",
                    "dpkg -i '%s' && apt-get install -f -y".printf (filepath) };
            } else {
                argv = { "/usr/bin/pkexec", "/bin/sh", "-c",
                    "rpm -i '%s'".printf (filepath) };
            }

            var launcher = new SubprocessLauncher (SubprocessFlags.STDOUT_SILENCE | SubprocessFlags.STDERR_SILENCE);
            var proc = launcher.spawnv (argv);
            yield proc.wait_check_async ();
            success = true;
        } catch (Error e) {
            // Authorization was declined or the install command failed
        }

        installing = false;

        if (success) {
            var toast = new Adw.Toast (_("Successfully installed %s").printf (basename));
            toast.timeout = 5;
            toast_overlay.add_toast (toast);
            reset_to_empty ();
        } else {
            var toast = new Adw.Toast (_("Couldn't install %s").printf (basename));
            toast.timeout = 5;
            toast_overlay.add_toast (toast);
            install_hint.set_label (_("Installation failed"));
            install_button.sensitive = true;
            change_button.sensitive = true;
        }
    }

    private async void run_uninstall (string? pkg_name, PackageType pkg_type) {
        if (pkg_name == null || pkg_name == "") {
            show_error (_("Could not determine the installed package name."));
            return;
        }

        installing = true;
        install_button.sensitive = false;
        change_button.sensitive = false;
        install_hint.set_label (_("Uninstalling…"));

        bool success = false;
        try {
            string[] argv;
            if (pkg_type == PackageType.DEB) {
                argv = { "/usr/bin/pkexec", "dpkg", "-r", pkg_name };
            } else {
                argv = { "/usr/bin/pkexec", "rpm", "-e", pkg_name };
            }

            var launcher = new SubprocessLauncher (SubprocessFlags.STDOUT_SILENCE | SubprocessFlags.STDERR_SILENCE);
            var proc = launcher.spawnv (argv);
            yield proc.wait_check_async ();
            success = true;
        } catch (Error e) {
            // Authorization was declined or the uninstall command failed
        }

        installing = false;

        if (success) {
            var toast = new Adw.Toast (_("Successfully uninstalled %s").printf (pkg_name));
            toast.timeout = 5;
            toast_overlay.add_toast (toast);
            reset_to_empty ();
        } else {
            var toast = new Adw.Toast (_("Couldn't uninstall %s").printf (pkg_name));
            toast.timeout = 5;
            toast_overlay.add_toast (toast);
            install_hint.set_label (_("Uninstall failed"));
            install_button.label = _("_Uninstall");
            install_button.sensitive = true;
            change_button.sensitive = true;
        }
    }

    private void show_error (string message) {
        var toast = new Adw.Toast (message);
        toast.timeout = 5;
        toast_overlay.add_toast (toast);
    }

    private void cleanup_icon_tmpdir () {
        if (icon_tmpdir != null) {
            try {
                var launcher = new SubprocessLauncher (SubprocessFlags.STDOUT_SILENCE | SubprocessFlags.STDERR_SILENCE);
                var proc = launcher.spawnv ({ "/bin/sh", "-c", "rm -rf '%s'".printf (icon_tmpdir) });
                proc.wait ();
            } catch (Error e) {}
            icon_tmpdir = null;
        }
    }

    private async void extract_icon_from_package (string filepath, PackageType pkg_type) {
        cleanup_icon_tmpdir ();

        try {
            icon_tmpdir = DirUtils.make_tmp ("softwareinstaller-XXXXXX");
        } catch (Error e) {
            return;
        }

        try {
            string? icon_entry = null;

            if (pkg_type == PackageType.RPM) {
                icon_entry = yield find_rpm_icon_entry (filepath);
                if (icon_entry != null) {
                    string cmd = "rpm2cpio '%s' 2>/dev/null | cpio -idm -D '%s' '%s' 2>/dev/null"
                        .printf (filepath, icon_tmpdir, icon_entry);
                    yield run_shell_command (cmd);
                }
            } else {
                icon_entry = yield find_deb_icon_entry (filepath);
                if (icon_entry != null) {
                    string cmd = "ar p '%s' data.tar.* 2>/dev/null | tar -xf - -C '%s' '%s' 2>/dev/null"
                        .printf (filepath, icon_tmpdir, icon_entry);
                    yield run_shell_command (cmd);
                }
            }

            string? icon_path = find_best_icon (icon_tmpdir);
            if (icon_path != null) {
                var file = File.new_for_path (icon_path);
                var texture = Gdk.Texture.from_file (file);
                app_texture = scale_texture (texture, 96);
                app_icon.set_from_paintable (app_texture);
            }
        } catch (Error e) {
            // Extraction failed — keep the generic icon
        }
    }

    private Gdk.Texture? scale_texture (Gdk.Texture texture, int size) {
        var src = Gdk.pixbuf_get_from_texture (texture);
        if (src == null) return texture;

        var scaled = src.scale_simple (size, size, Gdk.InterpType.BILINEAR);
        return Gdk.Texture.for_pixbuf (scaled);
    }

    private async string? find_rpm_icon_entry (string filepath) {
        try {
            string cmd = "rpm2cpio '%s' 2>/dev/null | cpio -t 2>/dev/null"
                .printf (filepath);
            string output;
            yield run_shell_command_with_output (cmd, out output);

            string? best = null;
            int best_score = -1;
            foreach (var line in output.split ("\n")) {
                var entry = line.strip ();
                if (entry == "" || entry.has_suffix ("/")) continue;

                int score = score_icon_path (entry);
                if (score > best_score) {
                    best_score = score;
                    best = entry;
                }
            }
            return best;
        } catch (Error e) {
            return null;
        }
    }

    private async string? find_deb_icon_entry (string filepath) {
        try {
            string cmd = "ar p '%s' data.tar.* 2>/dev/null | tar -t 2>/dev/null"
                .printf (filepath);
            string output;
            yield run_shell_command_with_output (cmd, out output);

            string? best = null;
            int best_score = -1;
            foreach (var line in output.split ("\n")) {
                var entry = line.strip ();
                if (entry == "" || entry.has_suffix ("/")) continue;

                int score = score_icon_path (entry);
                if (score > best_score) {
                    best_score = score;
                    best = entry;
                }
            }
            return best;
        } catch (Error e) {
            return null;
        }
    }

    private int score_icon_path (string entry) {
        if (entry.has_suffix (".svg")) return 10;
        if (!entry.has_suffix (".png") && !entry.has_suffix (".xpm")) return -1;

        if (entry.contains ("/icons/hicolor/") && entry.contains ("/apps/")) return 20;
        if (entry.contains ("/pixmaps/")) return 15;
        if (entry.contains ("/icons/")) return 5;
        return 0;
    }

    private async void run_shell_command (string cmd) throws Error {
        var launcher = new SubprocessLauncher (
            SubprocessFlags.STDOUT_SILENCE | SubprocessFlags.STDERR_SILENCE
        );
        var proc = launcher.spawnv ({ "/bin/sh", "-c", cmd });
        yield proc.wait_check_async ();
    }

    private async void run_shell_command_with_output (string cmd, out string output) throws Error {
        var launcher = new SubprocessLauncher (
            SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_SILENCE
        );
        var proc = launcher.spawnv ({ "/bin/sh", "-c", cmd });
        var dis = new DataInputStream (proc.get_stdout_pipe ());
        var builder = new StringBuilder ();
        string? line;
        while ((line = dis.read_line ()) != null) {
            builder.append (line);
            builder.append_c ('\n');
        }
        yield proc.wait_check_async ();
        output = builder.str;
    }

    private string? find_best_icon (string dir) {
        string? best_path = null;
        int best_size = 0;

        try {
            var directory = Dir.open (dir);
            string? name;
            while ((name = directory.read_name ()) != null) {
                var path = Path.build_filename (dir, name);
                if (FileUtils.test (path, FileTest.IS_DIR)) {
                    string? sub = find_best_icon (path);
                    if (sub != null) {
                        int sub_size = get_icon_size (sub);
                        if (sub_size > best_size) {
                            best_size = sub_size;
                            best_path = sub;
                        }
                    }
                } else if (name.has_suffix (".png") || name.has_suffix (".svg")) {
                    int sz = get_icon_size (path);
                    if (sz > best_size) {
                        best_size = sz;
                        best_path = path;
                    }
                }
            }
        } catch (Error e) {}

        return best_path;
    }

    private int get_icon_size (string path) {
        if (path.has_suffix (".svg")) return 512;

        try {
            var texture = Gdk.Texture.from_filename (path);
            return texture.get_width () * texture.get_height ();
        } catch (Error e) {
            return 0;
        }
    }

    private void apply_drop_zone_css () {
        var css_provider = new Gtk.CssProvider ();
        css_provider.load_from_string ("""
            .drop-zone {
                border: none;
                border-radius: 24px;
            }
            .drop-zone-active {
                background-color: alpha(@accent_bg_color, 0.1);
                border: 2px dashed @accent_bg_color;
            }
            .app-icon {
                color: @accent_bg_color;
            }
        """);
        Gtk.StyleContext.add_provider_for_display (
            Gdk.Display.get_default (),
            css_provider,
            Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION
        );
    }
}