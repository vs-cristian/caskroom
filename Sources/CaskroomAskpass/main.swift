import AppKit

// The SUDO_ASKPASS program for brew. When a cask's installer needs root, Homebrew
// runs `sudo -A`, and sudo runs this to get the password: it prints the password
// on stdout, or exits non-zero if the user cancels. sudo checks the password.

/// Only sudo may ask. Anything else launching this could read the password off stdout.
func launchedBySudo() -> Bool {
    var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    guard proc_pidpath(getppid(), &path, UInt32(path.count)) > 0 else { return false }
    return String(cString: path) == "/usr/bin/sudo"
}

/// This program's path, from the kernel: argv[0] is only what the launcher passed.
func executablePath() -> URL? {
    var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    guard proc_pidpath(getpid(), &path, UInt32(path.count)) > 0 else { return nil }
    return URL(fileURLWithPath: String(cString: path))
}

/// Caskroom.app, when this runs from its Contents/Helpers.
func enclosingApp() -> URL? {
    guard let app = executablePath()?.resolvingSymlinksInPath()
        .deletingLastPathComponent()   // Helpers
        .deletingLastPathComponent()   // Contents
        .deletingLastPathComponent(),  // Caskroom.app
        app.pathExtension == "app" else { return nil }
    return app
}

/// Caskroom's icon for the dialog. Without it AppKit would use the icon of
/// the folder this program sits in (Contents/Helpers): a plain folder.
func caskroomIcon() -> NSImage? {
    enclosingApp().map { NSWorkspace.shared.icon(forFile: $0.path) }
}

@MainActor
func askForPassword() -> String? {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let icon = caskroomIcon()
    if let icon { app.applicationIconImage = icon }

    let alert = NSAlert()
    if let icon { alert.icon = icon }
    alert.messageText = "Caskroom wants to make changes."
    alert.informativeText = "Homebrew needs an administrator password to finish this. Enter your password to allow this."
    alert.addButton(withTitle: "OK")
    alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"

    let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 22))
    field.placeholderString = "Password"
    alert.accessoryView = field
    alert.window.initialFirstResponder = field
    alert.window.level = .modalPanel

    app.activate()
    let response = alert.runModal()
    defer { field.stringValue = "" }
    guard response == .alertFirstButtonReturn, !field.stringValue.isEmpty else { return nil }
    return field.stringValue
}

guard launchedBySudo() else {
    FileHandle.standardError.write(Data("CaskroomAskpass: only sudo can run this\n".utf8))
    exit(1)
}
guard let password = MainActor.assumeIsolated({ askForPassword() }) else { exit(1) }
FileHandle.standardOutput.write(Data((password + "\n").utf8))
exit(0)
