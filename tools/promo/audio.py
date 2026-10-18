"""
Original, royalty-free soundtrack and sound effects for the promo, synthesised with numpy (no samples, no licences).
  * music(): a driving 120 BPM track (kick, clap, hats, bass, chord stabs, pluck arp) with a riser and a drop
  * sfx: ka-ching, coin, pop, whoosh, boom, tick
mix(timeline) places SFX at the cue times from edit.py and ducks the music under them.
"""
import numpy as np, wave

SR = 48000
BPM = 120
BEAT = 60 / BPM
rng = np.random.default_rng(7)

def t_(sec): return np.arange(int(sec * SR)) / SR
def env(n, a=.003, d=.2, curve=4.0):
    t = np.arange(n) / SR
    e = np.minimum(1, t / max(a, 1e-4)) * np.exp(-np.maximum(0, t - a) / max(d, 1e-4) * curve / 4)
    return e
def lp(x, a):  # one-pole low-pass, a in (0,1): smaller = darker
    y = np.empty_like(x); acc = 0.
    for i in range(len(x)): acc += a * (x[i] - acc); y[i] = acc
    return y
def lp_fast(x, cutoff):
    # FFT brick-ish low-pass, quick for long signals
    X = np.fft.rfft(x); f = np.fft.rfftfreq(len(x), 1 / SR)
    X *= 1 / (1 + (f / cutoff) ** 4)
    return np.fft.irfft(X, len(x))
def hp_fast(x, cutoff):
    X = np.fft.rfft(x); f = np.fft.rfftfreq(len(x), 1 / SR)
    X *= (f / cutoff) ** 4 / (1 + (f / cutoff) ** 4)
    return np.fft.irfft(X, len(x))
def saw(freq, sec, detune=0):
    t = t_(sec); out = np.zeros_like(t)
    for k in range(1, 14):
        out += np.sin(2 * np.pi * freq * (1 + detune) * k * t) / k
    return out * .55
def note(n): return 440 * 2 ** ((n - 69) / 12)

# ------------------------------------------------------------------ drums
def kick():
    n = int(.38 * SR); t = np.arange(n) / SR
    f = 45 + 110 * np.exp(-t * 28); ph = 2 * np.pi * np.cumsum(f) / SR
    return np.sin(ph) * np.exp(-t * 7.5) * 1.0 + (rng.standard_normal(n) * np.exp(-t * 300)) * .15
def clap():
    n = int(.25 * SR); t = np.arange(n) / SR
    x = hp_fast(rng.standard_normal(n), 1200)
    e = np.zeros(n)
    for o in (0, .011, .022): e += np.exp(-np.maximum(0, t - o) * 60) * (t >= o)
    e += np.exp(-t * 18) * .5
    return x * e * .45
def hat(open_=False):
    n = int((.22 if open_ else .06) * SR); t = np.arange(n) / SR
    return hp_fast(rng.standard_normal(n), 7000) * np.exp(-t * (14 if open_ else 70)) * .22

