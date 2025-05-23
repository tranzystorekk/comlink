const std = @import("std");
const comlink = @import("comlink.zig");
const lua = @import("lua.zig");
const tls = @import("tls");
const vaxis = @import("vaxis");
const zeit = @import("zeit");

const Completer = @import("completer.zig").Completer;
const Scrollbar = @import("Scrollbar.zig");
const testing = std.testing;
const mem = std.mem;
const vxfw = vaxis.vxfw;

const Allocator = std.mem.Allocator;
const Base64Encoder = std.base64.standard.Encoder;

const assert = std.debug.assert;

const log = std.log.scoped(.irc);

/// maximum size message we can write
pub const maximum_message_size = 512;

/// maximum size message we can receive
const max_raw_msg_size = 512 + 8191; // see modernircdocs

/// Seconds of idle connection before we start pinging
const keepalive_idle: i32 = 15;

/// Seconds between pings
const keepalive_interval: i32 = 5;

/// Number of failed pings before we consider the connection failed
const keepalive_retries: i32 = 3;

// Gutter (left side where time is printed) width
const gutter_width = 6;

pub const Buffer = union(enum) {
    client: *Client,
    channel: *Channel,
};

pub const Command = enum {
    RPL_WELCOME, // 001
    RPL_YOURHOST, // 002
    RPL_CREATED, // 003
    RPL_MYINFO, // 004
    RPL_ISUPPORT, // 005

    RPL_TRYAGAIN, // 263

    RPL_ENDOFWHO, // 315
    RPL_LISTSTART, // 321
    RPL_LIST, // 322
    RPL_LISTEND, // 323
    RPL_TOPIC, // 332
    RPL_WHOREPLY, // 352
    RPL_NAMREPLY, // 353
    RPL_WHOSPCRPL, // 354
    RPL_ENDOFNAMES, // 366

    RPL_LOGGEDIN, // 900
    RPL_SASLSUCCESS, // 903

    // Named commands
    AUTHENTICATE,
    AWAY,
    BATCH,
    BOUNCER,
    CAP,
    CHATHISTORY,
    JOIN,
    MARKREAD,
    NOTICE,
    PART,
    PONG,
    PRIVMSG,
    TAGMSG,

    unknown,

    const map = std.StaticStringMap(Command).initComptime(.{
        .{ "001", .RPL_WELCOME },
        .{ "002", .RPL_YOURHOST },
        .{ "003", .RPL_CREATED },
        .{ "004", .RPL_MYINFO },
        .{ "005", .RPL_ISUPPORT },

        .{ "263", .RPL_TRYAGAIN },

        .{ "315", .RPL_ENDOFWHO },
        .{ "321", .RPL_LISTSTART },
        .{ "322", .RPL_LIST },
        .{ "323", .RPL_LISTEND },
        .{ "332", .RPL_TOPIC },
        .{ "352", .RPL_WHOREPLY },
        .{ "353", .RPL_NAMREPLY },
        .{ "354", .RPL_WHOSPCRPL },
        .{ "366", .RPL_ENDOFNAMES },

        .{ "900", .RPL_LOGGEDIN },
        .{ "903", .RPL_SASLSUCCESS },

        .{ "AUTHENTICATE", .AUTHENTICATE },
        .{ "AWAY", .AWAY },
        .{ "BATCH", .BATCH },
        .{ "BOUNCER", .BOUNCER },
        .{ "CAP", .CAP },
        .{ "CHATHISTORY", .CHATHISTORY },
        .{ "JOIN", .JOIN },
        .{ "MARKREAD", .MARKREAD },
        .{ "NOTICE", .NOTICE },
        .{ "PART", .PART },
        .{ "PONG", .PONG },
        .{ "PRIVMSG", .PRIVMSG },
        .{ "TAGMSG", .TAGMSG },
    });

    pub fn parse(cmd: []const u8) Command {
        return map.get(cmd) orelse .unknown;
    }
};

