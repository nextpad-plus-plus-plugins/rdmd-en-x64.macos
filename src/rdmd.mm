// rdmd-en-x64 — macOS port
// Original Windows plugin: "RDMD for Notepad++" (English build) by dokutoku —
// https://gitlab.com/dokutoku/rdmd-for-npp  (source is written in the D
// language itself; this is a from-scratch Objective-C++ re-implementation of its
// *feature*, not a recompile).
//
// Feature: compile / run the current D-language source file with the D toolchain
// (rdmd / dmd / ldc2 / dub), and show the output. It also offers a few
// convenience commands the original shipped: "Auto run" (infer the language from
// the current buffer and run it), DUB project discovery, a "new Hello file" set
// of starter templates, and a menu of D-language web links.
//
// ── What the Windows original did, and how this port maps it ──────────────────
//   * The Windows plugin drove a *real Win32 console* it spawned
//     (CreateProcessW + CREATE_NEW_CONSOLE, AttachConsole, WriteConsoleInputW),
//     typing the compiler command into cmd.exe / PowerShell and letting the user
//     watch it run. macOS has no per-plugin console window, so — exactly like the
//     sibling rustnpp.macos port — each command is run with **NSTask**, its
//     combined **stdout + stderr** captured, and the transcript surfaced in a
//     **new editor tab** (NPPM_MENUCOMMAND + IDM_FILE_NEW, then SCI_SETTEXT).
//   * SendMessageW(NPPM_GETFULLCURRENTPATH) → nppData._sendMessage(...).
//   * "Save before compiling" (the original sent IDM_FILE_SAVE) →
//     NPPM_SAVECURRENTFILE (synchronous on the macOS host, so the on-disk file is
//     up to date before we launch the compiler).
//   * Toolchain discovery: the original assumed dmd/ldc2/dub were reachable (it
//     looked under %HOMEDRIVE% for ldc and otherwise relied on PATH). A GUI app
//     on macOS inherits a minimal PATH, so this port searches PATH +
//     /usr/local/bin, /opt/homebrew/bin, /usr/bin, /opt/local/bin and the
//     conventional D install dirs (~/dlang/*/bin, e.g. ~/dlang/dmd-2.xxx/bin,
//     ~/dlang/ldc-1.xx/bin).
//   * Missing toolchain → NSAlert pointing at https://dlang.org/download.html
//     (no crash). The original popped a generic Windows error.
//
// ── Compiler option strings ───────────────────────────────────────────────────
// The exact dmd / ldc2 / dub option strings are reproduced verbatim from the
// original's dlang_option.d (dmd_option / ldc_option / dub_option) for every
// build type and flag that is meaningful on macOS. The Windows-only knobs
// (-m32mscoff, the LDC --mtriple cross-compile targets that all point at Windows,
// msvcEnv.bat, x86 "mscoff") are intentionally dropped — see README "Differences".
//
// ── Menu commands that could NOT be ported (documented, host left untouched) ───
//   * The whole "Console" group (Open/Close Console, Change Console → cmd /
//     PowerShell / other exe, Enable msvcEnv.bat, Enable startup console). These
//     manage a persistent Win32 console; there is no equivalent on macOS and the
//     host exposes no plugin console surface. Each compile here is a one-shot
//     NSTask whose output goes to a tab.
//   * "Force D language style" — the original sent NPPM_SETCURRENTLANGTYPE(L_D);
//     that message is **not implemented** by the macOS host (no-op), so the new
//     output / hello tabs are not auto-restyled. Documented; host not modified.
//   * Keyboard shortcuts (ALT+R Auto run, ALT+D dub, ALT+L ldc2, ALT+C find-dub,
//     etc.): the macOS host ignores plugin FuncItem._pShKey, so none are bound.
//
// HARD CONSTRAINT honoured: no host changes; the host headers are read-only.

#include "NppPluginInterfaceMac.h"
#include "Scintilla.h"
#import <Cocoa/Cocoa.h>

#include <dlfcn.h>   // dladdr / Dl_info — locate the bundled resources/ dir
#include <string>
#include <vector>

// ── canonical Windows LangType values the host understands ───────────────────
//    (host NppPluginManager.mm NPPM_GETCURRENTLANGTYPE map)
static const int L_TEXT   = 0;
static const int L_PHP    = 1;
static const int L_PYTHON = 22;
static const int L_RUBY   = 36;
static const int L_D      = 52;
static const int L_RUST   = 81;
static const int L_GOLANG = 90;

// IDM the macOS host honours for NPPM_MENUCOMMAND.
static const int IDM_FILE_NEW  = 41001;

static const char *PLUGIN_NAME = "RDMD for Notepad++";

