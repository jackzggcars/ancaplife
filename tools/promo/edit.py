"""
ANCAP LIFE promo edit: turns the captured frames into a 1080x1920 30 fps vertical video with captions, punch-ins,
flash cuts, music and synced sound effects. Everything about the cut lives in TIMELINE / CAPTIONS / CUES below,
so timing and wording can be changed and re-rendered in a minute.

  python3 tools/promo/edit.py                 # -> tools/promo/out/ancap-life-promo.mp4
  python3 tools/promo/edit.py --hook 2        # use hook line #2 (see HOOKS) for A/B versions
  python3 tools/promo/edit.py --all-hooks     # render one video per hook
"""
import json, math, subprocess, sys
from pathlib import Path
import numpy as np
from PIL import Image, ImageDraw, ImageFont, ImageFilter
sys.path.insert(0, str(Path(__file__).resolve().parent))
import audio

HERE = Path(__file__).resolve().parent
FR = HERE / 'frames'
OUTD = HERE / 'out'; OUTD.mkdir(exist_ok=True)
W, H, FPS = 1080, 1920, 30
FONT = '/usr/share/fonts/truetype/google-fonts/Poppins-Bold.ttf'
for cand in ('Poppins-Black.ttf', 'Poppins-ExtraBold.ttf'):
    p = Path('/usr/share/fonts/truetype/google-fonts') / cand
    if p.exists(): FONT = str(p)
URL = 'ancaplife.vercel.app'

# -------------------------------------------------------------------------------- the cut (cuts land on the 120 BPM beat)
# shot, out-seconds, source window (0..1 of the captured shot), speed curve ('lin' | 'ramp' = slow start, fast end)
TIMELINE = [
    ('hook',     3.0, (0.0, 1.0), 'lin'),
    ('first',    2.0, (0.05, 0.95), 'lin'),
    ('timessq',  3.0, (0.0, 1.0), 'lin'),
    ('interior', 2.5, (0.0, 1.0), 'lin'),
    ('build',    2.5, (0.0, 1.0), 'lin'),
    ('tokyo',    2.0, (0.0, 1.0), 'lin'),
    ('payoff',   5.0, (0.0, 1.0), 'ramp'),
    ('cta',      3.0, (0.0, 1.0), 'lin'),
]
HOOKS = [
    'Can I own the ENTIRE planet?',
    'I started with ONE shop...',
    'From $0 to world empire in 30 seconds',
    'This is a business sim on the REAL Earth',
    'POV: you lease a shop in Times Square',
    'I bought a street in London. Then Tokyo.',
    'This browser game lets you buy the world',
    'Rate my $1 BILLION empire',
    'Nobody told me Earth was for sale',
    'Day 1: a food cart. Day 100: the planet.',
]
# captions: (start, end, text, style) — words in CAPS get the yellow highlight. Keep inside the safe zone.
def captions(hook):
    return [
        (0.00, 1.55, hook, 'hook'),
        (1.55, 3.00, 'Already worth $48M...', 'mid'),
        (3.00, 5.00, 'Day 1: ONE tiny shop', 'mid'),
        (5.00, 6.50, 'POV: you lease a shop', 'mid'),
        (6.50, 8.00, 'in TIMES SQUARE', 'mid'),
        (8.00, 10.50, 'Hire staff. Profits JUMP.', 'mid'),
        (10.50, 13.00, 'Build your OWN tower', 'mid'),
        (13.00, 15.00, 'Next stop... TOKYO', 'mid'),
        (15.00, 17.20, 'Real Earth. Real STREETS.', 'mid'),
        (17.20, 19.10, 'Every block is FOR SALE', 'mid'),
        (19.10, 20.00, '$1 BILLION', 'big'),
        (20.00, 23.00, 'PLAY FREE|in your browser', 'cta'),
    ]
