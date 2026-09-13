const std = @import("std");
const c = @cImport({
    @cInclude("stdio.h");
    @cInclude("unistd.h");
    @cInclude("sys/socket.h");
    @cInclude("sys/un.h");
    @cInclude("signal.h");
    @cInclude("sys/wait.h");
    @cInclude("fcntl.h");
    @cInclude("stdlib.h");
    @cInclude("crt_externs.h");
});
extern fn _NSGetExecutablePath(buf: [*:0]u8, bufsize: *u32) c_int;

const native_sdk = @import("native_sdk");
const ffi = @cImport({
    @cInclude("irohnet.h");
    @cInclude("idfon_client.h");
});

const max_message = 8192;
const max_payload = 8192;
// ponytail: matches the runtime's max_effect_host_result_bytes (256 KiB);
// the daemon frame limit is 1 MiB, but the runtime rejects anything larger.
const max_result = 256 * 1024;
const queue_size = 16;
const default_socket = "/tmp/idfon/idfond.sock";
const default_data_dir = "/tmp/idfon";
const ProfilePaths = struct {
    socket: [128]u8 = undefined,
    socket_len: usize = 0,
    data: [128]u8 = undefined,
    data_len: usize = 0,
};
const Completion = struct {
    key: u64,
    ok: bool,
    // Heap-owned copy. Valid until the consumer's next poll() call: the
    // runtime copies handed-out bytes synchronously (feedHostResult memcpys
    // before draining the next completion), so we free the previous handout
    // on the following poll.
    bytes: []const u8 = "",
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

const Host = struct {
    services: ?*const native_sdk.platform.PlatformServices = null,
    services_lock: std.atomic.Mutex = .unlocked,
    queue: [queue_size]Completion = undefined,
    queue_head: usize = 0,
    queue_len: usize = 0,
    queue_lock: std.atomic.Mutex = .unlocked,
    daemon_lock: std.atomic.Mutex = .unlocked,
    daemon_pid: c.pid_t = -1,
    handed_out: ?[]const u8 = null,

    fn binding(self: *Host) native_sdk.HostCallBinding {
        return .{ .context = self, .send_fn = send, .request_fn = request,
            .cancel_fn = cancel, .poll_fn = poll, .pending_fn = pending,
            .bind_services_fn = bindServices, .shutdown_fn = shutdown };
    }

    /// Fetched live-publisher failure text for job completions.
    fn last_live_error(self: *Host) []const u8 {
        _ = self;
        const err = ffi.media_live_last_error();
        defer ffi.rust_free_string(err);
        const text = std.mem.span(err);
        // Copy before the defer frees: complete() runs after we return, and
        // reading the freed buffer was rendering heap garbage in the banner.
        if (text.len == 0 or text.len >= live_error_buf.len) return "live_start_failed";
        @memcpy(live_error_buf[0..text.len], text);
        return live_error_buf[0..text.len];
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
        item.bytes = std.heap.page_allocator.dupe(u8, bytes) catch "";
        if (item.bytes.len == 0 and bytes.len != 0) {
            // Out of memory: release the reserved slot with a failure
            // completion instead of silently truncating the payload.
            item.ok = false;
            item.bytes = "out_of_memory";
        }
        item.len = item.bytes.len;
        self.queue_len += 1;
        self.queue_lock.unlock();
        lock(&self.services_lock);
        const services = self.services;
        self.services_lock.unlock();
        trace("completion queued key={d} ok={} bytes={d}", .{ key, ok, bytes.len });
        if (services) |value| value.wake() catch {};
    }

};

var host: Host = .{};

/// Scratch for last_live_error(): the Rust string is freed before the caller's
/// complete() copies it, so it must be copied out here first. Single GUI error
/// string at a time — a static buffer is enough.
var live_error_buf: [512]u8 = undefined;

var trace_lock: std.atomic.Mutex = .unlocked;

fn trace(comptime format: []const u8, args: anytype) void {
    var line: [512]u8 = undefined;
    var path: [64]u8 = undefined;
    const text = std.fmt.bufPrint(&line, format, args) catch return;
    const log_path = std.fmt.bufPrintZ(&path, "/tmp/idfon-{d}.log", .{c.getpid()}) catch return;
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
    if (std.mem.eql(u8, name, "idfond.request")) {
        const head = payload[0..@min(payload.len, 180)];
        const tail_start = if (payload.len > 280) payload.len - 280 else 0;
        trace("idfond request key={d} head={s}", .{ key, head });
        trace("idfond request key={d} tail={s}", .{ key, payload[tail_start..] });
    }
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
        std.mem.eql(u8, name, "media.audio.set_bitrate") or
        std.mem.eql(u8, name, "media.audio.input_count") or
        std.mem.eql(u8, name, "media.audio.probe") or
        std.mem.eql(u8, name, "media.live.start") or
        std.mem.eql(u8, name, "media.live.video_start") or
        std.mem.eql(u8, name, "media.live.stop") or
        std.mem.eql(u8, name, "media.live.subscribe") or
        std.mem.eql(u8, name, "media.live.unsubscribe") or
        std.mem.eql(u8, name, "media.live.recording.store") or
        std.mem.eql(u8, name, "media.video.start") or
        std.mem.eql(u8, name, "media.video.start") or
        std.mem.eql(u8, name, "media.video.stop") or
        std.mem.eql(u8, name, "media.blob.fetch");
    if (!std.mem.eql(u8, name, "idfond.request") and !is_media_audio and
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
    if (std.mem.eql(u8, name, "idfond.request")) {
        var thread = std.Thread.spawn(.{}, daemonWorker, .{job}) catch {
            std.heap.page_allocator.destroy(job); self.complete(key, false, "thread_failed"); return;
        };
        thread.detach();
    } else if (is_media_audio or std.mem.eql(u8, name, "media.set_scope") or std.mem.eql(u8, name, "media.recording.persist")) {
        var thread = std.Thread.spawn(.{}, mediaAudioWorker, .{job}) catch {
            std.heap.page_allocator.destroy(job); self.complete(key, false, "thread_failed"); return;
        };
        thread.detach();
    } else {
        std.heap.page_allocator.destroy(job);
        self.complete(key, false, "unknown_command");
    }
}

fn cancel(context: *anyopaque, key: u64) void { _ = context; _ = key; }

fn bindServices(context: *anyopaque, services: *const native_sdk.platform.PlatformServices) void {
    const self: *Host = @ptrCast(@alignCast(context));
    lock(&self.services_lock); self.services = services; self.services_lock.unlock();
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
    if (self.handed_out) |old| if (old.len > 0) std.heap.page_allocator.free(old);
    self.handed_out = if (item.len > 0) item.bytes else null;
    const result = native_sdk.HostCallCompletion{ .key = item.key, .ok = item.ok, .bytes = item.bytes[0..item.len] };
    self.queue_head = (self.queue_head + 1) % queue_size; self.queue_len -= 1; return result;
}

const ClientResponse = struct {
    code: c_int,
    ok: bool,
    ptr: [*c]u8,
    len: usize,
};

/// Maps Rust client error codes to the historical completion strings.
fn daemonError(code: c_int) []const u8 {
    return switch (code) {
        ffi.IDFON_EREQUEST => "payload_too_large",
        ffi.IDFON_ECONNECT => "daemon_unavailable",
        ffi.IDFON_EWRITE => "daemon_write_failed",
        ffi.IDFON_EREAD => "daemon_read_failed",
        ffi.IDFON_ETOOLARGE => "daemon_result_too_large",
        ffi.IDFON_EINVALID => "daemon_invalid_response",
        else => "client_invalid_argument", // IDFON_EARG: shim bug, not a daemon state
    };
}

fn clientRequest(socket: []const u8, payload: []const u8, timeout_ms: u32) ClientResponse {
    var socket_z: [128:0]u8 = undefined;
    const socket_z_ptr = std.fmt.bufPrintZ(&socket_z, "{s}", .{socket}) catch {
        return .{ .code = ffi.IDFON_EARG, .ok = false, .ptr = null, .len = 0 };
    };
    var out: [*c]u8 = null;
    var out_len: usize = 0;
    var ok: u8 = 0;
    const code = ffi.idfon_client_request(socket_z_ptr.ptr, payload.ptr, payload.len, &out, &out_len, &ok, timeout_ms);
    if (code != ffi.IDFON_OK) return .{ .code = code, .ok = false, .ptr = null, .len = 0 };
    return .{ .code = code, .ok = ok == 1, .ptr = out, .len = out_len };
}

fn daemonWorker(job: *Job) void {
    defer std.heap.page_allocator.destroy(job);
    const self = job.host;
    const paths = profilePaths();
    // Single fast attempt first so a cold start goes through launchDaemon.
    var response = clientRequest(paths.socket[0..paths.socket_len], job.bytes[0..job.len], 0);
    if (response.code == ffi.IDFON_ECONNECT) {
        if (!launchDaemon(self, paths)) {
            self.complete(job.key, false, "daemon_unavailable");
            return;
        }
        response = clientRequest(paths.socket[0..paths.socket_len], job.bytes[0..job.len], 5000);
    }
    if (response.code != ffi.IDFON_OK) {
        self.complete(job.key, false, daemonError(response.code));
        return;
    }
    defer ffi.idfon_client_result_free(response.ptr, response.len);
    // Cap at the runtime's host-result budget (max_effect_host_result_bytes);
    // rejecting here keeps the error legible instead of the runtime's opaque
    // "host result over budget".
    if (response.len > max_result) {
        self.complete(job.key, false, "daemon_result_too_large");
        return;
    }
    const body = response.ptr[0..response.len];
    trace("daemon response key={d} ok={} body={s}", .{ job.key, response.ok, body[0..@min(body.len, 400)] });
    self.complete(job.key, response.ok, body);
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
        var ticket: [max_payload + 1]u8 = undefined;
        @memcpy(ticket[0..job.len], job.bytes[0..job.len]); ticket[job.len] = 0;
        if (ffi.media_recording_play(&ticket) == 0) self.complete(job.key, true, "recording_playing")
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
    } else if (std.mem.eql(u8, name, "media.audio.set_bitrate")) {
        const kbps = if (job.len != 0) std.fmt.parseInt(u32, job.bytes[0..job.len], 10) catch null else null;
        if (kbps) |value| {
            if (value >= 8 and value <= 510) {
                if (ffi.media_audio_set_bitrate(value * 1000) == 0) self.complete(job.key, true, "bitrate_set")
                else self.complete(job.key, false, "bitrate_set_failed");
            } else self.complete(job.key, false, "invalid_bitrate");
        } else self.complete(job.key, false, "invalid_bitrate");
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
        const ticket = ffi.media_live_start(1, 0); // audio only
        defer ffi.rust_free_string(ticket);
        const text = std.mem.span(ticket);
        if (text.len == 0) self.complete(job.key, false, self.last_live_error())
        else self.complete(job.key, true, text);
    } else if (std.mem.eql(u8, name, "media.live.video_start")) {
        const ticket = ffi.media_live_start(1, 1); // mic + camera
        defer ffi.rust_free_string(ticket);
        // start_live opens mic-open, camera-closed; open the gate explicitly so
        // a failed/raced shell does not leave the video track silent.
        _ = ffi.media_live_set_video_enabled(1);
        const text = std.mem.span(ticket);
        if (text.len == 0) self.complete(job.key, false, self.last_live_error())
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
        if (text.len == 0) self.complete(job.key, false, "recording_store_failed") else {
            var result: [max_result]u8 = undefined;
            const duration = std.fmt.bufPrint(&result, "{d}", .{(ffi.media_recording_duration_ms() + 500) / 1000}) catch { self.complete(job.key, false, "recording_store_failed"); return; };
            if (duration.len + 1 + text.len > result.len) { self.complete(job.key, false, "recording_store_failed"); return; }
            result[duration.len] = 10;
            @memcpy(result[duration.len + 1 ..][0..text.len], text);
            self.complete(job.key, true, result[0 .. duration.len + 1 + text.len]);
        }
    } else if (std.mem.eql(u8, name, "media.video.start")) {
        var ticket: [max_payload + 1]u8 = undefined;
        @memcpy(ticket[0..job.len], job.bytes[0..job.len]); ticket[job.len] = 0;
        const path = ffi.media_video_start(&ticket);
        defer ffi.rust_free_string(path);
        const text = std.mem.span(path);
        if (text.len == 0) self.complete(job.key, false, "video_start_failed")
        else self.complete(job.key, true, text);
    } else if (std.mem.eql(u8, name, "media.video.stop")) {
        ffi.media_video_stop();
        self.complete(job.key, true, "video_stopped");
    } else if (std.mem.eql(u8, name, "media.blob.fetch")) {
        var ticket: [max_payload + 1]u8 = undefined;
        @memcpy(ticket[0..job.len], job.bytes[0..job.len]);
        ticket[job.len] = 0;
        // Echo the ticket back so the app can mark the exact history item.
        if (ffi.media_blob_fetch(&ticket) == 0) self.complete(job.key, true, ticket[0..job.len])
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


fn profilePaths() ProfilePaths {
    var paths = ProfilePaths{};
    // Socket path comes from Rust (single source of truth with the daemon);
    // the data dir is always the socket's parent (/tmp/idfon[-{profile}]).
    const socket_len = ffi.idfon_client_socket_path(null, &paths.socket, paths.socket.len);
    if (socket_len < 0) {
        @memcpy(paths.socket[0..default_socket.len], default_socket);
        paths.socket_len = default_socket.len;
    } else {
        paths.socket_len = @intCast(socket_len);
    }
    const socket = paths.socket[0..paths.socket_len];
    const slash = std.mem.lastIndexOfScalar(u8, socket, '/') orelse 0;
    if (slash == 0) {
        @memcpy(paths.data[0..default_data_dir.len], default_data_dir);
        paths.data_len = default_data_dir.len;
        return paths;
    }
    @memcpy(paths.data[0..slash], socket[0..slash]);
    paths.data_len = slash;
    return paths;
}

fn launchDaemon(self: *Host, paths: ProfilePaths) bool {
    lock(&self.daemon_lock);
    defer self.daemon_lock.unlock();
    if (self.daemon_pid > 0) {
        var status: c_int = 0;
        const result = c.waitpid(self.daemon_pid, &status, c.WNOHANG);
        if (result == 0) return true;
        if (result == self.daemon_pid) {
            self.daemon_pid = -1;
        } else {
            return true;
        }
    }
    const pid = c.fork();
    if (pid < 0) return false;
    if (pid == 0) {
        var socket_path: [128:0]u8 = undefined;
        var data_path: [128:0]u8 = undefined;
        const socket_z = std.fmt.bufPrintZ(&socket_path, "{s}", .{paths.socket[0..paths.socket_len]}) catch c._exit(127);
        const data_z = std.fmt.bufPrintZ(&data_path, "{s}", .{paths.data[0..paths.data_len]}) catch c._exit(127);
        var daemon_log_path: [64:0]u8 = undefined;
        const daemon_log = std.fmt.bufPrintZ(&daemon_log_path, "/tmp/idfond-auto-{d}.log", .{c.getpid()}) catch null;
        var log_fd: c_int = -1;
        if (daemon_log) |path_z| {
            log_fd = c.open(path_z.ptr, c.O_WRONLY | c.O_CREAT | c.O_TRUNC, @as(c_int, 0o600));
            if (log_fd >= 0) {
                _ = c.dup2(log_fd, c.STDOUT_FILENO);
                _ = c.dup2(log_fd, c.STDERR_FILENO);
                // Keep the descriptor open so failed exec attempts are logged.
            }
        }
        if (log_fd >= 0) _ = c.dprintf(log_fd, "auto-start child pid=%d\n", c.getpid());
        const launch_argv = [_]?[*:0]u8{
            @constCast("idfond"), @constCast("--socket"), @constCast(socket_z.ptr), @constCast("--data-dir"), @constCast(data_z.ptr), null,
        };
        const argv = launch_argv;
        _ = c.execvp(argv[0], @ptrCast(&argv));
        if (log_fd >= 0) _ = c.dprintf(log_fd, "execvp failed\n");
        const launch_paths = [_][]const u8{
            "target/release/idfond",
            "../target/release/idfond",
            "zig-out/bin/idfond",
            "Idfon.app/Contents/MacOS/idfond",
            "/usr/local/bin/idfond",
        };
        for (launch_paths) |path| {
            var path_z: [256:0]u8 = undefined;
            const name = std.fmt.bufPrintZ(&path_z, "{s}", .{path}) catch continue;
            var path_argv = [_]?[*:0]u8{ name.ptr, @constCast("--socket"), @constCast(socket_z.ptr), @constCast("--data-dir"), @constCast(data_z.ptr), null };
            _ = c.execv(name.ptr, @ptrCast(&path_argv));
            if (log_fd >= 0) _ = c.dprintf(log_fd, "execv %s failed\n", name.ptr);
        }
        var executable: [1024:0]u8 = undefined;
        var executable_len: u32 = executable.len;
        if (log_fd >= 0) _ = c.dprintf(log_fd, "executable path lookup\n");
        if (_NSGetExecutablePath(&executable, &executable_len) == 0) {
            var end: usize = 0;
            while (end < executable.len and executable[end] != 0) : (end += 1) {}
            while (end > 0 and executable[end - 1] != '/') : (end -= 1) {}
            if (end == 0) { c._exit(127); }
            const sibling = std.fmt.bufPrintZ(executable[end..], "idfond", .{}) catch null;
            if (sibling) |_| {
                var sibling_argv = [_]?[*:0]u8{ executable[0..].ptr, @constCast("--socket"), @constCast(socket_z.ptr), @constCast("--data-dir"), @constCast(data_z.ptr), null };
                if (log_fd >= 0) _ = c.dprintf(log_fd, "execv sibling %s\n", executable[0..].ptr);
                _ = c.execv(executable[0..].ptr, @ptrCast(&sibling_argv));
                if (log_fd >= 0) _ = c.dprintf(log_fd, "execv sibling failed\n");
            }
        }
        c._exit(127);
    }
    self.daemon_pid = pid;
    trace("launched idfond pid={d}", .{pid});
    return true;
}

fn stopDaemon(self: *Host) void {
    lock(&self.daemon_lock);
    const pid = self.daemon_pid;
    self.daemon_pid = -1;
    self.daemon_lock.unlock();
    if (pid > 0) {
        // idfond handles SIGINT through tokio and runs its lock/socket cleanup.
        _ = c.kill(pid, c.SIGINT);
        _ = c.waitpid(pid, null, 0);
        trace("stopped idfond pid={d}", .{pid});
    }
}

fn shutdown(context: *anyopaque) void {
    const self: *Host = @ptrCast(@alignCast(context));
    trace("host shutdown", .{});
    // idfond is a shared long-running service; one GUI client must not stop it
    // while another client or the CLI is still using the same profile.
    ffi.media_shutdown();
    lock(&self.services_lock);
    self.services = null;
    self.services_lock.unlock();
}