pub const Channel = struct {
    client: *Client,
    name: []const u8,
    topic: ?[]const u8 = null,
    members: std.ArrayList(Member),
    in_flight: struct {
        who: bool = false,
        names: bool = false,
    } = .{},

    messages: std.ArrayList(Message),
    history_requested: bool = false,
    who_requested: bool = false,
    at_oldest: bool = false,
    can_scroll_up: bool = false,
    // The MARKREAD state of this channel
    last_read: u32 = 0,
    // The location of the last read indicator. This doesn't necessarily match the state of
    // last_read
    last_read_indicator: u32 = 0,
    scroll_to_last_read: bool = false,
    has_unread: bool = false,
    has_unread_highlight: bool = false,

    has_mouse: bool = false,

    view: vxfw.SplitView,
    member_view: vxfw.ListView,
    text_field: vxfw.TextField,

    scroll: struct {
        /// Line offset from the bottom message
        offset: u16 = 0,
        /// Message offset into the list of messages. We use this to lock the viewport if we have a
        /// scroll. Otherwise, when offset == 0 this is effectively ignored (and should be 0)
        msg_offset: ?usize = null,

        /// Pending scroll we have to handle while drawing. This could be up or down. By convention
        /// we say positive is a scroll up.
        pending: i17 = 0,
    } = .{},

    animation_end_ms: u64 = 0,

    message_view: struct {
        mouse: ?vaxis.Mouse = null,
        hovered_message: ?Message = null,
    } = .{},

    completer: Completer,
    completer_shown: bool = false,
    typing_last_active: u32 = 0,
    typing_last_sent: u32 = 0,

    pub const Member = struct {
        user: *User,

        /// Highest channel membership prefix (or empty space if no prefix)
        prefix: u8,

        channel: *Channel,
        has_mouse: bool = false,
        typing: u32 = 0,

        pub fn compare(_: void, lhs: Member, rhs: Member) bool {
            if (lhs.prefix == rhs.prefix) {
                return std.ascii.orderIgnoreCase(lhs.user.nick, rhs.user.nick).compare(.lt);
            }
            return lhs.prefix > rhs.prefix;
        }

        pub fn widget(self: *Member) vxfw.Widget {
            return .{
                .userdata = self,
                .eventHandler = Member.eventHandler,
                .drawFn = Member.draw,
            };
        }

        fn eventHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
            const self: *Member = @ptrCast(@alignCast(ptr));
            switch (event) {
                .mouse => |mouse| {
                    if (!self.has_mouse) {
                        self.has_mouse = true;
                        try ctx.setMouseShape(.pointer);
                    }
                    switch (mouse.type) {
                        .press => {
                            if (mouse.button == .left) {
                                // Open a private message with this user
                                const client = self.channel.client;
                                const ch = try client.getOrCreateChannel(self.user.nick);
                                try client.requestHistory(.after, ch);
                                client.app.selectChannelName(client, ch.name);
                                return ctx.consumeAndRedraw();
                            }
                            if (mouse.button == .right) {
                                // Insert nick at cursor
                                try self.channel.text_field.insertSliceAtCursor(self.user.nick);
                                return ctx.consumeAndRedraw();
                            }
                        },
                        else => {},
                    }
                },
                .mouse_enter => {
                    self.has_mouse = true;
                    try ctx.setMouseShape(.pointer);
                },
                .mouse_leave => {
                    self.has_mouse = false;
                    try ctx.setMouseShape(.default);
                },
                else => {},
            }
        }

        pub fn draw(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
            const self: *Member = @ptrCast(@alignCast(ptr));
            var style: vaxis.Style = if (self.user.away)
                .{ .fg = .{ .index = 8 } }
            else
                .{ .fg = self.user.color };
            if (self.has_mouse) style.reverse = true;
            const prefix: []const u8 = switch (self.prefix) {
                '~' => "󰜥 ", // founder
                '&' => "󰪍 ", // protected
                '@' => " ", // operator
                '%' => " ", // half op
                '+' => " ", // voice
                else => try std.fmt.allocPrint(ctx.arena, "{c} ", .{self.prefix}),
            };
            const text: vxfw.RichText = .{
                .text = &.{
                    .{ .text = prefix, .style = style },
                    .{ .text = self.user.nick, .style = style },
                },
                .softwrap = false,
            };
            var surface = try text.draw(ctx);
            surface.widget = self.widget();
            return surface;
        }
    };

    pub fn init(
        self: *Channel,
        gpa: Allocator,
        client: *Client,
        name: []const u8,
        unicode: *const vaxis.Unicode,
    ) Allocator.Error!void {
        self.* = .{
            .name = try gpa.dupe(u8, name),
            .members = std.ArrayList(Channel.Member).init(gpa),
            .messages = std.ArrayList(Message).init(gpa),
            .client = client,
            .view = .{
                .lhs = self.contentWidget(),
                .rhs = self.member_view.widget(),
                .width = 16,
                .constrain = .rhs,
            },
            .member_view = .{
                .children = .{
                    .builder = .{
                        .userdata = self,
                        .buildFn = Channel.buildMemberList,
                    },
                },
                .draw_cursor = false,
            },
            .text_field = vxfw.TextField.init(gpa, unicode),
            .completer = Completer.init(gpa),
        };

        self.text_field.style = .{ .bg = client.app.blendBg(10) };
        self.text_field.userdata = self;
        self.text_field.onSubmit = Channel.onSubmit;
        self.text_field.onChange = Channel.onChange;
    }

    fn onSubmit(ptr: ?*anyopaque, ctx: *vxfw.EventContext, input: []const u8) anyerror!void {
        // Check the message is not just whitespace
        for (input) |b| {
            // Break on the first non-whitespace byte
            if (!std.ascii.isWhitespace(b)) break;
        } else return;

        const self: *Channel = @ptrCast(@alignCast(ptr orelse unreachable));

        // Copy the input into a temporary buffer
        var buf: [1024]u8 = undefined;
        @memcpy(buf[0..input.len], input);
        const local = buf[0..input.len];
        // Free the text field. We do this here because the command may destroy our channel
        self.text_field.clearAndFree();
        self.completer_shown = false;

        if (std.mem.startsWith(u8, local, "/")) {
            self.client.app.handleCommand(.{ .channel = self }, local) catch {
                log.warn("invalid command: {s}", .{input});
                return;
            };
        } else {
            try self.client.print("PRIVMSG {s} :{s}\r\n", .{ self.name, local });
        }
        ctx.redraw = true;
    }

    pub fn insertMessage(self: *Channel, msg: Message) !void {
        try self.messages.append(msg);
        if (msg.timestamp_s > self.last_read) {
            self.has_unread = true;
            if (msg.containsPhrase(self.client.nickname())) {
                self.has_unread_highlight = true;
            }
        }
    }

    fn onChange(ptr: ?*anyopaque, _: *vxfw.EventContext, input: []const u8) anyerror!void {
        const self: *Channel = @ptrCast(@alignCast(ptr orelse unreachable));
        if (!self.client.caps.@"message-tags") return;
        if (std.mem.startsWith(u8, input, "/")) {
            return;
        }
        if (input.len == 0) {
            self.typing_last_sent = 0;
            try self.client.print("@+typing=done TAGMSG {s}\r\n", .{self.name});
            return;
        }
        const now: u32 = @intCast(std.time.timestamp());
        // Send another typing message if it's been more than 3 seconds
        if (self.typing_last_sent + 3 < now) {
            try self.client.print("@+typing=active TAGMSG {s}\r\n", .{self.name});
            self.typing_last_sent = now;
            return;
        }
    }

    pub fn deinit(self: *Channel, alloc: std.mem.Allocator) void {
        alloc.free(self.name);
        self.members.deinit();
        if (self.topic) |topic| {
            alloc.free(topic);
        }
        for (self.messages.items) |msg| {
            alloc.free(msg.bytes);
        }
        self.messages.deinit();
        self.text_field.deinit();
        self.completer.deinit();
    }

    pub fn compare(_: void, lhs: *Channel, rhs: *Channel) bool {
        return std.ascii.orderIgnoreCase(lhs.name, rhs.name).compare(std.math.CompareOperator.lt);
    }

    pub fn compareRecentMessages(self: *Channel, lhs: Member, rhs: Member) bool {
        var l: u32 = 0;
        var r: u32 = 0;
        var iter = std.mem.reverseIterator(self.messages.items);
        while (iter.next()) |msg| {
            if (msg.source()) |source| {
                const bang = std.mem.indexOfScalar(u8, source, '!') orelse source.len;
                const nick = source[0..bang];

                if (l == 0 and std.mem.eql(u8, lhs.user.nick, nick)) {
                    l = msg.timestamp_s;
                } else if (r == 0 and std.mem.eql(u8, rhs.user.nick, nick))
                    r = msg.timestamp_s;
            }
            if (l > 0 and r > 0) break;
        }
        return l < r;
    }

    pub fn nameWidget(self: *Channel, selected: bool) vxfw.Widget {
        return .{
            .userdata = self,
            .eventHandler = Channel.typeErasedEventHandler,
            .drawFn = if (selected)
                Channel.typeErasedDrawNameSelected
            else
                Channel.typeErasedDrawName,
        };
    }

    pub fn doSelect(self: *Channel) void {
        // Set the state of the last_read_indicator
        self.last_read_indicator = self.last_read;
        if (self.has_unread) {
            self.scroll_to_last_read = true;
        }
    }

    fn typeErasedEventHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const self: *Channel = @ptrCast(@alignCast(ptr));
        switch (event) {
            .mouse => |mouse| {
                try ctx.setMouseShape(.pointer);
                if (mouse.type == .press and mouse.button == .left) {
                    self.client.app.selectBuffer(.{ .channel = self });
                    try ctx.requestFocus(self.text_field.widget());
                    const buf = &self.client.app.title_buf;
                    const suffix = " - comlink";
                    if (self.name.len + suffix.len <= buf.len) {
                        const title = try std.fmt.bufPrint(buf, "{s}{s}", .{ self.name, suffix });
                        try ctx.setTitle(title);
                    } else {
                        const title = try std.fmt.bufPrint(
                            buf,
                            "{s}{s}",
                            .{ self.name[0 .. buf.len - suffix.len], suffix },
                        );
                        try ctx.setTitle(title);
                    }
                    return ctx.consumeAndRedraw();
                }
            },
            .mouse_enter => {
                try ctx.setMouseShape(.pointer);
                self.has_mouse = true;
            },
            .mouse_leave => {
                try ctx.setMouseShape(.default);
                self.has_mouse = false;
            },
            else => {},
        }
    }

    pub fn drawName(self: *Channel, ctx: vxfw.DrawContext, selected: bool) Allocator.Error!vxfw.Surface {
        var style: vaxis.Style = .{};
        if (selected) style.bg = .{ .index = 8 };
        if (self.has_mouse) style.bg = .{ .index = 8 };
        if (self.has_unread) {
            style.fg = .{ .index = 4 };
            style.bold = true;
        }
        const prefix: vxfw.RichText.TextSpan = if (self.has_unread_highlight)
            .{ .text = " ●︎", .style = .{ .fg = .{ .index = 1 } } }
        else
            .{ .text = "  " };
        const text: vxfw.RichText = if (std.mem.startsWith(u8, self.name, "#"))
            .{
                .text = &.{
                    prefix,
                    .{ .text = " ", .style = .{ .fg = .{ .index = 8 } } },
                    .{ .text = self.name[1..], .style = style },
                },
                .softwrap = false,
            }
        else
            .{
                .text = &.{
                    prefix,
                    .{ .text = "  " },
                    .{ .text = self.name, .style = style },
                },
                .softwrap = false,
            };

        var surface = try text.draw(ctx);
        // Replace the widget reference so we can handle the events
        surface.widget = self.nameWidget(selected);
        return surface;
    }

    fn typeErasedDrawName(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
        const self: *Channel = @ptrCast(@alignCast(ptr));
        return self.drawName(ctx, false);
    }

    fn typeErasedDrawNameSelected(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
        const self: *Channel = @ptrCast(@alignCast(ptr));
        return self.drawName(ctx, true);
    }

    pub fn sortMembers(self: *Channel) void {
        std.sort.insertion(Member, self.members.items, {}, Member.compare);
    }

    pub fn addMember(self: *Channel, user: *User, args: struct {
        prefix: ?u8 = null,
        sort: bool = true,
    }) Allocator.Error!void {
        for (self.members.items) |*member| {
            if (user == member.user) {
                // Update the prefix for an existing member if the prefix is
                // known
                if (args.prefix) |p| member.prefix = p;
                return;
            }
        }

        try self.members.append(.{
            .user = user,
            .prefix = args.prefix orelse ' ',
            .channel = self,
        });

        if (args.sort) {
            self.sortMembers();
        }
    }

    pub fn removeMember(self: *Channel, user: *User) void {
        for (self.members.items, 0..) |member, i| {
            if (user == member.user) {
                _ = self.members.orderedRemove(i);
                return;
            }
        }
    }

    /// issue a MARKREAD command for this channel. The most recent message in the channel will be used as
    /// the last read time
    pub fn markRead(self: *Channel) Allocator.Error!void {
        self.has_unread = false;
        self.has_unread_highlight = false;
        if (self.client.caps.@"draft/read-marker") {
            const last_msg = self.messages.getLastOrNull() orelse return;
            if (last_msg.timestamp_s > self.last_read) {
                const time_tag = last_msg.getTag("time") orelse return;
                try self.client.print(
                    "MARKREAD {s} timestamp={s}\r\n",
                    .{
                        self.name,
                        time_tag,
                    },
                );
            }
        } else self.last_read = @intCast(std.time.timestamp());
    }

    pub fn contentWidget(self: *Channel) vxfw.Widget {
        return .{
            .userdata = self,
            .captureHandler = Channel.captureEvent,
            .drawFn = Channel.typeErasedViewDraw,
        };
    }

    fn captureEvent(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const self: *Channel = @ptrCast(@alignCast(ptr));
        switch (event) {
            .key_press => |key| {
                if (key.matches(vaxis.Key.tab, .{})) {
                    ctx.redraw = true;
                    // if we already have a completion word, then we are
                    // cycling through the options
                    if (self.completer_shown) {
                        const line = self.completer.next(ctx);
                        self.text_field.clearRetainingCapacity();
                        try self.text_field.insertSliceAtCursor(line);
                    } else {
                        var completion_buf: [maximum_message_size]u8 = undefined;
                        const content = self.text_field.sliceToCursor(&completion_buf);
                        try self.completer.reset(content);
                        if (self.completer.kind == .nick) {
                            try self.completer.findMatches(self);
                        }
                        self.completer_shown = true;
                    }
                    return;
                }
                if (key.matches(vaxis.Key.tab, .{ .shift = true })) {
                    if (self.completer_shown) {
                        const line = self.completer.prev(ctx);
                        self.text_field.clearRetainingCapacity();
                        try self.text_field.insertSliceAtCursor(line);
                    }
                    return;
                }
                if (key.matches(vaxis.Key.page_up, .{})) {
                    self.scroll.pending += self.client.app.last_height / 2;
                    self.animation_end_ms = @intCast(std.time.milliTimestamp() + 200);
                    try self.doScroll(ctx);
                    return ctx.consumeAndRedraw();
                }
                if (key.matches(vaxis.Key.page_down, .{})) {
                    self.animation_end_ms = @intCast(std.time.milliTimestamp() + 200);
                    self.scroll.pending -|= self.client.app.last_height / 2;
                    try self.doScroll(ctx);
                    return ctx.consumeAndRedraw();
                }
                if (key.matches(vaxis.Key.home, .{})) {
                    self.animation_end_ms = @intCast(std.time.milliTimestamp() + 200);
                    self.scroll.pending -= self.scroll.offset;
                    self.scroll.msg_offset = null;
                    try self.doScroll(ctx);
                    return ctx.consumeAndRedraw();
                }
                if (!key.isModifier()) {
                    self.completer_shown = false;
                }
            },
            else => {},
        }
    }

    fn typeErasedViewDraw(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
        const self: *Channel = @ptrCast(@alignCast(ptr));
        if (!self.who_requested) {
            try self.client.whox(self);
        }

        const max = ctx.max.size();
        var children = std.ArrayList(vxfw.SubSurface).init(ctx.arena);

        {
            const spans = try formatMessage(ctx.arena, undefined, self.topic orelse "");
            // Draw the topic
            const topic: vxfw.RichText = .{
                .text = spans,
                .softwrap = false,
            };

            const topic_sub: vxfw.SubSurface = .{
                .origin = .{ .col = 0, .row = 0 },
                .surface = try topic.draw(ctx),
            };

            try children.append(topic_sub);

            // Draw a border below the topic
            const bot = "─";
            var writer = try std.ArrayList(u8).initCapacity(ctx.arena, bot.len * max.width);
            try writer.writer().writeBytesNTimes(bot, max.width);

            const border: vxfw.Text = .{
                .text = writer.items,
                .softwrap = false,
            };

            const topic_border: vxfw.SubSurface = .{
                .origin = .{ .col = 0, .row = 1 },
                .surface = try border.draw(ctx),
            };
            try children.append(topic_border);
        }

        const msg_view_ctx = ctx.withConstraints(.{ .height = 0, .width = 0 }, .{
            .height = max.height - 4,
            .width = max.width - 1,
        });
        const message_view = try self.drawMessageView(msg_view_ctx);
        try children.append(.{
            .origin = .{ .row = 2, .col = 0 },
            .surface = message_view,
        });

        const scrollbar_ctx = ctx.withConstraints(
            ctx.min,
            .{ .width = 1, .height = max.height - 4 },
        );

        var scrollbars: Scrollbar = .{
            // Estimate number of lines per message
            .total = @intCast(self.messages.items.len * 3),
            .view_size = max.height - 4,
            .bottom = self.scroll.offset,
        };
        const scrollbar_surface = try scrollbars.draw(scrollbar_ctx);
        try children.append(.{
            .origin = .{ .col = max.width - 1, .row = 2 },
            .surface = scrollbar_surface,
        });

        // Draw typers
        typing: {
            var buf: [3]*User = undefined;
            const typers = self.getTypers(&buf);

            const typer_style: vaxis.Style = .{ .fg = self.client.app.blendBg(50) };

            switch (typers.len) {
                0 => break :typing,
                1 => {
                    const text = try std.fmt.allocPrint(
                        ctx.arena,
                        "{s} is typing...",
                        .{typers[0].nick},
                    );
                    const typer: vxfw.Text = .{ .text = text, .style = typer_style };
                    const typer_ctx = ctx.withConstraints(.{}, ctx.max);
                    try children.append(.{
                        .origin = .{ .col = 0, .row = max.height - 2 },
                        .surface = try typer.draw(typer_ctx),
                    });
                },
                2 => {
                    const text = try std.fmt.allocPrint(
                        ctx.arena,
                        "{s} and {s} are typing...",
                        .{ typers[0].nick, typers[1].nick },
                    );
                    const typer: vxfw.Text = .{ .text = text, .style = typer_style };
                    const typer_ctx = ctx.withConstraints(.{}, ctx.max);
                    try children.append(.{
                        .origin = .{ .col = 0, .row = max.height - 2 },
                        .surface = try typer.draw(typer_ctx),
                    });
                },
                else => {
                    const text = "Several people are typing...";
                    const typer: vxfw.Text = .{ .text = text, .style = typer_style };
                    const typer_ctx = ctx.withConstraints(.{}, ctx.max);
                    try children.append(.{
                        .origin = .{ .col = 0, .row = max.height - 2 },
                        .surface = try typer.draw(typer_ctx),
                    });
                },
            }
        }

        {
            // Draw the character limit. 14 is length of message overhead "PRIVMSG  :\r\n"
            const max_limit = maximum_message_size -| self.name.len -| 14 -| self.name.len;
            const limit = try std.fmt.allocPrint(
                ctx.arena,
                " {d}/{d}",
                .{ self.text_field.buf.realLength(), max_limit },
            );
            const style: vaxis.Style = if (self.text_field.buf.realLength() > max_limit)
                .{ .fg = .{ .index = 1 }, .reverse = true }
            else
                .{ .bg = self.client.app.blendBg(30) };
            const limit_text: vxfw.Text = .{ .text = limit, .style = style };
            const limit_ctx = ctx.withConstraints(.{ .width = @intCast(limit.len) }, ctx.max);
            const limit_s = try limit_text.draw(limit_ctx);

            try children.append(.{
                .origin = .{ .col = max.width -| limit_s.size.width, .row = max.height - 1 },
                .surface = limit_s,
            });

            const text_field_ctx = ctx.withConstraints(
                ctx.min,
                .{ .height = 1, .width = max.width -| limit_s.size.width },
            );

            // Draw the text field
            try children.append(.{
                .origin = .{ .col = 0, .row = max.height - 1 },
                .surface = try self.text_field.draw(text_field_ctx),
            });
            // Write some placeholder text if we don't have anything in the text field
            if (self.text_field.buf.realLength() == 0) {
                const text = try std.fmt.allocPrint(ctx.arena, "Message {s}", .{self.name});
                var text_style = self.text_field.style;
                text_style.italic = true;
                text_style.dim = true;
                var ghost_text_ctx = text_field_ctx;
                ghost_text_ctx.max.width = text_field_ctx.max.width.? -| 2;
                const ghost_text: vxfw.Text = .{ .text = text, .style = text_style };
                try children.append(.{
                    .origin = .{ .col = 2, .row = max.height - 1 },
                    .surface = try ghost_text.draw(ghost_text_ctx),
                });
            }
        }

        if (self.completer_shown) {
            const widest: u16 = @intCast(self.completer.widestMatch(ctx));
            const height: u16 = @intCast(@min(10, self.completer.options.items.len));
            const completer_ctx = ctx.withConstraints(ctx.min, .{ .height = height, .width = widest + 2 });
            const surface = try self.completer.list_view.draw(completer_ctx);
            try children.append(.{
                .origin = .{ .col = 0, .row = max.height -| 1 -| height },
                .surface = surface,
            });
        }

        return .{
            .size = max,
            .widget = self.contentWidget(),
            .buffer = &.{},
            .children = children.items,
        };
    }

    fn handleMessageViewEvent(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const self: *Channel = @ptrCast(@alignCast(ptr));
        switch (event) {
            .mouse => |mouse| {
                if (self.message_view.mouse) |last_mouse| {
                    // We need to redraw if the column entered the gutter
                    if (last_mouse.col >= gutter_width and mouse.col < gutter_width)
                        ctx.redraw = true
                            // Or if the column exited the gutter
                    else if (last_mouse.col < gutter_width and mouse.col >= gutter_width)
                        ctx.redraw = true
                            // Or if the row changed
                    else if (last_mouse.row != mouse.row)
                        ctx.redraw = true
                            // Or if we did a middle click, and now released it
                    else if (last_mouse.button == .middle)
                        ctx.redraw = true;
                } else {
                    // If we didn't have the mouse previously, we redraw
                    ctx.redraw = true;
                }

                // Save this mouse state for when we draw
                self.message_view.mouse = mouse;

                // A middle press on a hovered message means we copy the content
                if (mouse.type == .press and
                    mouse.button == .middle and
                    self.message_view.hovered_message != null)
                {
                    const msg = self.message_view.hovered_message orelse unreachable;
                    var iter = msg.paramIterator();
                    // Skip the target
                    _ = iter.next() orelse unreachable;
                    // Get the content
                    const content = iter.next() orelse unreachable;
                    try ctx.copyToClipboard(content);
                    return ctx.consumeAndRedraw();
                }
                if (mouse.button == .wheel_down) {
                    self.scroll.pending -|= 1;
                    ctx.consume_event = true;
                }
                if (mouse.button == .wheel_up) {
                    self.scroll.pending +|= 1;
                    ctx.consume_event = true;
                }
                if (self.scroll.pending != 0) {
                    try self.doScroll(ctx);
                }
            },
            .mouse_leave => {
                self.message_view.mouse = null;
                self.message_view.hovered_message = null;
                ctx.redraw = true;
            },
            .tick => {
                try self.doScroll(ctx);
            },
            else => {},
        }
    }

    /// Consumes any pending scrolls and schedules another tick if needed
    fn doScroll(self: *Channel, ctx: *vxfw.EventContext) anyerror!void {
        defer {
            // At the end of this function, we anchor our msg_offset if we have any amount of
            // scroll. This prevents new messages from automatically scrolling us
            if (self.scroll.offset > 0 and self.scroll.msg_offset == null) {
                self.scroll.msg_offset = @intCast(self.messages.items.len);
            }
            // If we have no offset, we reset our anchor
            if (self.scroll.offset == 0) {
                self.scroll.msg_offset = null;
            }
        }
        // No pending scroll. Return early
        if (self.scroll.pending == 0) return;

        const animation_tick: u32 = 8;
        const now_ms: u64 = @intCast(std.time.milliTimestamp());

        // Scroll up
        if (self.scroll.pending > 0) {
            // Check if we can scroll up. If we can't, we are done
            if (!self.can_scroll_up) {
                self.scroll.pending = 0;
                return;
            }

            // At this point, we always redraw
            ctx.redraw = true;

            // If we are past the end of the animation, or on the last tick, consume the rest of the
            // pending scroll
            if (self.animation_end_ms <= now_ms) {
                self.scroll.offset += @intCast(self.scroll.pending);
                self.scroll.pending = 0;
                return;
            }

            // Calculate the amount to scroll this tick. We use 8ms ticks.
            // Total time = end_ms - now_ms
            // Lines / ms = self.scroll.pending / total time
            // Lines this tick = 8 ms * lines / ms
            // All together: (8 ms * self.scroll.pending ) / (end_ms - now_ms)
            const delta_scroll = (@as(u64, animation_tick) * @as(u64, @intCast(self.scroll.pending))) /
                (self.animation_end_ms - now_ms);

            // Ensure we always scroll at least one line
            const resolved_scroll = @max(1, delta_scroll);

            // Consume 1 line, and schedule a tick
            self.scroll.offset += @intCast(resolved_scroll);
            self.scroll.pending -|= @intCast(resolved_scroll);
            ctx.redraw = true;
            return ctx.tick(animation_tick, self.messageViewWidget());
        }

        // From here, we only scroll down. First, we check if we are at the bottom already. If we
        // are, we have nothing to do
        if (self.scroll.offset == 0) {
            // Already at bottom. Nothing to do
            self.scroll.pending = 0;
            return;
        }

        // Scroll down
        if (self.scroll.pending < 0) {
            const pending: u16 = @intCast(@abs(self.scroll.pending));

            // At this point, we always redraw
            ctx.redraw = true;

            // If we are past the end of the animation, or on the last tick, consume the rest of the
            // pending scroll
            if (self.animation_end_ms <= now_ms) {
                self.scroll.offset -|= pending;
                self.scroll.pending = 0;
                return;
            }

            // Calculate the amount to scroll this tick. We use 8ms ticks.
            // Total time = end_ms - now_ms
            // Lines / ms = self.scroll.pending / total time
            // Lines this tick = 8 ms * lines / ms
            // All together: (8 ms * self.scroll.pending ) / (end_ms - now_ms)
            const delta_scroll = (@as(u64, animation_tick) * @as(u64, @intCast(pending))) /
                (self.animation_end_ms - now_ms);

            // Ensure we always scroll at least one line
            const resolved_scroll = @max(1, delta_scroll);
            self.scroll.offset -|= @intCast(resolved_scroll);
            self.scroll.pending += @intCast(resolved_scroll);
            ctx.redraw = true;
            return ctx.tick(animation_tick, self.messageViewWidget());
        }
    }

    fn messageViewWidget(self: *Channel) vxfw.Widget {
        return .{
            .userdata = self,
            .eventHandler = Channel.handleMessageViewEvent,
            .drawFn = Channel.typeErasedDrawMessageView,
        };
    }

    fn typeErasedDrawMessageView(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
        const self: *Channel = @ptrCast(@alignCast(ptr));
        return self.drawMessageView(ctx);
    }

    pub fn messageViewIsAtBottom(self: *Channel) bool {
        if (self.scroll.msg_offset) |msg_offset| {
            return self.scroll.offset == 0 and
                msg_offset == self.messages.items.len and
                self.scroll.pending == 0;
        }
        return self.scroll.offset == 0 and
            self.scroll.msg_offset == null and
            self.scroll.pending == 0;
    }

    fn drawMessageView(self: *Channel, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
        self.message_view.hovered_message = null;
        const max = ctx.max.size();
        if (max.width == 0 or max.height == 0 or self.messages.items.len == 0) {
            return .{
                .size = max,
                .widget = self.messageViewWidget(),
                .buffer = &.{},
                .children = &.{},
            };
        }

        var children = std.ArrayList(vxfw.SubSurface).init(ctx.arena);

        // Row is the row we are printing on. We add the offset to achieve our scroll location
        var row: i17 = max.height + self.scroll.offset;
        // Message offset
        const offset = self.scroll.msg_offset orelse self.messages.items.len;

        const messages = self.messages.items[0..offset];
        var iter = std.mem.reverseIterator(messages);

        assert(messages.len > 0);
        // Initialize sender and maybe_instant to the last message values
        const last_msg = iter.next() orelse unreachable;
        // Reset iter index
        iter.index += 1;
        var sender = last_msg.senderNick() orelse "";
        var this_instant = last_msg.localTime(&self.client.app.tz);

        // True when we *don't* need to scroll to last message. False if we do. We will turn this
        // true when we have it the last message
        var did_scroll_to_last_read = !self.scroll_to_last_read;
        // We track whether we need to reposition the viewport based on the position of the
        // last_read scroll
        var needs_reposition = true;
        while (iter.next()) |msg| {
            if (row >= 0 and did_scroll_to_last_read) {
                needs_reposition = false;
            }
            // Break if we have gone past the top of the screen
            if (row < 0 and did_scroll_to_last_read) break;

            // Get the sender nickname of the *next* message. Next meaning next message in the
            // iterator, which is chronologically the previous message since we are printing in
            // reverse
            const next_sender: []const u8 = blk: {
                const next_msg = iter.next() orelse break :blk "";
                // Fix the index of the iterator
                iter.index += 1;
                break :blk next_msg.senderNick() orelse "";
            };

            // Get the server time for the *next* message. We'll use this to decide printing of
            // username and time
            const maybe_next_instant: ?zeit.Instant = blk: {
                const next_msg = iter.next() orelse break :blk null;
                // Fix the index of the iterator
                iter.index += 1;
                break :blk next_msg.localTime(&self.client.app.tz);
            };

            defer {
                // After this loop, we want to save these values for the next iteration
                if (maybe_next_instant) |next_instant| {
                    this_instant = next_instant;
                }
                sender = next_sender;
            }

            // Message content
            const content: []const u8 = blk: {
                var param_iter = msg.paramIterator();
                // First param is the target, we don't need it
                _ = param_iter.next() orelse unreachable;
                break :blk param_iter.next() orelse "";
            };

            // Get the user ref for this sender
            const user = try self.client.getOrCreateUser(sender);

            const spans = try formatMessage(ctx.arena, user, content);

            // Draw the message so we have it's wrapped height
            const text: vxfw.RichText = .{ .text = spans };
            const child_ctx = ctx.withConstraints(
                .{ .width = max.width -| gutter_width, .height = 1 },
                .{ .width = max.width -| gutter_width, .height = null },
            );
            const surface = try text.draw(child_ctx);
            // Adjust the row we print on for the wrapped height of this message
            row -= surface.size.height;
            if (self.client.app.yellow != null and msg.containsPhrase(self.client.nickname())) {
                const bg = self.client.app.blendYellow(30);
                for (surface.buffer) |*cell| {
                    if (cell.style.bg != .default) continue;
                    cell.style.bg = bg;
                }
                const left_hl = try vxfw.Surface.init(
                    ctx.arena,
                    self.messageViewWidget(),
                    .{ .height = surface.size.height, .width = 1 },
                );
                const left_hl_cell: vaxis.Cell = .{
                    .char = .{ .grapheme = "▕", .width = 1 },
                    .style = .{ .fg = .{ .index = 3 } },
                };
                @memset(left_hl.buffer, left_hl_cell);
                try children.append(.{
                    .origin = .{ .row = row, .col = gutter_width - 1 },
                    .surface = left_hl,
                });
            }

            // See if our message contains the mouse. We'll highlight it if it does
            const message_has_mouse: bool = blk: {
                const mouse = self.message_view.mouse orelse break :blk false;
                break :blk mouse.col >= gutter_width and
                    mouse.row < row + surface.size.height and
                    mouse.row >= row;
            };

            if (message_has_mouse) {
                const last_mouse = self.message_view.mouse orelse unreachable;
                // If we had a middle click, we highlight yellow to indicate we copied the text
                const bg: vaxis.Color = if (last_mouse.button == .middle and last_mouse.type == .press)
                    .{ .index = 3 }
                else
                    .{ .index = 8 };
                // Set the style for the entire message
                for (surface.buffer) |*cell| {
                    cell.style.bg = bg;
                }
                // Create a surface to highlight the entire area under the message
                const hl_surface = try vxfw.Surface.init(
                    ctx.arena,
                    text.widget(),
                    .{ .width = max.width -| gutter_width, .height = surface.size.height },
                );
                const base: vaxis.Cell = .{ .style = .{ .bg = bg } };
                @memset(hl_surface.buffer, base);

                try children.append(.{
                    .origin = .{ .row = row, .col = gutter_width },
                    .surface = hl_surface,
                });

                self.message_view.hovered_message = msg;
            }

            try children.append(.{
                .origin = .{ .row = row, .col = gutter_width },
                .surface = surface,
            });

            var style: vaxis.Style = .{ .dim = true };

            // The time text we will print
            const buf: []const u8 = blk: {
                const time = this_instant.time();
                // Check our next time. If *this* message occurs on a different day, we want to
                // print the date
                if (maybe_next_instant) |next_instant| {
                    const next_time = next_instant.time();
                    if (time.day != next_time.day) {
                        style = .{};
                        break :blk try std.fmt.allocPrint(
                            ctx.arena,
                            "{d:0>2}/{d:0>2}",
                            .{ @intFromEnum(time.month), time.day },
                        );
                    }
                }

                // if it is the first message, we also want to print the date
                if (iter.index == 0) {
                    style = .{};
                    break :blk try std.fmt.allocPrint(
                        ctx.arena,
                        "{d:0>2}/{d:0>2}",
                        .{ @intFromEnum(time.month), time.day },
                    );
                }

                // Otherwise, we print clock time
                break :blk try std.fmt.allocPrint(
                    ctx.arena,
                    "{d:0>2}:{d:0>2}",
                    .{ time.hour, time.minute },
                );
            };

            // If the message has our nick, we'll highlight the time
            if (self.client.app.yellow == null and msg.containsPhrase(self.client.nickname())) {
                style.fg = .{ .index = 3 };
                style.reverse = true;
            }

            const time_text: vxfw.Text = .{
                .text = buf,
                .style = style,
                .softwrap = false,
            };
            const time_ctx = ctx.withConstraints(
                .{ .width = 0, .height = 1 },
                .{ .width = max.width -| gutter_width, .height = null },
            );
            try children.append(.{
                .origin = .{ .row = row, .col = 0 },
                .surface = try time_text.draw(time_ctx),
            });

            var printed_sender: bool = false;
            // Check if we need to print the sender of this message. We do this when the timegap
            // between this message and next message is > 5 minutes, or if the sender is
            // different
            if (sender.len > 0 and
                printSender(sender, next_sender, this_instant, maybe_next_instant))
            {
                // Back up one row to print
                row -= 1;
                // If we need to print the sender, it will be *this* messages sender
                const sender_text: vxfw.Text = .{
                    .text = user.nick,
                    .style = .{ .fg = user.color, .bold = true },
                };
                const sender_ctx = ctx.withConstraints(
                    .{ .width = 0, .height = 1 },
                    .{ .width = max.width -| gutter_width, .height = null },
                );
                const sender_surface = try sender_text.draw(sender_ctx);
                try children.append(.{
                    .origin = .{ .row = row, .col = gutter_width },
                    .surface = sender_surface,
                });
                if (self.message_view.mouse) |mouse| {
                    if (mouse.row == row and
                        mouse.col >= gutter_width and
                        user.real_name != null)
                    {
                        const realname: vxfw.Text = .{
                            .text = user.real_name orelse unreachable,
                            .style = .{ .fg = .{ .index = 8 }, .italic = true },
                        };
                        try children.append(.{
                            .origin = .{
                                .row = row,
                                .col = gutter_width + sender_surface.size.width + 1,
                            },
                            .surface = try realname.draw(child_ctx),
                        });
                    }
                }

                // Back up 1 more row for spacing
                row -= 1;
                printed_sender = true;
            }

            // Check if we should print a "last read" line. If the next message we will print is
            // before the last_read, and this message is after the last_read then it is our border.
            // Before
            const next_instant = maybe_next_instant orelse continue;
            const this = this_instant.unixTimestamp();
            const next = next_instant.unixTimestamp();

            // If this message is before last_read, we did any scroll_to_last_read. Set the flag to
            // true
            if (this <= self.last_read) did_scroll_to_last_read = true;

            if (this > self.last_read_indicator and next <= self.last_read_indicator) {
                const bot = "━";
                var writer = try std.ArrayList(u8).initCapacity(ctx.arena, bot.len * max.width);
                try writer.writer().writeBytesNTimes(bot, max.width);

                const border: vxfw.Text = .{
                    .text = writer.items,
                    .style = .{ .fg = .{ .index = 1 } },
                    .softwrap = false,
                };

                // We don't need to backup a line if we printed the sender
                if (!printed_sender) row -= 1;

                const unread: vxfw.SubSurface = .{
                    .origin = .{ .col = 0, .row = row },
                    .surface = try border.draw(ctx),
                };
                try children.append(unread);
                const new: vxfw.RichText = .{
                    .text = &.{
                        .{ .text = "", .style = .{ .fg = .{ .index = 1 } } },
                        .{ .text = " New ", .style = .{ .fg = .{ .index = 1 }, .reverse = true } },
                    },
                    .softwrap = false,
                };
                const new_sub: vxfw.SubSurface = .{
                    .origin = .{ .col = max.width - 6, .row = row },
                    .surface = try new.draw(ctx),
                };
                try children.append(new_sub);
            }
        }

        // Request more history when we are within 5 messages of the top of the screen
        if (iter.index < 5 and !self.at_oldest) {
            try self.client.requestHistory(.before, self);
        }

        // If we scroll_to_last_read, we probably need to reposition all of our children. We also
        // check that we have messages, and if we do that the top message is outside the viewport.
        // If we don't have messages, or the top message is within the viewport, we don't have to
        // reposition
        if (needs_reposition and
            children.items.len > 0 and
            children.getLast().origin.row < 0)
        {
            // We will adjust the origin of each item so that the last item we added has an origin
            // of 0
            const adjustment: u16 = @intCast(@abs(children.getLast().origin.row));
            for (children.items) |*item| {
                item.origin.row += adjustment;
            }
            // Our scroll offset gets adjusted as well
            self.scroll.offset += adjustment;
            // We will set the msg offset too to prevent any bumping of the scroll state when we get
            // a new message
            self.scroll.msg_offset = self.messages.items.len;
        }

        // Set the can_scroll_up flag. this is true if we drew past the top of the screen
        self.can_scroll_up = row <= 0;
        if (row > 0) {
            // If we didn't draw past the top of the screen, we must have reached the end of
            // history. Draw an indicator letting the user know this
            const bot = "━";
            var writer = try std.ArrayList(u8).initCapacity(ctx.arena, bot.len * max.width);
            try writer.writer().writeBytesNTimes(bot, max.width);

            const border: vxfw.Text = .{
                .text = writer.items,
                .style = .{ .fg = .{ .index = 8 } },
                .softwrap = false,
            };

            const unread: vxfw.SubSurface = .{
                .origin = .{ .col = 0, .row = row },
                .surface = try border.draw(ctx),
            };
            try children.append(unread);
            const no_more_history: vxfw.Text = .{
                .text = " Perhaps the archives are incomplete ",
                .style = .{ .fg = .{ .index = 8 } },
                .softwrap = false,
            };
            const no_history_surf = try no_more_history.draw(ctx);
            const new_sub: vxfw.SubSurface = .{
                .origin = .{ .col = (max.width -| no_history_surf.size.width) / 2, .row = row },
                .surface = no_history_surf,
            };
            try children.append(new_sub);
        }

        if (did_scroll_to_last_read) {
            self.scroll_to_last_read = false;
        }

        if (self.has_unread and
            self.client.app.has_focus and
            self.messageViewIsAtBottom())
        {
            try self.markRead();
        }

        return .{
            .size = max,
            .widget = self.messageViewWidget(),
            .buffer = &.{},
            .children = children.items,
        };
    }

    fn buildMemberList(ptr: *const anyopaque, idx: usize, _: usize) ?vxfw.Widget {
        const self: *const Channel = @ptrCast(@alignCast(ptr));
        if (idx < self.members.items.len) {
            return self.members.items[idx].widget();
        }
        return null;
    }

    // Helper function which tells us if we should print the sender of a message, based on he
    // current message sender and time, and the (chronologically) previous message sent
    fn printSender(
        a_sender: []const u8,
        b_sender: []const u8,
        a_instant: ?zeit.Instant,
        b_instant: ?zeit.Instant,
    ) bool {
        // If sender is different, we always print the sender
        if (!std.mem.eql(u8, a_sender, b_sender)) return true;

        if (a_instant != null and b_instant != null) {
            const a_ts = a_instant.?.timestamp;
            const b_ts = b_instant.?.timestamp;
            const delta: i64 = @intCast(a_ts - b_ts);
            return @abs(delta) > (5 * std.time.ns_per_min);
        }

        // In any other case, we
        return false;
    }

    fn getTypers(self: *Channel, buf: []*User) []*User {
        const now: u32 = @intCast(std.time.timestamp());
        var i: usize = 0;
        for (self.members.items) |member| {
            if (i == buf.len) {
                return buf[0..i];
            }
            // The spec says we should consider people as typing if the last typing message was
            // received within 6 seconds from now
            if (member.typing + 6 >= now) {
                buf[i] = member.user;
                i += 1;
            }
        }
        return buf[0..i];
    }

    fn typingCount(self: *Channel) usize {
        const now: u32 = @intCast(std.time.timestamp());

        var n: usize = 0;
        for (self.members.items) |member| {
            // The spec says we should consider people as typing if the last typing message was
            // received within 6 seconds from now
            if (member.typing + 6 >= now) {
                n += 1;
            }
        }
        return n;
    }
};

