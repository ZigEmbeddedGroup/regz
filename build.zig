const std = @import("std");
const Builder = std.build.Builder;
const LibExeObjStep = std.build.LibExeObjStep;
const Step = std.build.Step;
const GeneratedFile = std.build.GeneratedFile;

const libxml2 = @import("deps/zig-libxml2/libxml2.zig");

fn root() []const u8 {
    return comptime (std.fs.path.dirname(@src().file) orelse unreachable) ++ "/";
}

pub const Regz = struct {
    builder: *Builder,
    exe: *LibExeObjStep,
    build_options: *std.build.OptionsStep,
    xml: libxml2.Library,

    pub const Options = struct {
        target: ?std.zig.CrossTarget = null,
        optimize: ?std.builtin.OptimizeMode = null,
    };

    pub fn create(builder: *Builder, opts: Options) *Regz {
        const target = opts.target orelse std.zig.CrossTarget{};
        const optimize = opts.optimize orelse .Debug;

        const xml = libxml2.create(builder, target, optimize, .{
            .iconv = false,
            .lzma = false,
            .zlib = false,
        }) catch unreachable;
        builder.installArtifact(xml.step);

        const commit_result = std.ChildProcess.exec(.{
            .allocator = builder.allocator,
            .argv = &.{ "git", "rev-parse", "HEAD" },
            .cwd = comptime root(),
        }) catch unreachable;

        const build_options = builder.addOptions();
        build_options.addOption([]const u8, "commit", commit_result.stdout);

        const clap_dep = builder.dependency("clap", .{});

        const exe = builder.addExecutable(.{
            .name = "regz",
            .root_source_file = .{ .path = comptime root() ++ "src/main.zig" },
            .target = target,
            .optimize = optimize,
        });
        exe.addOptions("build_options", build_options);
        exe.addModule("clap", clap_dep.module("clap"));
        xml.link(exe);

        var regz = builder.allocator.create(Regz) catch unreachable;
        regz.* = Regz{
            .builder = builder,
            .exe = exe,
            .build_options = build_options,
            .xml = xml,
        };

        return regz;
    }

    pub fn addGeneratedChipFile(regz: *Regz, schema_path: []const u8) GeneratedFile {
        // generate path where the schema will go
        // TODO: improve collision resistance
        const basename = std.fs.path.basename(schema_path);
        const extension = std.fs.path.extension(basename);
        const destination_path = regz.builder.cache_root.join(regz.builder.allocator, &.{
            "regz",
            std.mem.join(regz.builder.allocator, "", &.{
                basename[0 .. basename.len - extension.len],
                ".zig",
            }) catch unreachable,
        }) catch unreachable;

        const run_step = regz.builder.addRunArtifact(regz.exe);
        run_step.addArgs(&.{
            schema_path,
            "-o",
            destination_path,
        });

        return GeneratedFile{
            .step = &run_step.step,
            .path = destination_path,
        };
    }
};

pub fn build(b: *std.build.Builder) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{
        .preferred_optimize_mode = .ReleaseSafe,
    });

    const regz = Regz.create(b, .{
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(regz.exe);

    const run_cmd = b.addRunArtifact(regz.exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const contextualize_fields = b.addExecutable(.{
        .name = "contextualize-fields",
        .root_source_file = .{
            .path = "src/contextualize-fields.zig",
        },
    });
    regz.xml.link(contextualize_fields);

    const contextualize_fields_run = b.addRunArtifact(contextualize_fields);
    if (b.args) |args| {
        contextualize_fields_run.addArgs(args);
    }

    const contextualize_fields_step = b.step("contextualize-fields", "Create ndjson of all the fields with the context of parent fields");
    contextualize_fields_step.dependOn(&contextualize_fields_run.step);

    const characterize = b.addExecutable(.{
        .name = "characterize",
        .root_source_file = .{
            .path = "src/characterize.zig",
        },
    });
    regz.xml.link(characterize);

    const characterize_run = b.addRunArtifact(characterize);
    const characterize_step = b.step("characterize", "Characterize a number of xml files whose paths are piped into stdin, results are ndjson");
    characterize_step.dependOn(&characterize_run.step);

    const test_chip_file = regz.addGeneratedChipFile("tests/svd/cmsis-example.svd");
    _ = test_chip_file;

    const tests = b.addTest(.{
        .root_source_file = .{
            .path = "src/Database.zig",
        },
        .target = target,
        .optimize = optimize,
    });

    tests.addOptions("build_options", regz.build_options);
    //tests.addPackagePath("xml", "src/xml.zig");
    //tests.addPackagePath("Database", "src/Database.zig");
    regz.xml.link(tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&tests.step);
}