namespace {

NppData nppData;

// ── menu model ───────────────────────────────────────────────────────────────
// We keep our own checkable state so the option-string builders read exactly
// like the original (which queried each menu item's _init2Check). The host
// allocates _cmdID per item with a _pFunc; we mirror checkmarks back with
// NPPM_SETMENUITEMCHECK.

// Build-type radio choices (index into kBuildTypes / matches the original menu).
enum class BuildType {
    none = 0, plain, debug, release, release_debug, release_nobounds,
    unittest_, docs, ddox, profile, profile_gc, cov, unittest_cov, syntax
};

// Arch radio.
enum class Arch { def = 0, x32, x64 };

// Compiler radio (drives "Auto run" / dub --compiler).
enum class Compiler { dmd = 0, ldc2 };

struct State {
    Compiler  compiler   = Compiler::dmd;     // default_compiler: dmd checked
    Arch      arch       = Arch::x64;          // x64 checked on 64-bit
    BuildType build      = BuildType::none;    // no build type checked initially
    bool      betterC    = false;
    bool      mainFlag   = false;              // --main
    bool      enableRdmd = true;               // Enable rdmd (checked)
    bool      enableRun  = true;               // dub: Enable run (checked)
    bool      forceBuild = false;              // dub: --force
} g;

// Each entry in the menu we build. The host fills _cmdID into the matching
// FuncItem; we keep these parallel to gFuncItems (same index).
struct MenuEntry {
    std::string name;          // UTF-8 menu text ("" => separator)
    PFUNCPLUGINCMD fn;         // command (nullptr for separator)
    bool init2Check;
};

std::vector<MenuEntry> gMenu;
std::vector<FuncItem>  gFuncItems;

// ── platform helpers ─────────────────────────────────────────────────────────

NppHandle currentScintilla() {
    int which = -1;
    nppData._sendMessage(nppData._nppHandle, NPPM_GETCURRENTSCINTILLA, 0, (intptr_t)&which);
    return (which == 0) ? nppData._scintillaMainHandle
         : (which == 1) ? nppData._scintillaSecondHandle : 0;
}

std::string currentNppFile() {
    char buf[2048] = {0};
    nppData._sendMessage(nppData._nppHandle, NPPM_GETFULLCURRENTPATH, 0, (intptr_t)buf);
    return std::string(buf);
}

int currentLangType() {
    int lang = L_TEXT;
    nppData._sendMessage(nppData._nppHandle, NPPM_GETCURRENTLANGTYPE, 0, (intptr_t)&lang);
    return lang;
}

void saveCurrentFile() {
    // Synchronous on the macOS host (returns the save result). Mirrors the
    // original's IDM_FILE_SAVE before every compile/run.
    nppData._sendMessage(nppData._nppHandle, NPPM_SAVECURRENTFILE, 0, 0);
}

std::string pluginsConfigDir() {
    char buf[2048] = {0};
    nppData._sendMessage(nppData._nppHandle, NPPM_GETPLUGINSCONFIGDIR, sizeof(buf), (intptr_t)buf);
    return std::string(buf);
}

// Directory next to this dylib that holds the bundled resources/ (hello/ etc.).
NSString *resourcesDir() {
    Dl_info info;
    if (dladdr((const void *)&resourcesDir, &info) && info.dli_fname) {
        NSString *dylib = [NSString stringWithUTF8String:info.dli_fname];
        return [[dylib stringByDeletingLastPathComponent]
                   stringByAppendingPathComponent:@"resources"];
    }
    return nil;
}

void setMenuCheck(int idx, bool checked) {
    if (idx < 0 || idx >= (int)gFuncItems.size()) return;
    nppData._sendMessage(nppData._nppHandle, NPPM_SETMENUITEMCHECK,
                         (uintptr_t)gFuncItems[idx]._cmdID, checked ? 1 : 0);
}

void showAlert(NSString *title, NSString *info) {
    @autoreleasepool {
        NSAlert *a = [[NSAlert alloc] init];
        a.messageText = title;
        if (info) a.informativeText = info;
        [a addButtonWithTitle:@"OK"];
        [a runModal];
    }
}

void showMissingToolAlert(NSString *tool) {
    showAlert([NSString stringWithFormat:@"D toolchain not found (%@)", tool],
        [NSString stringWithFormat:
            @"The RDMD plugin could not locate “%@”.\n\n"
            @"Install a D compiler from https://dlang.org/download.html\n"
            @"(the official installer puts the tools in ~/dlang/<compiler>/bin), "
            @"then restart Nextpad++ so the plugin can find them.\n\n"
            @"Searched: PATH, /usr/local/bin, /opt/homebrew/bin, /usr/bin, "
            @"/opt/local/bin, ~/dlang/*/bin.", tool]);
}

void showNoFileAlert() {
    showAlert(@"No file to compile",
              @"Save the current document to a file first, then use the RDMD "
              @"commands.");
}

// Resolve a D toolchain executable. Order: PATH (inherited) → common bin dirs →
// every ~/dlang/<sdk>/bin (dmd / ldc subfolders). Returns nil if not found.
NSString *resolveTool(NSString *tool) {
    NSFileManager *fm = [NSFileManager defaultManager];

    NSMutableArray<NSString *> *dirs = [NSMutableArray array];
    const char *envPath = getenv("PATH");
    if (envPath && *envPath) {
        for (NSString *d in [[NSString stringWithUTF8String:envPath]
                                componentsSeparatedByString:@":"]) {
            if (d.length) [dirs addObject:d];
        }
    }
    for (NSString *d in @[ @"/usr/local/bin", @"/opt/homebrew/bin",
                           @"/usr/bin", @"/opt/local/bin" ]) {
        if (![dirs containsObject:d]) [dirs addObject:d];
    }

    // ~/dlang/*/bin — the layout the official install.sh / curl installer uses.
    NSString *dlang = [NSHomeDirectory() stringByAppendingPathComponent:@"dlang"];
    NSArray<NSString *> *kids = [fm contentsOfDirectoryAtPath:dlang error:nil];
    for (NSString *kid in kids) {
        NSString *bin = [[dlang stringByAppendingPathComponent:kid]
                            stringByAppendingPathComponent:@"bin"];
        if (![dirs containsObject:bin]) [dirs addObject:bin];
    }

    for (NSString *d in dirs) {
        NSString *c = [d stringByAppendingPathComponent:tool];
        if ([fm isExecutableFileAtPath:c]) return c;
    }
    return nil;
}

// Open a fresh editor tab and drop `text` into it. IDM_FILE_NEW is dispatched
// async by the host, so we defer SCI_SETTEXT to the next main-queue turn, by
// which point the new buffer is the current Scintilla. (Same idiom as rustnpp.)
void showOutputInNewTab(const std::string &text) {
    NSString *ns = [NSString stringWithUTF8String:text.c_str()];
    if (!ns) ns = @"";  // guard non-UTF-8 compiler bytes
    nppData._sendMessage(nppData._nppHandle, NPPM_MENUCOMMAND, 0, (intptr_t)IDM_FILE_NEW);
    dispatch_async(dispatch_get_main_queue(), ^{
        std::string body([ns UTF8String] ? [ns UTF8String] : "");
        NppHandle sci = currentScintilla();
        if (!sci) return;
        nppData._sendMessage(sci, SCI_SETTEXT, 0, (intptr_t)body.c_str());
        nppData._sendMessage(sci, SCI_GOTOPOS, 0, 0);
    });
}

// Run `toolPath args…` (args may be empty) with working dir `cwd`, capture
// stdout+stderr, surface in a new tab. Async; the UI never blocks. A leading
// banner mirrors the command line the original showed in its console window.
void runTool(NSString *toolPath, NSArray<NSString *> *args, NSString *cwd) {
    @autoreleasepool {
        NSTask *task = [[NSTask alloc] init];
        task.executableURL = [NSURL fileURLWithPath:toolPath];
        task.arguments = args ?: @[];
        if (cwd.length) task.currentDirectoryURL = [NSURL fileURLWithPath:cwd];

        NSPipe *outPipe = [NSPipe pipe];
        NSPipe *errPipe = [NSPipe pipe];
        task.standardOutput = outPipe;
        task.standardError  = errPipe;
        task.standardInput  = [NSFileHandle fileHandleWithNullDevice];

        NSMutableString *cmdline = [NSMutableString stringWithString:toolPath.lastPathComponent];
        for (NSString *a in args) [cmdline appendFormat:@" %@", a];
        std::string banner = std::string("$ ") + [cmdline UTF8String];
        if (cwd.length) { banner += "   (cwd: "; banner += [cwd UTF8String]; banner += ")"; }
        banner += "\n\n";

        task.terminationHandler = ^(NSTask *t) {
            NSData *outData = [outPipe.fileHandleForReading readDataToEndOfFile];
            NSData *errData = [errPipe.fileHandleForReading readDataToEndOfFile];
            std::string combined = banner;
            if (outData.length) combined.append((const char *)outData.bytes, outData.length);
            if (errData.length) combined.append((const char *)errData.bytes, errData.length);
            char tail[96];
            snprintf(tail, sizeof(tail),
                     "\n[process exited with code %d]\n", (int)t.terminationStatus);
            combined.append(tail);
            dispatch_async(dispatch_get_main_queue(), ^{ showOutputInNewTab(combined); });
        };

        NSError *err = nil;
        if (![task launchAndReturnError:&err]) {
            showAlert(@"Failed to launch D toolchain",
                      err ? err.localizedDescription : @"NSTask launch failed.");
        }
    }
}

// Split a single option string ("-release -O -inline") into argv tokens.
NSArray<NSString *> *splitOptions(NSString *opts) {
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    for (NSString *tok in [opts componentsSeparatedByCharactersInSet:
                              [NSCharacterSet whitespaceCharacterSet]]) {
        if (tok.length) [out addObject:tok];
    }
    return out;
}

// ── option-string builders (verbatim from dlang_option.d, macOS subset) ──────

// dmd / rdmd flags. enableRdmd controls whether we invoke rdmd (run) vs dmd.
NSString *dmdOptions() {
    NSMutableArray<NSString *> *o = [NSMutableArray array];

    // arch
    if (g.arch == Arch::x32)      [o addObject:@"-m32"];
    else if (g.arch == Arch::x64) [o addObject:@"-m64"];

    if (g.betterC) [o addObject:@"-betterC"];

    switch (g.build) {
        case BuildType::plain:            break;
        case BuildType::debug:            [o addObject:@"-debug"]; [o addObject:@"-g"]; break;
        case BuildType::release:          [o addObject:@"-release"]; [o addObject:@"-O"]; [o addObject:@"-inline"]; break;
        case BuildType::release_debug:    [o addObject:@"-release"]; [o addObject:@"-O"]; [o addObject:@"-inline"]; [o addObject:@"-g"]; break;
        case BuildType::release_nobounds: [o addObject:@"-release"]; [o addObject:@"-O"]; [o addObject:@"-inline"]; [o addObject:@"-boundscheck=off"]; break;
        case BuildType::unittest_:        [o addObject:@"-unittest"]; [o addObject:@"-debug"]; [o addObject:@"-g"]; break;
        case BuildType::docs:             [o addObject:@"-o-"]; [o addObject:@"-c"]; [o addObject:@"-Dddocs"]; break;
        case BuildType::ddox:             [o addObject:@"-o-"]; [o addObject:@"-c"]; [o addObject:@"-Df__dummy.html"]; [o addObject:@"-Xfdocs.json"]; break;
        case BuildType::profile:          [o addObject:@"-profile"]; [o addObject:@"-O"]; [o addObject:@"-inline"]; [o addObject:@"-g"]; break;
        case BuildType::profile_gc:       [o addObject:@"-profile=gc"]; [o addObject:@"-g"]; break;
        case BuildType::cov:              [o addObject:@"-cov"]; [o addObject:@"-g"]; break;
        case BuildType::unittest_cov:     [o addObject:@"-unittest"]; [o addObject:@"-cov"]; [o addObject:@"-debug"]; [o addObject:@"-g"]; break;
        case BuildType::syntax:           [o addObject:@"-o-"]; break;
        case BuildType::none:             break;
    }

    if (g.mainFlag) [o addObject:@"-main"];
    // When invoking dmd directly (rdmd disabled), -run is needed to also run.
    if (g.enableRdmd) [o addObject:@"-run"];  // rdmd: filename follows; rdmd treats it as the script
    return [o componentsJoinedByString:@" "];
}

// ldc2 flags.
NSString *ldcOptions() {
    NSMutableArray<NSString *> *o = [NSMutableArray array];

    if (g.arch == Arch::x32)      [o addObject:@"--m32"];
    else if (g.arch == Arch::x64) [o addObject:@"--m64"];

    if (g.betterC) [o addObject:@"--betterC"];

    switch (g.build) {
        case BuildType::plain:            break;
        case BuildType::debug:            [o addObject:@"--d-debug"]; [o addObject:@"-g"]; break;
        case BuildType::release:          [o addObject:@"--release"]; [o addObject:@"--O2"]; break;
        case BuildType::release_debug:    [o addObject:@"--release"]; [o addObject:@"--O2"]; [o addObject:@"-g"]; break;
        case BuildType::release_nobounds: [o addObject:@"--release"]; [o addObject:@"--O2"]; [o addObject:@"--boundscheck=off"]; break;
        case BuildType::unittest_:        [o addObject:@"--unittest"]; [o addObject:@"--d-debug"]; [o addObject:@"-g"]; break;
        case BuildType::docs:             [o addObject:@"--o-"]; [o addObject:@"-c"]; [o addObject:@"--Dd=docs"]; break;
        case BuildType::ddox:             [o addObject:@"--o-"]; [o addObject:@"-c"]; [o addObject:@"--Df=__dummy.html"]; [o addObject:@"--Xf=docs.json"]; break;
        case BuildType::profile:          break;  // upstream left this unset for ldc
        case BuildType::profile_gc:       break;  // upstream left this unset for ldc
        case BuildType::cov:              [o addObject:@"--cov"]; [o addObject:@"-g"]; break;
        case BuildType::unittest_cov:     [o addObject:@"--unittest"]; [o addObject:@"--cov"]; [o addObject:@"--d-debug"]; [o addObject:@"-g"]; break;
        case BuildType::syntax:           [o addObject:@"--o-"]; break;
        case BuildType::none:             break;
    }

    if (g.mainFlag) [o addObject:@"--main"];
    if (g.enableRdmd) [o addObject:@"--run"];
    return [o componentsJoinedByString:@" "];
}

// dub flags (subcommand + arch + compiler + force + build).
NSString *dubOptions(NSString *compilerPath) {
    NSMutableArray<NSString *> *o = [NSMutableArray array];

    [o addObject:(g.enableRun ? @"run" : @"build")];

    if (g.arch == Arch::x32)      [o addObject:@"--arch=x86"];
    else if (g.arch == Arch::x64) [o addObject:@"--arch=x86_64"];

    if (compilerPath.length) [o addObject:[@"--compiler=" stringByAppendingString:compilerPath]];

    if (g.forceBuild) [o addObject:@"--force"];

    switch (g.build) {
        case BuildType::plain:            [o addObject:@"--build=plain"]; break;
        case BuildType::debug:            [o addObject:@"--build=debug"]; break;
        case BuildType::release:          [o addObject:@"--build=release"]; break;
        case BuildType::release_debug:    [o addObject:@"--build=release-debug"]; break;
        case BuildType::release_nobounds: [o addObject:@"--build=release-nobounds"]; break;
        case BuildType::unittest_:        [o addObject:@"--build=unittest"]; break;
        case BuildType::docs:             [o addObject:@"--build=docs"]; break;
        case BuildType::ddox:             [o addObject:@"--build=ddox"]; break;
        case BuildType::profile:          [o addObject:@"--build=profile"]; break;
        case BuildType::profile_gc:       [o addObject:@"--build=profile-gc"]; break;
        case BuildType::cov:              [o addObject:@"--build=cov"]; break;
        case BuildType::unittest_cov:     [o addObject:@"--build=unittest-cov"]; break;
        case BuildType::syntax:           [o addObject:@"--build=syntax"]; break;
        case BuildType::none:             break;
    }
    return [o componentsJoinedByString:@" "];
}

// ── core run actions ─────────────────────────────────────────────────────────

// Run the current D file with dmd (or rdmd, when Enable rdmd is checked).
void dmdRun() {
    saveCurrentFile();
    std::string f = currentNppFile();
    if (f.empty()) { showNoFileAlert(); return; }

    NSString *tool = resolveTool(g.enableRdmd ? @"rdmd" : @"dmd");
    if (!tool) { showMissingToolAlert(g.enableRdmd ? @"rdmd" : @"dmd"); return; }

    NSString *path = [NSString stringWithUTF8String:f.c_str()];
    NSString *dir  = [path stringByDeletingLastPathComponent];

    NSMutableArray<NSString *> *args = [NSMutableArray array];
    // When using rdmd we DON'T pass -run (rdmd runs by default); when using dmd
    // directly the -run from dmdOptions() makes it compile+run. Strip a stray
    // -run when the tool is rdmd (it's not a valid rdmd flag in this position).
    NSMutableArray<NSString *> *opt = [splitOptions(dmdOptions()) mutableCopy];
    if (g.enableRdmd) [opt removeObject:@"-run"];
    [args addObjectsFromArray:opt];
    [args addObject:path];
    runTool(tool, args, dir);
}

// Run the current D file with ldc2 (or rdmd driving ldc when Enable rdmd).
void ldc2Run() {
    saveCurrentFile();
    std::string f = currentNppFile();
    if (f.empty()) { showNoFileAlert(); return; }

    // The original ran rdmd next to ldc2 when Enable rdmd was set; here we use
    // ldc2 directly (rdmd defaults to dmd; faithfully driving ldc via rdmd needs
    // --compiler= and is environment-specific). Use ldc2 -run to also execute.
    NSString *tool = resolveTool(@"ldc2");
    if (!tool) { showMissingToolAlert(@"ldc2"); return; }

    NSString *path = [NSString stringWithUTF8String:f.c_str()];
    NSString *dir  = [path stringByDeletingLastPathComponent];

    NSArray<NSString *> *args = splitOptions([ldcOptions()
        stringByAppendingFormat:@" %@", path]);
    runTool(tool, args, dir);
}

// Run dub in the current file's directory (or the directory of a discovered
// dub.json/dub.sdl walking up). Mirrors dub_run / dub_action.
void dubRun() {
    saveCurrentFile();
    std::string f = currentNppFile();
    if (f.empty()) { showNoFileAlert(); return; }

    NSString *tool = resolveTool(@"dub");
    if (!tool) { showMissingToolAlert(@"dub"); return; }

    NSString *path = [NSString stringWithUTF8String:f.c_str()];
    NSFileManager *fm = [NSFileManager defaultManager];

    // Walk up to the nearest directory containing dub.json/dub.sdl.
    NSString *dir = [path stringByDeletingLastPathComponent];
    NSString *projDir = nil;
    for (NSString *p = dir; p.length && ![p isEqualToString:@"/"];
         p = [p stringByDeletingLastPathComponent]) {
        BOOL isDir = NO;
        if (([fm fileExistsAtPath:[p stringByAppendingPathComponent:@"dub.json"] isDirectory:&isDir] && !isDir) ||
            ([fm fileExistsAtPath:[p stringByAppendingPathComponent:@"dub.sdl"]  isDirectory:&isDir] && !isDir)) {
            projDir = p;
            break;
        }
    }
    if (!projDir) projDir = dir;

    // The dub --compiler= path uses the chosen compiler radio.
    NSString *compilerPath = resolveTool(g.compiler == Compiler::ldc2 ? @"ldc2" : @"dmd");
    NSArray<NSString *> *args = splitOptions(dubOptions(compilerPath ?: @""));
    runTool(tool, args, projDir);
}

// Auto run: infer from current language / extension, then run. Mirrors auto_run
// → auto_action. D → dmd/ldc per the compiler radio; the P-languages run their
// interpreter (python/ruby/php); Go → `go run`; others fall through.
void autoRun() {
    saveCurrentFile();
    std::string f = currentNppFile();
    if (f.empty()) { showNoFileAlert(); return; }

    NSString *path = [NSString stringWithUTF8String:f.c_str()];
    NSString *ext  = [[path pathExtension] lowercaseString];
    int lang = currentLangType();

    // dub project file? run dub directly.
    NSString *base = [[path lastPathComponent] lowercaseString];
    if ([base isEqualToString:@"dub.json"] || [base isEqualToString:@"dub.sdl"]) {
        dubRun();
        return;
    }

    // D source.
    if (lang == L_D || [ext isEqualToString:@"d"]) {
        if (g.compiler == Compiler::ldc2) ldc2Run(); else dmdRun();
        return;
    }

    // Scripting languages: run their interpreter on the file.
    struct { int lang; const char *ext; const char *tool; } kP[] = {
        { L_PYTHON, "py",  "python3" },
        { L_RUBY,   "rb",  "ruby"    },
        { L_PHP,    "php", "php"     },
    };
    for (auto &p : kP) {
        if (lang == p.lang || [ext isEqualToString:[NSString stringWithUTF8String:p.ext]]) {
            NSString *toolName = [NSString stringWithUTF8String:p.tool];
            NSString *tool = resolveTool(toolName);
            if (!tool && [toolName isEqualToString:@"python3"]) {
                tool = resolveTool(@"python");  // fall back to a python2-named binary
            }
            if (!tool) { showMissingToolAlert(toolName); return; }
            runTool(tool, @[ path ], [path stringByDeletingLastPathComponent]);
            return;
        }
    }

    // Go: `go run <file>` (Enable rdmd → run, else build), matching upstream.
    if (lang == L_GOLANG || [ext isEqualToString:@"go"]) {
        NSString *go = resolveTool(@"go");
        if (!go) { showMissingToolAlert(@"go"); return; }
        runTool(go, @[ (g.enableRun || g.enableRdmd) ? @"run" : @"build", path ],
                [path stringByDeletingLastPathComponent]);
        return;
    }

    // Rust: stand-alone rustc (parity with the bundled hello.rs starter).
    if (lang == L_RUST || [ext isEqualToString:@"rs"]) {
        NSString *rustc = resolveTool(@"rustc");
        if (!rustc) { showMissingToolAlert(@"rustc"); return; }
        runTool(rustc, @[ [path lastPathComponent] ],
                [path stringByDeletingLastPathComponent]);
        return;
    }

    showAlert(@"Auto run: unsupported language",
              @"RDMD Auto run handles D, Python, Ruby, PHP, Go and Rust files. "
              @"Use the dmd / ldc2 / dub commands for explicit control.");
}

// Search up from the current file for a dub.json/dub.sdl and report it.
// (The Windows version cd'd its console there + loaded the project; on macOS
// there is no persistent console, so we surface what we found.)
void searchDub() {
    std::string f = currentNppFile();
    if (f.empty()) { showNoFileAlert(); return; }
    NSString *path = [NSString stringWithUTF8String:f.c_str()];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dir = [path stringByDeletingLastPathComponent];
    for (NSString *p = dir; p.length && ![p isEqualToString:@"/"];
         p = [p stringByDeletingLastPathComponent]) {
        for (NSString *fn in @[ @"dub.json", @"dub.sdl" ]) {
            NSString *cand = [p stringByAppendingPathComponent:fn];
            BOOL isDir = NO;
            if ([fm fileExistsAtPath:cand isDirectory:&isDir] && !isDir) {
                showAlert(@"DUB project found", cand);
                return;
            }
        }
    }
    showAlert(@"No DUB project found",
              @"No dub.json / dub.sdl was found walking up from the current "
              @"file's directory.");
}

// ── "new Hello file" commands ────────────────────────────────────────────────

// Default starter content if the bundled template isn't present.
const char *defaultHello(NSString *ext) {
    if ([ext isEqualToString:@"d"])   return "import std;\n\nvoid main(string[] argv)\n{\n\twriteln(\"Hello, World!\");\n}\n";
    if ([ext isEqualToString:@"go"])  return "package main\n\nfunc main() {\n\tprint(\"Hello, World!\", \"\\n\");\n}\n";
    if ([ext isEqualToString:@"php"]) return "<?php\ndeclare(strict_types=1);\n\necho 'Hello, World!';\n";
    if ([ext isEqualToString:@"py"])  return "print(\"Hello, World!\")\n";
    if ([ext isEqualToString:@"rb"])  return "puts \"Hello, World!\"\n";
    if ([ext isEqualToString:@"rs"])  return "fn main()\n{\n\tprintln!(\"Hello, World!\");\n}\n";
    return "";
}

// Load hello.<ext> from the user's plugin config dir (rdmd/hello/<f>) if the
// user customised it, else the bundled resources/hello/<f>, else built-in.
// Mirrors create_hello / internal_create_hello: open a NEW tab + set the text.
void createHelloForExt(NSString *ext) {
    if (!ext.length) return;
    NSString *fname = [@"hello." stringByAppendingString:ext];

    std::string body;
    @autoreleasepool {
        NSFileManager *fm = [NSFileManager defaultManager];

        // 1) user override: <pluginsConfigDir>/rdmd/hello/hello.<ext>
        std::string cfg = pluginsConfigDir();
        NSString *userFile = nil;
        if (!cfg.empty()) {
            userFile = [[[[NSString stringWithUTF8String:cfg.c_str()]
                            stringByAppendingPathComponent:@"rdmd"]
                            stringByAppendingPathComponent:@"hello"]
                            stringByAppendingPathComponent:fname];
        }
        // 2) bundled: <dylibdir>/resources/hello/hello.<ext>
        NSString *bundled = [[resourcesDir() stringByAppendingPathComponent:@"hello"]
                                stringByAppendingPathComponent:fname];

        NSString *content = nil;
        if (userFile && [fm fileExistsAtPath:userFile])
            content = [NSString stringWithContentsOfFile:userFile encoding:NSUTF8StringEncoding error:nil];
        if (!content && bundled && [fm fileExistsAtPath:bundled])
            content = [NSString stringWithContentsOfFile:bundled encoding:NSUTF8StringEncoding error:nil];
        if (content) body = std::string([content UTF8String] ? [content UTF8String] : "");
        else         body = std::string(defaultHello(ext));
    }
    showOutputInNewTab(body);
}

void createHelloFromCurrentLang() {
    // Derive the extension from the current buffer's path, else its language.
    std::string f = currentNppFile();
    NSString *ext = nil;
    if (!f.empty()) {
        ext = [[[NSString stringWithUTF8String:f.c_str()] pathExtension] lowercaseString];
    }
    if (!ext.length) {
        switch (currentLangType()) {
            case L_D:      ext = @"d";   break;
            case L_GOLANG: ext = @"go";  break;
            case L_PHP:    ext = @"php"; break;
            case L_PYTHON: ext = @"py";  break;
            case L_RUBY:   ext = @"rb";  break;
            case L_RUST:   ext = @"rs";  break;
            default:       ext = @"d";   break;  // upstream's natural default
        }
    }
    createHelloForExt(ext);
}

void helloD()    { createHelloForExt(@"d");   }
void helloGo()   { createHelloForExt(@"go");  }
void helloPHP()  { createHelloForExt(@"php"); }
void helloPy()   { createHelloForExt(@"py");  }
void helloRuby() { createHelloForExt(@"rb");  }
void helloRust() { createHelloForExt(@"rs");  }

// ── folders / web ────────────────────────────────────────────────────────────

void openHelloFolder() {
    @autoreleasepool {
        NSFileManager *fm = [NSFileManager defaultManager];
        std::string cfg = pluginsConfigDir();
        NSString *dir = nil;
        if (!cfg.empty()) {
            dir = [[[NSString stringWithUTF8String:cfg.c_str()]
                      stringByAppendingPathComponent:@"rdmd"]
                      stringByAppendingPathComponent:@"hello"];
            [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        }
        // Seed it with the bundled templates the first time, so the user has
        // something to edit (mirrors the original shipping a hello/ dir).
        if (dir.length) {
            NSString *bundled = [resourcesDir() stringByAppendingPathComponent:@"hello"];
            for (NSString *fn in @[ @"hello.d", @"hello.go", @"hello.php",
                                    @"hello.py", @"hello.rb", @"hello.rs" ]) {
                NSString *dst = [dir stringByAppendingPathComponent:fn];
                NSString *src = [bundled stringByAppendingPathComponent:fn];
                if (![fm fileExistsAtPath:dst] && [fm fileExistsAtPath:src])
                    [fm copyItemAtPath:src toPath:dst error:nil];
            }
            [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:dir]];
        }
    }
}

void openConfigFolder() {
    @autoreleasepool {
        std::string cfg = pluginsConfigDir();
        if (!cfg.empty())
            [[NSWorkspace sharedWorkspace]
                openURL:[NSURL fileURLWithPath:[NSString stringWithUTF8String:cfg.c_str()]]];
    }
}

void openURL(NSString *u) {
    [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:u]];
}
void webPluginTop()  { openURL(@"https://gitlab.com/dokutoku/rdmd-for-npp"); }
void webNppApi()     { openURL(@"https://gitlab.com/dokutoku/npp-api"); }
void webDlangTop()   { openURL(@"https://dlang.org/index.html"); }
void webDlangSpec()  { openURL(@"https://dlang.org/spec/spec.html"); }
void webPhobos()     { openURL(@"https://dlang.org/phobos/index.html"); }
void webDlangApi()   { openURL(@"https://dlang.org/library/index.html"); }
void webDub()        { openURL(@"https://code.dlang.org/"); }
void webWiki()       { openURL(@"https://wiki.dlang.org/The_D_Programming_Language"); }
void webForum()      { openURL(@"https://forum.dlang.org/"); }
void webDmdDl()      { openURL(@"https://dlang.org/download.html"); }
void webLdcDl()      { openURL(@"https://github.com/ldc-developers/ldc/releases"); }
void webAuthor()     { openURL(@"https://gitlab.com/dokutoku"); }
void webDonate()     { openURL(@"https://dokutoku.gitlab.io/donation/donation-en.html"); }

