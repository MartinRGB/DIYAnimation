import Foundation
import XPC
import os

/// Note: trying to {en,de}code this results in gibberish unless using XPC{En,De}Coder.
public final class XPCConnection: Codable, Hashable  {
    private enum CodingKeys: CodingKey {}
    
    /// Describes any remote transport/wire/serialization errors that XPC may emit.
    public enum XPCError: Int, Error, Codable {
        case connectionInterrupted, connectionInvalid, terminationImminent
        case codingError, replyInvalid, unregisteredMessage
        
        /// Attempt to map an XPC_ERROR_TYPE to an XPCError.
        /// Note: not all XPC_ERROR_* are mappable to XPCErrors.
        public init?(from obj: xpc_object_t) {
            if xpc_equal(obj, XPC_ERROR_CONNECTION_INTERRUPTED) {
                self = .connectionInterrupted
            } else if xpc_equal(obj, XPC_ERROR_CONNECTION_INVALID) {
                self = .connectionInvalid
            } else if xpc_equal(obj, XPC_ERROR_TERMINATION_IMMINENT) {
                self = .terminationImminent
            } else {
                return nil
            }
        }
        
        /// Attempt to map an XPCError to an XPC_ERROR_TYPE.
        /// Note: not all XPCErrors are mappable to XPC_ERROR_*.
        var underlyingError: xpc_object_t? {
            switch self {
            case .connectionInterrupted: return XPC_ERROR_CONNECTION_INTERRUPTED
            case .connectionInvalid: return XPC_ERROR_CONNECTION_INVALID
            case .terminationImminent: return XPC_ERROR_TERMINATION_IMMINENT
            default: return nil
            }
        }
    }
    
    /// Encapsulates all the properties of the wire underlying the XPCConnection.
    /// - Note: internally, XPC uses `audit_token_to_au32(...)` to provide this information.
    public struct XPCConnectionProperties: Codable {
        public let euid: uid_t
        public let egid: gid_t
        public let pid: pid_t
        public let asid: au_asid_t
        
        //xpc_connection_get_audit_token(...)?
        internal init(_ connection: xpc_connection_t) {
            self.euid = xpc_connection_get_euid(connection)
            self.egid = xpc_connection_get_egid(connection)
            self.pid = xpc_connection_get_pid(connection)
            self.asid = xpc_connection_get_asid(connection)
        }
    }
    
    /// The name of the endpoint (other end) the XPCConnection is connected to.
    public var name: String {
        guard let c = self.connection else { return "" }
        guard let n = xpc_connection_get_name(c) else { return "" }
        return String(cString: n)
    }
    
    /// The properties of the wire underlying the XPCConnection.
    public var properties: XPCConnectionProperties {
        return XPCConnectionProperties(self.connection)
    }
    
    ///
    internal var connection: xpc_connection_t! = nil
    
    ///
    internal var replyQueue = DispatchQueue(label: "")
    
    ///
    private var errorHandlers = [XPCError: [() -> ()]]()
    
    /// - Note: Does nothing for an unconfigured XPCConnection.
    public var active: Bool = false {
        didSet {
            guard self.connection != nil else { return }
            if active {
                xpc_connection_resume(self.connection)
            } else {
                xpc_connection_suspend(self.connection)
            }
        }
    }
    
    /// Create an XPCConnection for an existing underlying connection.
    internal init(_ connection: xpc_connection_t) {
        self.connection = connection
    }
    
    /// When creating an XPCConnection for an existing underlying connection, the event handler
    /// is not automatically configured; if needed, bootstrap() must be called to do so.
    internal func bootstrap() {
        xpc_connection_set_event_handler(self.connection, self._recv(_:))
        xpc_connection_resume(self.connection)
    }
    
    /// Connect to a service in the local bootstrap domain called `name`.
    /// Wire messages will be serviced on the designated `queue`.
    public init(name: String, active: Bool = false) {
        name.withCString {
            self.connection = xpc_connection_create($0, nil)
        }
        xpc_connection_set_event_handler(self.connection, self._recv(_:))
        if active { self.active = true }
    }
    