# ------------------------------------------------------------------ music
PROG = [(57, [57, 60, 64]), (53, [53, 57, 60]), (48, [48, 52, 55, 60]), (55, [55, 59, 62])]   # Am F C G
def music(sec, drop_at=None, riser=None, intro_beats=0):
    N = int(sec * SR); out = np.zeros(N + SR); bars = int(np.ceil(sec / (4 * BEAT))) + 1
    K, C, Hc, Ho = kick(), clap(), hat(), hat(True)
    def add(sig, at, g=1.):
        i = int(at * SR)
        if i >= len(out): return
        j = min(len(out), i + len(sig)); out[i:j] += sig[:j - i] * g
    for b in range(bars):
        root, ch = PROG[b % 4]; t0 = b * 4 * BEAT
        for q in range(4):
            tb = t0 + q * BEAT
            add(K, tb, .95)
            if q in (1, 3): add(C, tb, .8)
            add(Hc, tb + BEAT / 2, .9); add(Hc, tb + BEAT * .25, .35); add(Hc, tb + BEAT * .75, .35)
        add(Ho, t0 + 3.5 * BEAT, .6)
        # bass: eighth-note pulses, octave jump on the "and" of 4
        for e8 in range(8):
            f = note(root - 24 + (12 if e8 == 7 else 0)); s = saw(f, BEAT / 2 * .95)
            s = lp_fast(s, 380) * env(len(s), .004, .18, 3); add(s, t0 + e8 * BEAT / 2, .55)
        # chord stabs on the off-beats
        for st in (.5, 1.5, 2.5, 3.25, 3.5):
            s = sum(saw(note(n), .32, d) for n in ch for d in (-.004, .004))
            s = lp_fast(s, 2600) * env(len(s), .005, .12, 4); add(s, t0 + st * BEAT, .085)
        # pluck arpeggio, sixteenths
        arp = ch + [ch[0] + 12, ch[1] + 12]
        for k in range(16):
            n = arp[(k * 3) % len(arp)] + 12
            tt = t_(.14); s = (np.sin(2 * np.pi * note(n) * tt) + .4 * np.sin(4 * np.pi * note(n) * tt)) * np.exp(-tt * 22)
            add(s, t0 + k * BEAT / 4, .07)
    out = out[:N]
    # intro: filtered and without kick for the first beats
    if intro_beats:
        m = int(intro_beats * BEAT * SR); out[:m] = lp_fast(out[:m], 900) * .8
    if riser:
        a, b = riser; n = int((b - a) * SR); t = np.arange(n) / SR
        f = 200 * (12 ** (t / t[-1])); r = np.sin(2 * np.pi * np.cumsum(f) / SR) * .12 + hp_fast(rng.standard_normal(n), 3000) * .18 * (t / t[-1])
        r *= (t / t[-1]) ** 1.6; i = int(a * SR); out[i:i + n] += r[:max(0, min(n, N - i))]
        # filter the music down during the riser for tension
        seg = out[i:i + n]; out[i:i + n] = seg * (1 - .5 * (t / t[-1])[:len(seg)])
    return out

# ------------------------------------------------------------------ sfx
def kaching():
    tt = t_(1.1); x = np.zeros_like(tt)
    for f, g, d in ((2093, .5, 3.2), (2637, .35, 3.8), (3136, .3, 4.5), (4186, .2, 6), (1568, .25, 3)):
        x += np.sin(2 * np.pi * f * tt) * np.exp(-tt * d) * g
    drawer = hp_fast(rng.standard_normal(len(tt)), 2500) * np.exp(-tt * 40) * .35
    x2 = np.zeros_like(x); off = int(.06 * SR); x2[off:] = x[:-off]
    return (x * .55 + x2 * .7 + drawer) * .8
def coin():
    tt = t_(.28); x = np.sin(2 * np.pi * 1975 * tt) * (tt < .07) + np.sin(2 * np.pi * 2637 * tt) * (tt >= .07)
    return x * np.exp(-tt * 14) * .32
def tick():
    tt = t_(.05); return np.sin(2 * np.pi * 3200 * tt) * np.exp(-tt * 120) * .25
def pop():
    tt = t_(.16); f = 300 + 900 * np.exp(-tt * 40)
    return np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-tt * 26) * .7
def whoosh(sec=.55):
    n = int(sec * SR); t = np.arange(n) / SR
    x = rng.standard_normal(n); X = np.fft.rfft(x); f = np.fft.rfftfreq(n, 1 / SR)
    X *= np.exp(-((np.log(f + 1) - np.log(1800)) ** 2) / 1.2); x = np.fft.irfft(X, n)
    e = np.sin(np.pi * t / sec) ** 2
    return x / (np.abs(x).max() + 1e-9) * e * .55
def boom():
    n = int(1.4 * SR); t = np.arange(n) / SR
    f = 38 + 70 * np.exp(-t * 9); x = np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-t * 2.2)
    x += lp_fast(rng.standard_normal(n), 400) * np.exp(-t * 6) * .6
    return x * .9
