#!/usr/bin/env python3
"""
Records the login-screen background from the REAL in-game map.

It loads the game itself (the same three.js globe, buildings, roads, lights and
night sky players see), hides the menus, flies a slow seamless orbit over
Manhattan, grabs every frame, and encodes media/nyc-bg.mp4 + media/nyc-poster.jpg.

Needs internet (the game loads three.js and fonts from CDNs) and a GPU-capable
Chrome/Chromium. Run from the project root:

    pip install playwright && playwright install chromium
    # ffmpeg must be on PATH
    python3 tools/record-login-video.py

Options (all optional):
    --lat 40.7580 --lon -73.9855   centre of the orbit (default: Midtown / Times Sq)
    --dist 650                      camera distance in metres
    --phase 0.70                    time of day, 0.12 = morning, 0.64 = dusk, 0.70+ = night
    --secs 20 --fps 24              loop length and frame rate
    --size 1920x1080                output size
"""
import argparse, math, os, shutil, subprocess, sys, tempfile, threading, http.server, socketserver, functools
from playwright.sync_api import sync_playwright

ap = argparse.ArgumentParser()
ap.add_argument("--lat", type=float, default=40.7580)
ap.add_argument("--lon", type=float, default=-73.9855)
ap.add_argument("--dist", type=float, default=650)
ap.add_argument("--phase", type=float, default=0.70)
ap.add_argument("--secs", type=float, default=20)
ap.add_argument("--fps", type=int, default=24)
ap.add_argument("--size", default="1920x1080")
ap.add_argument("--warmup", type=float, default=15, help="seconds to let map tiles load before filming")
ap.add_argument("--show", action="store_true", help="show the browser window")
a = ap.parse_args()
W, H = map(int, a.size.lower().split("x"))
root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
out_mp4, out_jpg = os.path.join(root, "media", "nyc-bg.mp4"), os.path.join(root, "media", "nyc-poster.jpg")
if not shutil.which("ffmpeg"):
    sys.exit("ffmpeg not found on PATH")

# tiny static server so the game's fetch('data/...') calls work
handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=root)
handler.log_message = lambda *args, **kw: None
srv = socketserver.TCPServer(("127.0.0.1", 0), handler)
port = srv.server_address[1]
threading.Thread(target=srv.serve_forever, daemon=True).start()

frames = tempfile.mkdtemp(prefix="ancap-frames-")
N = int(a.secs * a.fps)

with sync_playwright() as p:
    b = p.chromium.launch(headless=not a.show, args=["--ignore-gpu-blocklist", "--enable-webgl", "--use-angle=default"])
    pg = b.new_page(viewport={"width": W, "height": H}, device_scale_factor=1)
    # guest/offline is fine: we only need the map, never an account
    pg.goto(f"http://127.0.0.1:{port}/index.html", wait_until="domcontentloaded")
    pg.wait_for_function("typeof ui!=='undefined' && ui.started===false && !document.querySelector('#loading')", timeout=120000)

    # strip every menu/overlay so only the 3D map is on screen
    pg.add_style_tag(content="#front,#bar,#loading,.toast,#toasts{display:none!important} #app>*:not(canvas#gl){visibility:hidden!important} canvas#gl{visibility:visible!important}")
    pg.evaluate("""([lat,lon,dist,phase])=>{
        VIS.cycle=true; VIS.period=1e9; VIS.phase=phase;     // freeze time of day
        stopFlight&&stopFlight(); stopMotion();
        CAM.lat=lat; CAM.lon=lon; CAM.dist=dist; CAM.heading=0; CAM.tiltU=0.15;
        QUAL.fixed=true;                                     // no auto quality drops while filming
    }""", [a.lat, a.lon, a.dist, a.phase])

    def pose(i):
        t = i / N                       # 0..1, seamless loop
        h = 2 * math.pi * t             # one slow full orbit
        d = a.dist * (1 + 0.12 * math.sin(2 * math.pi * t))   # gentle push in / out
        pg.evaluate("([h,d])=>{ZOOM.t=null;CAM.heading=h;CAM.dist=d;CAM.tiltU=0.15}", [h, d])

    # warm-up: do one full lap (so every tile on the route is fetched), then wait for idle
    print("Warming up map tiles…")
    for i in range(0, N, 6):
        pose(i); pg.wait_for_timeout(int(a.warmup * 1000 / (N / 6)))
    pg.wait_for_timeout(4000)

    print(f"Filming {N} frames at {W}x{H}…")
    for i in range(N):
        pose(i)
        pg.evaluate("()=>new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r)))")  # let the frame draw
        pg.screenshot(path=os.path.join(frames, f"f{i:05d}.png"), type="png")
        if i % 48 == 0: print(f"  {i}/{N}")
    b.close()
srv.shutdown()

print("Encoding…")
os.makedirs(os.path.join(root, "media"), exist_ok=True)
subprocess.check_call(["ffmpeg", "-y", "-v", "error", "-framerate", str(a.fps), "-i", os.path.join(frames, "f%05d.png"),
    "-c:v", "libx264", "-preset", "slow", "-crf", "24", "-pix_fmt", "yuv420p", "-movflags", "+faststart", "-an", out_mp4])
subprocess.check_call(["ffmpeg", "-y", "-v", "error", "-i", os.path.join(frames, "f00000.png"), "-q:v", "4", out_jpg])
shutil.rmtree(frames, ignore_errors=True)
print("Done:", out_mp4, f"({os.path.getsize(out_mp4)/1e6:.1f} MB)")