pub const User = struct {
    nick: []const u8,
    away: bool = false,
    color: vaxis.Color = .default,
    real_name: ?[]const u8 = null,

    pub fn deinit(self: *const User, alloc: std.mem.Allocator) void {
        alloc.free(self.nick);
        if (self.real_name) |realname| alloc.free(realname);
    }
};

/// an irc message
pub const Message = struct {
    bytes: []const u8,
    timestamp_s: u32 = 0,

    pub fn init(bytes: []const u8) Message {
        var msg: Message = .{ .bytes = bytes };
        if (msg.getTag("time")) |time_str| {
            const inst = zeit.instant(.{ .source = .{ .iso8601 = time_str } }) catch |err| {
                log.warn("couldn't parse time: '{s}', error: {}", .{ time_str, err });
                msg.timestamp_s = @intCast(std.time.timestamp());
                return msg;
            };
            msg.timestamp_s = @intCast(inst.unixTimestamp());
        } else {
            msg.timestamp_s = @intCast(std.time.timestamp());
        }
        return msg;
    }

    pub fn dupe(self: Message, alloc: std.mem.Allocator) Allocator.Error!Message {
        return .{
            .bytes = try alloc.dupe(u8, self.bytes),
            .timestamp_s = self.timestamp_s,
        };
    }

    pub const ParamIterator = struct {
        params: ?[]const u8,
        index: usize = 0,

        pub fn next(self: *ParamIterator) ?[]const u8 {
            const params = self.params orelse return null;
            if (self.index >= params.len) return null;

            // consume leading whitespace
            while (self.index < params.len) {
                if (params[self.index] != ' ') break;
                self.index += 1;
            }

            const start = self.index;
            if (start >= params.len) return null;

            // If our first byte is a ':', we return the rest of the string as a
            // single param (or the empty string)
            if (params[start] == ':') {
                self.index = params.len;
                if (start == params.len - 1) {
                    return "";
                }
                return params[start + 1 ..];
            }

            // Find the first index of space. If we don't have any, the reset of
            // the line is the last param
            self.index = std.mem.indexOfScalarPos(u8, params, self.index, ' ') orelse {
                defer self.index = params.len;
                return params[start..];
            };

            return params[start..self.index];
        }
    };

    pub const Tag = struct {
        key: []const u8,
        value: []const u8,
    };

    pub const TagIterator = struct {
        tags: []const u8,
        index: usize = 0,

        // tags are a list of key=value pairs delimited by semicolons.
        // key[=value] [; key[=value]]
        pub fn next(self: *TagIterator) ?Tag {
            if (self.index >= self.tags.len) return null;

            // find next delimiter
            const end = std.mem.indexOfScalarPos(u8, self.tags, self.index, ';') orelse self.tags.len;
            var kv_delim = std.mem.indexOfScalarPos(u8, self.tags, self.index, '=') orelse end;
            // it's possible to have tags like this:
            //     @bot;account=botaccount;+typing=active
            // where the first tag doesn't have a value. Guard against the
            // kv_delim being past the end position
            if (kv_delim > end) kv_delim = end;

            defer self.index = end + 1;

            return .{
                .key = self.tags[self.index..kv_delim],
                .value = if (end == kv_delim) "" else self.tags[kv_delim + 1 .. end],
            };
        }
    };

    pub fn tagIterator(msg: Message) TagIterator {
        const src = msg.bytes;
        if (src[0] != '@') return .{ .tags = "" };

        assert(src.len > 1);
        const n = std.mem.indexOfScalarPos(u8, src, 1, ' ') orelse src.len;
        return .{ .tags = src[1..n] };
    }

    pub fn source(msg: Message) ?[]const u8 {
        const src = msg.bytes;
        var i: usize = 0;

        // get past tags
        if (src[0] == '@') {
            assert(src.len > 1);
            i = std.mem.indexOfScalarPos(u8, src, 1, ' ') orelse return null;
        }

        // consume whitespace
        while (i < src.len) : (i += 1) {
            if (src[i] != ' ') break;
        }

        // Start of source
        if (src[i] == ':') {
            assert(src.len > i);
            i += 1;
            const end = std.mem.indexOfScalarPos(u8, src, i, ' ') orelse src.len;
            return src[i..end];
        }

        return null;
    }

    pub fn command(msg: Message) Command {
        const src = msg.bytes;
        var i: usize = 0;

        // get past tags
        if (src[0] == '@') {
            assert(src.len > 1);
            i = std.mem.indexOfScalarPos(u8, src, 1, ' ') orelse return .unknown;
        }
        // consume whitespace
        while (i < src.len) : (i += 1) {
            if (src[i] != ' ') break;
        }

        // get past source
        if (src[i] == ':') {
            assert(src.len > i);
            i += 1;
            i = std.mem.indexOfScalarPos(u8, src, i, ' ') orelse return .unknown;
        }
        // consume whitespace
        while (i < src.len) : (i += 1) {
            if (src[i] != ' ') break;
        }

        assert(src.len > i);
        // Find next space
        const end = std.mem.indexOfScalarPos(u8, src, i, ' ') orelse src.len;
        return Command.parse(src[i..end]);
    }

    pub fn containsPhrase(self: Message, phrase: []const u8) bool {
        switch (self.command()) {
            .PRIVMSG, .NOTICE => {},
            else => return false,
        }
        var iter = self.paramIterator();
        // We only handle PRIVMSG and NOTICE which have syntax <target> :<content>. Skip the target
        _ = iter.next() orelse return false;

        const content = iter.next() orelse return false;
        return std.mem.indexOf(u8, content, phrase) != null;
    }

    pub fn paramIterator(msg: Message) ParamIterator {
        const src = msg.bytes;
        var i: usize = 0;

        // get past tags
        if (src[0] == '@') {
            i = std.mem.indexOfScalarPos(u8, src, 0, ' ') orelse return .{ .params = "" };
        }
        // consume whitespace
        while (i < src.len) : (i += 1) {
            if (src[i] != ' ') break;
        }

        // get past source
        if (src[i] == ':') {
            assert(src.len > i);
            i += 1;
            i = std.mem.indexOfScalarPos(u8, src, i, ' ') orelse return .{ .params = "" };
        }
        // consume whitespace
        while (i < src.len) : (i += 1) {
            if (src[i] != ' ') break;
        }

        // get past command
        i = std.mem.indexOfScalarPos(u8, src, i, ' ') orelse return .{ .params = "" };

        assert(src.len > i);
        return .{ .params = src[i + 1 ..] };
    }

    /// Returns the value of the tag 'key', if present
    pub fn getTag(self: Message, key: []const u8) ?[]const u8 {
        var tag_iter = self.tagIterator();
        while (tag_iter.next()) |tag| {
            if (!std.mem.eql(u8, tag.key, key)) continue;
            return tag.value;
        }
        return null;
    }

    pub fn time(self: Message) zeit.Instant {
        return zeit.instant(.{
            .source = .{ .unix_timestamp = self.timestamp_s },
        }) catch unreachable;
    }

    pub fn localTime(self: Message, tz: *const zeit.TimeZone) zeit.Instant {
        const utc = self.time();
        return utc.in(tz);
    }

    pub fn compareTime(_: void, lhs: Message, rhs: Message) bool {
        return lhs.timestamp_s < rhs.timestamp_s;
    }

    /// Returns the NICK of the sender of the message
    pub fn senderNick(self: Message) ?[]const u8 {
        const src = self.source() orelse return null;
        if (std.mem.indexOfScalar(u8, src, '!')) |idx| return src[0..idx];
        if (std.mem.indexOfScalar(u8, src, '@')) |idx| return src[0..idx];
        return src;
    }
};

