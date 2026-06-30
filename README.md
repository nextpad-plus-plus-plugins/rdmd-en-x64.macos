# RDMD for Notepad++ (macOS)

A macOS port of **“RDMD for Notepad++”** (the English build, `rdmd-en-x64`) by
[dokutoku](https://gitlab.com/dokutoku/rdmd-for-npp) — a plugin that
compiles / runs the currently open **D-language** source file via the D toolchain
(`rdmd` / `dmd` / `ldc2` / `dub`) and shows the output.

The original is written in the **D language** itself and drives a real Windows
console (`CreateProcessW` + `CREATE_NEW_CONSOLE`, `AttachConsole`,
`WriteConsoleInputW`). This is a **from-scratch re-implementation of its feature**
in Objective-C++ as a standard native Nextpad++ / Notepad++-macOS plugin — it is
**not** a recompile of the D source.

## Commands (under **Plugins → RDMD for Notepad++**)

Run / build:

- **dmd** — compile/run the current file with `dmd` (or `rdmd` when *Enable rdmd*
  is checked).
- **ldc2** — compile/run with `ldc2`.
- **dub** — run `dub run` / `dub build` in the nearest directory containing a
  `dub.json` / `dub.sdl` (walking up from the current file).
- **Auto run** — infer the language from the current buffer and run it: D →
  `dmd`/`ldc2` (per the *Compiler* choice), Python/Ruby/PHP → their interpreter,
  Go → `go run`, Rust → `rustc`. (This is the original's headline **Alt+R**
  action.)
- **Search dub from this file** — locate the project's `dub.json`/`dub.sdl`.

Options (mirrored verbatim from the original `dlang_option.d`):

- **Compiler**: `dmd` / `ldc2` (radio — drives Auto run and `dub --compiler=`).
- **Arch**: `x32` / `x64`.
- **Build type**: `plain`, `debug`, `release`, `release-debug`,
  `release-nobounds`, `unittest`, `docs`, `ddox`, `profile`, `profile-gc`,
  `cov`, `unittest-cov`, `syntax` (each emits exactly the original's flag set for
  the chosen compiler / dub).
- Flags: `-betterC`, `--main`, `Enable rdmd`, and for dub `--force` /
  `Enable run`.

“New Hello file” starters (`D`, `Go`, `PHP`, `Python`, `Ruby`, `Rust`) open a new
tab pre-filled with the bundled template (or your customised copy in the config
dir — see *Open hello world folder*). Plus the original's **Web Sites** links
(dlang.org, Phobos, DUB, downloads, …), **Open config folder**, and **About**.

## Output

Each command runs as a one-shot **`NSTask`**; its combined **stdout + stderr**
(plus an exit-code line and a banner echoing the command) is opened in a **new
editor tab**. This is the macOS-native equivalent of the original popping a
console window — there is no per-plugin console window on macOS, and a new tab is
the established Notepad++-macOS idiom for command output.

## Toolchain discovery

The Windows original assumed the tools were reachable (it looked under
`%HOMEDRIVE%` for LDC and otherwise relied on `PATH`). A GUI app on macOS
inherits a minimal `PATH`, so this port searches:

`PATH` → `/usr/local/bin`, `/opt/homebrew/bin`, `/usr/bin`, `/opt/local/bin` →
every `~/dlang/*/bin` (the layout the official D installer uses, e.g.
`~/dlang/dmd-2.109.1/bin`, `~/dlang/ldc-1.39.0/bin`).

If a needed tool can’t be found, the plugin shows an **NSAlert** pointing at
<https://dlang.org/download.html> — it never crashes and does nothing
destructive.

## Differences from the Windows original (and host limitations)

This port deliberately drops a few Windows-only menu items; the host is **not**
modified to accommodate them:

- **The whole “Console” group** — *Open/Close Console*, *Change Console* (cmd /
  PowerShell / other exe), *Enable msvcEnv.bat*, *Enable startup console*. These
  manage a persistent Win32 console that has no macOS equivalent; here every
  compile is a one-shot `NSTask` to a tab.
- **Windows-only build knobs** — `-m32mscoff` / `x86 mscoff`, and the LDC
  cross-compile `--mtriple` targets (which all point at Windows triples in the
  original). The `x32`/`x64` arch radio is kept (`-m32`/`-m64`, `--m32`/`--m64`,
  `--arch=x86`/`x86_64`).
- **Force D-language style** — the original sent `NPPM_SETCURRENTLANGTYPE(L_D)`
  before opening output / hello tabs. That message is **not implemented** by the
  macOS host (no-op), so new tabs are not auto-restyled. (Documented; host left
  untouched.)
- **Keyboard shortcuts** — the original bound Alt+R (Auto run), Alt+D (dub),
  Alt+L (ldc2), Alt+C (find dub), etc. The macOS host **ignores plugin-supplied
  shortcuts** (`FuncItem._pShKey`), so none are bound. Invoke the commands from
  the Plugins menu.
- **Persistent console `cd`** — *cd file/project directory* (which typed `cd`
  into the live console) are dropped; *Open … folder* commands reveal the
  directory in Finder instead.

## Build

```sh
cmake -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j
```

Produces a universal (arm64 + x86_64) `rdmd.dylib`. `cmake --install build`
copies it (and the bundled `resources/hello/` templates) to
`~/Library/Application Support/Nextpad++/plugins/rdmd/`.

## License

GPL-2.0-or-later (same as the original; see `LICENSE`). Original plugin
© dokutoku.