# sound cues: (time, sfx, gain)
def cues():
    c = [(0.0, 'boom', .8)]
    c += [(0.12 + i * 0.14, 'coin', .45) for i in range(18)]          # counter climbing in the hook
    c += [(3.0, 'pop', .9), (4.2, 'tick', .6), (4.45, 'tick', .6)]
    c += [(5.0, 'whoosh', .8), (7.0, 'kaching', 1.0)]
    c += [(8.0, 'pop', .8), (9.3, 'kaching', .9), (9.9, 'coin', .5), (10.15, 'coin', .5)]
    c += [(10.5, 'whoosh', .7), (11.5, 'tick', .5), (12.0, 'tick', .5), (12.5, 'kaching', .9)]
    c += [(13.0, 'whoosh', 1.0), (14.2, 'coin', .55), (14.45, 'coin', .55)]
    c += [(15.0, 'whoosh', .9)]
    c += [(15.4 + 4.5 * (1 - (1 - k / 22) ** 1.7), 'coin', .4) for k in range(22)]   # speeding up
    c += [(20.0, 'boom', 1.0), (20.02, 'kaching', 1.0), (21.0, 'pop', .8)]
    return c
RISER = (15.6, 20.0)
# punch-ins: (start, end, zoom from, zoom to, centre x, centre y) in output pixels
PUNCH = [
    (1.55, 3.0, 1.0, 1.22, 540, 330),     # zoom into the net worth counter
    (19.0, 20.0, 1.0, 1.15, 540, 330),
]
FLASH_AT = [3.0, 5.0, 8.0, 10.5, 13.0, 15.0, 20.0]    # 2-frame white flash on these cuts
SHAKE = [(20.0, .35, 14)]                            # (time, seconds, pixels)

# -------------------------------------------------------------------------------- frames
def shot_frames(name):
    d = FR / name; fs = sorted(d.glob('*.jpg'))[1:]   # the first frame of a shot can be caught mid-rebuild
    if not fs: raise SystemExit(f'missing frames for {name}: run capture.py first')
    return fs
_cache = {}
def load(path):
    im = _cache.get(path)
    if im is None:
        if len(_cache) > 40: _cache.clear()
        im = _cache[path] = Image.open(path).convert('RGB').resize((W, H), Image.LANCZOS)
    return im
def source_frame(name, u):
    """u in 0..1 over the shot: blend the two nearest captured frames (smooth 30 fps from 15 fps capture)"""
    fs = shot_frames(name); x = u * (len(fs) - 1); i = int(math.floor(x)); f = x - i
    a = load(fs[min(i, len(fs) - 1)])
    if f < .02 or i + 1 >= len(fs): return a
    return Image.blend(a, load(fs[i + 1]), f)

# -------------------------------------------------------------------------------- captions
def font(sz): return ImageFont.truetype(FONT, sz)
def draw_caption(img, text, style, k):
    """k: 0..1 progress through this caption (for the pop-in)"""
    d = ImageDraw.Draw(img)
    pop = min(1, k * 7) if k < .15 else 1
    scale = .82 + .18 * (1 - (1 - pop) ** 3) + (.04 * math.sin(min(1, k * 7) * math.pi) if k < .15 else 0)
    if style == 'cta':
        lines = text.split('|')
        y = int(H * .40)
        for li, line in enumerate(lines):
            sz = int((128 if li == 0 else 74) * scale)
            y = put(d, img, line, y, sz, highlight_all=(li == 0)) + 14
        # URL pill
        f = font(int(58 * scale)); tw = d.textlength(URL, font=f); pad = 30
        x0 = (W - tw) / 2 - pad; y0 = y + 26; x1 = (W + tw) / 2 + pad; y1 = y0 + 96
        d.rounded_rectangle([x0, y0, x1, y1], radius=48, fill=(255, 222, 0), outline=(0, 0, 0), width=6)
        d.text((W / 2, (y0 + y1) / 2), URL, font=f, fill=(0, 0, 0), anchor='mm')
        put(d, img, 'No download. Link in bio.', y1 + 40, int(50 * scale))
        return
    sz = {'hook': 96, 'mid': 86, 'big': 150}[style]
    y = int(H * (.27 if style != 'big' else .36))
    put(d, img, text, y, int(sz * scale), highlight_all=(style == 'big'))
def wrap(d, text, f, maxw):
    words, lines, cur = text.split(), [], ''
    for w_ in words:
        t = (cur + ' ' + w_).strip()
        if d.textlength(t, font=f) <= maxw: cur = t
        else: lines.append(cur); cur = w_
    if cur: lines.append(cur)
    return lines
