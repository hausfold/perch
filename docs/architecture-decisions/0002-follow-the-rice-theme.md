# ADR 0002: Follow the rice theme through a read-only config drop

Status: accepted

## Context

The shelf was white-on-black with one sage literal, so `haus.theme.flavor`
and `.contrast` were a lie for perch: a latte rice still got a black glass panel,
and a nebelung palette bump could only reach perch through a rebuild. Pounce
already solves this — a rice-written JSON names a palette per polarity, and the
app resolves it at runtime — but pounce is not sandboxed, and perch is.

Perch's own settings (displays, retention, launch at login) live in
`UserDefaults`, which Nix has no business writing. What the rice owns is the
theme, and nothing else.

## Decision

Perch reads two things under `~/.config/perch/`, both optional:

- `config.json` — `{ "themeDark": …, "themeLight": … }`, the palette per
  polarity. The macOS appearance picks the half.
- `themes/<name>.json` — a flat catppuccin-style `role → "#hex"` map, i.e. a
  nebelung `*.hex.json` verbatim. A file **shadows** the compiled-in variant of
  the same name.

The four nebelung variants are compiled in, so a Homebrew install with an empty
`~/.config` still gets the right colors and a malformed or missing file always
falls back rather than failing. There is no in-app theme picker: the shelf is a
five-second surface with nowhere to put one, so the rice's word is final and the
resolution order is just `config.json › compiled-in nebelung`.

Reaching outside the container costs one entitlement —
`com.apple.security.temporary-exception.files.home-relative-path.read-only` for
`/.config/perch/`. Read-only, one directory, and the only path perch opens that a
drag or a file picker did not hand it.

## Consequences

The sandbox is one directory wider than it was. That is a real cost and the
reason the exception is read-only and singular: perch can look at its own theme
and at nothing else, and it still asks for no Accessibility, no input taps, and
no Full Disk Access.

Two knock-on constraints, both load-bearing:

- **The rice must write real files, not symlinks.** The sandbox resolves a
  symlink before it checks the path, so home-manager's usual `xdg.configFile`
  link into `/nix/store` reads as a store access and is denied — the shelf would
  silently sit on compiled-in nebelung. `haus/modules/perch` copies the drop
  in an activation script instead.
- **The real home has to come from the passwd entry.** Inside the sandbox
  `NSHomeDirectory()` and `homeDirectoryForCurrentUser` both answer with the
  container, so `~/.config` is only nameable via `getpwuid`.

Perch parses seven of nebelung's twenty-three roles and ignores the rest, so the
palette files stay interchangeable with every other app the rice themes — a new
role is a code change here, not a file-format change.