void showAbout() {
    showAlert(@"RDMD for Notepad++",
              @"Version: 1.0.0 (macOS port of dokutoku's 0.1.0.2)\n\n"
              @"License: GPL-2.0-or-later\n\n"
              @"Author: dokutoku  —  macOS port for Nextpad++\n\n"
              @"Compiles / runs the current D source via the D toolchain "
              @"(rdmd / dmd / ldc2 / dub); output opens in a new tab.");
}

// ── radio / checkbox handling ────────────────────────────────────────────────
// One named handler per checkable item — exactly like the original's per-item
// check_* functions. Each handler mutates g, then re-syncs the menu checkmarks
// for its radio group (or its own checkbox). Mirroring checkmarks back to the
// host is best-effort (NPPM_SETMENUITEMCHECK); the option-string builders read
// g, so the *behaviour* is always correct regardless of the visual checkmark.

// Refresh all checkmarks for one radio group, given the field's current value.
void syncArchChecks();
void syncBuildChecks();
void syncCompilerChecks();

// Find the gMenu index of an entry by its exact name (linear; tiny menu).
int indexOfName(const char *name) {
    for (int i = 0; i < (int)gMenu.size(); i++)
        if (gMenu[i].name == name) return i;
    return -1;
}

void syncCompilerChecks() {
    setMenuCheck(indexOfName("Compiler: dmd"),  g.compiler == Compiler::dmd);
    setMenuCheck(indexOfName("Compiler: ldc2"), g.compiler == Compiler::ldc2);
}
void syncArchChecks() {
    setMenuCheck(indexOfName("x32"), g.arch == Arch::x32);
    setMenuCheck(indexOfName("x64"), g.arch == Arch::x64);
}
void syncBuildChecks() {
    struct { const char *name; BuildType v; } items[] = {
        {"Build: plain", BuildType::plain}, {"Build: debug", BuildType::debug},
        {"Build: release", BuildType::release}, {"Build: release-debug", BuildType::release_debug},
        {"Build: release-nobounds", BuildType::release_nobounds}, {"Build: unittest", BuildType::unittest_},
        {"Build: docs", BuildType::docs}, {"Build: ddox", BuildType::ddox},
        {"Build: profile", BuildType::profile}, {"Build: profile-gc", BuildType::profile_gc},
        {"Build: cov", BuildType::cov}, {"Build: unittest-cov", BuildType::unittest_cov},
        {"Build: syntax", BuildType::syntax},
    };
    for (auto &it : items) setMenuCheck(indexOfName(it.name), g.build == it.v);
}