pub const Client = struct {
    pub const Config = struct {
        user: []const u8,
        nick: []const u8,
        password: []const u8,
        real_name: []const u8,
        server: []const u8,
        port: ?u16,
        network_id: ?[]const u8 = null,
        network_nick: ?[]const u8 = null,
        name: ?[]const u8 = null,
        tls: bool = true,
        lua_table: i32,

        /// Creates a copy of this config. Nullable strings are not copied
        pub fn copy(self: Config, gpa: std.mem.Allocator) Allocator.Error!Config {
            return .{
                .user = try gpa.dupe(u8, self.user),
                .nick = try gpa.dupe(u8, self.nick),
                .password = try gpa.dupe(u8, self.password),
                .real_name = try gpa.dupe(u8, self.real_name),
                .server = try gpa.dupe(u8, self.server),
                .port = self.port,
                .lua_table = self.lua_table,
            };
        }

        pub fn deinit(self: Config, gpa: std.mem.Allocator) void {
            gpa.free(self.user);
            gpa.free(self.nick);
            gpa.free(self.password);
            gpa.free(self.real_name);
            gpa.free(self.server);
            if (self.network_id) |v| gpa.free(v);
            if (self.network_nick) |v| gpa.free(v);
            if (self.name) |v| gpa.free(v);
        }
    };

    pub const Capabilities = struct {
        @"away-notify": bool = false,
        batch: bool = false,
        @"echo-message": bool = false,
        @"message-tags": bool = false,
        sasl: bool = false,
        @"server-time": bool = false,

        @"draft/chathistory": bool = false,
        @"draft/no-implicit-names": bool = false,
        @"draft/read-marker": bool = false,

        @"soju.im/bouncer-networks": bool = false,
        @"soju.im/bouncer-networks-notify": bool = false,
    };

    /// ISupport are features only advertised via ISUPPORT that we care about
    pub const ISupport = struct {
        whox: bool = false,
        prefix: []const u8 = "",
        chathistory: ?u16 = null,
    };

    pub const Status = enum(u8) {
        disconnected,
        connecting,
        connected,
    };

    alloc: std.mem.Allocator,
    app: *comlink.App,
    client: tls.Connection(std.net.Stream),
    stream: std.net.Stream,
    config: Config,

    channels: std.ArrayList(*Channel),
    users: std.StringHashMap(*User),

    status: std.atomic.Value(Status),

    caps: Capabilities = .{},
    supports: ISupport = .{},

    batches: std.StringHashMap(*Channel),
    write_queue: *comlink.WriteQueue,

    thread: ?std.Thread = null,

    redraw: std.atomic.Value(bool),
    read_buf_mutex: std.Thread.Mutex,
    read_buf: std.ArrayList(u8),

    has_mouse: bool,
    retry_delay_s: u8,

    text_field: vxfw.TextField,
    completer_shown: bool,

    list_modal: ListModal,
    messages: std.ArrayListUnmanaged(Message),
    scroll: struct {
        /// Line offset from the bottom message
        offset: u16 = 0,
        /// Message offset into the list of messages. We use this to lock the viewport if we have a
        /// scroll. Otherwise, when offset == 0 this is effectively ignored (and should be 0)
        msg_offset: ?usize = null,

        /// Pending scroll we have to handle while drawing. This could be up or down. By convention
        /// we say positive is a scroll up.
        pending: i17 = 0,
    } = .{},
    can_scroll_up: bool = false,
    message_view: struct {
        mouse: ?vaxis.Mouse = null,
        hovered_message: ?Message = null,
    } = .{},

    pub fn init(
        self: *Client,
        alloc: std.mem.Allocator,
        app: *comlink.App,
        wq: *comlink.WriteQueue,
        cfg: Config,
    ) !void {
        self.* = .{
            .alloc = alloc,
            .app = app,
            .client = undefined,
            .stream = undefined,
            .config = cfg,
            .channels = std.ArrayList(*Channel).init(alloc),
            .users = std.StringHashMap(*User).init(alloc),
            .batches = std.StringHashMap(*Channel).init(alloc),
            .write_queue = wq,
            .status = std.atomic.Value(Status).init(.disconnected),
            .redraw = std.atomic.Value(bool).init(false),
            .read_buf_mutex = .{},
            .read_buf = std.ArrayList(u8).init(alloc),
            .has_mouse = false,
            .retry_delay_s = 0,
            .text_field = .init(alloc, app.unicode),
            .completer_shown = false,
            .list_modal = undefined,
            .messages = .empty,
        };
        self.list_modal.init(alloc, self);
        self.text_field.style = .{ .bg = self.app.blendBg(10) };
        self.text_field.userdata = self;
        self.text_field.onSubmit = Client.onSubmit;
    }

    fn onSubmit(ptr: ?*anyopaque, ctx: *vxfw.EventContext, input: []const u8) anyerror!void {
        // Check the message is not just whitespace
        for (input) |b| {
            // Break on the first non-whitespace byte
            if (!std.ascii.isWhitespace(b)) break;
        } else return;

        const self: *Client = @ptrCast(@alignCast(ptr orelse unreachable));

        // Copy the input into a temporary buffer
        var buf: [1024]u8 = undefined;
        @memcpy(buf[0..input.len], input);
        const local = buf[0..input.len];
        // Free the text field. We do this here because the command may destroy our channel
        self.text_field.clearAndFree();
        self.completer_shown = false;

        if (std.mem.startsWith(u8, local, "/")) {
            try self.app.handleCommand(.{ .client = self }, local);
        }
        ctx.redraw = true;
    }

    /// Closes the connection
    pub fn close(self: *Client) void {
        if (self.status.load(.acquire) == .disconnected) return;
        if (self.config.tls) {
            self.client.close() catch {};
        }
        std.posix.shutdown(self.stream.handle, .both) catch {};
        self.stream.close();
    }

    pub fn deinit(self: *Client) void {
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }

        self.config.deinit(self.alloc);

        for (self.channels.items) |channel| {
            channel.deinit(self.alloc);
            self.alloc.destroy(channel);
        }
        self.channels.deinit();

        self.list_modal.deinit(self.alloc);
        for (self.messages.items) |msg| {
            self.alloc.free(msg.bytes);
        }
        self.messages.deinit(self.alloc);

        var user_iter = self.users.valueIterator();
        while (user_iter.next()) |user| {
            user.*.deinit(self.alloc);
            self.alloc.destroy(user.*);
        }
        self.users.deinit();
        self.alloc.free(self.supports.prefix);
        var batches = self.batches;
        var iter = batches.keyIterator();
        while (iter.next()) |key| {
            self.alloc.free(key.*);
        }
        batches.deinit();
        self.read_buf.deinit();
    }

    fn retryWidget(self: *Client) vxfw.Widget {
        return .{
            .userdata = self,
            .eventHandler = Client.retryTickHandler,
            .drawFn = Client.typeErasedDrawNameSelected,
        };
    }

    pub fn retryTickHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const self: *Client = @ptrCast(@alignCast(ptr));
        switch (event) {
            .tick => {
                const status = self.status.load(.acquire);
                switch (status) {
                    .disconnected => {
                        // Clean up a thread if we have one
                        if (self.thread) |thread| {
                            thread.join();
                            self.thread = null;
                        }
                        self.status.store(.connecting, .release);
                        self.thread = try std.Thread.spawn(.{}, Client.readThread, .{self});
                    },
                    .connecting => {},
                    .connected => {
                        // Reset the delay
                        self.retry_delay_s = 0;
                        return;
                    },
                }
                // Increment the retry and try again
                self.retry_delay_s = @max(self.retry_delay_s <<| 1, 1);
                log.debug("retry in {d} seconds", .{self.retry_delay_s});
                try ctx.tick(@as(u32, self.retry_delay_s) * std.time.ms_per_s, self.retryWidget());
            },
            else => {},
        }
    }

    pub fn view(self: *Client) vxfw.Widget {
        return .{
            .userdata = self,
            .eventHandler = Client.eventHandler,
            .drawFn = Client.typeErasedViewDraw,
        };
    }

    fn eventHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        _ = ptr;
        _ = ctx;
        _ = event;
    }

    fn typeErasedViewDraw(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
        const self: *Client = @ptrCast(@alignCast(ptr));
        const max = ctx.max.size();

        var children = std.ArrayList(vxfw.SubSurface).init(ctx.arena);
        {
            const message_view_ctx = ctx.withConstraints(ctx.min, .{
                .height = max.height - 2,
                .width = max.width,
            });
            const s = try self.drawMessageView(message_view_ctx);
            try children.append(.{
                .origin = .{ .col = 0, .row = 0 },
                .surface = s,
            });
        }

        {
            // Draw the character limit. 14 is length of message overhead "PRIVMSG  :\r\n"
            const max_limit = 510;
            const limit = try std.fmt.allocPrint(
                ctx.arena,
                " {d}/{d}",
                .{ self.text_field.buf.realLength(), max_limit },
            );
            const style: vaxis.Style = if (self.text_field.buf.realLength() > max_limit)
                .{ .fg = .{ .index = 1 }, .reverse = true }
            else
                .{ .bg = self.app.blendBg(30) };
            const limit_text: vxfw.Text = .{ .text = limit, .style = style };
            const limit_ctx = ctx.withConstraints(.{ .width = @intCast(limit.len) }, ctx.max);
            const limit_s = try limit_text.draw(limit_ctx);

            try children.append(.{
                .origin = .{ .col = max.width -| limit_s.size.width, .row = max.height - 1 },
                .surface = limit_s,
            });

            const text_field_ctx = ctx.withConstraints(
                ctx.min,
                .{ .height = 1, .width = max.width -| limit_s.size.width },
            );

            // Draw the text field
            try children.append(.{
                .origin = .{ .col = 0, .row = max.height - 1 },
                .surface = try self.text_field.draw(text_field_ctx),
            });
            // Write some placeholder text if we don't have anything in the text field
            if (self.text_field.buf.realLength() == 0) {
                const text = try std.fmt.allocPrint(ctx.arena, "Message {s}", .{self.serverName()});
                var text_style = self.text_field.style;
                text_style.italic = true;
                text_style.dim = true;
                var ghost_text_ctx = text_field_ctx;
                ghost_text_ctx.max.width = text_field_ctx.max.width.? -| 2;
                const ghost_text: vxfw.Text = .{ .text = text, .style = text_style };
                try children.append(.{
                    .origin = .{ .col = 2, .row = max.height - 1 },
                    .surface = try ghost_text.draw(ghost_text_ctx),
                });
            }
        }
        return .{
            .widget = self.view(),
            .size = max,
            .buffer = &.{},
            .children = children.items,
        };
    }

    pub fn serverName(self: *Client) []const u8 {
        return self.config.name orelse self.config.server;
    }

    pub fn nameWidget(self: *Client, selected: bool) vxfw.Widget {
        return .{
            .userdata = self,
            .eventHandler = Client.typeErasedEventHandler,
            .drawFn = if (selected)
                Client.typeErasedDrawNameSelected
            else
                Client.typeErasedDrawName,
        };
    }

    pub fn drawName(self: *Client, ctx: vxfw.DrawContext, selected: bool) Allocator.Error!vxfw.Surface {
        var style: vaxis.Style = .{};
        if (selected) style.reverse = true;
        if (self.has_mouse) style.bg = .{ .index = 8 };
        if (self.status.load(.acquire) == .disconnected) style.fg = .{ .index = 8 };

        const name = self.config.name orelse self.config.server;

        const text: vxfw.RichText = .{
            .text = &.{
                .{ .text = name, .style = style },
            },
            .softwrap = false,
        };
        var surface = try text.draw(ctx);
        // Replace the widget reference so we can handle the events
        surface.widget = self.nameWidget(selected);
        return surface;
    }

    fn typeErasedDrawName(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
        const self: *Client = @ptrCast(@alignCast(ptr));
        return self.drawName(ctx, false);
    }

    fn typeErasedDrawNameSelected(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
        const self: *Client = @ptrCast(@alignCast(ptr));
        return self.drawName(ctx, true);
    }

    fn typeErasedEventHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const self: *Client = @ptrCast(@alignCast(ptr));
        switch (event) {
            .mouse => |mouse| {
                try ctx.setMouseShape(.pointer);
                if (mouse.type == .press and mouse.button == .left) {
                    self.app.selectBuffer(.{ .client = self });
                    const buf = &self.app.title_buf;
                    const suffix = " - comlink";
                    const name = self.config.name orelse self.config.server;
                    if (name.len + suffix.len <= buf.len) {
                        const title = try std.fmt.bufPrint(buf, "{s}{s}", .{ name, suffix });
                        try ctx.setTitle(title);
                    } else {
                        const title = try std.fmt.bufPrint(
                            buf,
                            "{s}{s}",
                            .{ name[0 .. buf.len - suffix.len], suffix },
                        );
                        try ctx.setTitle(title);
                    }
                    return ctx.consumeAndRedraw();
                }
            },
            .mouse_enter => {
                try ctx.setMouseShape(.pointer);
                self.has_mouse = true;
            },
            .mouse_leave => {
                try ctx.setMouseShape(.default);
                self.has_mouse = false;
            },
            else => {},
        }
    }

    pub fn drainFifo(self: *Client, ctx: *vxfw.EventContext) void {
        self.read_buf_mutex.lock();
        defer self.read_buf_mutex.unlock();
        var i: usize = 0;
        while (std.mem.indexOfPos(u8, self.read_buf.items, i, "\r\n")) |idx| {
            defer i = idx + 2;
            log.debug("[<-{s}] {s}", .{
                self.config.name orelse self.config.server,
                self.read_buf.items[i..idx],
            });
            self.handleEvent(self.read_buf.items[i..idx], ctx) catch |err| {
                log.err("error: {}", .{err});
            };
        }
        self.read_buf.replaceRangeAssumeCapacity(0, i, "");
    }

    // Checks if any channel has an expired typing status. The typing status is considered expired
    // if the last typing status received is more than 6 seconds ago. In this case, we set the last
    // typing time to 0 and redraw.
    pub fn checkTypingStatus(self: *Client, ctx: *vxfw.EventContext) void {
        // We only care about typing tags if we have the message-tags cap
        if (!self.caps.@"message-tags") return;
        const now: u32 = @intCast(std.time.timestamp());
        for (self.channels.items) |channel| {
            // If the last_active is set, and it is more than 6 seconds ago, we will redraw
            if (channel.typing_last_active != 0 and channel.typing_last_active + 6 < now) {
                channel.typing_last_active = 0;
                ctx.redraw = true;
            }
        }
    }

    pub fn handleEvent(self: *Client, line: []const u8, ctx: *vxfw.EventContext) !void {
        const msg = Message.init(line);
        const client = self;
        switch (msg.command()) {
            .unknown => {
                const msg2 = try msg.dupe(self.alloc);
                try self.messages.append(self.alloc, msg2);
            },
            .PONG => {},
            .CAP => {
                const msg2 = try msg.dupe(self.alloc);
                try self.messages.append(self.alloc, msg2);
                // syntax: <client> <ACK/NACK> :caps
                var iter = msg.paramIterator();
                _ = iter.next() orelse return; // client
                const ack_or_nak = iter.next() orelse return;
                const caps = iter.next() orelse return;
                var cap_iter = mem.splitScalar(u8, caps, ' ');
                while (cap_iter.next()) |cap| {
                    if (mem.eql(u8, ack_or_nak, "ACK")) {
                        client.ack(cap);
                        if (mem.eql(u8, cap, "sasl"))
                            try client.queueWrite("AUTHENTICATE PLAIN\r\n");
                    } else if (mem.eql(u8, ack_or_nak, "NAK")) {
                        log.debug("CAP not supported {s}", .{cap});
                    } else if (mem.eql(u8, ack_or_nak, "DEL")) {
                        client.del(cap);
                    }
                }
            },
            .AUTHENTICATE => {
                var iter = msg.paramIterator();
                while (iter.next()) |param| {
                    // A '+' is the continuuation to send our
                    // AUTHENTICATE info
                    if (!mem.eql(u8, param, "+")) continue;
                    var buf: [4096]u8 = undefined;
                    const config = client.config;
                    const sasl = try std.fmt.bufPrint(
                        &buf,
                        "{s}\x00{s}\x00{s}",
                        .{ config.user, config.user, config.password },
                    );

                    // Create a buffer big enough for the base64 encoded string
                    const b64_buf = try self.alloc.alloc(u8, Base64Encoder.calcSize(sasl.len));
                    defer self.alloc.free(b64_buf);
                    const encoded = Base64Encoder.encode(b64_buf, sasl);
                    // Make our message
                    const auth = try std.fmt.bufPrint(
                        &buf,
                        "AUTHENTICATE {s}\r\n",
                        .{encoded},
                    );
                    try client.queueWrite(auth);
                    if (config.network_id) |id| {
                        const bind = try std.fmt.bufPrint(
                            &buf,
                            "BOUNCER BIND {s}\r\n",
                            .{id},
                        );
                        try client.queueWrite(bind);
                    }
                    try client.queueWrite("CAP END\r\n");
                }
            },
            .RPL_WELCOME => {
                const msg2 = try msg.dupe(self.alloc);
                try self.messages.append(self.alloc, msg2);
                const now = try zeit.instant(.{});
                var now_buf: [30]u8 = undefined;
                const now_fmt = try now.time().bufPrint(&now_buf, .rfc3339);

                const past = try now.subtract(.{ .days = 7 });
                var past_buf: [30]u8 = undefined;
                const past_fmt = try past.time().bufPrint(&past_buf, .rfc3339);

                var buf: [128]u8 = undefined;
                const targets = try std.fmt.bufPrint(
                    &buf,
                    "CHATHISTORY TARGETS timestamp={s} timestamp={s} 50\r\n",
                    .{ now_fmt, past_fmt },
                );
                try client.queueWrite(targets);
                // on_connect callback
                try lua.onConnect(self.app.lua, client);
            },
            .RPL_YOURHOST => {
                const msg2 = try msg.dupe(self.alloc);
                try self.messages.append(self.alloc, msg2);
            },
            .RPL_CREATED => {
                const msg2 = try msg.dupe(self.alloc);
                try self.messages.append(self.alloc, msg2);
            },
            .RPL_MYINFO => {
                const msg2 = try msg.dupe(self.alloc);
                try self.messages.append(self.alloc, msg2);
            },
            .RPL_ISUPPORT => {
                const msg2 = try msg.dupe(self.alloc);
                try self.messages.append(self.alloc, msg2);
                // syntax: <client> <token>[ <token>] :are supported
                var iter = msg.paramIterator();
                _ = iter.next() orelse return; // client
                while (iter.next()) |token| {
                    if (mem.eql(u8, token, "WHOX"))
                        client.supports.whox = true
                    else if (mem.startsWith(u8, token, "PREFIX")) {
                        const prefix = blk: {
                            const idx = mem.indexOfScalar(u8, token, ')') orelse
                                // default is "@+"
                                break :blk try self.alloc.dupe(u8, "@+");
                            break :blk try self.alloc.dupe(u8, token[idx + 1 ..]);
                        };
                        client.supports.prefix = prefix;
                    } else if (mem.startsWith(u8, token, "CHATHISTORY")) {
                        const idx = mem.indexOfScalar(u8, token, '=') orelse continue;
                        const limit_str = token[idx + 1 ..];
                        client.supports.chathistory = std.fmt.parseUnsigned(u16, limit_str, 10) catch 50;
                    }
                }
            },
            .RPL_LOGGEDIN => {
                const msg2 = try msg.dupe(self.alloc);
                try self.messages.append(self.alloc, msg2);
            },
            .RPL_TOPIC => {
                // syntax: <client> <channel> :<topic>
                var iter = msg.paramIterator();
                _ = iter.next() orelse return; // client ("*")
                const channel_name = iter.next() orelse return; // channel
                const topic = iter.next() orelse return; // topic

                var channel = try client.getOrCreateChannel(channel_name);
                if (channel.topic) |old_topic| {
                    self.alloc.free(old_topic);
                }
                channel.topic = try self.alloc.dupe(u8, topic);
            },
            .RPL_TRYAGAIN => {
                const msg2 = try msg.dupe(self.alloc);
                try self.messages.append(self.alloc, msg2);
                if (self.list_modal.expecting_response) {
                    self.list_modal.expecting_response = false;
                    try self.list_modal.finish(ctx);
                }
            },
            .RPL_LISTSTART => try self.list_modal.reset(),
            .RPL_LIST => {
                // We might not always get a RPL_LISTSTART, so we check if we have a list already
                // and if it needs reseting
                if (self.list_modal.finished) {
                    try self.list_modal.reset();
                }
                self.list_modal.expecting_response = false;
                try self.list_modal.addMessage(self.alloc, msg);
            },
            .RPL_LISTEND => try self.list_modal.finish(ctx),
            .RPL_SASLSUCCESS => {
                const msg2 = try msg.dupe(self.alloc);
                try self.messages.append(self.alloc, msg2);
            },
            .RPL_WHOREPLY => {
                // syntax: <client> <channel> <username> <host> <server> <nick> <flags> :<hopcount> <real name>
                var iter = msg.paramIterator();
                _ = iter.next() orelse return; // client
                const channel_name = iter.next() orelse return; // channel
                if (mem.eql(u8, channel_name, "*")) return;
                _ = iter.next() orelse return; // username
                _ = iter.next() orelse return; // host
                _ = iter.next() orelse return; // server
                const nick = iter.next() orelse return; // nick
                const flags = iter.next() orelse return; // flags

                const user_ptr = try client.getOrCreateUser(nick);
                if (mem.indexOfScalar(u8, flags, 'G')) |_| user_ptr.away = true;
                var channel = try client.getOrCreateChannel(channel_name);

                const prefix = for (flags) |c| {
                    if (std.mem.indexOfScalar(u8, client.supports.prefix, c)) |_| {
                        break c;
                    }
                } else ' ';

                try channel.addMember(user_ptr, .{ .prefix = prefix });
            },
            .RPL_WHOSPCRPL => {
                // syntax: <client> <channel> <nick> <flags> :<realname>
                var iter = msg.paramIterator();
                _ = iter.next() orelse return;
                const channel_name = iter.next() orelse return; // channel
                const nick = iter.next() orelse return;
                const flags = iter.next() orelse return;

                const user_ptr = try client.getOrCreateUser(nick);
                if (iter.next()) |real_name| {
                    if (user_ptr.real_name) |old_name| {
                        self.alloc.free(old_name);
                    }
                    user_ptr.real_name = try self.alloc.dupe(u8, real_name);
                }
                if (mem.indexOfScalar(u8, flags, 'G')) |_| user_ptr.away = true;
                var channel = try client.getOrCreateChannel(channel_name);

                const prefix = for (flags) |c| {
                    if (std.mem.indexOfScalar(u8, client.supports.prefix, c)) |_| {
                        break c;
                    }
                } else ' ';

                try channel.addMember(user_ptr, .{ .prefix = prefix });
            },
            .RPL_ENDOFWHO => {
                // syntax: <client> <mask> :End of WHO list
                var iter = msg.paramIterator();
                _ = iter.next() orelse return; // client
                const channel_name = iter.next() orelse return; // channel
                if (mem.eql(u8, channel_name, "*")) return;
                var channel = try client.getOrCreateChannel(channel_name);
                channel.in_flight.who = false;
                ctx.redraw = true;
            },
            .RPL_NAMREPLY => {
                // syntax: <client> <symbol> <channel> :[<prefix>]<nick>{ [<prefix>]<nick>}
                var iter = msg.paramIterator();
                _ = iter.next() orelse return; // client
                _ = iter.next() orelse return; // symbol
                const channel_name = iter.next() orelse return; // channel
                const names = iter.next() orelse return;
                var channel = try client.getOrCreateChannel(channel_name);
                var name_iter = std.mem.splitScalar(u8, names, ' ');
                while (name_iter.next()) |name| {
                    const nick, const prefix = for (client.supports.prefix) |ch| {
                        if (name[0] == ch) {
                            break .{ name[1..], name[0] };
                        }
                    } else .{ name, ' ' };

                    if (prefix != ' ') {
                        log.debug("HAS PREFIX {s}", .{name});
                    }

                    const user_ptr = try client.getOrCreateUser(nick);

                    try channel.addMember(user_ptr, .{ .prefix = prefix, .sort = false });
                }

                channel.sortMembers();
            },
            .RPL_ENDOFNAMES => {
                // syntax: <client> <channel> :End of /NAMES list
                var iter = msg.paramIterator();
                _ = iter.next() orelse return; // client
                const channel_name = iter.next() orelse return; // channel
                var channel = try client.getOrCreateChannel(channel_name);
                channel.in_flight.names = false;
                ctx.redraw = true;
            },
            .BOUNCER => {
                const msg2 = try msg.dupe(self.alloc);
                try self.messages.append(self.alloc, msg2);
                var iter = msg.paramIterator();
                while (iter.next()) |param| {
                    if (mem.eql(u8, param, "NETWORK")) {
                        const id = iter.next() orelse continue;
                        const attr = iter.next() orelse continue;
                        // check if we already have this network
                        for (self.app.clients.items, 0..) |cl, i| {
                            if (cl.config.network_id) |net_id| {
                                if (mem.eql(u8, net_id, id)) {
                                    if (mem.eql(u8, attr, "*")) {
                                        // * means the network was
                                        // deleted
                                        cl.deinit();
                                        _ = self.app.clients.swapRemove(i);
                                    }
                                    return;
                                }
                            }
                        }

                        var cfg = try client.config.copy(self.alloc);
                        cfg.network_id = try self.app.alloc.dupe(u8, id);

                        var attr_iter = std.mem.splitScalar(u8, attr, ';');
                        while (attr_iter.next()) |kv| {
                            const n = std.mem.indexOfScalar(u8, kv, '=') orelse continue;
                            const key = kv[0..n];
                            if (mem.eql(u8, key, "name"))
                                cfg.name = try self.alloc.dupe(u8, kv[n + 1 ..])
                            else if (mem.eql(u8, key, "nickname"))
                                cfg.network_nick = try self.alloc.dupe(u8, kv[n + 1 ..]);
                        }
                        try self.app.connect(cfg);
                        ctx.redraw = true;
                    }
                }
            },
            .AWAY => {
                const src = msg.source() orelse return;
                var iter = msg.paramIterator();
                const n = std.mem.indexOfScalar(u8, src, '!') orelse src.len;
                const user = try client.getOrCreateUser(src[0..n]);
                // If there are any params, the user is away. Otherwise
                // they are back.
                user.away = if (iter.next()) |_| true else false;
                ctx.redraw = true;
            },
            .BATCH => {
                var iter = msg.paramIterator();
                const tag = iter.next() orelse return;
                switch (tag[0]) {
                    '+' => {
                        const batch_type = iter.next() orelse return;
                        if (mem.eql(u8, batch_type, "chathistory")) {
                            const target = iter.next() orelse return;
                            var channel = try client.getOrCreateChannel(target);
                            channel.at_oldest = true;
                            const duped_tag = try self.alloc.dupe(u8, tag[1..]);
                            try client.batches.put(duped_tag, channel);
                        }
                    },
                    '-' => {
                        const key = client.batches.getKey(tag[1..]) orelse return;
                        var chan = client.batches.get(key) orelse @panic("key should exist here");
                        chan.history_requested = false;
                        _ = client.batches.remove(key);
                        self.alloc.free(key);
                        ctx.redraw = true;
                    },
                    else => {},
                }
            },
            .CHATHISTORY => {
                var iter = msg.paramIterator();
                const should_targets = iter.next() orelse return;
                if (!mem.eql(u8, should_targets, "TARGETS")) return;
                const target = iter.next() orelse return;
                // we only add direct messages, not more channels
                assert(target.len > 0);
                if (target[0] == '#') return;

                var channel = try client.getOrCreateChannel(target);
                const user_ptr = try client.getOrCreateUser(target);
                const me_ptr = try client.getOrCreateUser(client.nickname());
                try channel.addMember(user_ptr, .{});
                try channel.addMember(me_ptr, .{});
                // we set who_requested so we don't try to request
                // who on DMs
                channel.who_requested = true;
                var buf: [128]u8 = undefined;
                const mark_read = try std.fmt.bufPrint(
                    &buf,
                    "MARKREAD {s}\r\n",
                    .{channel.name},
                );
                try client.queueWrite(mark_read);
                try client.requestHistory(.after, channel);
            },
            .JOIN => {
                // get the user
                const src = msg.source() orelse return;
                const n = std.mem.indexOfScalar(u8, src, '!') orelse src.len;
                const user = try client.getOrCreateUser(src[0..n]);

                // get the channel
                var iter = msg.paramIterator();
                const target = iter.next() orelse return;
                var channel = try client.getOrCreateChannel(target);

                const trimmed_nick = std.mem.trimRight(u8, user.nick, "_");
                // If it's our nick, we request chat history
                if (mem.eql(u8, trimmed_nick, client.nickname())) {
                    try client.requestHistory(.after, channel);
                    if (self.app.explicit_join) {
                        self.app.selectChannelName(client, target);
                        self.app.explicit_join = false;
                    }
                } else try channel.addMember(user, .{});
                ctx.redraw = true;
            },
            .MARKREAD => {
                var iter = msg.paramIterator();
                const target = iter.next() orelse return;
                const timestamp = iter.next() orelse return;
                const equal = std.mem.indexOfScalar(u8, timestamp, '=') orelse return;
                const last_read = zeit.instant(.{
                    .source = .{
                        .iso8601 = timestamp[equal + 1 ..],
                    },
                }) catch |err| {
                    log.err("couldn't convert timestamp: {}", .{err});
                    return;
                };
                var channel = try client.getOrCreateChannel(target);
                channel.last_read = @intCast(last_read.unixTimestamp());
                const last_msg = channel.messages.getLastOrNull() orelse return;
                channel.has_unread = last_msg.timestamp_s > channel.last_read;
                if (!channel.has_unread) {
                    channel.has_unread_highlight = false;
                }
                ctx.redraw = true;
            },
            .PART => {
                // get the user
                const src = msg.source() orelse return;
                const n = std.mem.indexOfScalar(u8, src, '!') orelse src.len;
                const user = try client.getOrCreateUser(src[0..n]);

                // get the channel
                var iter = msg.paramIterator();
                const target = iter.next() orelse return;

                if (mem.eql(u8, user.nick, client.nickname())) {
                    for (client.channels.items, 0..) |channel, i| {
                        if (!mem.eql(u8, channel.name, target)) continue;
                        client.app.prevChannel();
                        var chan = client.channels.orderedRemove(i);
                        chan.deinit(self.app.alloc);
                        self.alloc.destroy(chan);
                        break;
                    }
                } else {
                    const channel = try client.getOrCreateChannel(target);
                    channel.removeMember(user);
                }
                ctx.redraw = true;
            },
            .PRIVMSG, .NOTICE => {
                ctx.redraw = true;
                // syntax: <target> :<message>
                const msg2 = Message.init(try self.app.alloc.dupe(u8, msg.bytes));

                // We handle batches separately. When we encounter a PRIVMSG from a batch, we use
                // the original target from the batch start. We also never notify from a batched
                // message. Batched messages also require sorting
                if (msg2.getTag("batch")) |tag| {
                    const entry = client.batches.getEntry(tag) orelse @panic("TODO");
                    var channel = entry.value_ptr.*;
                    try channel.insertMessage(msg2);
                    std.sort.insertion(Message, channel.messages.items, {}, Message.compareTime);
                    // We are probably adding at the top. Add to our msg_offset if we have one to
                    // prevent scroll
                    if (channel.scroll.msg_offset) |offset| {
                        channel.scroll.msg_offset = offset + 1;
                    }
                    channel.at_oldest = false;
                    return;
                }

                var iter = msg2.paramIterator();
                const target = blk: {
                    const tgt = iter.next() orelse return;
                    if (mem.eql(u8, tgt, client.nickname())) {
                        // If the target is us, we use the sender nick as the identifier
                        break :blk msg2.senderNick() orelse unreachable;
                    } else break :blk tgt;
                };
                // Get the channel
                var channel = try client.getOrCreateChannel(target);
                // Add the message to the channel. We don't need to sort because these come
                // chronologically
                try channel.insertMessage(msg2);

                // Get values for our lua callbacks
                const content = iter.next() orelse return;
                const sender = msg2.senderNick() orelse "";

                // Do the lua callback
                try lua.onMessage(self.app.lua, client, channel.name, sender, content);

                // Send a notification if this has our nick
                if (msg2.containsPhrase(client.nickname())) {
                    var buf: [64]u8 = undefined;
                    const title_or_err = if (sender.len > 0)
                        std.fmt.bufPrint(&buf, "{s} - {s}", .{ channel.name, sender })
                    else
                        std.fmt.bufPrint(&buf, "{s}", .{channel.name});
                    const title = title_or_err catch title: {
                        const len = @min(buf.len, channel.name.len);
                        @memcpy(buf[0..len], channel.name[0..len]);
                        break :title buf[0..len];
                    };
                    try ctx.sendNotification(title, content);
                }

                if (client.caps.@"message-tags") {
                    // Set the typing time to 0. We only need to do this when the server
                    // supports message-tags
                    for (channel.members.items) |*member| {
                        if (!std.mem.eql(u8, member.user.nick, sender)) {
                            continue;
                        }
                        member.typing = 0;
                        break;
                    }
                }
            },
            .TAGMSG => {
                const msg2 = Message.init(msg.bytes);
                // We only care about typing tags
                const typing = msg2.getTag("+typing") orelse return;

                var iter = msg2.paramIterator();
                const target = blk: {
                    const tgt = iter.next() orelse return;
                    if (mem.eql(u8, tgt, client.nickname())) {
                        // If the target is us, it likely has our
                        // hostname in it.
                        const source = msg2.source() orelse return;
                        const n = mem.indexOfScalar(u8, source, '!') orelse source.len;
                        break :blk source[0..n];
                    } else break :blk tgt;
                };
                const sender: []const u8 = blk: {
                    const src = msg2.source() orelse break :blk "";
                    const l = std.mem.indexOfScalar(u8, src, '!') orelse
                        std.mem.indexOfScalar(u8, src, '@') orelse
                        src.len;
                    break :blk src[0..l];
                };
                const sender_trimmed = std.mem.trimRight(u8, sender, "_");
                if (std.mem.eql(u8, sender_trimmed, client.nickname())) {
                    // We never considuer ourselves as typing
                    return;
                }
                const channel = try client.getOrCreateChannel(target);

                for (channel.members.items) |*member| {
                    if (!std.mem.eql(u8, member.user.nick, sender)) {
                        continue;
                    }
                    if (std.mem.eql(u8, "done", typing)) {
                        member.typing = 0;
                        ctx.redraw = true;
                        return;
                    }
                    if (std.mem.eql(u8, "active", typing)) {
                        member.typing = msg2.timestamp_s;
                        channel.typing_last_active = member.typing;
                        ctx.redraw = true;
                        return;
                    }
                }
            },
        }
    }

    pub fn nickname(self: *Client) []const u8 {
        return self.config.network_nick orelse self.config.nick;
    }

    pub fn del(self: *Client, cap: []const u8) void {
        const info = @typeInfo(Capabilities);
        assert(info == .@"struct");

        inline for (info.@"struct".fields) |field| {
            if (std.mem.eql(u8, field.name, cap)) {
                @field(self.caps, field.name) = false;
                return;
            }
        }
    }

    pub fn ack(self: *Client, cap: []const u8) void {
        const info = @typeInfo(Capabilities);
        assert(info == .@"struct");

        inline for (info.@"struct".fields) |field| {
            if (std.mem.eql(u8, field.name, cap)) {
                @field(self.caps, field.name) = true;
                return;
            }
        }
    }

    pub fn read(self: *Client, buf: []u8) !usize {
        switch (self.config.tls) {
            true => return self.client.read(buf),
            false => return self.stream.read(buf),
        }
    }

    fn warn(self: *Client, comptime fmt: []const u8, args: anytype) void {
        self.read_buf.appendSlice(":comlink WARN ") catch {};
        self.read_buf.writer().print(fmt, args) catch {};
        self.read_buf.appendSlice("\r\n") catch {};
    }

    pub fn readThread(self: *Client) void {
        defer self.status.store(.disconnected, .release);

        // We push this off to another function that can enforces it only fails for allocation
        // errors
        self._readThread() catch |err| {
            switch (err) {
                error.OutOfMemory => {},
            }
            log.err("out of memory", .{});
        };
    }

    fn _readThread(self: *Client) Allocator.Error!void {
        self.connect() catch |err| {
            self.warn("* CONNECTION_ERROR :Error while connecting to server: {}", .{err});
            return;
        };
        try self.queueWrite("CAP LS 302\r\n");

        const cap_names = std.meta.fieldNames(Capabilities);
        for (cap_names) |cap| {
            try self.print("CAP REQ :{s}\r\n", .{cap});
        }

        try self.print("NICK {s}\r\n", .{self.config.nick});

        const real_name = if (self.config.real_name.len > 0)
            self.config.real_name
        else
            self.config.nick;
        try self.print("USER {s} 0 * :{s}\r\n", .{ self.config.user, real_name });

        var buf: [4096]u8 = undefined;
        var retries: u8 = 0;
        while (true) {
            const n = self.read(&buf) catch |err| {
                // WouldBlock means our socket timeout expired
                switch (err) {
                    error.WouldBlock => {},
                    else => {
                        self.warn("* CONNECTION_ERROR :{}", .{err});
                        return;
                    },
                }

                if (retries == keepalive_retries) {
                    log.debug("[{s}] connection closed", .{self.config.name orelse self.config.server});
                    self.close();
                    return;
                }

                if (retries == 0) {
                    self.configureKeepalive(keepalive_interval) catch |err2| {
                        self.warn("* INTERNAL_ERROR :Couldn't configure socket: {}", .{err2});
                        return;
                    };
                }
                retries += 1;
                try self.queueWrite("PING comlink\r\n");
                continue;
            };
            if (n == 0) return;

            // If we did a connection retry, we reset the state
            if (retries > 0) {
                retries = 0;
                self.configureKeepalive(keepalive_idle) catch |err2| {
                    self.warn("* INTERNAL_ERROR :Couldn't configure socket: {}", .{err2});
                    return;
                };
            }
            self.read_buf_mutex.lock();
            defer self.read_buf_mutex.unlock();
            try self.read_buf.appendSlice(buf[0..n]);
        }
    }

    pub fn print(self: *Client, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
        const msg = try std.fmt.allocPrint(self.alloc, fmt, args);
        self.write_queue.push(.{ .write = .{
            .client = self,
            .msg = msg,
        } });
    }

    /// push a write request into the queue. The request should include the trailing
    /// '\r\n'. queueWrite will dupe the message and free after processing.
    pub fn queueWrite(self: *Client, msg: []const u8) Allocator.Error!void {
        self.write_queue.push(.{ .write = .{
            .client = self,
            .msg = try self.alloc.dupe(u8, msg),
        } });
    }

    pub fn write(self: *Client, buf: []const u8) !void {
        assert(std.mem.endsWith(u8, buf, "\r\n"));
        if (self.status.load(.acquire) == .disconnected) {
            log.warn("disconnected: dropping write: {s}", .{buf[0 .. buf.len - 2]});
            return;
        }
        log.debug("[->{s}] {s}", .{ self.config.name orelse self.config.server, buf[0 .. buf.len - 2] });
        switch (self.config.tls) {
            true => try self.client.writeAll(buf),
            false => try self.stream.writeAll(buf),
        }
    }

    pub fn connect(self: *Client) !void {
        if (self.config.tls) {
            const port: u16 = self.config.port orelse 6697;
            self.stream = try tcpConnectToHost(self.alloc, self.config.server, port);
            self.client = try tls.client(self.stream, .{
                .host = self.config.server,
                .root_ca = .{ .bundle = self.app.bundle },
            });
        } else {
            const port: u16 = self.config.port orelse 6667;
            self.stream = try std.net.tcpConnectToHost(self.alloc, self.config.server, port);
        }
        self.status.store(.connected, .release);

        try self.configureKeepalive(keepalive_idle);
    }

    pub fn configureKeepalive(self: *Client, seconds: i32) !void {
        const timeout = std.mem.toBytes(std.posix.timeval{
            .sec = seconds,
            .usec = 0,
        });

        try std.posix.setsockopt(
            self.stream.handle,
            std.posix.SOL.SOCKET,
            std.posix.SO.RCVTIMEO,
            &timeout,
        );
    }

    pub fn getOrCreateChannel(self: *Client, name: []const u8) Allocator.Error!*Channel {
        for (self.channels.items) |channel| {
            if (caseFold(name, channel.name)) return channel;
        }
        const channel = try self.alloc.create(Channel);
        try channel.init(self.alloc, self, name, self.app.unicode);
        try self.channels.append(channel);

        std.sort.insertion(*Channel, self.channels.items, {}, Channel.compare);
        return channel;
    }

    var color_indices = [_]u8{ 1, 2, 3, 4, 5, 6, 9, 10, 11, 12, 13, 14 };

    pub fn getOrCreateUser(self: *Client, nick: []const u8) Allocator.Error!*User {
        return self.users.get(nick) orelse {
            const color_u32 = std.hash.Fnv1a_32.hash(nick);
            const index = color_u32 % color_indices.len;
            const color_index = color_indices[index];

            const color: vaxis.Color = .{
                .index = color_index,
            };
            const user = try self.alloc.create(User);
            user.* = .{
                .nick = try self.alloc.dupe(u8, nick),
                .color = color,
            };
            try self.users.put(user.nick, user);
            return user;
        };
    }

    pub fn whox(self: *Client, channel: *Channel) !void {
        channel.who_requested = true;
        if (channel.name.len > 0 and
            channel.name[0] != '#')
        {
            const other = try self.getOrCreateUser(channel.name);
            const me = try self.getOrCreateUser(self.config.nick);
            try channel.addMember(other, .{});
            try channel.addMember(me, .{});
            return;
        }
        // Only use WHO if we have WHOX and away-notify. Without
        // WHOX, we can get rate limited on eg. libera. Without
        // away-notify, our list will become stale
        if (self.supports.whox and
            self.caps.@"away-notify" and
            !channel.in_flight.who)
        {
            channel.in_flight.who = true;
            try self.print(
                "WHO {s} %cnfr\r\n",
                .{channel.name},
            );
        } else {
            channel.in_flight.names = true;
            try self.print(
                "NAMES {s}\r\n",
                .{channel.name},
            );
        }
    }

    /// fetch the history for the provided channel.
    pub fn requestHistory(
        self: *Client,
        cmd: ChatHistoryCommand,
        channel: *Channel,
    ) Allocator.Error!void {
        if (!self.caps.@"draft/chathistory") return;
        if (channel.history_requested) return;
        const max = self.supports.chathistory orelse return;

        channel.history_requested = true;

        if (channel.messages.items.len == 0) {
            try self.print(
                "CHATHISTORY LATEST {s} * {d}\r\n",
                .{ channel.name, @min(50, max) },
            );
            channel.history_requested = true;
            return;
        }

        switch (cmd) {
            .before => {
                assert(channel.messages.items.len > 0);
                const first = channel.messages.items[0];
                const time = first.getTag("time") orelse {
                    log.warn("can't request history: no time tag", .{});
                    return;
                };
                try self.print(
                    "CHATHISTORY BEFORE {s} timestamp={s} {d}\r\n",
                    .{ channel.name, time, @min(50, max) },
                );
                channel.history_requested = true;
            },
            .after => {
                assert(channel.messages.items.len > 0);
                const last = channel.messages.getLast();
                const time = last.getTag("time") orelse {
                    log.warn("can't request history: no time tag", .{});
                    return;
                };
                try self.print(
                    // we request 500 because we have no
                    // idea how long we've been offline
                    "CHATHISTORY AFTER {s} timestamp={s} {d}\r\n",
                    .{ channel.name, time, @min(50, max) },
                );
                channel.history_requested = true;
            },
        }
    }

    fn messageViewWidget(self: *Client) vxfw.Widget {
        return .{
            .userdata = self,
            .eventHandler = Client.handleMessageViewEvent,
            .drawFn = Client.typeErasedDrawMessageView,
        };
    }

    fn handleMessageViewEvent(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const self: *Client = @ptrCast(@alignCast(ptr));
        switch (event) {
            .mouse => |mouse| {
                if (self.message_view.mouse) |last_mouse| {
                    // We need to redraw if the column entered the gutter
                    if (last_mouse.col >= gutter_width and mouse.col < gutter_width)
                        ctx.redraw = true
                            // Or if the column exited the gutter
                    else if (last_mouse.col < gutter_width and mouse.col >= gutter_width)
                        ctx.redraw = true
                            // Or if the row changed
                    else if (last_mouse.row != mouse.row)
                        ctx.redraw = true
                            // Or if we did a middle click, and now released it
                    else if (last_mouse.button == .middle)
                        ctx.redraw = true;
                } else {
                    // If we didn't have the mouse previously, we redraw
                    ctx.redraw = true;
                }

                // Save this mouse state for when we draw
                self.message_view.mouse = mouse;

                // A middle press on a hovered message means we copy the content
                if (mouse.type == .press and
                    mouse.button == .middle and
                    self.message_view.hovered_message != null)
                {
                    const msg = self.message_view.hovered_message orelse unreachable;
                    try ctx.copyToClipboard(msg.bytes);
                    return ctx.consumeAndRedraw();
                }
                if (mouse.button == .wheel_down) {
                    self.scroll.pending -|= 1;
                    ctx.consume_event = true;
                    ctx.redraw = true;
                }
                if (mouse.button == .wheel_up) {
                    self.scroll.pending +|= 1;
                    ctx.consume_event = true;
                    ctx.redraw = true;
                }
                if (self.scroll.pending != 0) {
                    try self.doScroll(ctx);
                }
            },
            .mouse_leave => {
                self.message_view.mouse = null;
                self.message_view.hovered_message = null;
                ctx.redraw = true;
            },
            .tick => {
                try self.doScroll(ctx);
            },
            else => {},
        }
    }

    fn typeErasedDrawMessageView(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
        const self: *Client = @ptrCast(@alignCast(ptr));
        return self.drawMessageView(ctx);
    }

    fn drawMessageView(self: *Client, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
        self.message_view.hovered_message = null;
        const max = ctx.max.size();
        if (max.width == 0 or max.height == 0 or self.messages.items.len == 0) {
            return .{
                .size = max,
                .widget = self.messageViewWidget(),
                .buffer = &.{},
                .children = &.{},
            };
        }

        var children = std.ArrayList(vxfw.SubSurface).init(ctx.arena);

        // Row is the row we are printing on. We add the offset to achieve our scroll location
        var row: i17 = max.height + self.scroll.offset;
        // Message offset
        const offset = self.scroll.msg_offset orelse self.messages.items.len;

        const messages = self.messages.items[0..offset];
        var iter = std.mem.reverseIterator(messages);

        assert(messages.len > 0);
        // Initialize sender and maybe_instant to the last message values
        const last_msg = iter.next() orelse unreachable;
        // Reset iter index
        iter.index += 1;
        var this_instant = last_msg.localTime(&self.app.tz);

        while (iter.next()) |msg| {
            // Break if we have gone past the top of the screen
            if (row < 0) break;

            // Get the server time for the *next* message. We'll use this to decide printing of
            // username and time
            const maybe_next_instant: ?zeit.Instant = blk: {
                const next_msg = iter.next() orelse break :blk null;
                // Fix the index of the iterator
                iter.index += 1;
                break :blk next_msg.localTime(&self.app.tz);
            };

            defer {
                // After this loop, we want to save these values for the next iteration
                if (maybe_next_instant) |next_instant| {
                    this_instant = next_instant;
                }
            }

            // Draw the message so we have it's wrapped height
            const text: vxfw.Text = .{ .text = msg.bytes };
            const child_ctx = ctx.withConstraints(
                .{ .width = max.width -| gutter_width, .height = 1 },
                .{ .width = max.width -| gutter_width, .height = null },
            );
            const surface = try text.draw(child_ctx);

            // See if our message contains the mouse. We'll highlight it if it does
            const message_has_mouse: bool = blk: {
                const mouse = self.message_view.mouse orelse break :blk false;
                break :blk mouse.col >= gutter_width and
                    mouse.row < row and
                    mouse.row >= row - surface.size.height;
            };

            if (message_has_mouse) {
                const last_mouse = self.message_view.mouse orelse unreachable;
                // If we had a middle click, we highlight yellow to indicate we copied the text
                const bg: vaxis.Color = if (last_mouse.button == .middle and last_mouse.type == .press)
                    .{ .index = 3 }
                else
                    .{ .index = 8 };
                // Set the style for the entire message
                for (surface.buffer) |*cell| {
                    cell.style.bg = bg;
                }
                // Create a surface to highlight the entire area under the message
                const hl_surface = try vxfw.Surface.init(
                    ctx.arena,
                    text.widget(),
                    .{ .width = max.width -| gutter_width, .height = surface.size.height },
                );
                const base: vaxis.Cell = .{ .style = .{ .bg = bg } };
                @memset(hl_surface.buffer, base);

                try children.append(.{
                    .origin = .{ .row = row - surface.size.height, .col = gutter_width },
                    .surface = hl_surface,
                });

                self.message_view.hovered_message = msg;
            }

            // Adjust the row we print on for the wrapped height of this message
            row -= surface.size.height;
            try children.append(.{
                .origin = .{ .row = row, .col = gutter_width },
                .surface = surface,
            });

            var style: vaxis.Style = .{ .dim = true };
            // The time text we will print
            const buf: []const u8 = blk: {
                const time = this_instant.time();
                // Check our next time. If *this* message occurs on a different day, we want to
                // print the date
                if (maybe_next_instant) |next_instant| {
                    const next_time = next_instant.time();
                    if (time.day != next_time.day) {
                        style = .{};
                        break :blk try std.fmt.allocPrint(
                            ctx.arena,
                            "{d:0>2}/{d:0>2}",
                            .{ @intFromEnum(time.month), time.day },
                        );
                    }
                }

                // if it is the first message, we also want to print the date
                if (iter.index == 0) {
                    style = .{};
                    break :blk try std.fmt.allocPrint(
                        ctx.arena,
                        "{d:0>2}/{d:0>2}",
                        .{ @intFromEnum(time.month), time.day },
                    );
                }

                // Otherwise, we print clock time
                break :blk try std.fmt.allocPrint(
                    ctx.arena,
                    "{d:0>2}:{d:0>2}",
                    .{ time.hour, time.minute },
                );
            };

            const time_text: vxfw.Text = .{
                .text = buf,
                .style = style,
                .softwrap = false,
            };
            const time_ctx = ctx.withConstraints(
                .{ .width = 0, .height = 1 },
                .{ .width = max.width -| gutter_width, .height = null },
            );
            try children.append(.{
                .origin = .{ .row = row, .col = 0 },
                .surface = try time_text.draw(time_ctx),
            });
        }

        // Set the can_scroll_up flag. this is true if we drew past the top of the screen
        self.can_scroll_up = row <= 0;
        if (row > 0) {
            row -= 1;
            // If we didn't draw past the top of the screen, we must have reached the end of
            // history. Draw an indicator letting the user know this
            const bot = "━";
            var writer = try std.ArrayList(u8).initCapacity(ctx.arena, bot.len * max.width);
            try writer.writer().writeBytesNTimes(bot, max.width);

            const border: vxfw.Text = .{
                .text = writer.items,
                .style = .{ .fg = .{ .index = 8 } },
                .softwrap = false,
            };
            const border_ctx = ctx.withConstraints(.{}, .{ .height = 1, .width = max.width });

            const unread: vxfw.SubSurface = .{
                .origin = .{ .col = 0, .row = row },
                .surface = try border.draw(border_ctx),
            };

            try children.append(unread);
            const no_more_history: vxfw.Text = .{
                .text = " Perhaps the archives are incomplete ",
                .style = .{ .fg = .{ .index = 8 } },
                .softwrap = false,
            };
            const no_history_surf = try no_more_history.draw(border_ctx);
            const new_sub: vxfw.SubSurface = .{
                .origin = .{ .col = (max.width -| no_history_surf.size.width) / 2, .row = row },
                .surface = no_history_surf,
            };
            try children.append(new_sub);
        }
        return .{
            .size = max,
            .widget = self.messageViewWidget(),
            .buffer = &.{},
            .children = children.items,
        };
    }

    /// Consumes any pending scrolls and schedules another tick if needed
    fn doScroll(self: *Client, ctx: *vxfw.EventContext) anyerror!void {
        defer {
            // At the end of this function, we anchor our msg_offset if we have any amount of
            // scroll. This prevents new messages from automatically scrolling us
            if (self.scroll.offset > 0 and self.scroll.msg_offset == null) {
                self.scroll.msg_offset = @intCast(self.messages.items.len);
            }
            // If we have no offset, we reset our anchor
            if (self.scroll.offset == 0) {
                self.scroll.msg_offset = null;
            }
        }
        const animation_tick: u32 = 30;
        // No pending scroll. Return early
        if (self.scroll.pending == 0) return;

        // Scroll up
        if (self.scroll.pending > 0) {
            // Check if we can scroll up. If we can't, we are done
            if (!self.can_scroll_up) {
                self.scroll.pending = 0;
                return;
            }
            // Consume 1 line, and schedule a tick
            self.scroll.offset += 1;
            self.scroll.pending -= 1;
            ctx.redraw = true;
            return ctx.tick(animation_tick, self.messageViewWidget());
        }

        // From here, we only scroll down. First, we check if we are at the bottom already. If we
        // are, we have nothing to do
        if (self.scroll.offset == 0) {
            // Already at bottom. Nothing to do
            self.scroll.pending = 0;
            return;
        }

        // Scroll down
        if (self.scroll.pending < 0) {
            // Consume 1 line, and schedule a tick
            self.scroll.offset -= 1;
            self.scroll.pending += 1;
            ctx.redraw = true;
            return ctx.tick(animation_tick, self.messageViewWidget());
        }
    }
};

