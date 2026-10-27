import Foundation
import Security

/// Runs one tool as root after the standard macOS admin prompt (Touch ID or password),
/// via Authorization Services. No sudoers, no installed helper, no standing privilege.
///
/// `AuthorizationExecuteWithPrivileges` is deprecated but still shipped; it is resolved at
/// runtime so the build does not depend on the header marking.
enum Privileged {
    enum Failure: LocalizedError {
        case cancelled
        case failed(String)
        var errorDescription: String? {
            switch self {
            case .cancelled:        return "Authorization cancelled."
            case .failed(let m):    return "Could not run privileged helper: \(m)"
            }
        }
    }

    private typealias ExecFn = @convention(c) (
        AuthorizationRef, UnsafePointer<CChar>, AuthorizationFlags,
        UnsafePointer<UnsafeMutablePointer<CChar>?>, UnsafeMutablePointer<UnsafeMutablePointer<FILE>?>?
    ) -> OSStatus

    /// Returns a handle connected to the tool's stdin and stdout (one bidirectional pipe).
    static func run(_ path: String, _ args: [String], prompt: String) throws -> FileHandle {
        var authRef: AuthorizationRef?
        var status = AuthorizationCreate(nil, nil, [], &authRef)
        guard status == errAuthorizationSuccess, let auth = authRef else {
            throw Failure.failed("AuthorizationCreate \(status)")
        }
        defer { AuthorizationFree(auth, []) }

        let rightName = strdup("system.privilege.admin")!
        let promptKey = strdup(kAuthorizationEnvironmentPrompt)!
        let promptValue = strdup(prompt)!
        defer { free(rightName); free(promptKey); free(promptValue) }

        var right = AuthorizationItem(name: rightName, valueLength: 0, value: nil, flags: 0)
        var rights = AuthorizationRights(count: 1, items: &right)
        var env = AuthorizationItem(name: promptKey, valueLength: strlen(promptValue),
                                    value: promptValue, flags: 0)
        var envs = AuthorizationEnvironment(count: 1, items: &env)
        status = AuthorizationCopyRights(auth, &rights, &envs,
                                         [.interactionAllowed, .extendRights, .preAuthorize], nil)
        if status == errAuthorizationCanceled { throw Failure.cancelled }
        guard status == errAuthorizationSuccess else { throw Failure.failed("authorization \(status)") }

        guard let lib = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_NOW),
              let sym = dlsym(lib, "AuthorizationExecuteWithPrivileges") else {
            throw Failure.failed("AuthorizationExecuteWithPrivileges unavailable on this macOS")
        }
        let exec = unsafeBitCast(sym, to: ExecFn.self)

        var argv: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pipe: UnsafeMutablePointer<FILE>?
        status = argv.withUnsafeBufferPointer { buf in
            exec(auth, path, [], buf.baseAddress!, &pipe)
        }
        guard status == errAuthorizationSuccess, let p = pipe else {
            throw Failure.failed("exec \(status)")
        }
        let fd = dup(fileno(p))
        fclose(p)
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }
}