// Compiler radio.
void chooseCompilerDmd()  { g.compiler = Compiler::dmd;  syncCompilerChecks(); }
void chooseCompilerLdc2() { g.compiler = Compiler::ldc2; syncCompilerChecks(); }
// Arch radio.
void chooseX32() { g.arch = Arch::x32; syncArchChecks(); }
void chooseX64() { g.arch = Arch::x64; syncArchChecks(); }
// Build-type radio. A second click on the active type clears it (back to none),
// matching the original where unchecking a build type leaves no flags.
void chooseBuild(BuildType v) { g.build = (g.build == v) ? BuildType::none : v; syncBuildChecks(); }
void buildPlain()           { chooseBuild(BuildType::plain); }
void buildDebug()           { chooseBuild(BuildType::debug); }
void buildRelease()         { chooseBuild(BuildType::release); }
void buildReleaseDebug()    { chooseBuild(BuildType::release_debug); }
void buildReleaseNobounds() { chooseBuild(BuildType::release_nobounds); }
void buildUnittest()        { chooseBuild(BuildType::unittest_); }
void buildDocs()            { chooseBuild(BuildType::docs); }
void buildDdox()            { chooseBuild(BuildType::ddox); }
void buildProfile()         { chooseBuild(BuildType::profile); }
void buildProfileGc()       { chooseBuild(BuildType::profile_gc); }
void buildCov()             { chooseBuild(BuildType::cov); }
void buildUnittestCov()     { chooseBuild(BuildType::unittest_cov); }
void buildSyntax()          { chooseBuild(BuildType::syntax); }
// Plain checkboxes.
void toggleBetterC()  { g.betterC    = !g.betterC;    setMenuCheck(indexOfName("-betterC"), g.betterC); }
void toggleMain()     { g.mainFlag   = !g.mainFlag;   setMenuCheck(indexOfName("--main"), g.mainFlag); }
void toggleRdmd()     { g.enableRdmd = !g.enableRdmd; setMenuCheck(indexOfName("Enable rdmd"), g.enableRdmd); }
void toggleForce()    { g.forceBuild = !g.forceBuild; setMenuCheck(indexOfName("--force (dub)"), g.forceBuild); }
void toggleEnableRun(){ g.enableRun  = !g.enableRun;  setMenuCheck(indexOfName("Enable run (dub)"), g.enableRun); }

