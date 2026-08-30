const std = @import("std");
const c = @cImport({
    @cInclude("stdio.h");
    @cInclude("unistd.h");
    @cInclude("sys/socket.h");
    @cInclude("sys/un.h");
    @cInclude("signal.h");
    @cInclude("sys/wait.h");
    @cInclude("fcntl.h");
    @cInclude("crt_externs.h");
});
extern fn _NSGetExecutablePath(buf: [*:0]u8, bufsize: *u32) c_int;

const native_sdk = @import("native_sdk");
const ffi = @cImport({ @cInclude("irohnet.h"); });

const max_message = 8192;
const max_payload = 8192;
const max_result = 8192;
const queue_size = 16;
const default_socket = "/tmp/nufon/nufond.sock";
const default_data_dir = "/tmp/nufon";
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
    daemon_lock: std.atomic.Mutex = .unlocked,
    daemon_pid: c.pid_t = -1,
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
    var socket_path: [256:0]u8 = undefined;
    const path = daemonPaths(&socket_path, null);
    var fd = connectDaemon(path);
    if (fd < 0) {
        if (!launchDaemon(self)) { self.complete(job.key, false, "daemon_unavailable"); return; }
        var attempt: usize = 0;
        while (attempt < 50 and fd < 0) : (attempt += 1) {
            _ = c.usleep(100000);
            fd = connectDaemon(path);
        }
    }
    if (fd < 0) { self.complete(job.key, false, "daemon_unavailable"); return; }
    defer _ = c.close(fd);
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


fn connectDaemon(path: []const u8) c_int {
    const fd = c.socket(c.AF_UNIX, c.SOCK_STREAM, 0);
    if (fd < 0) return -1;
    var address: c.struct_sockaddr_un = std.mem.zeroes(c.struct_sockaddr_un);
    address.sun_family = c.AF_UNIX;
    @memcpy(address.sun_path[0..path.len], path);
    const address_len: c.socklen_t = @intCast(@sizeOf(c.sa_family_t) + path.len + 1);
    if (c.connect(fd, @ptrCast(&address), address_len) != 0) {
        _ = c.close(fd);
        return -1;
    }
    return fd;
}

fn daemonSeed() ?[]const u8 {
    const argc = c._NSGetArgc().*;
    const argv = c._NSGetArgv().*;
    var index: c_int = 1;
    while (index + 1 < argc) : (index += 1) {
        const name = std.mem.span(argv[@intCast(index)]);
        if (std.mem.eql(u8, name, "--seed")) return std.mem.span(argv[@intCast(index + 1)]);
    }
    return null;
}

fn daemonPaths(socket_buffer: *[256:0]u8, data_buffer: ?*[256:0]u8) []const u8 {
    const seed = daemonSeed() orelse return default_socket;
    var safe: [64]u8 = undefined;
    var length: usize = 0;
    for (seed) |value| {
        if (length == safe.len) break;
        safe[length] = if ((value >= 'a' and value <= 'z') or (value >= 'A' and value <= 'Z') or (value >= '0' and value <= '9') or value == '-' or value == '_') value else '_';
        length += 1;
    }
    if (length == 0) return default_socket;
    if (data_buffer) |buffer| _ = std.fmt.bufPrintZ(buffer, "/tmp/nufon/{s}", .{safe[0..length]}) catch return default_socket;
    const path = std.fmt.bufPrintZ(socket_buffer, "/tmp/nufon/{s}/nufond.sock", .{safe[0..length]}) catch return default_socket;
    return path;
}

