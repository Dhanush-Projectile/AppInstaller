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

[GtkTemplate (ui = "/me/appinstaller/com/window.ui")]
public class Appinstaller.Window : Adw.ApplicationWindow {
    [GtkChild]
    private unowned Gtk.Label pkg_manager_label;
    [GtkChild]
    private unowned Gtk.Label status_label;
    [GtkChild]
    private unowned Gtk.Label drop_hint;
    [GtkChild]
    private unowned Gtk.Image app_icon;
    [GtkChild]
    private unowned Gtk.Label app_label;
    [GtkChild]
    private unowned Gtk.Image folder_icon_drop;
    [GtkChild]
    private unowned Gtk.Button choose_button;

    private string? detected_pkg_manager = null;
    private string? staged_filepath = null;
    private PackageType staged_pkg_type = PackageType.UNKNOWN;
    private string? icon_tmpdir = null;
    private Gdk.Texture? app_texture = null;

    public Window (Gtk.Application app) {
        Object (application: app);
    }

    construct {
        detect_package_manager ();
        setup_drop_target ();
        setup_drag_source ();
        choose_button.clicked.connect (on_choose_package);
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
            pkg_manager_label.set_label ("Package manager: dpkg (Debian/Ubuntu)");
            return;
        }

        if (has_command ("rpm")) {
            detected_pkg_manager = "rpm";
            pkg_manager_label.set_label ("Package manager: rpm (Fedora/RHEL)");
            return;
        }

        // Fall back to parsing /etc/os-release (works even in a sandbox
        // where host package manager binaries are not visible)
        var distro = detect_distro_from_os_release ();
        if (distro == "debian" || distro == "ubuntu") {
            detected_pkg_manager = "dpkg";
            pkg_manager_label.set_label ("Package manager: dpkg (%s)".printf (distro));
            return;
        }
        if (distro == "fedora" || distro == "rhel" || distro == "centos" || distro == "rocky") {
            detected_pkg_manager = "rpm";
            pkg_manager_label.set_label ("Package manager: rpm (%s)".printf (distro));
            return;
        }

