const std = @import("std");

const jsruntime = @import("jsruntime");
const Case = jsruntime.test_utils.Case;
const checkCases = jsruntime.test_utils.checkCases;
const generate = @import("../generate.zig");

const DOMError = @import("../netsurf.zig").DOMError;
const DOMException = @import("../dom/exceptions.zig").DOMException;

const ProgressEvent = @import("progress_event.zig").ProgressEvent;
const XMLHttpRequestEventTarget = @import("event_target.zig").XMLHttpRequestEventTarget;

const Loop = jsruntime.Loop;
const YieldImpl = Loop.Yield(XMLHttpRequest);
const Client = @import("../async/Client.zig");

const parser = @import("../netsurf.zig");

const log = std.log.scoped(.xhr);

// XHR interfaces
// https://xhr.spec.whatwg.org/#interface-xmlhttprequest
pub const Interfaces = generate.Tuple(.{
    XMLHttpRequestEventTarget,
    XMLHttpRequestUpload,
    XMLHttpRequest,
});

pub const XMLHttpRequestUpload = struct {
    pub const prototype = *XMLHttpRequestEventTarget;
    pub const mem_guarantied = true;

    proto: XMLHttpRequestEventTarget = XMLHttpRequestEventTarget{},
};

pub const XMLHttpRequest = struct {
    pub const prototype = *XMLHttpRequestEventTarget;
    pub const mem_guarantied = true;

    pub const UNSENT: u16 = 0;
    pub const OPENED: u16 = 1;
    pub const HEADERS_RECEIVED: u16 = 2;
    pub const LOADING: u16 = 3;
    pub const DONE: u16 = 4;

    // https://xhr.spec.whatwg.org/#response-type
    const ResponseType = enum {
        Empty,
        Text,
        ArrayBuffer,
        Blob,
        Document,
        JSON,
    };

    const PrivState = enum { new, open, send, finish, wait, done };

    proto: XMLHttpRequestEventTarget = XMLHttpRequestEventTarget{},
    alloc: std.mem.Allocator,
    cli: Client,
    impl: YieldImpl,

    priv_state: PrivState = .new,
    req: ?Client.Request = null,

    method: std.http.Method,
    state: u16,
    url: ?[]const u8,
    uri: std.Uri,
    headers: std.http.Headers,
    sync: bool = true,
    err: ?anyerror = null,

    upload: ?XMLHttpRequestUpload = null,
    timeout: u32 = 0,
    withCredentials: bool = false,
    // TODO: response readonly attribute any response;
    response_bytes: ?[]const u8 = null,
    response_type: ResponseType = .Empty,
    response_headers: std.http.Headers,
    response_status: u10 = 0,
    send_flag: bool = false,

    pub fn constructor(alloc: std.mem.Allocator, loop: *Loop) !XMLHttpRequest {
        return .{
            .alloc = alloc,
            .headers = .{ .allocator = alloc, .owned = true },
            .response_headers = .{ .allocator = alloc, .owned = true },
            .impl = YieldImpl.init(loop),
            .method = undefined,
            .url = null,
            .uri = undefined,
            .state = UNSENT,
            // TODO retrieve the HTTP client globally to reuse existing connections.
            .cli = .{ .allocator = alloc, .loop = loop },
        };
    }

    pub fn deinit(self: *XMLHttpRequest, alloc: std.mem.Allocator) void {
        self.proto.deinit(alloc);
        self.headers.deinit();
        self.response_headers.deinit();
        if (self.url) |v| alloc.free(v);
        if (self.response_bytes) |v| alloc.free(v);
        if (self.response_headers) |v| alloc.free(v);

        if (self.req) |*r| r.deinit();
        // TODO the client must be shared between requests.
        self.cli.deinit();
    }

    pub fn get_readyState(self: *XMLHttpRequest) u16 {
        return self.state;
    }

    pub fn get_timeout(self: *XMLHttpRequest) u32 {
        return self.timeout;
    }

    pub fn set_timeout(self: *XMLHttpRequest, timeout: u32) !void {
        // TODO If the current global object is a Window object and this’s
        // synchronous flag is set, then throw an "InvalidAccessError"
        // DOMException.
        // https://xhr.spec.whatwg.org/#dom-xmlhttprequest-timeout
        self.timeout = timeout;
    }

    pub fn get_withCredentials(self: *XMLHttpRequest) bool {
        return self.withCredentials;
    }

    pub fn set_withCredentials(self: *XMLHttpRequest, withCredentials: bool) !void {
        if (self.state != OPENED and self.state != UNSENT) return DOMError.InvalidState;
        if (self.send_flag) return DOMError.InvalidState;

        self.withCredentials = withCredentials;
    }

    pub fn _open(
        self: *XMLHttpRequest,
        alloc: std.mem.Allocator,
        method: []const u8,
        url: []const u8,
        asyn: ?bool,
        username: ?[]const u8,
        password: ?[]const u8,
    ) !void {
        _ = username;
        _ = password;

        // TODO If this’s relevant global object is a Window object and its
        // associated Document is not fully active, then throw an
        // "InvalidStateError" DOMException.

        self.method = try validMethod(method);

        self.url = try alloc.dupe(u8, url);
        self.uri = std.Uri.parse(self.url.?) catch return DOMError.Syntax;
        self.sync = if (asyn) |b| !b else false;
        self.send_flag = false;

        // TODO should we clearRetainingCapacity instead?
        self.headers.clearAndFree();
        self.response_headers.clearAndFree();
        self.response_status = 0;

        self.response_type = .Empty;
        if (self.response_bytes) |v| alloc.free(v);

        self.state = OPENED;
        self.priv_state = .new;
        if (self.req) |*r| {
            r.deinit();
            self.req = null;
        }

        self.dispatchEvt("readystatechange");
    }

    // dispatch request event.
    // errors are logged only.
    fn dispatchEvt(self: *XMLHttpRequest, typ: []const u8) void {
        const evt = parser.eventCreate() catch |e| {
            return log.err("dispatch event create: {any}", .{e});
        };

        // We can we defer event destroy once the event is dispatched.
        defer parser.eventDestroy(evt);

        parser.eventInit(evt, typ, .{ .bubbles = true, .cancelable = true }) catch |e| {
            return log.err("dispatch event init: {any}", .{e});
        };
        _ = parser.eventTargetDispatchEvent(@as(*parser.EventTarget, @ptrCast(self)), evt) catch |e| {
            return log.err("dispatch event: {any}", .{e});
        };
    }

    fn dispatchProgressEvent(
        self: *XMLHttpRequest,
        typ: []const u8,
        opts: ProgressEvent.EventInit,
    ) void {
        var evt = ProgressEvent.constructor(typ, .{
            // https://xhr.spec.whatwg.org/#firing-events-using-the-progressevent-interface
            .lengthComputable = opts.total > 0,
            .total = opts.total,
            .loaded = opts.loaded,
        }) catch |e| {
            return log.err("construct progress event: {any}", .{e});
        };

        _ = parser.eventTargetDispatchEvent(
            @as(*parser.EventTarget, @ptrCast(self)),
            @as(*parser.Event, @ptrCast(&evt)),
        ) catch |e| {
            return log.err("dispatch progress event: {any}", .{e});
        };
    }

    const methods = [_]struct {
        tag: std.http.Method,
        name: []const u8,
    }{
        .{ .tag = .DELETE, .name = "DELETE" },
        .{ .tag = .GET, .name = "GET" },
        .{ .tag = .HEAD, .name = "HEAD" },
        .{ .tag = .OPTIONS, .name = "OPTIONS" },
        .{ .tag = .POST, .name = "POST" },
        .{ .tag = .PUT, .name = "PUT" },
    };
    const methods_forbidden = [_][]const u8{ "CONNECT", "TRACE", "TRACK" };

    pub fn validMethod(m: []const u8) DOMError!std.http.Method {
        for (methods) |method| {
            if (std.ascii.eqlIgnoreCase(method.name, m)) {
                return method.tag;
            }
        }
        // If method is a forbidden method, then throw a "SecurityError" DOMException.
        for (methods_forbidden) |method| {
            if (std.ascii.eqlIgnoreCase(method, m)) {
                return DOMError.Security;
            }
        }

        // If method is not a method, then throw a "SyntaxError" DOMException.
        return DOMError.Syntax;
    }

    pub fn _setRequestHeader(self: *XMLHttpRequest, name: []const u8, value: []const u8) !void {
        if (self.state != OPENED) return DOMError.InvalidState;
        if (self.send_flag) return DOMError.InvalidState;
        return try self.headers.append(name, value);
    }

    // TODO body can be either a string or a document
    pub fn _send(self: *XMLHttpRequest, body: ?[]const u8) !void {
        if (self.state != OPENED) return DOMError.InvalidState;
        if (self.send_flag) return DOMError.InvalidState;

        //  The body argument provides the request body, if any, and is ignored
        //  if the request method is GET or HEAD.
        //  https://xhr.spec.whatwg.org/#the-send()-method
        _ = body;
        // TODO set Content-Type header according to the given body.

        self.send_flag = true;
        self.impl.yield(self);
    }

    // onYield is a callback called between each request's steps.
    // Between each step, the code is blocking.
    // Yielding allows pseudo-async and gives a chance to other async process
    // to be called.
    pub fn onYield(self: *XMLHttpRequest, err: ?anyerror) void {
        if (err) |e| return self.onErr(e);

        switch (self.priv_state) {
            .new => {
                self.priv_state = .open;
                self.req = self.cli.open(self.method, self.uri, self.headers, .{}) catch |e| return self.onErr(e);
            },
            .open => {
                self.priv_state = .send;
                self.req.?.send(.{}) catch |e| return self.onErr(e);
            },
            .send => {
                self.priv_state = .finish;
                self.req.?.finish() catch |e| return self.onErr(e);
            },
            .finish => {
                self.priv_state = .wait;
                self.req.?.wait() catch |e| return self.onErr(e);
            },
            .wait => {
                self.priv_state = .done;
                self.response_headers = self.req.?.response.headers.clone(self.response_headers.allocator) catch |e| return self.onErr(e);

                self.state = HEADERS_RECEIVED;
                self.dispatchEvt("readystatechange");

                self.response_status = @intFromEnum(self.req.?.response.status);

                var buf: std.ArrayListUnmanaged(u8) = .{};

                // TODO set correct length
                const total = 0;
                var loaded: u64 = 0;

                // dispatch a progress event loadstart.
                self.dispatchProgressEvent("loadstart", .{ .loaded = loaded, .total = total });

                const reader = self.req.?.reader();
                var buffer: [1024]u8 = undefined;
                var ln = buffer.len;
                while (ln > 0) {
                    ln = reader.read(&buffer) catch |e| {
                        buf.deinit(self.alloc);
                        return self.onErr(e);
                    };
                    buf.appendSlice(self.alloc, buffer[0..ln]) catch |e| {
                        buf.deinit(self.alloc);
                        return self.onErr(e);
                    };
                    loaded = loaded + ln;

                    // TODO dispatch only if 50ms have passed.

                    self.state = LOADING;
                    self.dispatchEvt("readystatechange");

                    // dispatch a progress event progress.
                    self.dispatchProgressEvent("progress", .{
                        .loaded = loaded,
                        .total = total,
                    });
                }
                self.response_bytes = buf.items;
                self.send_flag = false;

                self.state = DONE;
                self.dispatchEvt("readystatechange");

                // dispatch a progress event load.
                self.dispatchProgressEvent("load", .{ .loaded = loaded, .total = total });
                // dispatch a progress event loadend.
                self.dispatchProgressEvent("loadend", .{ .loaded = loaded, .total = total });
            },
            .done => {
                if (self.req) |*r| {
                    r.deinit();
                    self.req = null;
                }

                // finalize fetch process.
                return;
            },
        }

        self.impl.yield(self);
    }

    fn onErr(self: *XMLHttpRequest, err: anyerror) void {
        self.priv_state = .done;
        if (self.req) |*r| {
            r.deinit();
            self.req = null;
        }

        self.err = err;
        self.state = DONE;
        self.send_flag = false;
        self.dispatchEvt("readystatechange");
        self.dispatchProgressEvent("error", .{});
        self.dispatchProgressEvent("loadend", .{});
    }

    pub fn get_responseType(self: *XMLHttpRequest) []const u8 {
        return switch (self.response_type) {
            .Empty => "",
            .ArrayBuffer => "arraybuffer",
            .Blob => "blob",
            .Document => "document",
            .JSON => "json",
            .Text => "text",
        };
    }

    pub fn set_responseType(self: *XMLHttpRequest, rtype: []const u8) !void {
        if (self.state == LOADING or self.state == DONE) return DOMError.InvalidState;

        if (std.mem.eql(u8, rtype, "")) {
            self.response_type = .Empty;
            return;
        }
        if (std.mem.eql(u8, rtype, "arraybuffer")) {
            self.response_type = .ArrayBuffer;
            return;
        }
        if (std.mem.eql(u8, rtype, "blob")) {
            self.response_type = .Blob;
            return;
        }
        if (std.mem.eql(u8, rtype, "document")) {
            self.response_type = .Document;
            return;
        }
        if (std.mem.eql(u8, rtype, "json")) {
            self.response_type = .JSON;
            return;
        }
        if (std.mem.eql(u8, rtype, "text")) {
            self.response_type = .Text;
            return;
        }
    }

    pub fn get_responseText(self: *XMLHttpRequest) ![]const u8 {
        if (self.response_type != .Empty and self.response_type != .Text) return DOMError.InvalidState;

        return if (self.response_bytes) |v| v else "";
    }

    pub fn _getResponseHeader(self: *XMLHttpRequest, name: []const u8) ?[]const u8 {
        return self.response_headers.getFirstValue(name);
    }

    // The caller owns the string returned.
    // TODO change the return type to express the string ownership and let
    // jsruntime free the string once copied to v8.
    // see https://github.com/lightpanda-io/jsruntime-lib/issues/195
    pub fn _getAllResponseHeaders(self: *XMLHttpRequest, alloc: std.mem.Allocator) ![]const u8 {
        if (self.response_headers.list.items.len == 0) return "";
        self.response_headers.sort();

        var buf: std.ArrayListUnmanaged(u8) = .{};
        errdefer buf.deinit(alloc);

        const w = buf.writer(alloc);

        for (self.response_headers.list.items) |entry| {
            if (entry.value.len == 0) continue;

            try w.writeAll(entry.name);
            try w.writeAll(": ");
            try w.writeAll(entry.value);
            try w.writeAll("\r\n");
        }

        return buf.items;
    }

    pub fn get_status(self: *XMLHttpRequest) u16 {
        return self.response_status;
    }

    pub fn get_statusText(self: *XMLHttpRequest) []const u8 {
        if (self.response_status == 0) return "";

        return std.http.Status.phrase(@enumFromInt(self.response_status)) orelse "";
    }
};