fn launchDaemon(self: *Host) bool {
    lock(&self.daemon_lock);
    defer self.daemon_lock.unlock();
    if (self.daemon_pid > 0) return true;
    const pid = c.fork();
    if (pid < 0) return false;
    if (pid == 0) {
        var socket_buffer: [256:0]u8 = undefined;
        var data_buffer: [256:0]u8 = undefined;
        const socket_path = daemonPaths(&socket_buffer, &data_buffer);
        const data_path = if (daemonSeed() == null) default_data_dir else std.mem.span(data_buffer[0..].ptr);
        var daemon_log_path: [64:0]u8 = undefined;
        const daemon_log = std.fmt.bufPrintZ(&daemon_log_path, "/tmp/nufond-auto-{d}.log", .{c.getpid()}) catch null;
        var log_fd: c_int = -1;
        if (daemon_log) |path_z| {
            log_fd = c.open(path_z.ptr, c.O_WRONLY | c.O_CREAT | c.O_TRUNC, @as(c_int, 0o600));
            if (log_fd >= 0) {
                _ = c.dup2(log_fd, c.STDOUT_FILENO);
                _ = c.dup2(log_fd, c.STDERR_FILENO);
                // Keep the descriptor open so failed exec attempts are logged.
            }
        }
        if (log_fd >= 0) _ = c.dprintf(log_fd, "auto-start child pid=%d\\n", c.getpid());
        const launch_argv = [_]?[*:0]u8{
            @constCast("nufond"), @constCast("--socket"), @constCast(@ptrCast(socket_path.ptr)), @constCast("--data-dir"), @constCast(@ptrCast(data_path.ptr)), null,
        };
        const argv = launch_argv;
        _ = c.execvp(argv[0], @ptrCast(&argv));
        if (log_fd >= 0) _ = c.dprintf(log_fd, "execvp failed\\n");
        const paths = [_][]const u8{
            "target/release/nufond",
            "../target/release/nufond",
            "zig-out/bin/nufond",
            "Nufon.app/Contents/MacOS/nufond",
            "/usr/local/bin/nufond",
        };
        for (paths) |path| {
            var path_z: [256:0]u8 = undefined;
            const name = std.fmt.bufPrintZ(&path_z, "{s}", .{path}) catch continue;
            var path_argv = [_]?[*:0]u8{ name.ptr, @constCast("--socket"), @constCast(@ptrCast(socket_path.ptr)), @constCast("--data-dir"), @constCast(@ptrCast(data_path.ptr)), null };
            _ = c.execv(name.ptr, @ptrCast(&path_argv));
            if (log_fd >= 0) _ = c.dprintf(log_fd, "execv %s failed\\n", name.ptr);
        }
        var executable: [1024:0]u8 = undefined;
        var executable_len: u32 = executable.len;
        if (log_fd >= 0) _ = c.dprintf(log_fd, "executable path lookup\\n");
        if (_NSGetExecutablePath(&executable, &executable_len) == 0) {
            var end: usize = 0;
            while (end < executable.len and executable[end] != 0) : (end += 1) {}
            while (end > 0 and executable[end - 1] != '/') : (end -= 1) {}
            if (end == 0) { c._exit(127); }
            const sibling = std.fmt.bufPrintZ(executable[end..], "nufond", .{}) catch null;
            if (sibling) |_| {
                var sibling_argv = [_]?[*:0]u8{ executable[0..].ptr, @constCast("--socket"), @constCast(@ptrCast(socket_path.ptr)), @constCast("--data-dir"), @constCast(data_path.ptr), null };
                if (log_fd >= 0) _ = c.dprintf(log_fd, "execv sibling %s\\n", executable[0..].ptr);
                _ = c.execv(executable[0..].ptr, @ptrCast(&sibling_argv));
                if (log_fd >= 0) _ = c.dprintf(log_fd, "execv sibling failed\\n");
            }
        }
        c._exit(127);
    }
    self.daemon_pid = pid;
    trace("launched nufond pid={d}", .{pid});
    return true;
}

fn stopDaemon(self: *Host) void {
    lock(&self.daemon_lock);
    const pid = self.daemon_pid;
    self.daemon_pid = -1;
    self.daemon_lock.unlock();
    if (pid > 0) {
        // nufond handles SIGINT through tokio and runs its lock/socket cleanup.
        _ = c.kill(pid, c.SIGINT);
        _ = c.waitpid(pid, null, 0);
        trace("stopped nufond pid={d}", .{pid});
    }
}

fn shutdown(context: *anyopaque) void {
    const self: *Host = @ptrCast(@alignCast(context));
    trace("host shutdown", .{});
    stopDaemon(self);
    ffi.media_shutdown();
    lock(&self.services_lock);
    self.services = null;
    self.services_lock.unlock();
}
