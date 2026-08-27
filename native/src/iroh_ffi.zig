const std = @import("std");
const native_sdk = @import("native_sdk");
const ffi = @cImport({ @cInclude("irohnet.h"); });

const alpn = "nuphone-echo/1";
const channel_key = 1;
const max_message = 1024;
const max_payload = 8192;
const max_result = 8192;
const queue_size = 16;
const BindingPtr = @typeInfo(@TypeOf(@as(native_sdk.HostCallBinding, undefined).bind_channels_fn)).optional.child;
const BindFn = @typeInfo(BindingPtr).pointer.child;
const ChannelBinding = @typeInfo(BindFn).@"fn".params[1].type.?;
const Completion = struct {
    key: u64,
    ok: bool,
    bytes: [max_result]u8 = undefined,
    len: usize = 0,
};

const Job = struct {
    host: *Host,
    key: u64,
    bytes: [max_payload]u8 = undefined,
    len: usize = 0,
};

const ShutdownJob = struct {
    endpoint: ?*ffi.Endpoint_t,
    connection: ?*ffi.Connection_t,
};

const Host = struct {
    endpoint: ?*ffi.Endpoint_t = null,
    active_connection: ?*ffi.Connection_t = null,
    shutting_down: bool = false,
    endpoint_lock: std.atomic.Mutex = .unlocked,
    channel_binding: ?ChannelBinding = null,
    channel_lock: std.atomic.Mutex = .unlocked,
    services: ?*const native_sdk.platform.PlatformServices = null,
    services_lock: std.atomic.Mutex = .unlocked,
    queue: [queue_size]Completion = undefined,
    queue_head: usize = 0,
    queue_len: usize = 0,
    queue_lock: std.atomic.Mutex = .unlocked,
    poll_bytes: [max_result]u8 = undefined,

    fn binding(self: *Host) native_sdk.HostCallBinding {
        return .{ .context = self, .send_fn = send, .request_fn = request,
            .cancel_fn = cancel, .poll_fn = poll, .pending_fn = pending,
            .bind_services_fn = bindServices, .bind_channels_fn = bindChannels,
            .shutdown_fn = shutdown };
    }

    fn complete(self: *Host, key: u64, ok: bool, bytes: []const u8) void {
        while (true) {
            lock(&self.queue_lock);
            if (self.queue_len < queue_size) break;
            self.queue_lock.unlock();
            std.Thread.yield() catch {};
        }
        const item = &self.queue[(self.queue_head + self.queue_len) % queue_size];
        item.key = key;
        item.ok = ok;
        item.len = @min(bytes.len, max_result);
        @memcpy(item.bytes[0..item.len], bytes[0..item.len]);
        self.queue_len += 1;
        self.queue_lock.unlock();
        lock(&self.services_lock);
        const services = self.services;
        self.services_lock.unlock();
        if (services) |value| value.wake() catch {};
    }

    fn channel(self: *Host) ?native_sdk.ChannelHandle {
        lock(&self.channel_lock);
        const channels = self.channel_binding;
        self.channel_lock.unlock();
        return if (channels) |value| value.acquire_fn(value.context, channel_key) else null;
    }
};

var host: Host = .{};

pub fn binding() native_sdk.HostCallBinding { return host.binding(); }

fn lock(mutex: *std.atomic.Mutex) void {
    while (!mutex.tryLock()) std.atomic.spinLoopHint();
}

fn send(context: *anyopaque, name: []const u8, payload: []const u8) void {
    _ = context; _ = name; _ = payload;
}