// Helpers to populate gMenu.
void addSep() {
    gMenu.push_back(MenuEntry{ std::string(), nullptr, false });
}
void addCmd(const std::string &name, PFUNCPLUGINCMD fn, bool check = false) {
    gMenu.push_back(MenuEntry{ name, fn, check });
}

void buildMenu() {
    gMenu.clear();

    // "New Hello file" set (create_hello / auto_create_hello).
    addCmd("New file from current lang", createHelloFromCurrentLang);
    addCmd("New Hello: D",      helloD);
    addCmd("New Hello: Go",     helloGo);
    addCmd("New Hello: PHP",    helloPHP);
    addCmd("New Hello: Python", helloPy);
    addCmd("New Hello: Ruby",   helloRuby);
    addCmd("New Hello: Rust",   helloRust);
    addSep();

    // Default compiler (radio) — drives Auto run + dub --compiler=.
    addCmd("Compiler: dmd",  chooseCompilerDmd,  g.compiler == Compiler::dmd);
    addCmd("Compiler: ldc2", chooseCompilerLdc2, g.compiler == Compiler::ldc2);
    addSep();

    // Arch (radio).
    addCmd("x32", chooseX32, g.arch == Arch::x32);
    addCmd("x64", chooseX64, g.arch == Arch::x64);
    addSep();

    // Build type (radio).
    addCmd("Build: plain",            buildPlain,           false);
    addCmd("Build: debug",            buildDebug,           false);
    addCmd("Build: release",          buildRelease,         false);
    addCmd("Build: release-debug",    buildReleaseDebug,    false);
    addCmd("Build: release-nobounds", buildReleaseNobounds, false);
    addCmd("Build: unittest",         buildUnittest,        false);
    addCmd("Build: docs",             buildDocs,            false);
    addCmd("Build: ddox",             buildDdox,            false);
    addCmd("Build: profile",          buildProfile,         false);
    addCmd("Build: profile-gc",       buildProfileGc,       false);
    addCmd("Build: cov",              buildCov,             false);
    addCmd("Build: unittest-cov",     buildUnittestCov,     false);
    addCmd("Build: syntax",           buildSyntax,          false);
    addSep();

    // dmd / ldc2 explicit run + their flags.
    addCmd("dmd",  dmdRun);
    addCmd("ldc2", ldc2Run);
    addCmd("-betterC",    toggleBetterC, g.betterC);
    addCmd("--main",      toggleMain,    g.mainFlag);
    addCmd("Enable rdmd", toggleRdmd,    g.enableRdmd);
    addSep();

    // dub + its flags.
    addCmd("dub", dubRun);
    addCmd("--force (dub)",    toggleForce,     g.forceBuild);
    addCmd("Enable run (dub)", toggleEnableRun, g.enableRun);
    addSep();

    // Find dub + Auto run (the headline ALT+R command).
    addCmd("Search dub from this file", searchDub);
    addCmd("Auto run", autoRun);
    addSep();

    // Folders.
    addCmd("Open hello world folder", openHelloFolder);
    addCmd("Open config folder",      openConfigFolder);
    addSep();

    // Web sites (the original's "Web Sites" submenu, flattened).
    addCmd("Web: this plugin",  webPluginTop);
    addCmd("Web: NPP API",      webNppApi);
    addCmd("Web: dlang Top",    webDlangTop);
    addCmd("Web: dlang Spec",   webDlangSpec);
    addCmd("Web: Phobos",       webPhobos);
    addCmd("Web: dlang API",    webDlangApi);
    addCmd("Web: DUB",          webDub);
    addCmd("Web: Wiki",         webWiki);
    addCmd("Web: Forum",        webForum);
    addCmd("Web: Download DMD", webDmdDl);
    addCmd("Web: Download LDC", webLdcDl);
    addCmd("Web: Author",       webAuthor);
    addCmd("Web: Donate",       webDonate);
    addSep();

    addCmd("About", showAbout);
}

} // namespace

