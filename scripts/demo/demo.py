#!/usr/bin/env python3
"""Upthere demo toolkit: stage scenes on the real notch, record them, cut
GitHub GIFs, 9:16 reels and 16:9 / square showreels from the same take.

    scripts/demo/demo.py list
    scripts/demo/demo.py run <scene>             rehearse live, nothing recorded
    scripts/demo/demo.py record <scene>...       raw takes → build/demo/raw
    scripts/demo/demo.py render <scene>...       gif + reel + wide + square → build/demo/out
    scripts/demo/demo.py showreel <fmt> <cut|scene[@in-out]>...
                                                 intro card, scenes cross-faded, outro card

Needs a Debug build of Upthere running (the DebugBridge), ffmpeg + gifski,
and Screen Recording permission for the app that runs this script.
Spotify is driven for real: start it on the track you want before recording,
or pass --track spotify:track:… to have each scene start it.
"""

import argparse
import json
import os
import shutil
import socket
import subprocess
import sys
import time
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
WORK = ROOT / "build" / "demo"
RAW, OUT, CACHE = WORK / "raw", WORK / "out", WORK / "cache"
SOCKET = Path.home() / "Library/Application Support/upthere/claude.sock"
LEAD = 1.5  # seconds recorded before a scene starts; trimmed on render

# ---------------------------------------------------------------- staging


def notchctl_binary():
    """scripts/debug-notch.swift, compiled once: `swift file.swift` takes
    over a second per call, too slow for choreography."""
    binary = CACHE / "notchctl"
    source = ROOT / "scripts" / "debug-notch.swift"
    if not binary.exists() or binary.stat().st_mtime < source.stat().st_mtime:
        CACHE.mkdir(parents=True, exist_ok=True)
        subprocess.run(["swiftc", "-O", str(source), "-o", str(binary)], check=True)
    return binary


def notchctl(mode, snapshot=None):
    subprocess.run([str(notchctl_binary()), mode] + ([snapshot, "300"] if snapshot else []), check=True)


def osascript(script):
    subprocess.run(["osascript", "-e", script], check=True, capture_output=True)


class Director:
    """What a scene calls. In dry mode only the clock moves, which is how a
    scene's length is known before recording it."""

    def __init__(self, dry=False, track=None):
        self.dry, self.track, self.clock = dry, track, 0.0
        self.sessions = []
        self.cameras = []  # (time, preset): where the reel's camera heads

    def camera(self, preset):
        """Reel camera: one of CAMERAS. It eases there over CAMERA_MOVE seconds."""
        assert preset in CAMERAS, preset
        self.cameras.append((self.clock, preset))

    def wait(self, seconds):
        self.clock += seconds
        if not self.dry:
            time.sleep(seconds)

    def notch(self, mode):
        """A DebugBridge mode: collapsed, peek-left, peek-right, expanded, theme-aurora, timer:<text>…"""
        if not self.dry:
            notchctl(mode)

    def spotify(self, command):
        """play | pause | next track | previous track | seek <seconds>"""
        if self.dry:
            return
        if command.startswith("seek "):
            osascript(f'tell application "Spotify" to set player position to {float(command[5:])}')
        else:
            osascript(f'tell application "Spotify" to {command}')

    def start_music(self, at=None):
        if self.dry:
            return
        if self.track:
            osascript(f'tell application "Spotify" to play track "{self.track}"')
        else:
            osascript('tell application "Spotify" to play')
        if at is not None:
            self.spotify(f"seek {at}")

    def session(self, **kwargs):
        s = Session(self, **kwargs)
        self.sessions.append(s)
        return s

    def cleanup(self):
        for s in self.sessions:
            s.end()
        if not self.dry:
            notchctl("collapsed")


