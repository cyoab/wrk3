// TLS functionality is integrated directly into Socket.zig.
// This file exists for module structure compatibility.
//
// The Socket type handles both plain TCP and TLS connections. When TLS is
// needed, call Socket.startTlsHandshake() after the TCP connection is
// established. All subsequent send/recv calls will automatically go through
// the TLS layer.
pub const Socket = @import("Socket.zig");