SFX = {'kaching': kaching, 'coin': coin, 'tick': tick, 'pop': pop, 'whoosh': whoosh, 'boom': boom}

# ------------------------------------------------------------------ voice-over (Kokoro TTS, runs offline once the model files are downloaded)
VOICE = 'am_puck'
KOKORO_DIR = __import__('os').environ.get('KOKORO_DIR', '/tmp/kok')
_kok = None
def voice_line(text, max_sec, voice=VOICE):
    """speak one line, speeding up (to 1.5x) so it fits in max_sec; returns mono float array at SR"""
    global _kok
    import os
    if _kok is None:
        from kokoro_onnx import Kokoro
        _kok = Kokoro(os.path.join(KOKORO_DIR, 'kokoro-v1.0.onnx'), os.path.join(KOKORO_DIR, 'voices-v1.0.bin'))
    sp = 1.12
    for _ in range(6):
        y, sr = _kok.create(text, voice=voice, speed=sp, lang='en-us')
        y = np.asarray(y, dtype=float)
        nz = np.where(np.abs(y) > .01)[0]
        if len(nz): y = y[max(0, nz[0] - int(.02 * sr)):nz[-1] + int(.06 * sr)]
        if len(y) / sr <= max_sec or sp >= 1.5: break
        sp = min(1.5, sp * (len(y) / sr) / max_sec * 1.03)
    t_old = np.arange(len(y)) / sr; t_new = np.arange(int(len(y) / sr * SR)) / SR
    y = np.interp(t_new, t_old, y)
    y = y / (np.abs(y).max() + 1e-9)
    # presence: gentle high-shelf boost and soft compression so it cuts through the music
    y = y + .35 * hp_fast(y, 2500)
    return np.tanh(y * 1.6) / np.tanh(1.6)

def mix(sec, cues, riser=None, intro_beats=2, music_gain=.62, duck=.45, vo=None, vo_gain=.95):
    """cues: list of (time, name, gain); vo: list of (start, end, text)"""
    m = music(sec, riser=riser, intro_beats=intro_beats) * music_gain
    fx = np.zeros(len(m) + 2 * SR); duckenv = np.ones(len(m))
    cache = {}
    for t, name, g in cues:
        s = cache.get(name)
        if s is None: s = cache[name] = SFX[name]()
        i = int(t * SR); j = min(len(fx), i + len(s)); fx[i:j] += s[:j - i] * g
        if name in ('kaching', 'boom', 'pop'):
            a, b = i, min(len(m), i + int(.35 * SR))
            if a < len(m):
                ramp = np.linspace(duck, 1, b - a); duckenv[a:b] = np.minimum(duckenv[a:b], ramp)
    voice = np.zeros(len(m)); vduck = np.ones(len(m))
    for (a, b, text) in (vo or []):
        y = voice_line(text, max(.5, b - a - .08)); i = int(a * SR); j = min(len(m), i + len(y))
        voice[i:j] += y[:j - i] * vo_gain
        k0, k1 = max(0, i - int(.06 * SR)), min(len(m), j + int(.12 * SR)); vduck[k0:k1] = np.minimum(vduck[k0:k1], .38)
    vduck = np.convolve(vduck, np.ones(int(.05 * SR)) / int(.05 * SR), 'same')   # smooth the ducking
    out = m * duckenv * vduck + fx[:len(m)] * (.6 + .4 * vduck) + voice
    # end: fade the last 0.4 s slightly so the loop point is clean
    k = int(.25 * SR); out[-k:] *= np.linspace(1, .7, k)
    peak = np.abs(out).max(); out = out / peak * .89 if peak > 0 else out
    return np.tanh(out * 1.15) / np.tanh(1.15)

def write_wav(path, x):
    y = (np.clip(x, -1, 1) * 32767).astype(np.int16)
    st = np.stack([y, y], 1).reshape(-1)
    with wave.open(str(path), 'wb') as w:
        w.setnchannels(2); w.setsampwidth(2); w.setframerate(SR); w.writeframes(st.tobytes())