class Session:
    """A staged Claude Code session: hook events go to the app's socket the
    way upthere-hook sends them, and a transcript file supplies the title,
    model, context size and last message."""

    def __init__(self, director, project="upthere", title=None, model="claude-opus-5-5", context=48_000):
        self.d = director
        self.id = f"demo-{uuid.uuid4().hex[:12]}"
        self.cwd = f"{Path.home()}/Projects/{project}"
        self.model, self.context = model, context
        self.transcript = WORK / "transcripts" / f"{self.id}.jsonl"
        self.ended = False
        if director.dry:
            return
        self.transcript.parent.mkdir(parents=True, exist_ok=True)
        # Must exist before the first event: the tailer opens it once.
        self.transcript.write_text("")
        if title:
            self._append({"type": "custom-title", "customTitle": title})
        self._append(self._assistant(None))  # model + context before any text

    def _append(self, line):
        with self.transcript.open("a") as f:
            f.write(json.dumps(line) + "\n")

    def _assistant(self, text):
        return {
            "type": "assistant",
            "message": {
                "id": f"msg_{uuid.uuid4().hex[:16]}",
                "model": self.model,
                "content": [{"type": "text", "text": text}] if text else [],
                "usage": {"input_tokens": 12, "cache_read_input_tokens": self.context, "output_tokens": 400},
            },
        }

    def _send(self, event, **payload):
        if self.d.dry:
            return
        payload.update(hook_event_name=event, session_id=self.id, cwd=self.cwd,
                       transcript_path=str(self.transcript))
        envelope = {"v": 1, "term": "Apple_Terminal", "bundle": "com.apple.Terminal", "payload": payload}
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
            s.connect(str(SOCKET))
            s.sendall(json.dumps(envelope).encode())

    def start(self):
        self._send("SessionStart")

    def prompt(self, text="…"):
        self._send("UserPromptSubmit", prompt=text)

    def tool(self, name, **tool_input):
        self._send("PreToolUse", tool_name=name, tool_input=tool_input)

    def tool_done(self, name="Tool"):
        self._send("PostToolUse", tool_name=name)

    def ask_permission(self, name, **tool_input):
        """Running a tool that needs approval: amber, and the ear auto-peeks."""
        self.tool(name, **tool_input)
        self._send("Notification", notification_type="permission_prompt",
                   message=f"Claude needs your permission to use {name}")

    def ask(self, question):
        self.tool("AskUserQuestion", questions=[{"question": question}])

    def say(self, text, context=None):
        if context:
            self.context = context
        if not self.d.dry:
            self._append(self._assistant(text))

    def stop(self):
        self._send("Stop")

    def end(self):
        if not self.ended:
            self.ended = True
            self._send("SessionEnd")


# ---------------------------------------------------------------- scenes

SCENES = {}


# Reel camera presets: (centre, visible width), in points from the notch's
# centre. Ears hug the notch, so "left"/"right" frame one ear and the notch.
CAMERAS = {
    "wide": (0, 760),
    "left": (-240, 400),
    "right": (235, 400),
    "timers": (-280, 470),  # the timers ear is the widest thing up there
}
CAMERA_MOVE = 0.7


def scene(caption, subtitle=None, gif_width=1000, camera="wide"):
    """`gif_width`: how much of the menu bar the GIF shows, in points
    centred on the notch. `camera`: the videos' opening preset; scenes move
    it with d.camera()."""
    def register(fn):
        SCENES[fn.__name__.replace("_", "-")] = dict(
            fn=fn, caption=caption, subtitle=subtitle,
            gif_width=gif_width, camera=camera, doc=(fn.__doc__ or "").strip())
        return fn
    return register


@scene("Your notch grew ears", "Music on the right. Claude Code on the left.")
def hero(d):
    """README hero: music playing, Claude works, asks, finishes."""
    d.start_music()
    s = d.session(title="Pin timers to the notch", context=61_000)
    d.wait(0.8)
    s.start(); s.prompt(); d.wait(0.8)
    # Collapsed, the Claude ear is only a glyph: open it so the tools read.
    d.notch("peek-left"); d.camera("left"); d.wait(1.2)
    s.tool("Read", file_path="Upthere/Timer/TimerModel.swift"); d.wait(1.4)
    s.tool_done(); d.wait(0.4)
    s.tool("Edit", file_path="Upthere/UI/TimerViews.swift"); d.wait(1.6)
    s.tool_done()
    # Close it again, so the permission prompt visibly opens it by itself.
    d.notch("collapsed"); d.wait(1.2)
    s.ask_permission("Bash", description="Run the test suite"); d.wait(2.8)
    s.tool("Bash", description="Run the test suite"); d.wait(1.6)
    s.tool_done(); d.wait(0.4)
    s.say("All 64 tests pass. Pinned timers now stay in the left ear.", context=74_000)
    s.stop(); d.wait(1.0)
    d.notch("peek-left"); d.wait(2.4)
    d.notch("collapsed"); d.camera("wide"); d.wait(1.0)


