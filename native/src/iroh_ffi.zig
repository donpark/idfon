const std = @import("std");
const c = @cImport({
    @cInclude("stdio.h");
    @cInclude("unistd.h");
});
const native_sdk = @import("native_sdk");
const ffi = @cImport({ @cInclude("irohnet.h"); });

const alpn = "nufon-echo/1";
const channel_key = 1;
const max_message = 8192;
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
    command: [64]u8 = undefined,
    command_len: usize = 0,
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
    active_send_stream: ?*ffi.SendStream_t = null,
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
        trace("completion queued key={d} ok={} bytes={d}", .{ key, ok, bytes.len });
        if (services) |value| value.wake() catch {};
    }

    fn channel(self: *Host) ?native_sdk.ChannelHandle {
        lock(&self.channel_lock);
        const channels = self.channel_binding;
        self.channel_lock.unlock();
        return if (channels) |value| value.acquire_fn(value.context, channel_key) else null;
    }

    fn postReceiverEvent(self: *Host, bytes: []const u8) void {
        while (true) {
            if (self.channel()) |handle| {
                const result = handle.post(bytes);
                trace("receiver event post {t} ({d} bytes)", .{ result, bytes.len });
                return;
            }
            lock(&self.endpoint_lock);
            const stopping = self.shutting_down;
            self.endpoint_lock.unlock();
            if (stopping) return;
            std.Thread.yield() catch {};
        }
    }
};

var host: Host = .{};
var trace_lock: std.atomic.Mutex = .unlocked;

fn trace(comptime format: []const u8, args: anytype) void {
    var line: [512]u8 = undefined;
    var path: [64]u8 = undefined;
    const text = std.fmt.bufPrint(&line, format, args) catch return;
    const log_path = std.fmt.bufPrintZ(&path, "/tmp/nufon-{d}.log", .{c.getpid()}) catch return;
    lock(&trace_lock);
    defer trace_lock.unlock();
    var mode: [2:0]u8 = .{ 'a', 0 };
    const file = c.fopen(log_path.ptr, &mode) orelse return;
    defer _ = c.fclose(file);
    _ = c.fwrite(text.ptr, 1, text.len, file);
    _ = c.fwrite("\n", 1, 1, file);
    _ = c.fflush(file);
}

pub fn binding() native_sdk.HostCallBinding {
    ffi.iroh_enable_tracing();
    trace("Rust tracing initialized", .{});
    return host.binding();
}

fn lock(mutex: *std.atomic.Mutex) void {
    while (!mutex.tryLock()) std.atomic.spinLoopHint();
}

fn send(context: *anyopaque, name: []const u8, payload: []const u8) void {
    _ = context; _ = name; _ = payload;
}

