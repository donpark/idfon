const std = @import("std");
const c = @cImport({
    @cInclude("stdio.h");
    @cInclude("unistd.h");
    @cInclude("sys/socket.h");
    @cInclude("sys/un.h");
});
const native_sdk = @import("native_sdk");
const ffi = @cImport({ @cInclude("irohnet.h"); });

const max_message = 8192;
const max_payload = 8192;
const max_result = 8192;
const queue_size = 16;
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

const Host = struct {
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
            .bind_services_fn = bindServices, .shutdown_fn = shutdown };
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
    if (!std.mem.eql(u8, name, "nufond.request") and !is_media_audio and
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
    if (std.mem.eql(u8, name, "nufond.request")) {
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
    @memcpy(self.poll_bytes[0..item.len], item.bytes[0..item.len]);
    const result = native_sdk.HostCallCompletion{ .key = item.key, .ok = item.ok, .bytes = self.poll_bytes[0..item.len] };
    self.queue_head = (self.queue_head + 1) % queue_size; self.queue_len -= 1; return result;
}

fn daemonWorker(job: *Job) void {
    defer std.heap.page_allocator.destroy(job);
    const self = job.host;
    const path = "/tmp/nufon/nufond.sock";
    const fd = c.socket(c.AF_UNIX, c.SOCK_STREAM, 0);
    if (fd < 0) { self.complete(job.key, false, "daemon_unavailable"); return; }
    defer _ = c.close(fd);
    var address: c.struct_sockaddr_un = std.mem.zeroes(c.struct_sockaddr_un);
    address.sun_family = c.AF_UNIX;
    if (path.len >= address.sun_path.len) { self.complete(job.key, false, "socket_path_too_long"); return; }
    @memcpy(address.sun_path[0..path.len], path);
    const address_len: c.socklen_t = @intCast(@sizeOf(c.sa_family_t) + path.len + 1);
    if (c.connect(fd, @ptrCast(&address), address_len) != 0) { self.complete(job.key, false, "daemon_unavailable"); return; }
    var frame: [max_payload + 4]u8 = undefined;
    if (job.len > max_payload) { self.complete(job.key, false, "payload_too_large"); return; }
    std.mem.writeInt(u32, frame[0..4], @intCast(job.len), .big);
    @memcpy(frame[4..][0..job.len], job.bytes[0..job.len]);
    if (c.write(fd, &frame, job.len + 4) != job.len + 4) { self.complete(job.key, false, "daemon_write_failed"); return; }
    var header: [4]u8 = undefined;
    if (c.read(fd, &header, header.len) != 4) { self.complete(job.key, false, "daemon_read_failed"); return; }
    const length = std.mem.readInt(u32, &header, .big);
    if (length > max_result) { self.complete(job.key, false, "daemon_result_too_large"); return; }
    var result: [max_result]u8 = undefined;
    if (c.read(fd, @ptrCast(&result), length) != length) { self.complete(job.key, false, "daemon_read_failed"); return; }
    self.complete(job.key, true, result[0..length]);
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
        if (text.len == 0) self.complete(job.key, false, "recording_store_failed") else {
            var result: [max_result]u8 = undefined;
            const duration = std.fmt.bufPrint(&result, "{d}", .{(ffi.media_recording_duration_ms() + 500) / 1000}) catch { self.complete(job.key, false, "recording_store_failed"); return; };
            if (duration.len + 1 + text.len > result.len) { self.complete(job.key, false, "recording_store_failed"); return; }
            result[duration.len] = 10;
            @memcpy(result[duration.len + 1 ..][0..text.len], text);
            self.complete(job.key, true, result[0 .. duration.len + 1 + text.len]);
        }
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


fn shutdown(context: *anyopaque) void {
    const self: *Host = @ptrCast(@alignCast(context));
    trace("host shutdown", .{});
    ffi.media_shutdown();
    lock(&self.services_lock);
    self.services = null;
    self.services_lock.unlock();
}