pub fn toVaxisColor(irc: u8) vaxis.Color {
    return switch (irc) {
        0 => .default, // white
        1 => .{ .index = 0 }, // black
        2 => .{ .index = 4 }, // blue
        3 => .{ .index = 2 }, // green
        4 => .{ .index = 1 }, // red
        5 => .{ .index = 3 }, // brown
        6 => .{ .index = 5 }, // magenta
        7 => .{ .index = 11 }, // orange
        8 => .{ .index = 11 }, // yellow
        9 => .{ .index = 10 }, // light green
        10 => .{ .index = 6 }, // cyan
        11 => .{ .index = 14 }, // light cyan
        12 => .{ .index = 12 }, // light blue
        13 => .{ .index = 13 }, // pink
        14 => .{ .index = 8 }, // grey
        15 => .{ .index = 7 }, // light grey

        // 16 to 98 are specifically defined
        16 => .{ .index = 52 },
        17 => .{ .index = 94 },
        18 => .{ .index = 100 },
        19 => .{ .index = 58 },
        20 => .{ .index = 22 },
        21 => .{ .index = 29 },
        22 => .{ .index = 23 },
        23 => .{ .index = 24 },
        24 => .{ .index = 17 },
        25 => .{ .index = 54 },
        26 => .{ .index = 53 },
        27 => .{ .index = 89 },
        28 => .{ .index = 88 },
        29 => .{ .index = 130 },
        30 => .{ .index = 142 },
        31 => .{ .index = 64 },
        32 => .{ .index = 28 },
        33 => .{ .index = 35 },
        34 => .{ .index = 30 },
        35 => .{ .index = 25 },
        36 => .{ .index = 18 },
        37 => .{ .index = 91 },
        38 => .{ .index = 90 },
        39 => .{ .index = 125 },
        // TODO: finish these out https://modern.ircdocs.horse/formatting#color

        99 => .default,

        else => .{ .index = irc },
    };
}
/// generate TextSpans for the message content
fn formatMessage(
    arena: Allocator,
    user: *User,
    content: []const u8,
) Allocator.Error![]vxfw.RichText.TextSpan {
    const ColorState = enum {
        ground,
        fg,
        bg,
    };
    const LinkState = enum {
        h,
        t1,
        t2,
        p,
        s,
        colon,
        slash,
        consume,
    };

    var spans = std.ArrayList(vxfw.RichText.TextSpan).init(arena);

    var start: usize = 0;
    var i: usize = 0;
    var style: vaxis.Style = .{};
    while (i < content.len) : (i += 1) {
        const b = content[i];
        switch (b) {
            0x01 => { // https://modern.ircdocs.horse/ctcp
                if (i == 0 and
                    content.len > 7 and
                    mem.startsWith(u8, content[1..], "ACTION"))
                {
                    // get the user of this message
                    style.italic = true;
                    const user_style: vaxis.Style = .{
                        .fg = user.color,
                        .italic = true,
                    };
                    try spans.append(.{
                        .text = user.nick,
                        .style = user_style,
                    });
                    i += 6; // "ACTION"
                } else {
                    try spans.append(.{
                        .text = content[start..i],
                        .style = style,
                    });
                }
                start = i + 1;
            },
            0x02 => {
                try spans.append(.{
                    .text = content[start..i],
                    .style = style,
                });
                style.bold = !style.bold;
                start = i + 1;
            },
            0x03 => {
                try spans.append(.{
                    .text = content[start..i],
                    .style = style,
                });
                i += 1;
                var state: ColorState = .ground;
                var fg_idx: ?u8 = null;
                var bg_idx: ?u8 = null;
                while (i < content.len) : (i += 1) {
                    const d = content[i];
                    switch (state) {
                        .ground => {
                            switch (d) {
                                '0', '1', '2', '3', '4', '5', '6', '7', '8', '9' => {
                                    state = .fg;
                                    fg_idx = d - '0';
                                },
                                else => {
                                    style.fg = .default;
                                    style.bg = .default;
                                    start = i;
                                    break;
                                },
                            }
                        },
                        .fg => {
                            switch (d) {
                                '0', '1', '2', '3', '4', '5', '6', '7', '8', '9' => {
                                    const fg = fg_idx orelse 0;
                                    if (fg > 9) {
                                        style.fg = toVaxisColor(fg);
                                        start = i;
                                        break;
                                    } else {
                                        fg_idx = fg * 10 + (d - '0');
                                    }
                                },
                                else => {
                                    if (fg_idx) |fg| {
                                        style.fg = toVaxisColor(fg);
                                        start = i;
                                    }
                                    if (d == ',') state = .bg else break;
                                },
                            }
                        },
                        .bg => {
                            switch (d) {
                                '0', '1', '2', '3', '4', '5', '6', '7', '8', '9' => {
                                    const bg = bg_idx orelse 0;
                                    if (i - start == 2) {
                                        style.bg = toVaxisColor(bg);
                                        start = i;
                                        break;
                                    } else {
                                        bg_idx = bg * 10 + (d - '0');
                                    }
                                },
                                else => {
                                    if (bg_idx) |bg| {
                                        style.bg = toVaxisColor(bg);
                                        start = i;
                                    }
                                    break;
                                },
                            }
                        },
                    }
                }
            },
            0x0F => {
                try spans.append(.{
                    .text = content[start..i],
                    .style = style,
                });
                style = .{};
                start = i + 1;
            },
            0x16 => {
                try spans.append(.{
                    .text = content[start..i],
                    .style = style,
                });
                style.reverse = !style.reverse;
                start = i + 1;
            },
            0x1D => {
                try spans.append(.{
                    .text = content[start..i],
                    .style = style,
                });
                style.italic = !style.italic;
                start = i + 1;
            },
            0x1E => {
                try spans.append(.{
                    .text = content[start..i],
                    .style = style,
                });
                style.strikethrough = !style.strikethrough;
                start = i + 1;
            },
            0x1F => {
                try spans.append(.{
                    .text = content[start..i],
                    .style = style,
                });

                style.ul_style = if (style.ul_style == .off) .single else .off;
                start = i + 1;
            },
            else => {
                if (b == 'h') {
                    var state: LinkState = .h;
                    const h_start = i;
                    // consume until a space or EOF
                    i += 1;
                    while (i < content.len) : (i += 1) {
                        const b1 = content[i];
                        switch (state) {
                            .h => {
                                if (b1 == 't') state = .t1 else break;
                            },
                            .t1 => {
                                if (b1 == 't') state = .t2 else break;
                            },
                            .t2 => {
                                if (b1 == 'p') state = .p else break;
                            },
                            .p => {
                                if (b1 == 's')
                                    state = .s
                                else if (b1 == ':')
                                    state = .colon
                                else
                                    break;
                            },
                            .s => {
                                if (b1 == ':') state = .colon else break;
                            },
                            .colon => {
                                if (b1 == '/') state = .slash else break;
                            },
                            .slash => {
                                if (b1 == '/') {
                                    state = .consume;
                                    try spans.append(.{
                                        .text = content[start..h_start],
                                        .style = style,
                                    });
                                    start = h_start;
                                } else break;
                            },
                            .consume => {
                                switch (b1) {
                                    0x00...0x20, 0x7F => {
                                        try spans.append(.{
                                            .text = content[h_start..i],
                                            .style = .{
                                                .fg = .{ .index = 4 },
                                            },
                                            .link = .{
                                                .uri = content[h_start..i],
                                            },
                                        });
                                        start = i;
                                        // backup one
                                        i -= 1;
                                        break;
                                    },
                                    else => {
                                        if (i == content.len - 1) {
                                            start = i + 1;
                                            try spans.append(.{
                                                .text = content[h_start..],
                                                .style = .{
                                                    .fg = .{ .index = 4 },
                                                },
                                                .link = .{
                                                    .uri = content[h_start..],
                                                },
                                            });
                                            break;
                                        }
                                    },
                                }
                            },
                        }
                    }
                }
            },
        }
    }
    if (start < i and start < content.len) {
        try spans.append(.{
            .text = content[start..],
            .style = style,
        });
    }
    return spans.toOwnedSlice();
}