@scene("Claude asks. The notch tells you.", "Permission prompts glow amber and peek on their own.")
def claude_permission(d):
    """Thinking → tool → permission (amber auto-peek) → approved → done."""
    s = d.session(title="Fix flaky seek bar test")
    d.wait(1.0)
    s.start(); s.prompt(); d.camera("left"); d.wait(1.5)
    s.tool("Grep", pattern="previewSeek"); d.wait(1.0)
    s.tool_done(); d.wait(0.5)
    s.ask_permission("Bash", description="xcodebuild test"); d.wait(3.5)
    s.tool("Bash", description="xcodebuild test"); d.wait(1.5)
    s.tool_done(); s.say("Fixed: the seek preview now ignores stale scroll events.")
    s.stop(); d.wait(2.5)


@scene("Click for the details", "The current tool, how long it's been running, and one click to its terminal.")
def claude_expanded(d):
    """Hover the Claude ear, then click: both ears widen."""
    s = d.session(title="Refactor the hook installer", context=112_000)
    s.start(); s.prompt(); d.wait(0.6)
    s.tool("Edit", file_path="Upthere/Claude/HookInstaller.swift")
    s.say("Splitting install and uninstall so the backup is written once.")
    d.wait(1.2)
    d.notch("peek-left"); d.camera("left"); d.wait(2.0)
    d.notch("expanded"); d.camera("wide"); d.wait(3.5)
    d.notch("collapsed"); d.wait(1.0)


@scene("Now playing, up there", "Artwork, controls and a live visualizer on hover.")
def music_hover(d):
    """Hover the music ear, scrub the seek bar, change volume."""
    d.start_music()
    d.wait(1.5)
    d.notch("peek-right"); d.camera("right"); d.wait(2.2)
    d.notch("seek-active"); d.wait(1.4)
    d.notch("seek-end"); d.wait(1.2)
    d.notch("hud-volume"); d.wait(2.2)
    d.notch("collapsed"); d.camera("wide"); d.wait(1.0)


@scene("Pick your look", "Classic, Aurora or native Liquid Glass.", camera="right")
def themes(d):
    """Cycle the themes with the music ear open. Leaves Classic on."""
    d.start_music()
    d.notch("theme-classic"); d.notch("peek-right"); d.wait(2.0)
    d.notch("theme-aurora"); d.wait(2.2)
    d.notch("theme-clear"); d.notch("glass-color"); d.wait(2.2)
    d.notch("theme-classic"); d.wait(1.2)
    d.notch("collapsed"); d.wait(0.8)


@scene("Timers that stay in view", "A global shortcut, plain-English durations, several at once.",
       camera="timers")
def timers(d):
    """Start two timers, peek at them, pin one, clean up."""
    d.notch("timer-stopall")
    d.wait(0.8)
    d.notch("timer:deep work 25m"); d.wait(1.6)
    d.notch("timer:tea for 4"); d.wait(1.4)
    d.notch("peek-left"); d.wait(2.5)
    d.notch("timer-pin-first"); d.wait(1.8)
    d.notch("collapsed"); d.wait(2.0)
    d.notch("timer-stopall"); d.wait(0.6)


# ---------------------------------------------------------------- record


def duration(name):
    d = Director(dry=True)
    SCENES[name]["fn"](d)
    return d.clock


def run_scene(name, track):
    d = Director(track=track)
    notchctl("demo-on")
    notchctl("collapsed")
    try:
        SCENES[name]["fn"](d)
    finally:
        d.cleanup()


def notch_geometry():
    """Notch width/height in points, from the DebugBridge snapshot."""
    tmp = CACHE / "geometry"
    shutil.rmtree(tmp, ignore_errors=True)
    tmp.mkdir(parents=True)
    notchctl("collapsed", str(tmp))
    for _ in range(40):
        if (tmp / "notch.txt").exists():
            w, h = (tmp / "notch.txt").read_text().split()
            return float(w), float(h)
        time.sleep(0.1)
    sys.exit("No answer from the DebugBridge: is a Debug build of Upthere running?")