pub fn testExecFn(
    _: std.mem.Allocator,
    js_env: *jsruntime.Env,
) anyerror!void {
    var send = [_]Case{
        .{ .src = "var nb = 0; var evt = null; function cbk(event) { nb ++; evt = event; }", .ex = "undefined" },
        .{ .src = "const req = new XMLHttpRequest()", .ex = "undefined" },

        .{ .src = "req.onload = cbk", .ex = "function cbk(event) { nb ++; evt = event; }" },
        // Getter returning a callback crashes.
        // blocked by https://github.com/lightpanda-io/jsruntime-lib/issues/200
        // .{ .src = "req.onload", .ex = "function cbk(event) { nb ++; evt = event; }" },
        //.{ .src = "req.onload = cbk", .ex = "function cbk(event) { nb ++; evt = event; }" },

        .{ .src = "req.open('GET', 'https://w3.org')", .ex = "undefined" },
        .{ .src = "req.setRequestHeader('User-Agent', 'lightpanda/1.0')", .ex = "undefined" },

        // ensure open resets values
        .{ .src = "req.status", .ex = "0" },
        .{ .src = "req.statusText", .ex = "" },
        .{ .src = "req.getAllResponseHeaders()", .ex = "" },
        .{ .src = "req.getResponseHeader('Content-Type')", .ex = "null" },
        .{ .src = "req.responseText", .ex = "" },

        .{ .src = "req.send(); nb", .ex = "0" },

        // Each case executed waits for all loop callaback calls.
        // So the url has been retrieved.
        .{ .src = "nb", .ex = "1" },
        .{ .src = "evt.type", .ex = "load" },
        .{ .src = "evt.loaded > 0", .ex = "true" },
        .{ .src = "evt instanceof ProgressEvent", .ex = "true" },
        .{ .src = "req.status", .ex = "200" },
        .{ .src = "req.statusText", .ex = "OK" },
        .{ .src = "req.getResponseHeader('Content-Type')", .ex = "text/html; charset=UTF-8" },
        .{ .src = "req.getAllResponseHeaders().length > 1024", .ex = "true" },
        .{ .src = "req.responseText.length > 1024", .ex = "true" },
    };
    try checkCases(js_env, &send);
}