const CaseMapAlgo = enum {
    ascii,
    rfc1459,
    rfc1459_strict,
};

pub fn caseMap(char: u8, algo: CaseMapAlgo) u8 {
    switch (algo) {
        .ascii => {
            switch (char) {
                'A'...'Z' => return char + 0x20,
                else => return char,
            }
        },
        .rfc1459 => {
            switch (char) {
                'A'...'^' => return char + 0x20,
                else => return char,
            }
        },
        .rfc1459_strict => {
            switch (char) {
                'A'...']' => return char + 0x20,
                else => return char,
            }
        },
    }
}

pub fn caseFold(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var i: usize = 0;
    while (i < a.len) {
        const diff = std.mem.indexOfDiff(u8, a[i..], b[i..]) orelse return true;
        const a_diff = caseMap(a[diff], .rfc1459);
        const b_diff = caseMap(b[diff], .rfc1459);
        if (a_diff != b_diff) return false;
        i += diff + 1;
    }
    return true;
}

pub const ChatHistoryCommand = enum {
    before,
    after,
};

pub const ListModal = struct {
    client: *Client,
    /// the individual items we received
    items: std.ArrayListUnmanaged(Item),
    /// the list view
    list_view: vxfw.ListView,
    text_field: vxfw.TextField,

    filtered_items: std.ArrayList(Item),

    finished: bool,
    is_shown: bool,
    expecting_response: bool,

    focus: enum { text_field, list },

    const name_width = 24;
    const count_width = 8;

    // Item is a single RPL_LIST response
    const Item = struct {
        name: []const u8,
        topic: []const u8,
        count_str: []const u8,
        count: u32,

        fn deinit(self: Item, alloc: Allocator) void {
            alloc.free(self.name);
            alloc.free(self.topic);
            alloc.free(self.count_str);
        }

        fn widget(self: *Item) vxfw.Widget {
            return .{
                .userdata = self,
                .drawFn = Item.draw,
            };
        }

        fn lessThan(_: void, lhs: Item, rhs: Item) bool {
            return lhs.count > rhs.count;
        }

        fn draw(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
            const self: *Item = @ptrCast(@alignCast(ptr));

            var children: std.ArrayListUnmanaged(vxfw.SubSurface) = try .initCapacity(ctx.arena, 3);

            const name_ctx = ctx.withConstraints(.{ .width = name_width, .height = 1 }, ctx.max);
            const count_ctx = ctx.withConstraints(.{ .width = count_width, .height = 1 }, ctx.max);
            const topic_ctx = ctx.withConstraints(.{
                .width = ctx.max.width.? -| name_width -| count_width - 2,
                .height = 1,
            }, ctx.max);

            const name: vxfw.Text = .{ .text = self.name, .softwrap = false };
            const count: vxfw.Text = .{ .text = self.count_str, .softwrap = false, .text_align = .right };
            const spans = try formatMessage(ctx.arena, undefined, self.topic);
            const topic: vxfw.RichText = .{ .text = spans, .softwrap = false };

            children.appendAssumeCapacity(.{
                .origin = .{ .col = 0, .row = 0 },
                .surface = try name.draw(name_ctx),
            });
            children.appendAssumeCapacity(.{
                .origin = .{ .col = name_width, .row = 0 },
                .surface = try topic.draw(topic_ctx),
            });
            children.appendAssumeCapacity(.{
                .origin = .{ .col = ctx.max.width.? -| count_width, .row = 0 },
                .surface = try count.draw(count_ctx),
            });

            return .{
                .size = .{ .width = ctx.max.width.?, .height = 1 },
                .widget = self.widget(),
                .buffer = &.{},
                .children = children.items,
            };
        }
    };

    fn init(self: *ListModal, gpa: Allocator, client: *Client) void {
        self.* = .{
            .client = client,
            .filtered_items = std.ArrayList(Item).init(gpa),
            .items = .empty,
            .list_view = .{
                .children = .{
                    .builder = .{
                        .userdata = self,
                        .buildFn = ListModal.getItem,
                    },
                },
            },
            .text_field = .init(gpa, client.app.unicode),
            .finished = true,
            .is_shown = false,
            .focus = .text_field,
            .expecting_response = false,
        };
        self.text_field.style.bg = client.app.blendBg(10);
        self.text_field.userdata = self;
        self.text_field.onChange = ListModal.onChange;
    }

    fn reset(self: *ListModal) !void {
        self.items.clearRetainingCapacity();
        self.filtered_items.clearAndFree();
        self.text_field.clearAndFree();
        self.finished = false;
        self.focus = .text_field;
        self.is_shown = false;
    }

    fn show(self: *ListModal, ctx: *vxfw.EventContext) !void {
        self.is_shown = true;
        switch (self.focus) {
            .text_field => try ctx.requestFocus(self.text_field.widget()),
            .list => try ctx.requestFocus(self.list_view.widget()),
        }
        return ctx.consumeAndRedraw();
    }

    pub fn widget(self: *ListModal) vxfw.Widget {
        return .{
            .userdata = self,
            .captureHandler = ListModal.captureHandler,
            .drawFn = ListModal._draw,
        };
    }

    fn deinit(self: *ListModal, alloc: std.mem.Allocator) void {
        for (self.items.items) |item| {
            item.deinit(alloc);
        }
        self.items.deinit(alloc);
        self.filtered_items.deinit();
        self.text_field.deinit();
        self.* = undefined;
    }

    fn addMessage(self: *ListModal, alloc: Allocator, msg: Message) !void {
        var iter = msg.paramIterator();
        // client, we skip this one
        _ = iter.next() orelse return;
        const channel = iter.next() orelse {
            log.warn("got RPL_LIST without channel", .{});
            return;
        };
        const count = iter.next() orelse {
            log.warn("got RPL_LIST without count", .{});
            return;
        };
        const topic = iter.next() orelse {
            log.warn("got RPL_LIST without topic", .{});
            return;
        };
        const item: Item = .{
            .name = try alloc.dupe(u8, channel),
            .count_str = try alloc.dupe(u8, count),
            .topic = try alloc.dupe(u8, topic),
            .count = try std.fmt.parseUnsigned(u32, count, 10),
        };
        try self.items.append(alloc, item);
    }

    fn finish(self: *ListModal, ctx: *vxfw.EventContext) !void {
        self.finished = true;
        self.is_shown = true;
        std.mem.sort(Item, self.items.items, {}, Item.lessThan);
        self.filtered_items.clearRetainingCapacity();
        try self.filtered_items.appendSlice(self.items.items);
        try ctx.requestFocus(self.text_field.widget());
    }

    fn onChange(ptr: ?*anyopaque, ctx: *vxfw.EventContext, input: []const u8) anyerror!void {
        const self: *ListModal = @ptrCast(@alignCast(ptr orelse unreachable));
        self.filtered_items.clearRetainingCapacity();
        for (self.items.items) |item| {
            if (std.mem.indexOf(u8, item.name, input)) |_| {
                try self.filtered_items.append(item);
            } else if (std.mem.indexOf(u8, item.topic, input)) |_| {
                try self.filtered_items.append(item);
            }
        }
        return ctx.consumeAndRedraw();
    }

    fn captureHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const self: *ListModal = @ptrCast(@alignCast(ptr));
        switch (event) {
            .key_press => |key| {
                switch (self.focus) {
                    .text_field => {
                        if (key.matches(vaxis.Key.enter, .{})) {
                            try ctx.requestFocus(self.list_view.widget());
                            self.focus = .list;
                            return ctx.consumeAndRedraw();
                        } else if (key.matches(vaxis.Key.escape, .{})) {
                            self.close(ctx);
                            return;
                        } else if (key.matches(vaxis.Key.up, .{})) {
                            self.list_view.prevItem(ctx);
                            return ctx.consumeAndRedraw();
                        } else if (key.matches(vaxis.Key.down, .{})) {
                            self.list_view.nextItem(ctx);
                            return ctx.consumeAndRedraw();
                        }
                    },
                    .list => {
                        if (key.matches(vaxis.Key.escape, .{})) {
                            try ctx.requestFocus(self.text_field.widget());
                            self.focus = .text_field;
                            return ctx.consumeAndRedraw();
                        } else if (key.matches(vaxis.Key.enter, .{})) {
                            if (self.filtered_items.items.len > 0) {
                                // join the selected room, and deinit the view
                                var buf: [128]u8 = undefined;
                                const item = self.filtered_items.items[self.list_view.cursor];
                                const cmd = try std.fmt.bufPrint(&buf, "/join {s}", .{item.name});
                                try self.client.app.handleCommand(.{ .client = self.client }, cmd);
                            }
                            self.close(ctx);
                            return;
                        }
                    },
                }
            },
            else => {},
        }
    }

    fn close(self: *ListModal, ctx: *vxfw.EventContext) void {
        self.is_shown = false;
        const selected = self.client.app.selectedBuffer() orelse unreachable;
        self.client.app.selectBuffer(selected);
        return ctx.consumeAndRedraw();
    }

    fn getItem(ptr: *const anyopaque, idx: usize, _: usize) ?vxfw.Widget {
        const self: *const ListModal = @ptrCast(@alignCast(ptr));
        if (idx < self.filtered_items.items.len) {
            return self.filtered_items.items[idx].widget();
        }
        return null;
    }

    fn _draw(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
        const self: *ListModal = @ptrCast(@alignCast(ptr));
        return self.draw(ctx);
    }

    fn draw(self: *ListModal, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
        const max = ctx.max.size();
        var children: std.ArrayListUnmanaged(vxfw.SubSurface) = .empty;

        try children.append(ctx.arena, .{
            .origin = .{ .col = 0, .row = 0 },
            .surface = try self.text_field.draw(ctx),
        });
        const list_ctx = ctx.withConstraints(
            ctx.min,
            .{ .width = max.width, .height = max.height - 2 },
        );
        try children.append(ctx.arena, .{
            .origin = .{ .col = 0, .row = 2 },
            .surface = try self.list_view.draw(list_ctx),
        });

        return .{
            .size = max,
            .widget = self.widget(),
            .buffer = &.{},
            .children = children.items,
        };
    }
};