def screen_size():
    out = subprocess.run(["system_profiler", "SPDisplaysDataType", "-json"], capture_output=True, text=True).stdout
    for gpu in json.loads(out)["SPDisplaysDataType"]:
        for display in gpu.get("spdisplays_ndrvs", []):
            if display.get("spdisplays_main") == "spdisplays_yes":
                pixels = display.get("_spdisplays_pixels") or display["spdisplays_pixelresolution"]
                w, h = [int(v) for v in pixels.replace("x", " ").split()[:2]]
                points = display.get("_spdisplays_resolution", "").split(" @")[0]
                pw = int(points.replace("x", " ").split()[0]) if points else w // 2
                return w, h, w / pw
    sys.exit("Couldn't find the main display")


def record(name, track):
    RAW.mkdir(parents=True, exist_ok=True)
    notch_w, notch_h = notch_geometry()
    w, h, scale = screen_size()
    length = duration(name) + LEAD + 1.0
    movie = RAW / f"{name}.mov"
    movie.unlink(missing_ok=True)
    print(f"● {name}: {length:.1f}s")
    # -v video, -V length, -x silent; no -C, so no cursor in the take.
    capture = subprocess.Popen(["screencapture", "-v", "-x", "-V", f"{length:.1f}", str(movie)])
    time.sleep(LEAD)
    try:
        run_scene(name, track)
    finally:
        capture.wait()
    if not movie.exists():
        sys.exit("screencapture wrote nothing: grant Screen Recording to the app running this script.")
    meta = dict(scene=name, lead=LEAD, notch_width=notch_w, notch_height=notch_h,
                screen_width=w, screen_height=h, scale=scale)
    (RAW / f"{name}.json").write_text(json.dumps(meta, indent=2))
    print(f"  → {movie.relative_to(ROOT)}")


# ---------------------------------------------------------------- render


def even(v):
    return int(v) // 2 * 2


def art(*args):
    CACHE.mkdir(parents=True, exist_ok=True)
    subprocess.run(["swift", str(ROOT / "scripts/demo/art.swift"), *map(str, args)], check=True)


def ffmpeg(*args):
    subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", *map(str, args)], check=True)


X264 = ["-c:v", "libx264", "-preset", "slow", "-crf", "16", "-pix_fmt", "yuv420p", "-r", "60", "-movflags", "+faststart"]


# The camera roams this slice of the screen (points, centred on the notch).
SOURCE_WIDTH = 1100
# Band the strip is composited in, as a fraction of the canvas width. Tall
# enough for the strip at the closest camera (40 pt in 400 pt of view).
BAND = 0.12
REPO = "github.com/Mateu6/upthere"

# canvas, where the band sits, caption on/off, footer distance from the bottom
LAYOUTS = {
    "reel": dict(size=(1080, 1920), band_top=640, caption=True, footer=420),
    "wide": dict(size=(1920, 1080), band_top=300, caption=True, footer=60),
    "square": dict(size=(1080, 1080), band_top=290, caption=True, footer=70),
}


def camera_expressions(name, fps):
    """The scene's camera path as ffmpeg expressions of the output frame
    number: each move is a smoothstep from the previous preset."""
    d = Director(dry=True)
    SCENES[name]["fn"](d)
    first = CAMERAS[SCENES[name]["camera"]]
    exprs = [f"{first[0]}", f"{first[1]}"]
    previous = first
    for t, preset in d.cameras:
        target = CAMERAS[preset]
        p = f"clip((on/{fps}-{t:.3f})/{CAMERA_MOVE},0,1)"
        ease = f"{p}*{p}*(3-2*{p})"
        for i in (0, 1):
            if target[i] != previous[i]:
                exprs[i] += f"+({target[i] - previous[i]})*{ease}"
        previous = target
    return exprs