fn request(context: *anyopaque, name: []const u8, key: u64, payload: []const u8) void {
    const self: *Host = @ptrCast(@alignCast(context));
    trace("host request {s} key={d} payload={d}", .{ name, key, payload.len });
    const is_media_audio = std.mem.eql(u8, name, "media.audio.switch_input") or
        std.mem.eql(u8, name, "media.audio.switch_output") or
        std.mem.eql(u8, name, "media.recording.play") or
        std.mem.eql(u8, name, "media.recording.stop_playback") or
        std.mem.eql(u8, name, "media.recording.start") or
        std.mem.eql(u8, name, "media.recording.stop") or
        std.mem.eql(u8, name, "media.audio.start") or
        std.mem.eql(u8, name, "media.audio.stop") or
        std.mem.eql(u8, name, "media.emergency_stop") or
        std.mem.eql(u8, name, "media.audio.output_count") or
        std.mem.eql(u8, name, "media.audio.set_volume") or
        std.mem.eql(u8, name, "media.audio.input_count") or
        std.mem.eql(u8, name, "media.audio.probe") or
        std.mem.eql(u8, name, "media.live.start") or
        std.mem.eql(u8, name, "media.live.stop") or
        std.mem.eql(u8, name, "media.live.subscribe") or
        std.mem.eql(u8, name, "media.live.unsubscribe") or
        std.mem.eql(u8, name, "media.live.recording.store") or
        std.mem.eql(u8, name, "media.blob.fetch");
    if (!std.mem.eql(u8, name, "iroh.receiver.bind") and !std.mem.eql(u8, name, "iroh.receiver.reply") and
        !std.mem.eql(u8, name, "iroh.sender.send") and !is_media_audio and
        !std.mem.eql(u8, name, "media.set_scope") and
        !std.mem.eql(u8, name, "media.recording.persist")) {
        self.complete(key, false, "unknown_command"); return;
    }
    if (payload.len > max_payload) { self.complete(key, false, "payload_too_large"); return; }
    const job = std.heap.page_allocator.create(Job) catch {
        self.complete(key, false, "out_of_memory"); return;
    };
    if (name.len > job.command.len) {
        std.heap.page_allocator.destroy(job); self.complete(key, false, "command_too_large"); return;
    }
    job.* = .{ .host = self, .key = key, .command_len = name.len, .len = payload.len };
    @memcpy(job.command[0..name.len], name);
    @memcpy(job.bytes[0..payload.len], payload);
    if (std.mem.eql(u8, name, "iroh.receiver.bind")) {
        var thread = std.Thread.spawn(.{}, bindWorker, .{job}) catch {
            std.heap.page_allocator.destroy(job); self.complete(key, false, "thread_failed"); return;
        };
        thread.detach();
    } else if (std.mem.eql(u8, name, "iroh.receiver.reply")) {
        var thread = std.Thread.spawn(.{}, replyWorker, .{job}) catch {
            std.heap.page_allocator.destroy(job); self.complete(key, false, "thread_failed"); return;
        };
        thread.detach();
    } else if (is_media_audio or std.mem.eql(u8, name, "media.set_scope") or std.mem.eql(u8, name, "media.recording.persist")) {
        var thread = std.Thread.spawn(.{}, mediaAudioWorker, .{job}) catch {
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
    trace("UI channel binding installed key={d}", .{channel_key});
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
    trace("host poll completion key={d} ok={} bytes={d}", .{ item.key, item.ok, item.len });
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
    trace("endpoint bound", .{});
    const thread = std.Thread.spawn(.{}, acceptLoop, .{self}) catch {
        ffi.endpoint_close(endpoint); self.endpoint = null; self.complete(job.key, false, "thread_failed"); return;
    };
    thread.detach();
    finishBind(self, job.key, endpoint.?);
}

fn finishBind(self: *Host, key: u64, endpoint: *ffi.Endpoint_t) void {
    trace("preparing receiver_ready key={d}", .{key});
    var response: [max_result]u8 = undefined;
    const len = endpointInfo(endpoint, &response) catch { self.complete(key, false, "address_failed"); return; };
    var split: usize = 0;
    while (split < len and response[split] != 10) split += 1;
    if (split < len) trace("receiver endpoint id={s}", .{response[split + 1 .. len]});
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

fn replyWorker(job: *Job) void {
    defer std.heap.page_allocator.destroy(job);
    const self = job.host;
    var split: usize = 0; while (split < job.len and job.bytes[split] != 10) split += 1;
    if (split == 0 or split == job.len) { self.complete(job.key, false, "invalid_payload"); return; }
    const route = job.bytes[0..split];
    const message = job.bytes[split + 1 .. job.len];
    if (message.len > max_message) { self.complete(job.key, false, "message_too_large"); return; }

    lock(&self.endpoint_lock);
    const connection = self.active_connection;
    const stream = self.active_send_stream;
    self.active_connection = null;
    self.active_send_stream = null;
    self.endpoint_lock.unlock();
    if (!std.mem.eql(u8, route, "1") or stream == null) {
        self.complete(job.key, false, "reply_unavailable"); return;
    }
    var tx = stream;
    if (ffi.send_stream_write_timeout(&tx, .{ .ptr = message.ptr, .len = message.len }, 30_000) != 0) {
        ffi.send_stream_free(tx);
        if (connection) |value| ffi.connection_close(value);
        self.complete(job.key, false, "reply_failed"); return;
    }
    // send_stream_finish consumes tx; do not free it afterwards.
    if (ffi.send_stream_finish(tx) != 0) {
        if (connection) |value| ffi.connection_close(value);
        self.complete(job.key, false, "reply_failed"); return;
    }
    // Leave the connection open long enough for the peer to read the
    // finished reply stream; the sender closes it after receiving the reply.
    self.complete(job.key, true, "replied");
    var thread = std.Thread.spawn(.{}, acceptLoop, .{self}) catch return;
    thread.detach();
}

fn mediaAudioWorker(job: *Job) void {
    defer std.heap.page_allocator.destroy(job);
    const self = job.host;
    const name = job.command[0..job.command_len];
    if (std.mem.eql(u8, name, "media.set_scope")) {
        var scope: [max_payload + 1]u8 = undefined;
        @memcpy(scope[0..job.len], job.bytes[0..job.len]); scope[job.len] = 0;
        if (ffi.media_set_scope(&scope) == 0) self.complete(job.key, true, "media_scope_set")
        else self.complete(job.key, false, "media_scope_failed");
    } else if (std.mem.eql(u8, name, "media.recording.persist")) {
        var ticket: [max_payload + 1]u8 = undefined;
        @memcpy(ticket[0..job.len], job.bytes[0..job.len]); ticket[job.len] = 0;
        if (ffi.media_recording_persist(&ticket) == 0) self.complete(job.key, true, "recording_persisted")
        else self.complete(job.key, false, "recording_persist_failed");
    } else if (std.mem.eql(u8, name, "media.audio.switch_input")) {
        var device: [max_payload + 1]u8 = undefined;
        @memcpy(device[0..job.len], job.bytes[0..job.len]); device[job.len] = 0;
        if (ffi.media_audio_switch_input(&device) == 0) self.complete(job.key, true, "input_device_set")
        else self.complete(job.key, false, "input_device_failed");
    } else if (std.mem.eql(u8, name, "media.audio.switch_output")) {
        var device: [max_payload + 1]u8 = undefined;
        @memcpy(device[0..job.len], job.bytes[0..job.len]); device[job.len] = 0;
        if (ffi.media_audio_switch_output(&device) == 0) self.complete(job.key, true, "output_device_set")
        else self.complete(job.key, false, "output_device_failed");
    } else if (std.mem.eql(u8, name, "media.recording.play")) {
        if (ffi.media_recording_play() == 0) self.complete(job.key, true, "recording_playing")
        else self.complete(job.key, false, "recording_play_failed");
    } else if (std.mem.eql(u8, name, "media.recording.stop_playback")) {
        ffi.media_recording_stop_playback();
        self.complete(job.key, true, "recording_playback_stopped");
    } else if (std.mem.eql(u8, name, "media.recording.start")) {
        if (ffi.media_recording_start() == 0) self.complete(job.key, true, "recording_started")
        else self.complete(job.key, false, "recording_start_failed");
    } else if (std.mem.eql(u8, name, "media.recording.stop")) {
        if (ffi.media_recording_stop() == 0) self.complete(job.key, true, "recording_stopped")
        else self.complete(job.key, false, "recording_stop_failed");
    } else if (std.mem.eql(u8, name, "media.audio.output_count")) {
        var result: [32]u8 = undefined;
        const text = std.fmt.bufPrint(&result, "{d}", .{ffi.media_audio_output_count()}) catch {
            self.complete(job.key, false, "audio_output_count_failed"); return;
        };
        self.complete(job.key, true, text);
    } else if (std.mem.eql(u8, name, "media.audio.set_volume")) {
        const percent = if (job.len != 0) std.fmt.parseInt(u8, job.bytes[0..job.len], 10) catch null else null;
        if (percent) |value| {
            if (ffi.media_audio_set_volume(value) == 0) self.complete(job.key, true, "volume_set")
            else self.complete(job.key, false, "volume_set_failed");
        } else self.complete(job.key, false, "invalid_volume");
    } else if (std.mem.eql(u8, name, "media.audio.start")) {
        if (ffi.media_audio_start() == 0) self.complete(job.key, true, "audio_started")
        else self.complete(job.key, false, "audio_start_failed");
    } else if (std.mem.eql(u8, name, "media.audio.probe")) {
        const samples = ffi.media_audio_probe(1000);
        var result: [32]u8 = undefined;
        const text = std.fmt.bufPrint(&result, "{d}", .{samples}) catch {
            self.complete(job.key, false, "audio_probe_failed"); return;
        };
        self.complete(job.key, true, text);
    } else if (std.mem.eql(u8, name, "media.live.start")) {
        const ticket = ffi.media_live_start();
        defer ffi.rust_free_string(ticket);
        const text = std.mem.span(ticket);
        if (text.len == 0) self.complete(job.key, false, "live_start_failed")
        else self.complete(job.key, true, text);
    } else if (std.mem.eql(u8, name, "media.live.stop")) {
        ffi.media_live_stop();
        self.complete(job.key, true, "live_stopped");
    } else if (std.mem.eql(u8, name, "media.live.subscribe")) {
        var ticket: [max_payload + 1]u8 = undefined;
        @memcpy(ticket[0..job.len], job.bytes[0..job.len]);
        ticket[job.len] = 0;
        if (ffi.media_live_subscribe(&ticket) == 0) self.complete(job.key, true, "live_subscribed")
        else self.complete(job.key, false, "live_subscribe_failed");
    } else if (std.mem.eql(u8, name, "media.live.unsubscribe")) {
        ffi.media_live_unsubscribe();
        self.complete(job.key, true, "live_unsubscribed");
    } else if (std.mem.eql(u8, name, "media.live.recording.store")) {
        const ticket = ffi.media_live_recording_store();
        defer ffi.rust_free_string(ticket);
        const text = std.mem.span(ticket);
        if (text.len == 0) self.complete(job.key, false, "recording_store_failed")
        else self.complete(job.key, true, text);
    } else if (std.mem.eql(u8, name, "media.blob.fetch")) {
        var ticket: [max_payload + 1]u8 = undefined;
        @memcpy(ticket[0..job.len], job.bytes[0..job.len]);
        ticket[job.len] = 0;
        if (ffi.media_blob_fetch(&ticket) == 0) self.complete(job.key, true, "recording_fetched")
        else self.complete(job.key, false, "recording_fetch_failed");
    } else if (std.mem.eql(u8, name, "media.emergency_stop")) {
        ffi.media_emergency_stop();
        self.complete(job.key, true, "media_stopped");
    } else if (std.mem.eql(u8, name, "media.audio.stop")) {
        ffi.media_audio_stop();
        self.complete(job.key, true, "audio_stopped");
    } else {
        var result: [32]u8 = undefined;
        const text = std.fmt.bufPrint(&result, "{d}", .{ffi.media_audio_input_count()}) catch {
            self.complete(job.key, false, "audio_count_failed"); return;
        };
        self.complete(job.key, true, text);
    }
}

fn sendWorker(job: *Job) void {
    defer std.heap.page_allocator.destroy(job);
    const self = job.host;
    var split: usize = 0; while (split < job.len and job.bytes[split] != 10) split += 1;
    if (split == 0 or split == job.len) { self.complete(job.key, false, "invalid_payload"); return; }
    const address_text = job.bytes[0..split]; const message = job.bytes[split + 1 .. job.len];
    if (message.len > max_message) { self.complete(job.key, false, "message_too_large"); return; }
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
    const target_id = ffi.public_key_as_base32(&address.id) orelse { ffi.endpoint_addr_free(address); self.complete(job.key, false, "invalid_address"); return; };
    defer ffi.rust_free_string(target_id);
    trace("sender target endpoint id={s}", .{std.mem.span(target_id)});
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
    trace("accept loop started", .{});
    while (true) {
        lock(&self.endpoint_lock); const endpoint = self.endpoint; self.endpoint_lock.unlock();
        const ep = endpoint orelse return;
        var connection: ?*ffi.Connection_t = ffi.connection_default();
        if (connection == null or ffi.endpoint_accept(&ep, alpnSlice(), &connection) != 0) {
            trace("endpoint_accept failed", .{});
            ffi.connection_free(connection); return;
        }
        trace("inbound connection accepted", .{});
        lock(&self.endpoint_lock);
        const stopping = self.shutting_down;
        if (!stopping) self.active_connection = connection;
        self.endpoint_lock.unlock();
        if (stopping) { ffi.connection_close(connection); return; }
        var tx: ?*ffi.SendStream_t = ffi.send_stream_default(); var rx: ?*ffi.RecvStream_t = ffi.recv_stream_default();
        if (tx == null or rx == null or ffi.connection_accept_bi(&connection, &tx, &rx) != 0) {
            trace("connection_accept_bi failed", .{});
            lock(&self.endpoint_lock);
            const owns_connection = self.active_connection == connection;
            if (owns_connection) self.active_connection = null;
            self.endpoint_lock.unlock();
            if (owns_connection) ffi.connection_close(connection);
            ffi.send_stream_free(tx); ffi.recv_stream_free(rx); continue;
        }
        var received = ffi.rust_buffer_alloc(0);
        const read_result = ffi.recv_stream_read_to_end_timeout(&rx, &received, max_message, 30_000);
        trace("receive stream result={d} bytes={d}", .{ read_result, received.len });
        if (read_result == 0) {
            trace("received message ({d} bytes)", .{received.len});
            lock(&self.endpoint_lock);
            self.active_send_stream = tx;
            self.endpoint_lock.unlock();
            // Route 1 is local-only; the UI uses it to reply on this live connection.
            // ponytail: one live inbound route; map connection IDs when concurrent replies matter.
            var routed: [max_result]u8 = undefined;
            const prefix = "1\n";
            if (prefix.len + received.len <= routed.len) {
                @memcpy(routed[0..prefix.len], prefix);
                @memcpy(routed[prefix.len..][0..received.len], received.ptr[0..received.len]);
                self.postReceiverEvent(routed[0 .. prefix.len + received.len]);
            }
            ffi.recv_stream_free(rx);
            ffi.rust_buffer_free(received);
            return;
        }
        ffi.send_stream_free(tx);
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
    trace("host shutdown", .{});
    ffi.media_shutdown();
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