    /// Connect to a service in the global bootstrap domain called `machName`.
    /// Wire messages will be serviced on the designated `queue`.
    public init(machName name: String, active: Bool = false) {
        name.withCString {
            self.connection = xpc_connection_create_mach_service($0, nil, 0)
        }
        xpc_connection_set_event_handler(self.connection, self._recv(_:))
        if active { self.active = true }
    }
    
    /// Connect to a privileged service in the global bootstrap domain called `privilegedMachName`.
    /// Wire messages will be serviced on the designated `queue`.
    public init(privilegedMachName name: String, active: Bool = false) {
        name.withCString {
            self.connection = xpc_connection_create_mach_service($0, nil, UInt64(XPC_CONNECTION_MACH_SERVICE_PRIVILEGED))
        }
        xpc_connection_set_event_handler(self.connection, self._recv(_:))
        if active {self.active = true }
    }
    
    deinit {
        xpc_connection_cancel(self.connection)
    }
}

/// XPCConnection: Hashable, Equatable
public extension XPCConnection {
	func hash(into hasher: inout Hasher) {
		hasher.combine(self.connection == nil ? 0 : xpc_hash(self.connection))
	}
    
	static func ==(lhs: XPCConnection, rhs: XPCConnection) -> Bool {
        return xpc_equal(lhs.connection, rhs.connection)
    }
}

/// Primitive send & recv utilities.
public extension XPCConnection {
    
    /// Sends a handled message on the internal XPC connection with an optional reply.
    private func _send(_ event: xpc_object_t, _ reply: ((xpc_object_t) throws -> ())? = nil) {
        if reply != nil {
            xpc_connection_send_message_with_reply(self.connection, event, self.replyQueue) {
                do {
                    try reply!($0)
                } catch(let error) {
                    os_log("remote coding error: %@", error.localizedDescription)
                    self.errorHandlers[.codingError]?.forEach { $0() }
                }
            }
        } else {
            xpc_connection_send_message(self.connection, event)
        }
    }
    
    /// Receives a handled message on the internal XPC connection. Note: needs a preset handler.
    private func _recv(_ event: xpc_object_t) {
        
        // If the event isn't a dictionary (it's an error), trigger the error handlers.
        guard xpc_get_type(event) == XPC_TYPE_DICTIONARY else {
            if let err = XPCError(from: event) {
                self.errorHandlers[err]?.forEach { $0() }
            }; return
        }
        
        /*
        // Dispatch the message to an applicable handler on our reply queue.
        if  let identity = xpc_dictionary_get_string(event, "identity"),
            let handler = self.replyHandlers[String(cString: identity)] {
            self.replyQueue.async {
                do {
                    let x = try handler.handler(xpc_dictionary_get_value(event, "request"))
                    
                    // If the remote end awaits on a reply, respond.
                    if handler.requiresReply == true {
                        let dict = xpc_dictionary_create_reply(event)!
                        xpc_dictionary_set_value(dict, "response", x.0)
                        xpc_dictionary_set_value(dict, "error", x.1)
                        xpc_connection_send_message(self.connection, dict)
                    }
                } catch(let error) {
                    
                    // If we catch a handler error and we need to send a reply, send the
                    // error description if possible. (TODO: CodableError?)
                    if handler.requiresReply == true {
                        let dict = xpc_dictionary_create_reply(event)!
                        error.localizedDescription.withCString {
                            xpc_dictionary_set_string(dict, "__error", $0)
                        }
                        xpc_connection_send_message(self.connection, dict)
                    }
                }
            }
        } else {
            os_log("ignoring unregistered message: %@", event.description)
            self.errorHandlers[.unregisteredMessage]?.forEach { $0() }
        }
 */
    }
    
    /// Installs an error handler for the given error type (one-to-many).
	func handle(error: XPCConnection.XPCError, with handler: @escaping () -> ()) {
        self.errorHandlers[error, default: []].append(handler)
    }
    
    /// The block executes on the same serial queue that messages are handled on.
    /// This ensures that no messages are sent while this block executes.
	func perform(block barrier: @escaping () -> ()) {
        guard self.connection != nil else { return }
        xpc_connection_send_barrier(self.connection, barrier)
    }
}
