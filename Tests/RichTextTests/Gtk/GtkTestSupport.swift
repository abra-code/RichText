// Tests/RichTextTests/Gtk/GtkTestSupport.swift
//
// Whether GTK has a display, asked once for the whole test run: after a failed gtk_init_check, GTK aborts on
// the next one. Tests that need a display skip without one (in the box, run them in the GNOME session).

import CRichTextGtk

@MainActor
private var displayOpened: Bool?

@MainActor
func gtkDisplay() -> Bool {
    if let known = displayOpened {
        return known
    }
    let opened = gtk_init_check() != 0
    displayOpened = opened
    return opened
}
