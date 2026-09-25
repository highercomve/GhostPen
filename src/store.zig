//! GhostPen settings kept in an Oriel store (`<config dir>/settings.json`,
//! key "settings"), shared by the UI commands and the worker threads. On
//! first run the Tauri GhostPen's settings are imported when found, so a
//! user keeps their profiles, hotkeys and custom actions.

const std = @import("std");
const oriel = @import("oriel");
const settings = @import("settings.zig");
const Settings = settings.Settings;
const parse = settings.parse;
const clone = settings.clone;
const app_id = settings.app_id;

/// The Tauri app's id: its settings are imported on first run.
const tauri_app_id = "com.ghostpen.app";

/// The current settings, shared by the UI commands and the worker threads.
/// `get` hands out a snapshot owned by the caller's arena.
pub const Shared = struct {
    mutex: std.Io.Mutex = .init,
    arena: std.heap.ArenaAllocator,
    value: Settings = .{},

    pub fn init(gpa: std.mem.Allocator) Shared {
        return .{ .arena = .init(gpa) };
    }

    /// Load from the store (importing the Tauri app's settings the first
    /// time); defaults when there's nothing readable.
    pub fn load(self: *Shared, io: std.Io, gpa: std.mem.Allocator) void {
        const loaded = readStore(self.arena.allocator(), gpa) catch null;
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (loaded) |s| {
            self.value = s;
        } else {
            self.value = .{};
            writeStore(gpa, self.value) catch |err| std.log.warn("settings: can't save defaults: {s}", .{@errorName(err)});
        }
    }

    /// A deep copy of the current settings into `arena`.
    pub fn get(self: *Shared, io: std.Io, arena: std.mem.Allocator) !Settings {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return clone(arena, self.value);
    }

    /// Replace and persist.
    pub fn set(self: *Shared, io: std.Io, gpa: std.mem.Allocator, new: Settings) !void {
        try writeStore(gpa, new);
        var fresh: std.heap.ArenaAllocator = .init(gpa);
        errdefer fresh.deinit();
        const copy = try clone(fresh.allocator(), new);
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.arena.deinit();
        self.arena = fresh;
        self.value = copy;
    }

    /// Apply `edit` to the current settings and persist them.
    pub fn update(self: *Shared, io: std.Io, gpa: std.mem.Allocator, edit: anytype) !void {
        var scratch: std.heap.ArenaAllocator = .init(gpa);
        defer scratch.deinit();
        var s = try self.get(io, scratch.allocator());
        edit.apply(&s);
        try self.set(io, gpa, s);
    }

    pub fn deinit(self: *Shared) void {
        self.arena.deinit();
    }
};

fn readStore(arena: std.mem.Allocator, gpa: std.mem.Allocator) !?Settings {
    const store = try oriel.store.Store.open(gpa, app_id, "settings");
    defer store.deinit();
    if (store.get("settings")) |v| return try parse(arena, v);

    // First run: import the Tauri GhostPen's settings.
    const tauri_dir = oriel.store.dataDir(gpa, tauri_app_id) catch return null;
    defer gpa.free(tauri_dir);
    const tauri_path = try std.fs.path.join(gpa, &.{ tauri_dir, "settings.json" });
    defer gpa.free(tauri_path);
    const old = oriel.store.Store.openPath(gpa, tauri_path) catch return null;
    old.auto_save = false; // never write the other app's file
    defer old.deinit();
    const v = old.get("settings") orelse return null;
    const imported = parse(arena, v) catch return null;
    std.log.info("settings: imported from {s}", .{tauri_path});
    try store.set("settings", imported);
    return imported;
}

fn writeStore(gpa: std.mem.Allocator, s: Settings) !void {
    const store = try oriel.store.Store.open(gpa, app_id, "settings");
    defer store.deinit();
    try store.set("settings", s);
}