def render(name, formats):
    """Every format is the menu-bar strip of the take (the ears never go
    below it) on the indigo backdrop: whatever is on the desktop under the
    menu bar never reaches an output."""
    meta = json.loads((RAW / f"{name}.json").read_text())
    spec = SCENES[name]
    movie = RAW / f"{name}.mov"
    s, sw = meta["scale"], meta["screen_width"]
    strip_h = meta["notch_height"] + 2  # points
    OUT.mkdir(parents=True, exist_ok=True)

    notch_png = CACHE / f"notch-{name}.png"
    art("notch", even(meta["notch_width"] * s), even(meta["notch_height"] * s), round(9 * s), notch_png)
    length = float(subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", movie],
        capture_output=True, text=True).stdout) - meta["lead"]

    def composite(canvas, band_top, camera, fps, caption=None, footer=None):
        """Filter graph and extra inputs: strip → camera → onto the backdrop."""
        cw, ch = canvas
        band_h = even(cw * BAND)
        bg = CACHE / f"backdrop-{cw}x{ch}-{band_top}-{footer}.png"
        art("backdrop", cw, ch, band_top + band_h / 3, footer or 0, REPO if footer else "-", bg)
        centre, width = camera
        x = f"(({SOURCE_WIDTH / 2})+({centre})-({width})/2)*{s}"
        graph = (
            # The physical notch, then the menu-bar strip only, padded
            # with transparency to the band's aspect.
            f"[0:v][1:v]overlay=x=(W-w)/2:y=0,"
            f"crop={even(SOURCE_WIDTH * s)}:{even(strip_h * s)}:{even((sw - SOURCE_WIDTH * s) / 2)}:0,"
            f"format=rgba,pad={even(SOURCE_WIDTH * s)}:{even(SOURCE_WIDTH * BAND * s)}:0:0:color=black@0,"
            f"fps={fps},zoompan=z='{SOURCE_WIDTH}/({width})':x='{x}':y=0:d=1:fps={fps}:s={cw}x{band_h}[band];"
            f"[2:v][band]overlay=0:{band_top}:shortest=1"
        )
        extra = [bg]
        if caption:
            extra.append(caption)
            graph += (f"[v1];[3:v]format=rgba,fade=in:st=0.35:d=0.6:alpha=1[cap];"
                      f"[v1][cap]overlay=(W-w)/2:{band_top + band_h + 40}:shortest=1")
        inputs = ["-ss", meta["lead"], "-i", movie, "-i", notch_png]
        # Looped stills never end on their own: cap at the take's length.
        inputs += [a for png in extra for a in ("-loop", "1", "-i", png)]
        return inputs + ["-filter_complex", graph, "-t", f"{length:.2f}"]

    if "gif" in formats:
        # README: a fixed frame, no caption; drawn at 2x, saved at 1x.
        width = spec["gif_width"]
        canvas = (width * 2, even((strip_h + 26) * 2))
        frames = CACHE / f"frames-{name}"
        shutil.rmtree(frames, ignore_errors=True)
        frames.mkdir(parents=True)
        ffmpeg(*composite(canvas, 0, (0, width), 30), frames / "%05d.png")
        gif = OUT / f"{name}.gif"
        subprocess.run(["gifski", "--quiet", "--fps", "30", "--quality", "88", "--width", str(width),
                        "-o", str(gif), *sorted(map(str, frames.glob("*.png")))], check=True)
        shutil.rmtree(frames)
        print(f"  gif    {gif.relative_to(ROOT)}  {gif.stat().st_size / 1e6:.1f} MB")

    caption = CACHE / f"caption-{name}.png"
    if any(f in formats for f in LAYOUTS):
        art("caption", 1080, spec["caption"], spec["subtitle"] or "-", caption)
    for fmt, layout in LAYOUTS.items():
        if fmt not in formats:
            continue
        out = OUT / f"{name}-{fmt}.mp4"
        ffmpeg(*composite(layout["size"], layout["band_top"], camera_expressions(name, 60), 60,
                          caption=caption if layout["caption"] else None, footer=layout["footer"]),
               *X264, out)
        print(f"  {fmt:<6} {out.relative_to(ROOT)}")


# Named cuts for `showreel`: scene@in-out trims each scene to its best part
# (seconds from the scene's start, as `list` times them).
CUTS = {
    # ~30 s: Claude works, asks and finishes; music; timers.
    "short": ["hero@0.5-15.4", "music-hover@1.2-8.4", "timers@3.4-7.9"],
}
ICON = ROOT / "Upthere/Resources/Assets.xcassets/AppIcon.appiconset/icon_512x512@2x.png"
CARDS = {
    "intro": dict(length=2.4, title="upthere", subtitle="Music and Claude Code, in your notch.", small="-"),
    "outro": dict(length=3.2, title="Free and open source", subtitle="For MacBooks with a notch · macOS 26+",
                  small=REPO),
}
XFADE = 0.4


