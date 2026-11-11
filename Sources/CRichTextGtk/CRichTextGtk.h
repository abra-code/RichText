#ifndef RICHTEXT_CGTK_H
#define RICHTEXT_CGTK_H

// GTK 4 (GtkTextView, GtkTextBuffer and their tags; Pango for tab stops and measuring), for the Linux
// renderer. The oldest versions supported are GNOME 48's: GTK 4.18 and GLib 2.84. A call that needs a newer
// version compiles with the warning "is deprecated: Not available before X.Y", so it shows in the build even
// on a machine with newer libraries.
#define GLIB_VERSION_MIN_REQUIRED GLIB_VERSION_2_84
#define GLIB_VERSION_MAX_ALLOWED GLIB_VERSION_2_84
#define GDK_VERSION_MIN_REQUIRED GDK_VERSION_4_18
#define GDK_VERSION_MAX_ALLOWED GDK_VERSION_4_18

#include <gtk/gtk.h>

// GLib 2.88 declares its flags types with G_GNUC_FLAG_ENUM, and Swift then imports them as option sets whose
// members lose their C names (G_REGEX_MULTILINE is not found). These copies are plain numbers under every GLib
// version: Swift makes a flags value from them with init(rawValue:), and writes no flags as init(rawValue: 0),
// never Type(0) or a C name.
static const guint RICHTEXT_G_REGEX_CASELESS = G_REGEX_CASELESS;
static const guint RICHTEXT_G_REGEX_MULTILINE = G_REGEX_MULTILINE;
static const guint RICHTEXT_G_REGEX_OPTIMIZE = G_REGEX_OPTIMIZE;

#endif