/// All memory allocated with `allocator` will be freed before this function returns.
pub fn tcpConnectToHost(allocator: mem.Allocator, name: []const u8, port: u16) std.net.TcpConnectToHostError!std.net.Stream {
    const list = try std.net.getAddressList(allocator, name, port);
    defer list.deinit();

    if (list.addrs.len == 0) return error.UnknownHostName;

    for (list.addrs) |addr| {
        const stream = std.net.tcpConnectToAddress(addr) catch |err| {
            log.warn("error connecting to host: {}", .{err});
            continue;
        };
        return stream;
    }
    return std.posix.ConnectError.ConnectionRefused;
}

test "caseFold" {
    try testing.expect(caseFold("a", "A"));
    try testing.expect(caseFold("aBcDeFgH", "abcdefgh"));
}

test "simple message" {
    const msg: Message = .{ .bytes = "JOIN" };
    try testing.expect(msg.command() == .JOIN);
}

test "simple message with extra whitespace" {
    const msg: Message = .{ .bytes = "JOIN      " };
    try testing.expect(msg.command() == .JOIN);
}

test "well formed message with tags, source, params" {
    const msg: Message = .{ .bytes = "@key=value :example.chat JOIN abc def" };

    var tag_iter = msg.tagIterator();
    const tag = tag_iter.next();
    try testing.expect(tag != null);
    try testing.expectEqualStrings("key", tag.?.key);
    try testing.expectEqualStrings("value", tag.?.value);
    try testing.expect(tag_iter.next() == null);

    const source = msg.source();
    try testing.expect(source != null);
    try testing.expectEqualStrings("example.chat", source.?);
    try testing.expect(msg.command() == .JOIN);

    var param_iter = msg.paramIterator();
    const p1 = param_iter.next();
    const p2 = param_iter.next();
    try testing.expect(p1 != null);
    try testing.expect(p2 != null);
    try testing.expectEqualStrings("abc", p1.?);
    try testing.expectEqualStrings("def", p2.?);

    try testing.expect(param_iter.next() == null);
}