def card_clip(kind, fmt):
    """A card as video: drawn at 2x, pushed in slowly so it isn't a still."""
    w, h = LAYOUTS[fmt]["size"]
    card = CARDS[kind]
    png = CACHE / f"card-{kind}-{fmt}.png"
    art("card", w * 2, h * 2, ICON, card["title"], card["subtitle"], card["small"], png)
    frames = round(card["length"] * 60)
    out = CACHE / f"card-{kind}-{fmt}.mp4"
    ffmpeg("-loop", "1", "-i", png, "-t", card["length"], "-vf",
           f"zoompan=z='1+0.04*on/{frames}':x='iw/2-iw/zoom/2':y='ih/2-ih/zoom/2':d=1:fps=60:s={w}x{h}",
           *X264, out)
    return out, card["length"]


def length_of(movie):
    return float(subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", movie],
        capture_output=True, text=True).stdout)


def showreel(fmt, items, cards=True, name=None):
    """Scenes (optionally trimmed: scene@in-out) cross-faded into one video,
    between an intro and an outro card."""
    clips = []  # (file, start, end)
    for item in items:
        scene_name, _, trim = item.partition("@")
        path = OUT / f"{scene_name}-{fmt}.mp4"
        if not path.exists():
            sys.exit(f"Render {scene_name} first: demo.py render {scene_name} --formats {fmt}")
        start, end = (float(v) for v in trim.split("-")) if trim else (0.0, length_of(path))
        clips.append((path, start, min(end, length_of(path))))
    if cards:
        intro, outro = card_clip("intro", fmt), card_clip("outro", fmt)
        clips = [(intro[0], 0.0, intro[1])] + clips + [(outro[0], 0.0, outro[1])]

    # Same timebase and rate for every clip, or xfade refuses them.
    parts = [f"[{i}:v]trim={a:.3f}:{b:.3f},setpts=PTS-STARTPTS,fps=60,settb=AVTB,format=yuv420p[c{i}]"
             for i, (_, a, b) in enumerate(clips)]
    offset, last = 0.0, "[c0]"
    for i in range(1, len(clips)):
        offset += (clips[i - 1][2] - clips[i - 1][1]) - XFADE
        parts.append(f"{last}[c{i}]xfade=transition=fade:duration={XFADE}:offset={offset:.3f}[x{i}]")
        last = f"[x{i}]"
    total = offset + clips[-1][2] - clips[-1][1]
    if cards:
        parts.append(f"{last}fade=in:st=0:d=0.4,fade=out:st={total - 0.6:.3f}:d=0.6[out]")
        last = "[out]"
    out = OUT / f"showreel-{name + '-' if name else ''}{fmt}.mp4"
    ffmpeg(*[a for c in clips for a in ("-i", c[0])], "-filter_complex", ";".join(parts), "-map", last,
           *X264, out)
    print(f"  showreel {out.relative_to(ROOT)}  {total:.1f}s")


# ---------------------------------------------------------------- cli


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("command", choices=["list", "run", "record", "render", "showreel"])
    p.add_argument("args", nargs="*")
    p.add_argument("--track", help="spotify:track:… URI each music scene starts")
    p.add_argument("--formats", default="gif,reel,wide,square")
    p.add_argument("--no-cards", action="store_true", help="showreel without intro/outro cards")
    opts = p.parse_args()

    def scenes(names):
        names = names or list(SCENES)
        unknown = [n for n in names if n not in SCENES]
        if unknown:
            sys.exit(f"Unknown scene(s): {', '.join(unknown)}. Try: {', '.join(SCENES)}")
        return names

    if opts.command == "list":
        for name, spec in SCENES.items():
            print(f"{name:<18} {duration(name):5.1f}s  {spec['doc']}")
    elif opts.command == "run":
        for name in scenes(opts.args):
            run_scene(name, opts.track)
        notchctl("demo-off")
    elif opts.command == "record":
        try:
            for name in scenes(opts.args):
                record(name, opts.track)
        finally:
            notchctl("demo-off")
    elif opts.command == "render":
        for name in scenes(opts.args):
            print(f"● {name}")
            render(name, opts.formats.split(","))
    elif opts.command == "showreel":
        if not opts.args or opts.args[0] not in ("reel", "wide", "square"):
            sys.exit(f"showreel <reel|wide|square> <{'|'.join(CUTS)}|scene[@in-out]>...")
        items = opts.args[1:]
        cut = items[0] if len(items) == 1 and items[0] in CUTS else None
        items = CUTS[cut] if cut else items
        scenes([i.partition("@")[0] for i in items])
        showreel(opts.args[0], items, cards=not opts.no_cards, name=cut)


if __name__ == "__main__":
    main()
