// Sources/RichText/Gtk/RichTextGtkSignals.swift
//
// Connecting Swift closures to GObject signals. Each closure travels in a retained box as the handler's user
// data; GLib releases the box when the handler goes (with its object). A trampoline per signal shape unpacks
// it on the main thread, where GTK emits its signals.

import CRichTextGtk

@MainActor
private final class SignalBox<Run> {
    let run: Run
    init(_ run: Run) {
        self.run = run
    }
}

// GLib's destroy notification for a handler's box, whatever its closure type.
private let releaseBox: @convention(c) (gpointer?, UnsafeMutablePointer<GClosure>?) -> Void = { data, _ in
    guard let data else {
        return
    }
    Unmanaged<AnyObject>.fromOpaque(data).release()
}

private func box<Run>(_ data: gpointer) -> SignalBox<Run> {
    Unmanaged<SignalBox<Run>>.fromOpaque(data).takeUnretainedValue()
}

// Connects a trampoline with `run` in its box; when connecting fails (an unknown signal, which GLib logs),
// GLib never calls the destroy notification, so the box is released here.
@MainActor
@discardableResult
private func connect<Run>(_ instance: UnsafeMutableRawPointer, _ signal: String, _ trampoline: GCallback, _ run: Run) -> gulong {
    let data = Unmanaged.passRetained(SignalBox(run)).toOpaque()
    let id = g_signal_connect_data(instance, signal, trampoline, data, releaseBox, GConnectFlags(0))
    if id == 0 {
        Unmanaged<SignalBox<Run>>.fromOpaque(data).release()
    }
    return id
}

typealias RichTextGtkPointRun = @MainActor (Double, Double) -> Void
typealias RichTextGtkRun = @MainActor () -> Void

// A click gesture's "released": (gesture, press count, x, y, user data). The doubles travel in floating-point
// registers, so this shape needs its own trampoline.
private let clickTrampoline: @convention(c) (gpointer?, gint, gdouble, gdouble, gpointer?) -> Void = { _, _, x, y, data in
    guard let data else {
        return
    }
    let handler: SignalBox<RichTextGtkPointRun> = box(data)
    MainActor.assumeIsolated { handler.run(x, y) }
}

// A motion controller's "motion": (controller, x, y, user data).
private let pointTrampoline: @convention(c) (gpointer?, gdouble, gdouble, gpointer?) -> Void = { _, x, y, data in
    guard let data else {
        return
    }
    let handler: SignalBox<RichTextGtkPointRun> = box(data)
    MainActor.assumeIsolated { handler.run(x, y) }
}

// A signal with one pointer argument, such as notify:: (object, param spec, user data).
private let notifyTrampoline: @convention(c) (gpointer?, gpointer?, gpointer?) -> Void = { _, _, data in
    guard let data else {
        return
    }
    let handler: SignalBox<RichTextGtkRun> = box(data)
    MainActor.assumeIsolated { handler.run() }
}

// A signal with no arguments, such as "map" (widget, user data).
private let plainTrampoline: @convention(c) (gpointer?, gpointer?) -> Void = { _, data in
    guard let data else {
        return
    }
    let handler: SignalBox<RichTextGtkRun> = box(data)
    MainActor.assumeIsolated { handler.run() }
}

@MainActor
enum RichTextGtkSignals {
    static func onClickReleased(_ gesture: UnsafeMutableRawPointer, _ run: @escaping RichTextGtkPointRun) {
        connect(gesture, "released", unsafeBitCast(clickTrampoline, to: GCallback.self), run)
    }

    static func onMotion(_ controller: UnsafeMutableRawPointer, _ run: @escaping RichTextGtkPointRun) {
        connect(controller, "motion", unsafeBitCast(pointTrampoline, to: GCallback.self), run)
    }

    /// Returns the handler id, for g_signal_handler_disconnect on an object that outlives the connection.
    static func onNotify(_ object: UnsafeMutableRawPointer, _ property: String, _ run: @escaping RichTextGtkRun) -> gulong {
        connect(object, "notify::" + property, unsafeBitCast(notifyTrampoline, to: GCallback.self), run)
    }

    static func on(_ object: UnsafeMutableRawPointer, _ signal: String, _ run: @escaping RichTextGtkRun) {
        connect(object, signal, unsafeBitCast(plainTrampoline, to: GCallback.self), run)
    }
}

// A shortcut's callback action: (widget, arguments, user data) -> handled. The box is released by the action's
// destroy notification.
private let shortcutTrampoline: @convention(c) (UnsafeMutablePointer<GtkWidget>?, OpaquePointer?, gpointer?) -> gboolean = {
    _, _, data in
    guard let data else {
        return 0
    }
    let handler: SignalBox<RichTextGtkRun> = box(data)
    MainActor.assumeIsolated { handler.run() }
    return 1
}

private let releaseShortcutBox: @convention(c) (gpointer?) -> Void = { data in
    guard let data else {
        return
    }
    Unmanaged<AnyObject>.fromOpaque(data).release()
}

extension RichTextGtkSignals {
    /// Adds a keyboard shortcut (`trigger` in GTK's syntax, "<Control>f") to `controller`, a
    /// GtkShortcutController, that runs `run` and stops the key there.
    static func addShortcut(to controller: OpaquePointer, _ trigger: String, _ run: @escaping RichTextGtkRun) {
        let data = Unmanaged.passRetained(SignalBox(run)).toOpaque()
        let action = gtk_callback_action_new(shortcutTrampoline, data, releaseShortcutBox)
        let shortcut = gtk_shortcut_new(gtk_shortcut_trigger_parse_string(trigger), action)
        gtk_shortcut_controller_add_shortcut(controller, shortcut)
    }
}