test "message with tags, source, params and extra whitespace" {
    const msg: Message = .{ .bytes = "@key=value        :example.chat        JOIN    abc def" };

    var tag_iter = msg.tagIterator();
    const tag = tag_iter.next();
    try testing.expect(tag != null);
    try testing.expectEqualStrings("key", tag.?.key);
    try testing.expectEqualStrings("value", tag.?.value);
    try testing.expect(tag_iter.next() == null);

    const source = msg.source();
    try testing.expect(source != null);
    try testing.expectEqualStrings("example.chat", source.?);
    try testing.expect(msg.command() == .JOIN);

    var param_iter = msg.paramIterator();
    const p1 = param_iter.next();
    const p2 = param_iter.next();
    try testing.expect(p1 != null);
    try testing.expect(p2 != null);
    try testing.expectEqualStrings("abc", p1.?);
    try testing.expectEqualStrings("def", p2.?);

    try testing.expect(param_iter.next() == null);
}

test "param iterator: simple list" {
    var iter: Message.ParamIterator = .{ .params = "a b c" };
    var i: usize = 0;
    while (iter.next()) |param| {
        switch (i) {
            0 => try testing.expectEqualStrings("a", param),
            1 => try testing.expectEqualStrings("b", param),
            2 => try testing.expectEqualStrings("c", param),
            else => return error.TooManyParams,
        }
        i += 1;
    }
    try testing.expect(i == 3);
}

test "param iterator: trailing colon" {
    var iter: Message.ParamIterator = .{ .params = "* LS :" };
    var i: usize = 0;
    while (iter.next()) |param| {
        switch (i) {
            0 => try testing.expectEqualStrings("*", param),
            1 => try testing.expectEqualStrings("LS", param),
            2 => try testing.expectEqualStrings("", param),
            else => return error.TooManyParams,
        }
        i += 1;
    }
    try testing.expect(i == 3);
}

test "param iterator: colon" {
    var iter: Message.ParamIterator = .{ .params = "* LS :sasl multi-prefix" };
    var i: usize = 0;
    while (iter.next()) |param| {
        switch (i) {
            0 => try testing.expectEqualStrings("*", param),
            1 => try testing.expectEqualStrings("LS", param),
            2 => try testing.expectEqualStrings("sasl multi-prefix", param),
            else => return error.TooManyParams,
        }
        i += 1;
    }
    try testing.expect(i == 3);
}

test "param iterator: colon and leading colon" {
    var iter: Message.ParamIterator = .{ .params = "* LS ::)" };
    var i: usize = 0;
    while (iter.next()) |param| {
        switch (i) {
            0 => try testing.expectEqualStrings("*", param),
            1 => try testing.expectEqualStrings("LS", param),
            2 => try testing.expectEqualStrings(":)", param),
            else => return error.TooManyParams,
        }
        i += 1;
    }
    try testing.expect(i == 3);
}
