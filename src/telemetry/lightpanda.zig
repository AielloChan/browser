const std = @import("std");
const builtin = @import("builtin");
const build_info = @import("build_info");

const Thread = std.Thread;
const Allocator = std.mem.Allocator;

const App = @import("../app.zig").App;
const telemetry = @import("telemetry.zig");

const log = std.log.scoped(.telemetry);
const URL = "https://telemetry.lightpanda.io";
const MAX_BATCH_SIZE = 20;

pub const LightPanda = struct {
    uri: std.Uri,
    pending: List,
    running: bool,
    thread: ?std.Thread,
    allocator: Allocator,
    mutex: std.Thread.Mutex,
    cond: Thread.Condition,
    client: *std.http.Client,
    node_pool: std.heap.MemoryPool(List.Node),

    const List = std.DoublyLinkedList(LightPandaEvent);

    pub fn init(app: *App) !LightPanda {
        const allocator = app.allocator;
        return .{
            .cond = .{},
            .mutex = .{},
            .pending = .{},
            .thread = null,
            .running = true,
            .allocator = allocator,
            .client = @ptrCast(&app.http_client),
            .uri = std.Uri.parse(URL) catch unreachable,
            .node_pool = std.heap.MemoryPool(List.Node).init(allocator),
        };
    }

    pub fn deinit(self: *LightPanda) void {
        if (self.thread) |*thread| {
            self.mutex.lock();
            self.running = false;
            self.mutex.unlock();
            self.cond.signal();
            thread.join();
        }
        self.node_pool.deinit();
    }

    pub fn send(self: *LightPanda, iid: ?[]const u8, run_mode: App.RunMode, raw_event: telemetry.Event) !void {
        const event = LightPandaEvent{
            .iid = iid,
            .mode = run_mode,
            .event = raw_event,
        };

        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.thread == null) {
            self.thread = try std.Thread.spawn(.{}, run, .{self});
        }

        const node = try self.node_pool.create();
        errdefer self.node_pool.destroy(node);
        node.data = event;
        self.pending.append(node);
        self.cond.signal();
    }

    fn run(self: *LightPanda) void {
        const client = self.client;
        var arr: std.ArrayListUnmanaged(u8) = .{};
        defer arr.deinit(self.allocator);

        var batch: [MAX_BATCH_SIZE]LightPandaEvent = undefined;
        self.mutex.lock();
        while (true) {
            while (self.pending.first != null) {
                const b = self.collectBatch(&batch);
                self.mutex.unlock();
                self.postEvent(b, client, &arr) catch |err| {
                    log.warn("Telementry reporting error: {}", .{err});
                };
                self.mutex.lock();
            }
            if (self.running == false) {
                return;
            }
            self.cond.wait(&self.mutex);
        }
    }

    fn postEvent(self: *const LightPanda, events: []LightPandaEvent, client: *std.http.Client, arr: *std.ArrayListUnmanaged(u8)) !void {
        defer arr.clearRetainingCapacity();
        var writer = arr.writer(self.allocator);
        for (events) |event| {
            try std.json.stringify(event, .{ .emit_null_optional_fields = false }, writer);
            try writer.writeByte('\n');
        }

        var response_header_buffer: [2048]u8 = undefined;
        const result = try client.fetch(.{
            .method = .POST,
            .payload = arr.items,
            .response_storage = .ignore,
            .location = .{ .uri = self.uri },
            .server_header_buffer = &response_header_buffer,
        });
        if (result.status != .ok) {
            log.warn("server error status: {}", .{result.status});
        }
    }

    fn collectBatch(self: *LightPanda, into: []LightPandaEvent) []LightPandaEvent {
        var i: usize = 0;
        const node_pool = &self.node_pool;
        while (self.pending.popFirst()) |node| {
            into[i] = node.data;
            node_pool.destroy(node);

            i += 1;
            if (i == MAX_BATCH_SIZE) {
                break;
            }
        }
        return into[0..i];
    }
};

const LightPandaEvent = struct {
    iid: ?[]const u8,
    mode: App.RunMode,
    event: telemetry.Event,

    pub fn jsonStringify(self: *const LightPandaEvent, writer: anytype) !void {
        try writer.beginObject();

        try writer.objectField("iid");
        try writer.write(self.iid);

        try writer.objectField("mode");
        try writer.write(self.mode);

        try writer.objectField("os");
        try writer.write(builtin.os.tag);

        try writer.objectField("arch");
        try writer.write(builtin.cpu.arch);

        try writer.objectField("version");
        try writer.write(build_info.git_commit);

        try writer.objectField("event");
        try writer.write(@tagName(std.meta.activeTag(self.event)));

        inline for (@typeInfo(telemetry.Event).@"union".fields) |union_field| {
            if (self.event == @field(telemetry.Event, union_field.name)) {
                const inner = @field(self.event, union_field.name);
                const TI = @typeInfo(@TypeOf(inner));
                if (TI == .@"struct") {
                    inline for (TI.@"struct".fields) |field| {
                        try writer.objectField(field.name);
                        try writer.write(@field(inner, field.name));
                    }
                }
            }
        }

        try writer.endObject();
    }
};
