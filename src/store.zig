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
    /// time). A file that can't be read or doesn't match the schema is left
    /// alone: defaults are used in memory until the user saves.
    pub fn load(self: *Shared, io: std.Io, gpa: std.mem.Allocator) void {
        const loaded = readStore(io, self.arena.allocator(), gpa);
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        switch (loaded) {
            .settings => |s| self.value = s,
            .unreadable => self.value = .{},
            .missing => {
                self.value = .{};
                writeStore(gpa, self.value) catch |err| std.log.warn("settings: can't save defaults: {s}", .{@errorName(err)});
            },
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

const Loaded = union(enum) { settings: Settings, missing, unreadable };

fn readStore(io: std.Io, arena: std.mem.Allocator, gpa: std.mem.Allocator) Loaded {
    const store = oriel.store.Store.open(gpa, app_id, "settings") catch |err| {
        std.log.err("settings: can't open the store ({s}); using defaults", .{@errorName(err)});
        return .unreadable;
    };
    store.auto_save = false; // reading never writes
    defer store.deinit();
    if (store.get("settings")) |v| {
        return .{ .settings = parse(arena, v) catch |err| {
            std.log.err("settings: settings.json doesn't match the schema ({s}); using defaults until you save (the file is left as is)", .{@errorName(err)});
            return .unreadable;
        } };
    }
    // No settings: a first run, unless there's a file Oriel couldn't parse
    // (it kept a copy as settings.json.corrupt).
    if (settingsFileExists(io, gpa)) {
        std.log.err("settings: settings.json couldn't be read; using defaults until you save (a copy is in settings.json.corrupt)", .{});
        return .unreadable;
    }

    // First run: import the Tauri GhostPen's settings.
    const imported = importTauri(arena, gpa) orelse return .missing;
    writeStore(gpa, imported) catch |err| std.log.warn("settings: can't save the imported settings: {s}", .{@errorName(err)});
    return .{ .settings = imported };
}

fn settingsFileExists(io: std.Io, gpa: std.mem.Allocator) bool {
    const dir = oriel.store.configDir(gpa, app_id) catch return false;
    defer gpa.free(dir);
    const path = std.fs.path.join(gpa, &.{ dir, "settings.json" }) catch return false;
    defer gpa.free(path);
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return stat.size > 2;
}

fn importTauri(arena: std.mem.Allocator, gpa: std.mem.Allocator) ?Settings {
    // Next to our own data folder (which exists): only read, never create
    // the other app's folder (oriel.store.dataDir would).
    const own = oriel.store.dataDir(gpa, "GhostPen") catch return null;
    defer gpa.free(own);
    const base = std.fs.path.dirname(own) orelse return null;
    const tauri_path = std.fs.path.join(gpa, &.{ base, tauri_app_id, "settings.json" }) catch return null;
    defer gpa.free(tauri_path);
    const old = oriel.store.Store.openPath(gpa, tauri_path) catch return null;
    old.auto_save = false; // never write the other app's file
    defer old.deinit();
    const v = old.get("settings") orelse return null;
    const imported = parse(arena, v) catch return null;
    std.log.info("settings: imported from {s}", .{tauri_path});
    return imported;
}

fn writeStore(gpa: std.mem.Allocator, s: Settings) !void {
    const store = try oriel.store.Store.open(gpa, app_id, "settings");
    defer store.deinit();
    try store.set("settings", s);
}