        detected_pkg_manager = null;
        pkg_manager_label.set_label ("No supported package manager found");
        drop_hint.set_label ("Cannot install packages on this system");
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
        var folder_drop = create_drop_target_for_folder ();
        folder_icon_drop.add_controller (folder_drop);
    }

    private Gtk.DropTarget create_drop_target_for_folder () {
        var drop_target = new Gtk.DropTarget (typeof (Gdk.FileList), Gdk.DragAction.COPY);

        drop_target.enter.connect ((x, y) => {
            if (staged_filepath == null) {
                return (Gdk.DragAction) 0;
            }
            folder_icon_drop.add_css_class ("drop-zone-active");
            return Gdk.DragAction.COPY;
        });

        drop_target.leave.connect (() => {
            folder_icon_drop.remove_css_class ("drop-zone-active");
        });

        drop_target.drop.connect ((value, x, y) => {
            folder_icon_drop.remove_css_class ("drop-zone-active");

            if (detected_pkg_manager == null) {
                show_error ("No supported package manager found.");
                return false;
            }

            // If a package is staged, install it on drop
            if (staged_filepath != null) {
                show_password_dialog (staged_filepath, staged_pkg_type);
                return true;
            }

            // Otherwise accept an externally dropped package as the staged file
            if (!value.holds (typeof (Gdk.FileList))) {
                show_error ("Could not read dropped files.");
                return false;
            }

            var file_list = (Gdk.FileList) value.get_object ();
            var files = file_list.get_files ();
            if (files.is_empty ()) {
                show_error ("No files dropped.");
                return true;
            }

            var file = files.nth_data (0);
            var filepath = file.get_path ();
            var pkg_type = get_package_type (filepath);

            if (pkg_type == PackageType.UNKNOWN) {
                show_error ("Unsupported file type. Please drop a .deb or .rpm file.");
                return true;
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
        if (filepath.has_suffix (".deb")) return PackageType.DEB;
        if (filepath.has_suffix (".rpm")) return PackageType.RPM;
        return PackageType.UNKNOWN;
    }

    private void stage_package (string filepath, PackageType pkg_type) {
        staged_filepath = filepath;
        staged_pkg_type = pkg_type;

        var basename = Path.get_basename (filepath);

        // Show a generic icon immediately, then replace with the real one
        app_icon.set_from_icon_name (pkg_type == PackageType.DEB ? "package-x-generic" : "application-x-rpm");
        app_label.set_label (basename);

        drop_hint.set_label ("Drag the package onto the System folder to install");

        status_label.set_label ("Package ready: %s".printf (basename));
        status_label.remove_css_class ("success");
        status_label.remove_css_class ("error");
        status_label.remove_css_class ("accent");

        // Extract the actual app icon from the package asynchronously
        extract_icon_from_package.begin (filepath, pkg_type);
    }

    private void on_choose_package () {
        choose_package.begin ();
    }

    private async void choose_package () {
        if (detected_pkg_manager == null) {
            show_error ("No supported package manager found.");
            return;
        }

        var filter = new Gtk.FileFilter ();
        filter.name = "Package files";
        filter.add_suffix ("deb");
        filter.add_suffix ("rpm");

        var all_filter = new Gtk.FileFilter ();
        all_filter.name = "All files";
        all_filter.add_pattern ("*");

        var file_dialog = new Gtk.FileDialog ();
        file_dialog.title = "Select a Package";
        file_dialog.accept_label = "_Install";
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
            show_error ("Could not read selected file.");
            return;
        }

        var filepath = file.get_path ();
        var pkg_type = get_package_type (filepath);
        if (pkg_type == PackageType.UNKNOWN) {
            show_error ("Unsupported file type. Please choose a .deb or .rpm file.");
            return;
        }
        stage_package (filepath, pkg_type);
    }

    private void show_password_dialog (string filepath, PackageType pkg_type) {
        var dialog = new Adw.Dialog ();
        dialog.set_title ("Authentication Required");
        dialog.set_content_width (420);
        dialog.set_content_height (220);

        var main_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 16);
        main_box.set_margin_top (24);
        main_box.set_margin_bottom (24);
        main_box.set_margin_start (24);
        main_box.set_margin_end (24);

        var header_box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 12);
        header_box.set_halign (Gtk.Align.CENTER);

        var lock_icon = new Gtk.Image.from_icon_name ("dialog-password-symbolic");
        lock_icon.set_pixel_size (48);
        header_box.append (lock_icon);

        var title_label = new Gtk.Label ("Enter Password to Install");
        title_label.add_css_class ("title-2");
        header_box.append (title_label);

        main_box.append (header_box);

        var basename = Path.get_basename (filepath);
        var file_label = new Gtk.Label ("Installing: %s".printf (basename));
        file_label.add_css_class ("dim-label");
        file_label.set_halign (Gtk.Align.CENTER);
        file_label.set_ellipsize (Pango.EllipsizeMode.MIDDLE);
        main_box.append (file_label);

        var password_entry = new Gtk.PasswordEntry ();
        password_entry.show_peek_icon = true;
        password_entry.placeholder_text = "System Password";
        password_entry.hexpand = true;

        var password_box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
        password_box.append (password_entry);
        main_box.append (password_box);

        var button_box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
        button_box.set_halign (Gtk.Align.END);

        var cancel_btn = new Gtk.Button.with_label ("Cancel");
        cancel_btn.add_css_class ("flat");
        cancel_btn.clicked.connect (() => {
            dialog.close ();
        });
        button_box.append (cancel_btn);

        var install_btn = new Gtk.Button.with_label ("Install");
        install_btn.add_css_class ("suggested-action");
        install_btn.add_css_class ("pill");
        install_btn.clicked.connect (() => {
            var password = password_entry.get_text ();
            if (password.length == 0) {
                password_entry.add_css_class ("error");
                return;
            }
            password_entry.remove_css_class ("error");

            // Disable the form so the user can't change the password mid-install
            password_entry.sensitive = false;
            install_btn.sensitive = false;
            cancel_btn.sensitive = false;
            install_btn.label = "Installing…";

            // Keep the dialog open during install; close it when done
            run_install (filepath, pkg_type, password, () => {
                dialog.close ();
                return false;
            });
        });
        password_entry.activate.connect (() => {
            install_btn.clicked ();
        });
        button_box.append (install_btn);

        main_box.append (button_box);
        dialog.set_child (main_box);
        dialog.present (this);

        password_entry.grab_focus ();
    }

    private void run_install (string filepath, PackageType pkg_type, string password, owned GLib.SourceFunc? on_done) {
        var basename = Path.get_basename (filepath);
        status_label.set_label ("Installing %s ...".printf (basename));
        status_label.remove_css_class ("success");
        status_label.remove_css_class ("error");
        status_label.add_css_class ("accent");

        string[] argv;
        if (pkg_type == PackageType.DEB) {
            argv = { "/bin/sh", "-c",
                "echo '%s' | sudo -S dpkg -i '%s' 2>&1 && echo '%s' | sudo -S apt-get install -f -y 2>&1"
                .printf (password, filepath, password) };
        } else {
            argv = { "/bin/sh", "-c",
                "echo '%s' | sudo -S rpm -i '%s' 2>&1"
                .printf (password, filepath) };
        }

        do_subprocess_wait.begin (argv, basename, on_done);
    }

    private async void do_subprocess_wait (string[] argv, string basename, owned GLib.SourceFunc? on_done) {
        try {
            var launcher = new SubprocessLauncher (SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_PIPE);
            var proc = launcher.spawnv (argv);
            yield proc.wait_check_async ();
            status_label.set_label ("Successfully installed %s".printf (basename));
            status_label.remove_css_class ("accent");
            status_label.add_css_class ("success");
            show_toast ("Installation complete!");
        } catch (Error e) {
            status_label.set_label ("Installation failed: %s".printf (e.message));
            status_label.remove_css_class ("accent");
            status_label.add_css_class ("error");
        }
        if (on_done != null) {
            on_done ();
        }
    }

    private void show_error (string message) {
        status_label.set_label (message);
        status_label.remove_css_class ("accent");
        status_label.remove_css_class ("success");
        status_label.add_css_class ("error");
    }

    private void show_toast (string message) {
        status_label.set_label (message);
        GLib.Timeout.add_seconds (5, () => {
            status_label.set_label ("Ready");
            status_label.remove_css_class ("success");
            status_label.remove_css_class ("error");
            return false;
        });
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
            icon_tmpdir = DirUtils.make_tmp ("appinstaller-XXXXXX");
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
                app_texture = scale_texture (texture, 110);
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
                border: 3px dashed alpha(@borders, 0.5);
                border-radius: 24px;
                background: alpha(@card_bg_color, 0.3);
                padding: 32px;
                transition: all 200ms ease;
            }
            .drop-zone-active {
                border-color: @accent_bg_color;
                background: alpha(@accent_bg_color, 0.1);
            }
            .icon-drop-zone {
                color: @accent_color;
            }
            .app-icon {
                color: @accent_bg_color;
            }
            .installer-arrow {
                font-size: 40px;
                color: alpha(@window_fg_color, 0.5);
                font-weight: 300;
            }
            .success {
                color: @success_color;
            }
            .error {
                color: @error_color;
            }
        """);
        Gtk.StyleContext.add_provider_for_display (
            Gdk.Display.get_default (),
            css_provider,
            Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION
        );
    }
}