fn request(context: *anyopaque, name: []const u8, key: u64, payload: []const u8) void {
    const self: *Host = @ptrCast(@alignCast(context));
    if (!std.mem.eql(u8, name, "iroh.receiver.bind") and !std.mem.eql(u8, name, "iroh.sender.send")) {
        self.complete(key, false, "unknown_command"); return;
    }
    if (payload.len > max_payload) { self.complete(key, false, "payload_too_large"); return; }
    const job = std.heap.page_allocator.create(Job) catch {
        self.complete(key, false, "out_of_memory"); return;
    };
    job.* = .{ .host = self, .key = key, .len = payload.len };
    @memcpy(job.bytes[0..payload.len], payload);
    if (std.mem.eql(u8, name, "iroh.receiver.bind")) {
        var thread = std.Thread.spawn(.{}, bindWorker, .{job}) catch {
            std.heap.page_allocator.destroy(job); self.complete(key, false, "thread_failed"); return;
        };
        thread.detach();
    } else {
        var thread = std.Thread.spawn(.{}, sendWorker, .{job}) catch {
            std.heap.page_allocator.destroy(job); self.complete(key, false, "thread_failed"); return;
        };
        thread.detach();
    }
}

fn cancel(context: *anyopaque, key: u64) void { _ = context; _ = key; }

fn bindServices(context: *anyopaque, services: *const native_sdk.platform.PlatformServices) void {
    const self: *Host = @ptrCast(@alignCast(context));
    lock(&self.services_lock); self.services = services; self.services_lock.unlock();
}

fn bindChannels(context: *anyopaque, channels: ChannelBinding) void {
    const self: *Host = @ptrCast(@alignCast(context));
    lock(&self.channel_lock); self.channel_binding = channels; self.channel_lock.unlock();
}

fn pending(context: *anyopaque) bool {
    const self: *Host = @ptrCast(@alignCast(context));
    lock(&self.queue_lock); const result = self.queue_len != 0; self.queue_lock.unlock(); return result;
}

fn poll(context: *anyopaque) ?native_sdk.HostCallCompletion {
    const self: *Host = @ptrCast(@alignCast(context));
    lock(&self.queue_lock); defer self.queue_lock.unlock();
    if (self.queue_len == 0) return null;
    const item = &self.queue[self.queue_head];
    @memcpy(self.poll_bytes[0..item.len], item.bytes[0..item.len]);
    const result = native_sdk.HostCallCompletion{ .key = item.key, .ok = item.ok, .bytes = self.poll_bytes[0..item.len] };
    self.queue_head = (self.queue_head + 1) % queue_size; self.queue_len -= 1; return result;
}

fn bindWorker(job: *Job) void {
    defer std.heap.page_allocator.destroy(job);
    const self = job.host;
    lock(&self.endpoint_lock); defer self.endpoint_lock.unlock();
    if (self.endpoint) |endpoint| return finishBind(self, job.key, endpoint);
    var config = ffi.endpoint_config_default();
    defer ffi.endpoint_config_free(config);
    ffi.endpoint_config_add_alpn(&config, alpnSlice());
    var endpoint: ?*ffi.Endpoint_t = ffi.endpoint_default();
    if (endpoint == null or ffi.endpoint_bind(&config, null, null, &endpoint) != 0) {
        ffi.endpoint_free(endpoint); self.complete(job.key, false, "bind_failed"); return;
    }
    self.endpoint = endpoint;
    const thread = std.Thread.spawn(.{}, acceptLoop, .{self}) catch {
        ffi.endpoint_close(endpoint); self.endpoint = null; self.complete(job.key, false, "thread_failed"); return;
    };
    thread.detach();
    finishBind(self, job.key, endpoint.?);
}

fn finishBind(self: *Host, key: u64, endpoint: *ffi.Endpoint_t) void {
    var response: [max_result]u8 = undefined;
    const len = endpointInfo(endpoint, &response) catch { self.complete(key, false, "address_failed"); return; };
    self.complete(key, true, response[0..len]);
}

fn endpointInfo(endpoint: *ffi.Endpoint_t, output: []u8) !usize {
    var address = ffi.endpoint_addr_default(); defer ffi.endpoint_addr_free(address);
    if (ffi.endpoint_addr(&endpoint, &address) != 0) return error.Address;
    const address_text = ffi.endpoint_addr_as_str(&address) orelse return error.Address;
    defer ffi.rust_free_string(address_text);
    const key_text = ffi.public_key_as_base32(&address.id) orelse return error.Address;
    defer ffi.rust_free_string(key_text);
    const a = std.mem.span(address_text); const k = std.mem.span(key_text);
    if (a.len + 1 + k.len > output.len) return error.TooLong;
    @memcpy(output[0..a.len], a); output[a.len] = 10; @memcpy(output[a.len + 1 ..][0..k.len], k);
    return a.len + 1 + k.len;
}

