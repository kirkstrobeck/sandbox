# Hot reload

You save a file in your editor on the Mac. The dev server inside the container
rebuilds, and the browser updates. That works, and it takes a bridge to make it
work — this is why.

## The problem: virtiofs does not deliver inotify events

The repo reaches the container over a virtiofs bind mount. When you save a file
on macOS, the bytes change in the guest, and no guest inotify event is
generated. The write happened outside the guest kernel, so the guest kernel has
nothing to report.

Every dev server built on inotify — Next, Vite, webpack, nodemon, `tsc --watch`
— therefore sees nothing at all. Not a delayed event, not a coalesced one:
nothing. You sit there wondering why hot reload is broken while the file on disk
is plainly correct.

What virtiofs *does* expose is metadata. `stat` in the guest returns the new
mtime and size immediately. That is the hook everything below hangs on.

## Three approaches that failed, all the same way

- Colima's `--mount-inotify`, which signals a change by `chmod`-ing the guest
  file.
- A host-side script that rewrites file contents to force an event.
- A host-side FS bridge doing the same from the other direction.

Each one writes to a shared mount. Each write propagates back across the
boundary. Each propagation looks like a fresh change to the other side. The
result is a feedback loop that keeps firing with nobody typing — 34 inotify
events in a 15-second window on a file no one had touched, and rebuild storms
that make the machine unusable.

`boot.sh` actively stops the Colima `--mount-inotify` daemon for this reason;
see [colima.md](colima.md).

## Why not just turn on the framework's polling option

Because bundlers poll from the project root, not from your source directory. On
a repo of ~20k files that measured:

| | Time to detect one change |
| --- | --- |
| Framework polling from the repo root | **15,400 ms** |
| Native inotify watcher, fed by this bridge | **91 ms** |

Two orders of magnitude, and the slow number is not an outlier you can tune
away — it is the cost of stat-ing the world on every tick over virtiofs.

The fix is to move the polling somewhere narrow. Poll a short list of source
directories, and let the framework's real watcher stay native.

This is also why you should not add a polling watcher to your dev server to
"fix" hot reload in the container. It is already fixed, and turning on polling
replaces the 91 ms path with the 15,400 ms one.

## What works: `mac-save-bridge.mjs`

`tools/sandbox/mac-save-bridge.mjs` runs **inside the container**, started in
the background by `ensure_mac_save_bridge` in `dev-fs.sh` on every `./sandbox
up`.

It does one thing:

1. Walk the configured watch roots and record `mtimeMs:size` for every file
   matching the source pattern.
2. Every interval, walk again. When a file's stamp has genuinely changed, read
   its bytes and write them back over itself — `open` with `r+`, write at offset
   0, same length, no truncate.
3. Re-stat and store the mtime *our own write* produced.

Step 2 is the trick. That rewrite is a native guest write, so the guest kernel
emits a real inotify event, and every watcher in the container wakes up
normally. The content is byte-identical, so nothing is lost even if the rewrite
races an editor save. And because the write originates inside the guest, it does
not come back across the boundary as a new host-side change — which is exactly
what the three failed approaches could not avoid.

Step 3 is what makes self-triggering impossible rather than merely unlikely: the
bridge remembers the mtime it caused, so it never sees its own write as a
change.

Two details that keep it quiet:

- **A priming pass on startup** records a baseline without touching anything.
  Without it, the first sweep would "change" every file in the tree and trigger
  a full rebuild every time the bridge starts.
- **Empty files are skipped** (nothing to write, nothing to signal), and a file
  renamed or deleted mid-sweep is skipped rather than treated as an error.
  Directories named `node_modules`, `.next`, `.git`, `.turbo`, `dist`, `build`,
  `coverage`, and `.cache` are never walked.

On start it prints what it is doing, and `./sandbox status` shows the same:

```
mac-save-bridge: watching /workspace/src every 250ms (1274 files)
```

`ensure_mac_save_bridge` kills any existing bridge before starting a new one. A
bridge left over from a previous boot is watching whatever roots *that* boot
configured, and leaving it running is how a config change appears to have no
effect.

## The knobs

All three live in `tools/sandbox/sandbox.conf` and are passed to the bridge as
environment variables. Change any of them, then `./sandbox up` to restart the
bridge — no rebuild, no container recreation.

### `SANDBOX_WATCH_DIRS`

Repo-relative directories the bridge walks. Space or newline separated,
translated to absolute container paths (`src` → `/workspace/src`) by
`watch_roots` in `dev-fs.sh`.

```bash
SANDBOX_WATCH_DIRS="src"
SANDBOX_WATCH_DIRS="apps/web/src packages/ui/src"   # a monorepo
```

Keep these tight and pointed at your actual source roots. The bridge polls, and
polling the whole repo is precisely the thing that measured 15,400 ms. Setting
it empty disables the bridge entirely.

### `SANDBOX_WATCH_INTERVAL_MS`

Sweep interval, default `250`. This is the latency you feel between saving on
the Mac and the rebuild starting. Lower it if saves feel sluggish; raise it if a
large watch tree is costing noticeable CPU inside the container. Anything below
about 100 ms mostly buys you sweeps that overlap the previous one's work.

### `SANDBOX_WATCH_EXT`

A JavaScript regex, no delimiters, matched against each filename. Only matching
files are stamped and rewritten.

```bash
SANDBOX_WATCH_EXT="\\.(tsx?|jsx?|mjs|cjs|css|scss|json|svelte|vue)$"
```

Add extensions your framework actually watches; leave off anything generated. It
is a shell string being handed to `new RegExp`, so backslashes need doubling, as
above.

## When it stops working

**Saves on the Mac do not rebuild in the container.** Check `./sandbox status`
for the hot-reload line. If it says `stopped`, run `./sandbox up`. If it is
watching the wrong roots, fix `SANDBOX_WATCH_DIRS` and run `./sandbox up` again
— the bridge restarts rather than being reused.

**A file type never triggers a rebuild.** It is not matching
`SANDBOX_WATCH_EXT`, or it lives outside `SANDBOX_WATCH_DIRS`.

**Constant rebuilds with nobody typing.** Something else is writing into the
mount. The usual culprit is a Colima `--mount-inotify` daemon that came back;
`./sandbox up` stops it, and `./sandbox doctor` reports it.

**The browser cannot reach the dev server.** That is not hot reload. The server
must bind `0.0.0.0` inside the container — binding `127.0.0.1` makes it
unreachable from the Mac — and the port must be published in `SANDBOX_PORTS`.
See [configuration.md](configuration.md).
