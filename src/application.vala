/* application.vala
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

public class SoftwareInstaller.Application : Adw.Application {
    public Application () {
        Object (
            application_id: "me.softwareinstaller.com",
            flags: ApplicationFlags.DEFAULT_FLAGS,
            resource_base_path: "/me/softwareinstaller/com"
        );
    }

    construct {
        ActionEntry[] action_entries = {
            { "choose", this.on_choose_action },
            { "about", this.on_about_action },
            { "shortcuts", this.on_shortcuts_action },
            { "quit", this.quit }
        };
        this.add_action_entries (action_entries, this);
        this.set_accels_for_action ("app.choose", {"<control>o"});
        this.set_accels_for_action ("app.quit", {"<control>q"});
        this.set_accels_for_action ("app.shortcuts", {"<control>question"});
    }

    public override void activate () {
        base.activate ();
        var win = this.active_window ?? new SoftwareInstaller.Window (this);
        win.present ();
    }

    private void on_about_action () {
        string[] developers = { "Dhanush" };
        var about = new Adw.AboutDialog () {
            application_name = "Software Installer",
            application_icon = "me.softwareinstaller.com",
            developer_name = "Dhanush",
            translator_credits = _("translator-credits"),
            version = Config.PACKAGE_VERSION,
            developers = developers,
            copyright = "© 2026 Dhanush",
        };

        about.present (this.active_window);
    }

    private void on_choose_action () {
        var win = this.active_window as SoftwareInstaller.Window;
        if (win != null) {
            win.choose_package.begin ();
        }
    }

    private void on_shortcuts_action () {
        var dialog = new Adw.ShortcutsDialog ();
        var section = new Adw.ShortcutsSection (_("Shortcuts"));
        section.add (new Adw.ShortcutsItem.from_action (_("Choose a package"), "app.choose"));
        section.add (new Adw.ShortcutsItem.from_action (_("Quit"), "app.quit"));
        dialog.add (section);
        dialog.present (this.active_window);
    }
}