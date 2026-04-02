const std = @import("std");
const ArrayList = std.array_list.Managed;
const Allocator = std.mem.Allocator;
const allocPrint = std.fmt.allocPrint;
const data = @import("data.zig");
const log = @import("log.zig");

pub const SystemDescription = struct {
    allocator: Allocator,
    xml_data: ArrayList(u8),
    xml: ArrayList(u8).Writer,
    arch: Arch,
    pds: ArrayList(*ProtectionDomain),
    mrs: ArrayList(MemoryRegion),
    channels: ArrayList(Channel),
    /// Highest allocatable physical address on the platform
    paddr_top: u64,

    /// Supported architectures by seL4
    /// Expilictly assign values for better interop with C bindings.
    pub const Arch = enum(u8) {
        aarch32 = 0,
        aarch64 = 1,
        riscv32 = 2,
        riscv64 = 3,
        x86 = 4,
        x86_64 = 5,

        pub fn isArm(arch: Arch) bool {
            return arch == .aarch32 or arch == .aarch64;
        }

        pub fn isRiscv(arch: Arch) bool {
            return arch == .riscv32 or arch == .riscv64;
        }

        pub fn isX86(arch: Arch) bool {
            return arch == .x86 or arch == .x86_64;
        }

        pub fn defaultPageSize(_: Arch) u64 {
            // All the architectures we currently support default to this page size.
            return 0x1000;
        }

        pub fn pageAligned(arch: Arch, n: u64) bool {
            return (n % arch.defaultPageSize() == 0);
        }

        pub fn roundDownToPage(arch: Arch, n: u64) u64 {
            const page_size = arch.defaultPageSize();
            if (n < page_size) {
                return 0;
            } else if (n % page_size == 0) {
                return n;
            } else {
                return n - (n % page_size);
            }
        }

        pub fn roundUpToPage(arch: Arch, n: u64) u64 {
            const page_size = arch.defaultPageSize();
            if (n < page_size) {
                return page_size;
            } else if (n % page_size == 0) {
                return n;
            } else {
                return n + (page_size - (n % page_size));
            }
        }
    };

    pub const SetVar = struct {
        symbol: []const u8,
        name: []const u8,

        pub fn create(symbol: []const u8, mr: *const MemoryRegion) SetVar {
            return SetVar{
                .symbol = symbol,
                .name = mr.name,
            };
        }

        pub fn render(setvar: SetVar, writer: ArrayList(u8).Writer, separator: []const u8) !void {
            try std.fmt.format(writer, "{s}<setvar symbol=\"{s}\" region_paddr=\"{s}\" />\n", .{ separator, setvar.symbol, setvar.name });
        }
    };

    pub const MemoryRegion = struct {
        allocator: Allocator,
        name: []const u8,
        size: u64,
        paddr: ?u64,
        page_size: ?PageSize,

        pub const Options = struct {
            page_size: ?PageSize = null,
        };

        pub const OptionsPhysical = struct {
            paddr: ?u64 = null,
            page_size: ?PageSize = null,
        };

        // TODO: change to two API:
        // MemoryRegion.virtual()
        // MemoryRegion.physical()
        pub fn create(allocator: Allocator, name: []const u8, size: u64, options: Options) MemoryRegion {
            return MemoryRegion{
                .allocator = allocator,
                .name = allocator.dupe(u8, name) catch @panic("Could not allocate name for MemoryRegion"),
                .size = size,
                .page_size = options.page_size,
                .paddr = null,
            };
        }

        /// Creates a memory region at a specific physical address. Allocates the physical address automatically.
        pub fn physical(allocator: Allocator, sdf: *SystemDescription, name: []const u8, size: u64, options: OptionsPhysical) MemoryRegion {
            const paddr = if (options.paddr) |fixed_paddr| fixed_paddr else sdf.paddr_top - size;
            // TODO: handle alignment if people specify a page size.
            if (options.paddr == null) {
                sdf.paddr_top = paddr;
            }
            return MemoryRegion{
                .allocator = allocator,
                .name = allocator.dupe(u8, name) catch @panic("Could not allocate name for MemoryRegion"),
                .size = size,
                .paddr = paddr,
                .page_size = options.page_size,
            };
        }

        pub fn destroy(mr: MemoryRegion) void {
            mr.allocator.free(mr.name);
        }

        pub fn render(mr: MemoryRegion, sdf: *SystemDescription, writer: ArrayList(u8).Writer, separator: []const u8) !void {
            try std.fmt.format(writer, "{s}<memory_region name=\"{s}\" size=\"0x{x}\"", .{ separator, mr.name, mr.size });

            if (mr.paddr) |paddr| {
                try std.fmt.format(writer, " phys_addr=\"0x{x}\"", .{paddr});
            }

            if (mr.page_size) |page_size| {
                try std.fmt.format(writer, " page_size=\"0x{x}\"", .{page_size.toInt(sdf.arch)});
            }

            _ = try writer.write(" />\n");
        }

        pub const PageSize = enum(usize) {
            small,
            large,
            // huge,

            pub fn toInt(page_size: PageSize, arch: Arch) usize {
                // TODO: on RISC-V we are assuming that it's Sv39. For example if you
                // had a 64-bit system with Sv32, the page sizes would be different...
                switch (arch) {
                    .aarch64, .riscv64, .x86_64 => return switch (page_size) {
                        .small => 0x1000,
                        .large => 0x200000,
                        // .huge => 0x40000000,
                    },
                    .aarch32, .riscv32, .x86 => return switch (page_size) {
                        .small => 0x1000,
                        .large => 0x400000,
                        // .huge => 0x40000000,
                    },
                }
            }

            pub fn fromInt(page_size: usize, arch: Arch) !PageSize {
                switch (arch) {
                    .aarch64, .riscv64, .x86_64 => return switch (page_size) {
                        0x1000 => .small,
                        0x200000 => .large,
                        // 0x40000000 => .huge,
                        else => return error.InvalidPageSize,
                    },
                    .aarch32, .riscv32, .x86 => return switch (page_size) {
                        0x1000 => .small,
                        0x400000 => .large,
                        // 0x40000000 => .huge,
                        else => return error.InvalidPageSize,
                    },
                }
            }

            pub fn optimal(arch: Arch, region_size: u64) PageSize {
                // TODO would be better if we did some meta programming in case the
                // number of elements in PageSize change
                // if (region_size % PageSize.huge.toSize(sdf.arch) == 0) return .huge;
                if (region_size % PageSize.large.toInt(arch) == 0) return .large;

                return .small;
            }
        };
    };

    pub const Map = struct {
        mr: MemoryRegion,
        vaddr: u64,
        perms: Perms,
        cached: ?bool,
        setvar_vaddr: ?[]const u8,
        optional: ?bool,

        pub const Options = struct {
            cached: ?bool = null,
            setvar_vaddr: ?[]const u8 = null,
            optional: ?bool = null,
        };

        pub const Perms = packed struct {
            // TODO: check that perms are not write-only
            read: bool = false,
            write: bool = false,
            execute: bool = false,

            pub const r = Perms{ .read = true };
            pub const x = Perms{ .execute = true };
            pub const rw = Perms{ .read = true, .write = true };
            pub const rx = Perms{ .read = true, .execute = true };
            pub const wx = Perms{ .write = true, .execute = true };
            pub const rwx = Perms{ .read = true, .write = true, .execute = true };

            pub fn valid(perms: Perms) bool {
                if (!perms.read and !perms.execute and perms.write) {
                    return false;
                }

                return true;
            }

            pub fn toString(perms: Perms, buf: *[3]u8) []u8 {
                var i: u8 = 0;
                if (perms.read) {
                    buf[i] = 'r';
                    i += 1;
                }
                if (perms.write) {
                    buf[i] = 'w';
                    i += 1;
                }
                if (perms.execute) {
                    buf[i] = 'x';
                    i += 1;
                }

                std.debug.assert(i < 4);
                return buf[0..i];
            }

            pub fn fromString(str: []const u8) !Perms {
                const read_count = std.mem.count(u8, str, "r");
                const write_count = std.mem.count(u8, str, "w");
                const exec_count = std.mem.count(u8, str, "x");
                if (read_count > 1 or write_count > 1 or exec_count > 1) {
                    return error.InvalidPerms;
                }
                if (read_count == 0 and exec_count == 0 and write_count == 1) {
                    return error.InvalidPerms;
                }
                std.debug.assert(str.len == read_count + write_count + exec_count);
                var perms: Perms = .{};
                if (read_count > 0) {
                    perms.read = true;
                }
                if (write_count > 0) {
                    perms.write = true;
                }
                if (exec_count > 0) {
                    perms.execute = true;
                }

                return perms;
            }
        };

        // TODO: make vaddr optional so its easier to allocate it automatically
        pub fn create(mr: MemoryRegion, vaddr: u64, perms: Perms, options: Options) Map {
            if (!perms.valid()) {
                log.err("error creating mapping for '{s}': invalid permissions given", .{mr.name});
                @panic("todo");
            }

            return Map{
                .mr = mr,
                .vaddr = vaddr,
                .perms = perms,
                .cached = options.cached,
                .setvar_vaddr = options.setvar_vaddr,
                .optional = options.optional,
            };
        }

        pub fn render(map: *const Map, writer: ArrayList(u8).Writer, separator: []const u8) !void {
            var perms_buf = [_]u8{0} ** 3;
            const perms = map.perms.toString(&perms_buf);
            try std.fmt.format(writer, "{s}<map mr=\"{s}\" vaddr=\"0x{x}\" perms=\"{s}\"", .{ separator, map.mr.name, map.vaddr, perms });

            if (map.setvar_vaddr) |setvar_vaddr| {
                try std.fmt.format(writer, " setvar_vaddr=\"{s}\"", .{setvar_vaddr});
            }

            if (map.cached) |cached| {
                const cached_str = if (cached) "true" else "false";
                try std.fmt.format(writer, " cached=\"{s}\"", .{cached_str});
            }

            if (map.optional) |optional| {
                const optional_str = if (optional) "true" else "false";
                try std.fmt.format(writer, " optional=\"{s}\"", .{optional_str});
            }

            _ = try writer.write(" />\n");
        }
    };

    pub const VirtualMachine = struct {
        allocator: Allocator,
        name: []const u8,
        priority: ?u8,
        budget: ?u32,
        period: ?u32,
        vcpus: []const Vcpu,
        maps: ArrayList(Map),

        pub const Options = struct {
            priority: ?u8 = null,
            budget: ?u32 = null,
            period: ?u32 = null,
        };

        pub const Vcpu = struct {
            id: u8,
            /// Physical core the vCPU will run on
            cpu: ?u8 = null,
        };

        pub fn create(allocator: Allocator, name: []const u8, vcpus: []const Vcpu, options: Options) !VirtualMachine {
            var i: usize = 0;
            while (i < vcpus.len) : (i += 1) {
                var j = i + 1;
                while (j < vcpus.len) : (j += 1) {
                    if (vcpus[i].id == vcpus[j].id) {
                        return error.DuplicateVcpuId;
                    }
                }
            }

            return VirtualMachine{
                .allocator = allocator,
                .name = allocator.dupe(u8, name) catch @panic("Could not dupe VirtualMachine name"),
                .vcpus = allocator.dupe(Vcpu, vcpus) catch @panic("Could not dupe VirtualMachine vCPU list"),
                .maps = ArrayList(Map).init(allocator),
                .priority = options.priority,
                .budget = options.budget,
                .period = options.period,
            };
        }

        pub fn addMap(vm: *VirtualMachine, map: Map) void {
            vm.maps.append(map) catch @panic("Could not add Map to VirtualMachine");
        }

        pub fn destroy(vm: *VirtualMachine) void {
            vm.allocator.free(vm.vcpus);
            vm.allocator.free(vm.name);
            vm.maps.deinit();
        }

        pub fn render(vm: *VirtualMachine, sdf: *SystemDescription, writer: ArrayList(u8).Writer, separator: []const u8) !void {
            try std.fmt.format(writer, "{s}<virtual_machine name=\"{s}\"", .{ separator, vm.name });

            if (vm.priority) |priority| {
                try std.fmt.format(writer, " priority=\"{}\"", .{priority});
            }
            if (vm.budget) |budget| {
                try std.fmt.format(writer, " budget=\"{}\"", .{budget});
            }
            if (vm.period) |period| {
                try std.fmt.format(writer, " period=\"{}\"", .{period});
            }
            _ = try writer.write(">\n");

            const child_separator = try allocPrint(sdf.allocator, "{s}    ", .{separator});
            defer sdf.allocator.free(child_separator);

            for (vm.vcpus) |vcpu| {
                try std.fmt.format(writer, "{s}<vcpu id=\"{}\"", .{ child_separator, vcpu.id });
                if (vcpu.cpu) |cpu| {
                    try std.fmt.format(writer, " cpu=\"{}\"", .{cpu});
                }
                _ = try writer.write(" />\n");
            }

            for (vm.maps.items) |map| {
                try map.render(writer, child_separator);
            }

            try std.fmt.format(writer, "{s}</virtual_machine>\n", .{separator});
        }
    };

    pub const ProtectionDomain = struct {
        allocator: Allocator,
        name: []const u8,
        /// Program ELF
        program_image: ?[]const u8,
        /// Scheduling parameters
        /// The policy here is to follow the default values that Microkit uses.
        priority: ?u8,
        budget: ?u32,
        period: ?u32,
        passive: ?bool,
        stack_size: ?u32,
        /// Memory mappings
        maps: ArrayList(Map),
        /// The length of this array is bound by the maximum number of child PDs a PD can have.
        child_pds: ArrayList(*ProtectionDomain),
        /// The length of this array is bound by the maximum number of IRQs a PD can have.
        irqs: ArrayList(Irq),
        /// The length of this array is bound by the maximum number of I/O Ports a PD can have.
        ioports: ArrayList(IoPort),
        vm: ?*VirtualMachine,
        /// Keeping track of what IDs are available for channels, IRQs, etc
        channel_ids: std.bit_set.StaticBitSet(MAX_IDS),
        child_ids: std.bit_set.StaticBitSet(MAX_IDS),
        svc_id: std.bit_set.StaticBitSet(MAX_IDS),
        /// Whether or not ARM SMC is available
        arm_smc: ?bool,
        /// If this PD is a child of another PD, this ID identifies it to its parent PD
        child_id: ?u8,
        /// CPU core
        cpu: ?u8,

        setvars: ArrayList(SetVar),

        /// monitor pd feature (which controls dynamic pd)
        is_monitor: bool = false,
        /// OS services for a PD
        os_services: ArrayList(OSSvc),
        /// Reserved memory mappings for a PD
        maps_reserved: ArrayList(Map),
        // optional: only valid when is_monitor == true
        mon_svc_db: ?data.Resources.Monitor.SvcDb,

        // Matches Microkit implementation
        const MAX_IDS: u8 = 62;
        const MAX_IRQS: u8 = MAX_IDS;
        const MAX_IOPORTS: u8 = MAX_IDS;
        const MAX_CHILD_PDS: u8 = MAX_IDS;
        const MAX_OS_SERVICES: u8 = 16;
        const MAX_SVC_IDS: u8 = MAX_OS_SERVICES;

        pub const DEFAULT_PRIORITY: u8 = 100;

        pub const Options = struct {
            passive: ?bool = null,
            priority: ?u8 = null,
            budget: ?u32 = null,
            period: ?u32 = null,
            stack_size: ?u32 = null,
            arm_smc: ?bool = null,
            cpu: ?u8 = null,
            is_monitor: bool = false,
        };

        pub fn create(allocator: Allocator, name: []const u8, program_image: ?[]const u8, options: Options) ProtectionDomain {
            const program_image_dupe = if (program_image) |p| allocator.dupe(u8, p) catch @panic("Could not dupe PD program_image") else null;

            return ProtectionDomain{
                .allocator = allocator,
                .name = allocator.dupe(u8, name) catch @panic("Could not dupe PD name"),
                .program_image = program_image_dupe,
                .maps = ArrayList(Map).init(allocator),
                .maps_reserved = ArrayList(Map).init(allocator),
                .child_pds = ArrayList(*ProtectionDomain).initCapacity(allocator, MAX_CHILD_PDS) catch @panic("Could not allocate child_pds"),
                .irqs = ArrayList(Irq).initCapacity(allocator, MAX_IRQS) catch @panic("Could not allocate irqs"),
                .ioports = ArrayList(IoPort).initCapacity(allocator, MAX_IOPORTS) catch @panic("Could not allocate I/O Ports"),
                .vm = null,
                .channel_ids = std.bit_set.StaticBitSet(MAX_IDS).initEmpty(),
                .child_ids = std.bit_set.StaticBitSet(MAX_IDS).initEmpty(),
                .svc_id = std.bit_set.StaticBitSet(MAX_IDS).initEmpty(),
                .setvars = ArrayList(SetVar).init(allocator),
                .priority = options.priority,
                .passive = options.passive,
                .budget = options.budget,
                .period = options.period,
                .arm_smc = options.arm_smc,
                .stack_size = options.stack_size,
                .child_id = null,
                .cpu = options.cpu,
                .is_monitor = options.is_monitor,
                .os_services = ArrayList(OSSvc).initCapacity(allocator, MAX_OS_SERVICES) catch @panic("Could not allocate os_services"),
                .mon_svc_db = null,
            };
        }

        pub fn destroy(pd: *ProtectionDomain) void {
            pd.allocator.free(pd.name);
            if (pd.program_image) |program_image| {
                pd.allocator.free(program_image);
            }
            pd.maps.deinit();
            pd.child_pds.deinit();
            pd.irqs.deinit();
            pd.ioports.deinit();
            pd.setvars.deinit();
            pd.os_services.deinit();
        }

        /// There may be times where a PD resources is attached with an ID, such as a channel
        /// or IRQ require a fixed ID while others do not. One example might be
        /// that an IRQ needs to be at a particular ID while the channel numbers
        /// do not matter.
        /// This function is used to allocate an ID for use by one of those
        /// resources ensuring there are no clashes or duplicates.
        pub fn allocateId(id_set: *std.bit_set.StaticBitSet(MAX_IDS), id: ?u8) !u8 {
            if (id) |chosen_id| {
                if (id_set.*.isSet(chosen_id)) {
                    log.err("attempting to allocate already allocated ID '{}' '", .{chosen_id});
                    return error.AlreadyAllocatedId;
                } else {
                    id_set.*.setValue(chosen_id, true);
                    return chosen_id;
                }
            } else {
                for (0..MAX_IDS) |i| {
                    if (!id_set.*.isSet(i)) {
                        id_set.*.setValue(i, true);
                        return @intCast(i);
                    }
                }

                return error.NoMoreIds;
            }
        }

        pub fn allocateSvcId(pd: *ProtectionDomain, id: ?u32) !u32 {
            if (id) |chosen_id| {
                if (pd.svc_id.isSet(chosen_id)) {
                    log.err("attempting to allocate svc id '{}' in PD '{s}'", .{ chosen_id, pd.name });
                    return error.AlreadyAllocatedId;
                } else {
                    if (chosen_id >= MAX_SVC_IDS) {
                        log.err("attempting to allocate svc id '{}' which is out of bounds for PD '{s}'", .{ chosen_id, pd.name });
                        return error.IdOutOfBounds;
                    }
                    pd.svc_id.setValue(chosen_id, true);
                    return chosen_id;
                }
            } else {
                for (0..MAX_SVC_IDS) |i| {
                    if (!pd.svc_id.isSet(i)) {
                        pd.svc_id.setValue(i, true);
                        return @intCast(i);
                    }
                }
                return error.NoMoreIds;
            }
        }

        pub fn setVirtualMachine(pd: *ProtectionDomain, vm: *VirtualMachine) !void {
            if (pd.vm != null) return error.ProtectionDomainAlreadyHasVirtualMachine;
            pd.vm = vm;
        }

        pub fn addMap(pd: *ProtectionDomain, map: Map) void {
            pd.maps.append(map) catch @panic("Could not add Map to ProtectionDomain");
            pd.maps_reserved.append(map) catch @panic("Could not add Map to ProtectionDomain reserved maps");
        }

        pub fn addMapReserved(pd: *ProtectionDomain, map: Map) void {
            pd.maps_reserved.append(map) catch @panic("Could not add (reserved) Map to ProtectionDomain");
        }

        pub fn addIrq(pd: *ProtectionDomain, irq: Irq) !u8 {
            // If the IRQ ID is already set, then we check that we can allocate it with
            // the PD.
            if (irq.id) |id| {
                _ = try allocateId(&pd.channel_ids, id);
                try pd.irqs.append(irq);

                return id;
            } else {
                var irq_with_id = irq;
                irq_with_id.id = try allocateId(&pd.channel_ids, null);
                try pd.irqs.append(irq_with_id);
                return irq_with_id.id.?;
            }
        }

        pub fn addIoPort(pd: *ProtectionDomain, ioport: IoPort) !u8 {
            if (ioport.id) |id| {
                _ = try allocateId(&pd.channel_ids, id);
                try pd.ioports.append(ioport);
                return id;
            } else {
                var ioport_with_id = ioport;
                ioport_with_id.id = try allocateId(&pd.channel_ids, null);
                try pd.ioports.append(ioport_with_id);
                return ioport_with_id.id.?;
            }
        }

        pub fn addSetVar(pd: *ProtectionDomain, setvar: SetVar) void {
            pd.setvars.append(setvar) catch @panic("Could not add SetVar to ProtectionDomain");
        }

        const ChildOptions = struct {
            id: ?u8 = null,
        };

        pub fn addChild(pd: *ProtectionDomain, child: *ProtectionDomain, options: ChildOptions) !u8 {
            if (pd.child_pds.items.len == MAX_CHILD_PDS) {
                log.err("failed to add child '{s}' to parent '{s}', maximum children reached", .{ child.name, pd.name });
                return error.MaximumChildren;
            }

            pd.child_pds.appendAssumeCapacity(child);
            // Even though we check that we haven't added too many children, it is still
            // possible that allocation can fail.
            child.child_id = try allocateId(&pd.child_ids, options.id);

            return child.child_id.?;
        }

        // TODO: get rid of this extra arg?
        pub fn getMapVaddr(pd: *ProtectionDomain, mr: *const MemoryRegion) u64 {
            // TODO: should make sure we don't have a way of giving an invalid vaddr back (e.g on 32-bit systems this is more of a concern)

            // The approach for this is fairly simple and naive, we just loop
            // over all the maps and find the largest next available address.
            // We could extend this in the future to actually look for space
            // between mappings in the case they are not just sorted.
            // TODO: fix this
            const page_size = MemoryRegion.PageSize.optimal(.aarch64, mr.size).toInt(.aarch64);
            var next_vaddr: u64 = 0x20_000_000;
            for (pd.maps_reserved.items) |map| {
                if (map.vaddr >= next_vaddr) {
                    next_vaddr = map.vaddr + map.mr.size;
                    // TODO: Use builtins like @rem
                    const diff = next_vaddr % page_size;
                    if (diff != 0) {
                        // In the case the next virtual address is not page aligned, we need
                        // to increase it further.
                        next_vaddr += page_size - diff;
                    }
                }
            }

            // const padding: u64 = switch (page_size) {
            //     0x1000 => 0x1000,
            //     0x200_000 => 0x200_000,
            //     else => @panic("TODO"),
            // };

            return next_vaddr;
        }

        pub fn addOSService(pd: *ProtectionDomain, ossvc: OSSvc) void {
            if (pd.os_services.items.len == MAX_OS_SERVICES) {
                log.err("failed to add OS service '{s}' to PD '{s}', maximum OS services reached", .{ ossvc.svc_name, pd.name });
                return;
            }
            pd.os_services.appendAssumeCapacity(ossvc);
        }

        pub fn render(pd: *ProtectionDomain, sdf: *SystemDescription, writer: ArrayList(u8).Writer, separator: []const u8, id: ?u8) !void {
            // If we are given an ID, this PD is in fact a child PD and we have to
            // specify the ID for the root PD to use when referring to this child PD.

            if (pd.is_monitor) {
                try std.fmt.format(writer, "{s}<monitor_protection_domain name=\"{s}\"", .{ separator, pd.name });
            } else {
                try std.fmt.format(writer, "{s}<protection_domain name=\"{s}\"", .{ separator, pd.name });
            }

            if (id) |id_val| {
                try std.fmt.format(writer, " id=\"{}\"", .{id_val});
            }

            if (pd.priority) |priority| {
                try std.fmt.format(writer, " priority=\"{}\"", .{priority});
            }

            if (pd.budget) |budget| {
                try std.fmt.format(writer, " budget=\"{}\"", .{budget});
            }

            if (pd.period) |period| {
                try std.fmt.format(writer, " period=\"{}\"", .{period});
            }

            if (pd.passive) |passive| {
                try std.fmt.format(writer, " passive=\"{}\"", .{passive});
            }

            if (pd.stack_size) |stack_size| {
                try std.fmt.format(writer, " stack_size=\"0x{x}\"", .{stack_size});
            }

            if (pd.arm_smc) |smc| {
                if (!sdf.arch.isArm()) {
                    log.err("set 'arm_smc' option when not targeting ARM\n", .{});
                    return error.InvalidArmSmc;
                }

                try std.fmt.format(writer, " smc=\"{}\"", .{smc});
            }

            if (pd.cpu) |cpu| {
                try std.fmt.format(writer, " cpu=\"{}\"", .{cpu});
            }

            _ = try writer.write(">\n");

            const child_separator = try allocPrint(sdf.allocator, "{s}    ", .{separator});
            defer sdf.allocator.free(child_separator);
            // Add program image (if we have one)
            if (pd.program_image) |program_image| {
                try std.fmt.format(writer, "{s}<program_image path=\"{s}\" />\n", .{ child_separator, program_image });
            }
            for (pd.maps.items) |map| {
                try map.render(writer, child_separator);
            }
            for (pd.child_pds.items) |child_pd| {
                try child_pd.render(sdf, writer, child_separator, child_pd.child_id.?);
            }
            if (pd.vm) |vm| {
                try vm.render(sdf, writer, child_separator);
            }
            for (pd.irqs.items) |irq| {
                try irq.render(writer, child_separator);
            }
            for (pd.ioports.items) |ioport| {
                try ioport.render(writer, child_separator);
            }
            for (pd.setvars.items) |setvar| {
                try setvar.render(writer, child_separator);
            }
            for (pd.os_services.items) |ossvc| {
                try ossvc.render(writer, child_separator);
            }

            if (pd.is_monitor) {
                try std.fmt.format(writer, "{s}</monitor_protection_domain>\n", .{separator});
            } else {
                try std.fmt.format(writer, "{s}</protection_domain>\n", .{separator});
            }
        }

        fn pageSizeBytes(page_size: MemoryRegion.PageSize) usize {
            return @intCast(@intFromEnum(page_size));
        }

        fn fillSvcMapping(
            dst: *data.Resources.Monitor.SvcMapping,
            src: *const Map,
        ) void {
            // const ps = src.mr.page_size orelse .small;
            // const page_size = pageSizeBytes(ps);
            const page_size: usize = if (src.mr.page_size) |ps|
                pageSizeBytes(ps)
            else
                0x1000;

            if (page_size == 0) {
                @panic("page size cannot be zero");
            }
            if (src.mr.size % page_size != 0) {
                @panic("memory region size is not a multiple of page size");
            }

            dst.* = .{
                .vaddr = @intCast(src.vaddr),
                .page_num = @intCast(src.mr.size / page_size),
                .page_size = page_size,
            };
        }

        fn fillProtoConSvc(
            dst: *data.Resources.Monitor.ProtoConSvc,
            src: *const OSSvc,
        ) void {
            dst.* = std.mem.zeroes(data.Resources.Monitor.ProtoConSvc);
            @memset(&dst.channels, 0xff);
            @memset(&dst.irqs, 0xff);

            dst.svc_init = true;
            dst.svc_idx = @intCast(src.id orelse @panic("os service has no id"));
            dst.svc_type = src.svc_type orelse @panic("os service has no svc_type");

            // channels
            if (src.channels.items.len > dst.channels.len) {
                @panic("too many channels in os service");
            }
            for (src.channels.items, 0..) |ch, i| {
                dst.channels[i] = ch;
            }

            if (src.irqs.items.len > dst.irqs.len) {
                @panic("too many irqs in os service");
            }
            for (src.irqs.items, 0..) |irq, i| {
                dst.irqs[i] = irq.id orelse @panic("os service irq has no id");
            }
            // mappings
            if (src.maps.items.len > dst.mappings.len) {
                @panic("too many mappings in os service");
            }
            for (src.maps.items, 0..) |map, i| {
                fillSvcMapping(&dst.mappings[i], &map);
            }

            // data_path
            if (src.data_name) |name| {
                const n = @min(name.len, dst.data_path.len - 1);
                @memcpy(dst.data_path[0..n], name[0..n]);
                dst.data_path[n] = 0;
            }
        }

        fn populateMonitorSvcDb(pd: *ProtectionDomain) void {
            const svcdb = &pd.mon_svc_db.?;

            // initialise monitor_svcdb_t
            svcdb.* = .{
                .len = 0,
                .list = std.mem.zeroes([16]data.Resources.Monitor.ProtoConSvcDb),
            };

            var db_idx: usize = 0;

            for (pd.child_pds.items) |child_pd| {
                if (child_pd.os_services.items.len == 0) continue;

                if (db_idx >= svcdb.list.len) {
                    @panic("too many child PDs with os_services for monitor svc db");
                }

                var entry = &svcdb.list[db_idx];
                entry.* = std.mem.zeroes(data.Resources.Monitor.ProtoConSvcDb);

                entry.pd_idx = child_pd.child_id orelse @panic("child pd has no child_id");
                entry.svc_num = @intCast(child_pd.os_services.items.len);

                if (child_pd.os_services.items.len > entry.array.len) {
                    @panic("too many os_services in child pd");
                }

                for (child_pd.os_services.items, 0..) |*os_svc, svc_idx| {
                    fillProtoConSvc(&entry.array[svc_idx], os_svc);
                }

                db_idx += 1;
            }

            svcdb.len = db_idx;
        }

        pub fn setMonitor(pd: *ProtectionDomain) void {
            pd.is_monitor = true;
            if (pd.mon_svc_db == null) {
                pd.mon_svc_db = initMonitorSvcDb();
            }
        }

        pub fn generateSvc(pd: *ProtectionDomain, sdf: *SystemDescription, prefix: []const u8) !void {
            if (!pd.is_monitor) return;

            const full_path = try std.fs.path.join(sdf.allocator, &.{ prefix, pd.name });
            defer sdf.allocator.free(full_path);

            const full_path_data = try std.fmt.allocPrint(sdf.allocator, "{s}.svc", .{full_path});
            defer sdf.allocator.free(full_path_data);

            const serialize_file = try std.fs.cwd().createFile(full_path_data, .{});
            defer serialize_file.close();

            if (pd.mon_svc_db == null) {
                std.debug.print("generateSvc: pd '{s}' is_monitor=true but mon_svc_db is null\n", .{pd.name});
                @panic("monitor pd has no mon_svc_db");
            }

            populateMonitorSvcDb(pd);

            try serialize_file.writeAll(std.mem.asBytes(&pd.mon_svc_db.?));
        }
    };

    pub const OSSvc: type = struct {
        allocator: Allocator,
        /// Memory mappings
        maps: ArrayList(Map),
        /// The length of this array is bound by the maximum number of IRQs a PD can have.
        irqs: ArrayList(Irq),
        /// PD id to its parent PD
        ppd: *ProtectionDomain,
        /// ossvc id
        id: ?u32,
        /// Channel endpoint IDs
        channels: ArrayList(u8),
        /// serialised data (output)
        data_name: ?[]const u8,
        /// (unused for now...)
        svc_name: []const u8,
        ///
        svc_type: ?u8,

        // Matches Microkit implementation
        const MAX_IDS: u8 = 62;

        pub fn create(allocator: Allocator, ppd: *ProtectionDomain, id: u32, name: []const u8, svc_type: u8) OSSvc {
            return OSSvc{
                .allocator = allocator,
                .maps = ArrayList(Map).init(allocator),
                .irqs = ArrayList(Irq).initCapacity(allocator, MAX_IDS) catch @panic("Could not allocate irqs"),
                .ppd = ppd,
                .id = id,
                .channels = ArrayList(u8).init(allocator),
                .svc_name = allocator.dupe(u8, name) catch @panic("Could not dupe ossvc name"),
                .data_name = null,
                .svc_type = svc_type,
            };
        }

        pub fn destroy(ossvc: *OSSvc) void {
            ossvc.maps.deinit();
            ossvc.irqs.deinit();
            ossvc.channels.deinit();
            ossvc.allocator.free(ossvc.svc_name);
            if (ossvc.data_name) |buf| { // idiomatic optional test
                ossvc.allocator.free(buf);
            }
        }

        pub fn addDataName(ossvc: *OSSvc, data_name: []const u8) void {
            ossvc.data_name = ossvc.allocator.dupe(u8, data_name) catch @panic("Could not dupe ossvc data name");
        }

        pub fn allocateId(id_set: *std.bit_set.StaticBitSet(MAX_IDS), id: ?u8) !u8 {
            if (id) |chosen_id| {
                if (id_set.*.isSet(chosen_id)) {
                    log.err("attempting to allocate already allocated ID '{}' '", .{chosen_id});
                    return error.AlreadyAllocatedId;
                } else {
                    id_set.*.setValue(chosen_id, true);
                    return chosen_id;
                }
            } else {
                for (0..MAX_IDS) |i| {
                    if (!id_set.*.isSet(i)) {
                        id_set.*.setValue(i, true);
                        return @intCast(i);
                    }
                }

                return error.NoMoreIds;
            }
        }

        pub fn addMap(ossvc: *OSSvc, map: Map) void {
            ossvc.ppd.addMapReserved(map);
            ossvc.maps.append(map) catch @panic("Could not add Map to OSSvc");
        }

        pub fn addIrq(ossvc: *OSSvc, irq: Irq) !u8 {
            // If the IRQ ID is already set, then we check that we can allocate it with
            // the PD.
            if (irq.id) |id| {
                _ = try allocateId(&ossvc.ppd.channel_ids, id);
                try ossvc.irqs.append(irq);

                return id;
            } else {
                var irq_with_id = irq;
                irq_with_id.id = try allocateId(&ossvc.ppd.channel_ids, null);
                try ossvc.irqs.append(irq_with_id);
                return irq_with_id.id.?;
            }
        }

        pub fn addChannel(ossvc: *OSSvc, end_id: u8) void {
            ossvc.channels.append(end_id) catch @panic("Could not add channel to OSSvc");
        }

        // pub fn render(ossvc: *const OSSvc, sdf: *SystemDescription, writer: ArrayList(u8).Writer, separator: []const u8, id: ?u32) !void {
        pub fn render(ossvc: *const OSSvc, writer: ArrayList(u8).Writer, separator: []const u8) !void {
            for (ossvc.maps.items) |map| {
                try map.render(writer, separator);
            }
            for (ossvc.irqs.items) |irq| {
                try irq.render(writer, separator);
            }
        }
    };

    fn initMonitorSvcDb() data.Resources.Monitor.SvcDb {
        return .{
            .len = 0,
            .list = std.mem.zeroes([16]data.Resources.Monitor.ProtoConSvcDb),
        };
    }

    pub const Channel = struct {
        pd_a: *ProtectionDomain,
        pd_b: *ProtectionDomain,
        pd_a_id: u8,
        pd_b_id: u8,
        pd_a_notify: ?bool,
        pd_b_notify: ?bool,
        pp: ?End,
        pd_a_optional: ?bool,
        pd_b_optional: ?bool,

        pub const End = enum { a, b };

        pub const Options = struct {
            pd_a_notify: ?bool = null,
            pd_b_notify: ?bool = null,
            pp: ?End = null,
            pd_a_id: ?u8 = null,
            pd_b_id: ?u8 = null,
            pd_a_optional: ?bool = null,
            pd_b_optional: ?bool = null,
        };

        pub fn create(pd_a: *ProtectionDomain, pd_b: *ProtectionDomain, options: Options) !Channel {
            if (std.mem.eql(u8, pd_a.name, pd_b.name)) {
                log.err("channel end PDs do not differ, PD name is '{s}'\n", .{pd_a.name});
                return error.InvalidChannel;
            }

            return .{
                .pd_a = pd_a,
                .pd_b = pd_b,
                .pd_a_id = try ProtectionDomain.allocateId(&pd_a.channel_ids, options.pd_a_id),
                .pd_b_id = try ProtectionDomain.allocateId(&pd_b.channel_ids, options.pd_b_id),
                .pd_a_notify = options.pd_a_notify,
                .pd_b_notify = options.pd_b_notify,
                .pp = options.pp,
                .pd_a_optional = options.pd_a_optional,
                .pd_b_optional = options.pd_b_optional,
            };
        }

        pub fn render(ch: Channel, sdf: *SystemDescription, writer: ArrayList(u8).Writer, separator: []const u8) !void {
            const allocator = sdf.allocator;

            const child_separator = try allocPrint(sdf.allocator, "{s}    ", .{separator});
            defer allocator.free(child_separator);

            try std.fmt.format(writer, "{s}<channel", .{separator});
            // if (ch.optional) |optional| {
            //     if (optional) {
            //         try std.fmt.format(writer, " optional=\"true\"", .{});
            //     }
            // }
            try std.fmt.format(writer, ">\n", .{});
            try std.fmt.format(writer, "{s}<end pd=\"{s}\" id=\"{}\"", .{ child_separator, ch.pd_a.name, ch.pd_a_id });

            if (ch.pd_a_notify) |notify| {
                try std.fmt.format(writer, " notify=\"{}\"", .{notify});
            }

            if (ch.pp != null and ch.pp.? == .a) {
                _ = try writer.write(" pp=\"true\"");
            }

            if (ch.pd_a_optional) |optional| {
                if (optional) {
                    _ = try writer.write(" optional=\"true\"");
                } else {
                    _ = try writer.write(" optional=\"false\"");
                }
            }
            _ = try writer.write(" />\n");

            try std.fmt.format(writer, "{s}<end pd=\"{s}\" id=\"{}\"", .{ child_separator, ch.pd_b.name, ch.pd_b_id });

            if (ch.pd_b_notify) |notify| {
                try std.fmt.format(writer, " notify=\"{}\"", .{notify});
            }

            if (ch.pp != null and ch.pp.? == .b) {
                _ = try writer.write(" pp=\"true\"");
            }

            if (ch.pd_b_optional) |optional| {
                if (optional) {
                    _ = try writer.write(" optional=\"true\"");
                } else {
                    _ = try writer.write(" optional=\"false\"");
                }
            }

            try std.fmt.format(writer, " />\n{s}</channel>\n", .{separator});
        }
    };

    pub const Irq = struct {
        pub const Trigger = enum(u8) {
            edge = 0,
            level = 1,
        };

        pub const IoapicPolarity = enum(u8) {
            low = 0,
            high = 1,
        };

        const Kind = union(enum) {
            conventional: struct {
                irq: u32,
                trigger: ?Trigger,
            },

            //  @billn: double check which one is optional
            ioapic: struct {
                ioapic: ?u64,
                pin: u64,
                trigger: ?Trigger,
                polarity: ?IoapicPolarity,
                vector: u64,
            },

            msi: struct {
                pci_bus: u8, // 8 bits
                pci_dev: u8, // 5 bits
                pci_func: u8, // 3 bits
                handle: u64, // @billn double check type, and wtf does this do anyways?? double check in Mat's uKit tool
                vector: u64,
            },
        };

        /// IRQ on all architectures need to map to a channel
        id: ?u8,
        kind: Kind,

        pub const Options = struct {
            trigger: ?Trigger = null,
            id: ?u8 = null,
        };

        pub fn create(irq: u32, options: Options) Irq {
            return .{
                .id = options.id,
                .kind = .{
                    .conventional = .{
                        .irq = irq,
                        .trigger = options.trigger,
                    },
                },
            };
        }

        pub fn number(irq: *const Irq) ?u32 {
            switch (irq.kind) {
                .conventional => |s_irq| {
                    return s_irq.irq;
                },
                else => {
                    log.err("number called on invalid IRQ kind {s}", .{@tagName(irq.kind)});
                    return null;
                },
            }
        }

        pub fn trigger(irq: *const Irq) ?Trigger {
            switch (irq.kind) {
                .conventional => |s_irq| {
                    return s_irq.trigger;
                },
                .ioapic => |i_irq| {
                    return i_irq.trigger;
                },
                else => {
                    log.err("trigger called on invalid IRQ kind {s}", .{@tagName(irq.kind)});
                    return null;
                },
            }
        }

        pub const IoapicOptions = struct {
            ioapic: ?u64 = null,
            polarity: ?IoapicPolarity = null,
            trigger: ?Trigger = null,
            // Microkit channel ID
            id: ?u8 = null,
        };

        pub fn createIoapic(pin: u64, vector: u64, options: IoapicOptions) !Irq {
            return .{
                .id = options.id,
                .kind = .{
                    .ioapic = .{
                        .ioapic = options.ioapic,
                        .pin = pin,
                        .trigger = options.trigger,
                        .polarity = options.polarity,
                        .vector = vector,
                    },
                },
            };
        }

        pub const MsiOptions = struct {
            id: ?u8 = null,
        };

        pub fn createMsi(pci_bus: u8, pci_device: u8, pci_func: u8, vector: u64, handle: u64, options: MsiOptions) !Irq {
            // @billn: double check does MSI work in the same manner on arm and riscv?
            return .{
                .id = options.id,
                .kind = .{
                    .msi = .{
                        .pci_bus = pci_bus,
                        .pci_dev = pci_device,
                        .pci_func = pci_func,
                        .vector = vector,
                        .handle = handle,
                    },
                },
            };
        }

        pub fn render(irq: *const Irq, writer: ArrayList(u8).Writer, separator: []const u8) !void {
            // TODO: check the architecture here when rendering to see if the right IRQ kind is being
            // used.
            // By the time we get here, something should have populated the 'id' field.
            std.debug.assert(irq.id != null);

            try std.fmt.format(writer, "{s}<irq ", .{separator});

            switch (irq.kind) {
                .conventional => |s_irq| {
                    try std.fmt.format(writer, "irq=\"{}\" id=\"{}\"", .{ s_irq.irq, irq.id.? });
                    if (s_irq.trigger) |t| {
                        try std.fmt.format(writer, " trigger=\"{s}\"", .{@tagName(t)});
                    }
                },
                .ioapic => |i_irq| {
                    try std.fmt.format(writer, "pin=\"{}\" vector=\"{}\" id=\"{}\"", .{ i_irq.pin, i_irq.vector, irq.id.? });
                    if (i_irq.ioapic) |ioapic| {
                        try std.fmt.format(writer, " ioapic=\"{}\"", .{ioapic});
                    }
                    if (i_irq.trigger) |t| {
                        try std.fmt.format(writer, " trigger=\"{s}\"", .{@tagName(t)});
                    }
                    if (i_irq.polarity) |polarity| {
                        try std.fmt.format(writer, " polarity=\"{s}\"", .{@tagName(polarity)});
                    }
                },
                .msi => |m_irq| {
                    try std.fmt.format(writer, "pcidev=\"{}:{}.{}\" handle=\"{}\" vector=\"{}\" id=\"{}\"", .{ m_irq.pci_bus, m_irq.pci_dev, m_irq.pci_func, m_irq.handle, m_irq.vector, irq.id.? });
                },
            }

            _ = try writer.write(" />\n");
        }
    };

    /// Only supported for x86 targets
    pub const IoPort = struct {
        addr: u16,
        size: u16,
        id: ?u8,

        pub const Options = struct {
            id: ?u8 = null,
        };

        pub fn create(addr: u16, size: u16, options: Options) !IoPort {
            return .{
                .addr = addr,
                .size = size,
                .id = options.id,
            };
        }

        pub fn render(ioport: *const IoPort, writer: ArrayList(u8).Writer, separator: []const u8) !void {
            // By the time we get here, something should have populated the 'id' field.
            std.debug.assert(ioport.id != null);

            try std.fmt.format(writer, "{s}<ioport id=\"{}\" addr=\"{}\" size=\"{}\" />\n", .{ separator, ioport.id.?, ioport.addr, ioport.size });
        }
    };

    pub fn create(allocator: Allocator, arch: Arch, paddr_top: u64) SystemDescription {
        var xml_data = ArrayList(u8).init(allocator);
        return SystemDescription{
            .allocator = allocator,
            .xml_data = xml_data,
            .xml = xml_data.writer(),
            .arch = arch,
            .pds = ArrayList(*ProtectionDomain).init(allocator),
            .mrs = ArrayList(MemoryRegion).init(allocator),
            .channels = ArrayList(Channel).init(allocator),
            .paddr_top = paddr_top,
        };
    }

    pub fn destroy(sdf: *SystemDescription) void {
        sdf.pds.deinit();
        sdf.mrs.deinit();
        sdf.channels.deinit();
        sdf.xml_data.deinit();
    }

    pub fn addChannel(sdf: *SystemDescription, channel: Channel) void {
        sdf.channels.append(channel) catch @panic("Could not add Channel to SystemDescription");
    }

    pub fn addMemoryRegion(sdf: *SystemDescription, mr: MemoryRegion) void {
        sdf.mrs.append(mr) catch @panic("Could not add MemoryRegion to SystemDescription");
    }

    pub fn addProtectionDomain(sdf: *SystemDescription, protection_domain: *ProtectionDomain) void {
        sdf.pds.append(protection_domain) catch @panic("Could not add ProtectionDomain to SystemDescription");
    }

    pub fn addPd(sdf: *SystemDescription, name: []const u8, program_image: ?[]const u8) ProtectionDomain {
        var pd = ProtectionDomain.create(sdf, name, program_image);
        sdf.addProtectionDomain(&pd);

        return pd;
    }

    pub fn findPd(sdf: *SystemDescription, name: []const u8) ?*ProtectionDomain {
        for (sdf.pds.items) |pd| {
            if (std.mem.eql(u8, name, pd.name)) {
                return pd;
            }
        }

        return null;
    }

    pub fn render(sdf: *SystemDescription) ![:0]const u8 {
        const writer = sdf.xml_data.writer();
        _ = try writer.write("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<system>\n");

        // Use 4-space indent for the XML
        const separator = "    ";
        for (sdf.mrs.items) |mr| {
            try mr.render(sdf, writer, separator);
        }
        for (sdf.pds.items) |pd| {
            try pd.render(sdf, writer, separator, null);
        }
        for (sdf.channels.items) |ch| {
            try ch.render(sdf, writer, separator);
        }

        // Given that this is library code, it is better for us to provide a zero-terminated
        // array of bytes for consumption by langauges like C.
        _ = try writer.write("</system>" ++ "\x00");

        return sdf.xml_data.items[0 .. sdf.xml_data.items.len - 1 :0];
    }

    pub fn generateSvc(sdf: *SystemDescription, prefix: []const u8) !void {
        for (sdf.pds.items) |pd| {
            try pd.generateSvc(sdf, prefix);
        }
    }

    pub fn print(sdf: *SystemDescription) !void {
        const stdout = std.io.getStdOut().writer();
        try stdout.writeAll(try sdf.render());
        try stdout.writeAll("\n");
    }
};