def put(d, img, text, y, sz, highlight_all=False):
    f = font(sz); maxw = W - 120; lines = wrap(d, text, f, maxw); lh = int(sz * 1.12)
    for line in lines:
        words = line.split(' '); widths = [d.textlength(w_ + ' ', font=f) for w_ in words]
        x = (W - (sum(widths) - d.textlength(' ', font=f))) / 2
        for w_, ww in zip(words, widths):
            hi = highlight_all or (sum(c.isupper() for c in w_) >= 2 and w_.upper() == w_) or w_.startswith('$')
            col = (255, 222, 0) if hi else (255, 255, 255)
            d.text((x, y), w_, font=f, fill=col, stroke_width=max(6, sz // 9), stroke_fill=(0, 0, 0))
            x += ww
        y += lh
    return y

# -------------------------------------------------------------------------------- render
def render(hook_i=0, out=None):
    total = sum(t[1] for t in TIMELINE); n = int(round(total * FPS))
    caps = captions(HOOKS[hook_i]); out = out or OUTD / f'ancap-life-promo{"" if hook_i == 0 else f"-hook{hook_i+1}"}.mp4'
    wav = OUTD / 'promo-audio.wav'
    audio.write_wav(wav, audio.mix(total, cues(), riser=RISER))
    ff = subprocess.Popen(['ffmpeg', '-y', '-loglevel', 'error', '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-s', f'{W}x{H}', '-r', str(FPS), '-i', '-',
                           '-i', str(wav), '-c:v', 'libx264', '-preset', 'slow', '-crf', '17', '-pix_fmt', 'yuv420p', '-profile:v', 'high',
                           '-af', 'loudnorm=I=-14:TP=-1.0:LRA=9', '-c:a', 'aac', '-b:a', '192k', '-ar', '48000', '-shortest', '-movflags', '+faststart', str(out)], stdin=subprocess.PIPE)
    starts = np.cumsum([0] + [t[1] for t in TIMELINE])
    for fi in range(n):
        t = fi / FPS
        si = max(0, np.searchsorted(starts, t, side='right') - 1); si = min(si, len(TIMELINE) - 1)
        name, dur, (a, b), curve = TIMELINE[si]; k = (t - starts[si]) / dur
        if curve == 'ramp': k = k ** 1.35
        img = source_frame(name, a + (b - a) * min(1, k)).copy()
        # punch-ins
        for (p0, p1, z0, z1, cx, cy) in PUNCH:
            if p0 <= t < p1:
                q = (t - p0) / (p1 - p0); z = z0 + (z1 - z0) * (q * q * (3 - 2 * q))
                cw, ch = W / z, H / z; x0 = min(max(0, cx - cw * cx / W), W - cw); y0 = min(max(0, cy - ch * cy / H), H - ch)
                img = img.crop((int(x0), int(y0), int(x0 + cw), int(y0 + ch))).resize((W, H), Image.LANCZOS)
        for (st, sd, px) in SHAKE:
            if st <= t < st + sd:
                q = 1 - (t - st) / sd; dx = int(px * q * math.sin(fi * 2.3)); dy = int(px * q * math.cos(fi * 1.7))
                img = Image.fromarray(np.roll(np.roll(np.asarray(img), dy, 0), dx, 1))
        for (c0, c1, text, style) in caps:
            if c0 <= t < c1: draw_caption(img, text, style, (t - c0) / (c1 - c0))
        for fa in FLASH_AT:
            if 0 <= t - fa < 2 / FPS:
                a_ = .55 if t - fa < 1 / FPS else .25
                img = Image.blend(img, Image.new('RGB', (W, H), (255, 255, 255)), a_)
        ff.stdin.write(img.tobytes())
        if fi % 60 == 0: print(f'{fi}/{n}', flush=True)
    ff.stdin.close(); ff.wait()
    print('wrote', out)
    return out

if __name__ == '__main__':
    args = sys.argv[1:]
    if '--all-hooks' in args:
        for i in range(len(HOOKS)): render(i)
    else:
        i = int(args[args.index('--hook') + 1]) - 1 if '--hook' in args else 0
        render(i)
