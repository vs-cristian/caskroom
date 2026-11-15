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

/// Caskroom.app, when this runs from its Contents/Helpers.
func enclosingApp() -> URL? {
    let app = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    return app.pathExtension == "app" ? app : nil
}

@MainActor
func askForPassword() -> String? {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    if let caskroom = enclosingApp() {
        app.applicationIconImage = NSWorkspace.shared.icon(forFile: caskroom.path)
    }

    let alert = NSAlert()
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