// ── plugin exports ───────────────────────────────────────────────────────────

extern "C" NPP_EXPORT void setInfo(NppData data) {
    nppData = data;
    buildMenu();

    gFuncItems.assign(gMenu.size(), FuncItem{});
    for (size_t i = 0; i < gMenu.size(); i++) {
        memset(&gFuncItems[i], 0, sizeof(FuncItem));
        strncpy(gFuncItems[i]._itemName, gMenu[i].name.c_str(), NPP_MENU_ITEM_SIZE - 1);
        gFuncItems[i]._pFunc      = gMenu[i].fn;   // nullptr => separator
        gFuncItems[i]._init2Check = gMenu[i].init2Check;
        gFuncItems[i]._pShKey     = nullptr;        // host ignores plugin shortcuts
    }
}

extern "C" NPP_EXPORT const char *getName() { return PLUGIN_NAME; }

extern "C" NPP_EXPORT FuncItem *getFuncsArray(int *nbF) {
    *nbF = (int)gFuncItems.size();
    return gFuncItems.data();
}

extern "C" NPP_EXPORT void beNotified(SCNotification *n) { (void)n; }

extern "C" NPP_EXPORT intptr_t messageProc(uint32_t m, uintptr_t w, intptr_t l) {
    (void)m; (void)w; (void)l; return 1;
}