fn sendWorker(job: *Job) void {
    defer std.heap.page_allocator.destroy(job);
    const self = job.host;
    var split: usize = 0; while (split < job.len and job.bytes[split] != 10) split += 1;
    if (split == 0 or split == job.len) { self.complete(job.key, false, "invalid_payload"); return; }
    const address_text = job.bytes[0..split]; const message = job.bytes[split + 1 .. job.len];
    if (message.len > max_message) { self.complete(job.key, false, "message_too_large"); return; }
    lock(&self.endpoint_lock); const receiver_endpoint = self.endpoint; self.endpoint_lock.unlock();
    if (receiver_endpoint == null) { self.complete(job.key, false, "receiver_unavailable"); return; }

    // An endpoint cannot dial its own endpoint ID. Use a second endpoint in
    // this process for the sender while keeping the receiver shared in the UI.
    var config = ffi.endpoint_config_default();
    defer ffi.endpoint_config_free(config);
    ffi.endpoint_config_add_alpn(&config, alpnSlice());
    var sender_endpoint: ?*ffi.Endpoint_t = ffi.endpoint_default();
    if (sender_endpoint == null or ffi.endpoint_bind(&config, null, null, &sender_endpoint) != 0) {
        ffi.endpoint_free(sender_endpoint); self.complete(job.key, false, "sender_bind_failed"); return;
    }
    // endpoint_close waits for all connections; endpoint_free drops this
    // short-lived sender endpoint without blocking the request worker.
    defer ffi.endpoint_free(sender_endpoint.?);
    const local_endpoint = sender_endpoint.?;
    // endpoint_connect takes ownership of the parsed address on every return path.
    var address = ffi.endpoint_addr_default();
    var address_buffer: [4096]u8 = undefined;
    if (address_text.len >= address_buffer.len) { ffi.endpoint_addr_free(address); self.complete(job.key, false, "address_too_large"); return; }
    @memcpy(address_buffer[0..address_text.len], address_text); address_buffer[address_text.len] = 0;
    if (ffi.endpoint_addr_from_string(&address_buffer, &address) != 0) { ffi.endpoint_addr_free(address); self.complete(job.key, false, "invalid_address"); return; }
    var connection: ?*ffi.Connection_t = ffi.connection_default();
    if (connection == null or ffi.endpoint_connect(&local_endpoint, alpnSlice(), address, &connection) != 0) { ffi.connection_free(connection); self.complete(job.key, false, "connect_failed"); return; }
    var tx: ?*ffi.SendStream_t = ffi.send_stream_default(); var rx: ?*ffi.RecvStream_t = ffi.recv_stream_default();
    if (tx == null or rx == null or ffi.connection_open_bi(&connection, &tx, &rx) != 0) { ffi.connection_close(connection); ffi.send_stream_free(tx); ffi.recv_stream_free(rx); self.complete(job.key, false, "stream_failed"); return; }
    if (ffi.send_stream_write_timeout(&tx, .{ .ptr = message.ptr, .len = message.len }, 30_000) != 0) { ffi.send_stream_free(tx); ffi.recv_stream_free(rx); ffi.connection_close(connection); self.complete(job.key, false, "write_failed"); return; }
    if (ffi.send_stream_finish(tx) != 0) { ffi.recv_stream_free(rx); ffi.connection_close(connection); self.complete(job.key, false, "write_failed"); return; }
    var echoed = ffi.rust_buffer_alloc(0); defer ffi.rust_buffer_free(echoed);
    const read_result = ffi.recv_stream_read_to_end_timeout(&rx, &echoed, max_message, 30_000);
    if (read_result != 0) { ffi.recv_stream_free(rx); ffi.connection_close(connection); self.complete(job.key, false, if (read_result == ffi.ENDPOINT_RESULT_TIMEOUT) "read_timeout" else "read_failed"); return; }
    ffi.recv_stream_free(rx); ffi.connection_close(connection); self.complete(job.key, true, echoed.ptr[0..echoed.len]);
}

fn acceptLoop(self: *Host) void {
    while (true) {
        lock(&self.endpoint_lock); const endpoint = self.endpoint; self.endpoint_lock.unlock();
        const ep = endpoint orelse return;
        var connection: ?*ffi.Connection_t = ffi.connection_default();
        if (connection == null or ffi.endpoint_accept(&ep, alpnSlice(), &connection) != 0) { ffi.connection_free(connection); return; }
        lock(&self.endpoint_lock);
        const stopping = self.shutting_down;
        if (!stopping) self.active_connection = connection;
        self.endpoint_lock.unlock();
        if (stopping) { ffi.connection_close(connection); return; }
        var tx: ?*ffi.SendStream_t = ffi.send_stream_default(); var rx: ?*ffi.RecvStream_t = ffi.recv_stream_default();
        if (tx == null or rx == null or ffi.connection_accept_bi(&connection, &tx, &rx) != 0) {
            lock(&self.endpoint_lock);
            const owns_connection = self.active_connection == connection;
            if (owns_connection) self.active_connection = null;
            self.endpoint_lock.unlock();
            if (owns_connection) ffi.connection_close(connection);
            ffi.send_stream_free(tx); ffi.recv_stream_free(rx); continue;
        }
        var received = ffi.rust_buffer_alloc(0);
        if (ffi.recv_stream_read_to_end_timeout(&rx, &received, max_message, 30_000) == 0) {
            if (ffi.send_stream_write(&tx, .{ .ptr = received.ptr, .len = received.len }) == 0) {
                _ = ffi.send_stream_finish(tx);
            } else {
                ffi.send_stream_free(tx);
            }
            if (self.channel()) |handle| _ = handle.post(received.ptr[0..received.len]);
        } else {
            ffi.send_stream_free(tx);
        }
        ffi.rust_buffer_free(received); ffi.recv_stream_free(rx);
        lock(&self.endpoint_lock);
        const owns_connection = self.active_connection == connection;
        if (owns_connection) self.active_connection = null;
        self.endpoint_lock.unlock();
        if (owns_connection) ffi.connection_close(connection);
    }
}

fn alpnSlice() ffi.slice_ref_uint8_t { return .{ .ptr = alpn.ptr, .len = alpn.len }; }

fn shutdownWorker(job: *ShutdownJob) void {
    defer std.heap.page_allocator.destroy(job);
    if (job.connection) |value| ffi.connection_close(value);
    if (job.endpoint) |value| ffi.endpoint_close(value);
}

fn shutdown(context: *anyopaque) void {
    const self: *Host = @ptrCast(@alignCast(context));
    lock(&self.endpoint_lock);
    self.shutting_down = true;
    const endpoint = self.endpoint;
    self.endpoint = null;
    const connection = self.active_connection;
    self.active_connection = null;
    self.endpoint_lock.unlock();
    const cleanup = std.heap.page_allocator.create(ShutdownJob) catch {
        if (connection) |value| ffi.connection_close(value);
        if (endpoint) |value| ffi.endpoint_close(value);
        return;
    };
    cleanup.* = .{ .endpoint = endpoint, .connection = connection };
    const thread = std.Thread.spawn(.{}, shutdownWorker, .{cleanup}) catch {
        std.heap.page_allocator.destroy(cleanup);
        if (connection) |value| ffi.connection_close(value);
        if (endpoint) |value| ffi.endpoint_close(value);
        return;
    };
    thread.detach();
    lock(&self.services_lock); self.services = null; self.services_lock.unlock();
    lock(&self.channel_lock); self.channel_binding = null; self.channel_lock.unlock();
}
