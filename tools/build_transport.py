#!/usr/bin/env python3
"""ANCAP LIFE · airports, docks and sea lanes.

Inputs (downloaded once into /tmp/tp):
  airports.csv, runways.csv  — OurAirports (public domain), github.com/davidmegginson/ourairports-data
  ports.json                 — github.com/marchah/sea-ports (MIT)
  lanes.json                 — sea lanes computed by lanes.py (A* over a 0.25° land mask)
  osm_air_*.json, osm_dock_*.json — OpenStreetMap extracts (ODbL) for airports/docks near featured cities
Outputs: data/transport.json and data/airhide.js (zones where generated buildings are cleared)
"""
import csv, json, math, os, glob

T = '/tmp/tp'
KY = 110540
def KX(la): return 111320 * math.cos(math.radians(la))

FEAT = {'london': (51.507, -0.128), 'nyc': (40.758, -73.985), 'paris': (48.857, 2.352), 'tokyo': (35.681, 139.767), 'sydney': (-33.868, 151.209), 'saopaulo': (-23.55, -46.633),
        'lagos': (6.455, 3.394), 'mumbai': (18.94, 72.835), 'berlin': (52.52, 13.405), 'toronto': (43.653, -79.383), 'mexico': (19.433, -99.133), 'cairo': (30.044, 31.236),
        'singapore': (1.283, 103.851), 'la': (34.05, -118.244), 'seoul': (37.566, 126.978), 'chicago': (41.882, -87.628)}
DOCKC = {'nyc': (40.66, -74.08), 'london': (51.50, 0.05), 'sydney': (-33.91, 151.20), 'tokyo': (35.60, 139.80), 'singapore': (1.28, 103.78), 'la': (33.75, -118.24),
         'mumbai': (18.95, 72.87), 'lagos': (6.44, 3.38), 'toronto': (43.64, -79.38), 'chicago': (41.88, -87.61)}

def gdist(a, b, c, d):
    p1, p2 = math.radians(a), math.radians(c); dl = math.radians(d - b)
    return 6371000 * 2 * math.asin(min(1, math.sqrt(math.sin((p2 - p1) / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2)))

def enc(pts):
    o = []; px = py = 0
    for x, y in pts:
        x, y = int(round(x)), int(round(y)); o += [x - px, y - py]; px, py = x, y
    return o

def num(v, d=None):
    try: return float(str(v).split()[0].replace('m', ''))
    except Exception: return d

# ---------------- airports ----------------
A = {r['id']: r for r in csv.DictReader(open(f'{T}/airports.csv', encoding='utf-8'))}
RW = {}
for r in csv.DictReader(open(f'{T}/runways.csv', encoding='utf-8')):
    if not (r['le_latitude_deg'] and r['he_latitude_deg'] and r['le_longitude_deg'] and r['he_longitude_deg']) or r['closed'] == '1': continue
    RW.setdefault(r['airport_ref'], []).append(r)
ap = []
small_count = {k: 0 for k in FEAT}
for aid, a in A.items():
    t = a['type']; rws = RW.get(aid)
    if not rws: continue
    keep = t == 'large_airport' or (t == 'medium_airport' and a['scheduled_service'] == 'yes')
    tt = 'L' if t == 'large_airport' else 'M'
    if not keep and t in ('small_airport', 'medium_airport'):
        la, lo = float(a['latitude_deg']), float(a['longitude_deg'])
        paved = any(r['surface'][:3].upper() in ('ASP', 'CON', 'PEM', 'BIT') for r in rws)
        for k, (fl, fo) in FEAT.items():
            if paved and gdist(la, lo, fl, fo) < 110000 and small_count[k] < 8:
                small_count[k] += 1; keep = True; tt = 'S' if t == 'small_airport' else 'M'; break
    if not keep: continue
    rw = []
    for r in rws:
        w = num(r['width_ft'], 0) * 0.3048
        if w < 10: w = 45 if tt == 'L' else 30 if tt == 'M' else 18
        rw.append([round(float(r['le_latitude_deg']), 6), round(float(r['le_longitude_deg']), 6), round(float(r['he_latitude_deg']), 6), round(float(r['he_longitude_deg']), 6),
                   round(min(w, 75)), r['le_ident'][:4], r['he_ident'][:4]])
    ap.append([a['ident'], a['iata_code'], a['name'][:60], round(float(a['latitude_deg']), 5), round(float(a['longitude_deg']), 5), tt, rw])
print('airports', len(ap), {k: sum(1 for x in ap if x[5] == k) for k in 'LMS'})
byiata = {x[1]: x for x in ap if x[1]}

def ring(geom, la0, lo0):
    kx = KX(la0)
    return [((p['lon'] - lo0) * kx, (p['lat'] - la0) * KY) for p in geom if p]

def stitch_outer(el, la0, lo0, role='outer'):
    ws = [[(round(p['lat'], 7), round(p['lon'], 7)) for p in m['geometry'] if p] for m in el.get('members', []) if m.get('type') == 'way' and m.get('role', 'outer') == role and m.get('geometry')]
    rings = []
    while ws:
        cur = ws.pop(0); ch = True
        while ch and cur[0] != cur[-1]:
            ch = False
            for i, s in enumerate(ws):
                if s[0] == cur[-1]: cur += s[1:]
                elif s[-1] == cur[-1]: cur += s[::-1][1:]
                elif s[-1] == cur[0]: cur = s[:-1] + cur
                elif s[0] == cur[0]: cur = s[::-1][:-1] + cur
                else: continue
                ws.pop(i); ch = True; break
        if len(cur) > 3:
            kx = KX(la0); rings.append([((lo - lo0) * kx, (la - la0) * KY) for la, lo in cur])
    return rings

def simplify(pts, tol=1.5):
    out = []
    for p in pts:
        if out and abs(p[0] - out[-1][0]) + abs(p[1] - out[-1][1]) < tol: continue
        out.append(p)
    if len(out) > 2 and abs(out[0][0] - out[-1][0]) + abs(out[0][1] - out[-1][1]) < tol: out.pop()
    return out

osm = {}
hide_polys = []
for f in sorted(glob.glob(f'{T}/osm_air_*.json')):
    code = f.split('_')[-1][:-5]
    a = byiata.get(code)
    if not a: continue
    la0, lo0 = a[3], a[4]
    d = json.load(open(f))
    O = {'bnd': [], 'ap': [], 'tw': [], 'te': [], 'hg': [], 'ct': []}
    for el in d.get('elements', []):
        tg = el.get('tags', {}); ae = tg.get('aeroway'); t = el['type']
        geoms = []
        if t == 'way' and el.get('geometry'): geoms = [ring(el['geometry'], la0, lo0)]
        elif t == 'relation': geoms = stitch_outer(el, la0, lo0)
        elif t == 'node': geoms = [[((el['lon'] - lo0) * KX(la0), (el['lat'] - la0) * KY)]]
        for g in geoms:
            closed = t == 'relation' or (t == 'way' and el['geometry'][0] == el['geometry'][-1])
            g2 = simplify(g, 1.5 if ae != 'aerodrome' else 8)
            if ae == 'aerodrome' and closed and len(g2) > 2:
                O['bnd'].append(enc(g2)); hide_polys.append([la0, lo0, enc(g2)])
            elif ae == 'apron' and closed and len(g2) > 2: O['ap'].append(enc(g2))
            elif ae == 'taxiway' and len(g2) > 1 and not closed: O['tw'].append([round(num(tg.get('width'), 20) or 20), enc(g2)])
            elif (ae == 'terminal' or tg.get('building') == 'terminal') and closed and len(g2) > 2:
                h = num(tg.get('height')) or (num(tg.get('building:levels'), 0) or 0) * 4.5 or 20
                O['te'].append([round(min(h, 45)), enc(g2)])
            elif (ae == 'hangar' or tg.get('building') == 'hangar') and closed and len(g2) > 2:
                O['hg'].append([round(min(num(tg.get('height')) or 16, 35)), enc(g2)])
            elif ae == 'control_tower' or (tg.get('man_made') == 'tower' and tg.get('tower:type') in ('control', 'observation', None) and ae):
                cx = sum(p[0] for p in g) / len(g); cy = sum(p[1] for p in g) / len(g)
                O['ct'].append([round(cx), round(cy), round(min(num(tg.get('height')) or 45, 140))])
    # keep the largest aerodrome boundary only
    if O['bnd']:
        def ar(e):
            pts = []; x = y = 0
            for i in range(0, len(e), 2): x += e[i]; y += e[i + 1]; pts.append((x, y))
            return abs(sum(pts[i][0] * pts[(i + 1) % len(pts)][1] - pts[(i + 1) % len(pts)][0] * pts[i][1] for i in range(len(pts)))) / 2
        O['bnd'] = [max(O['bnd'], key=ar)]
    O['ct'] = O['ct'][:2]
    osm[code] = O
    print('osm', code, {k: len(v) for k, v in O.items()})

# ---------------- docks ----------------
docks = {}
for f in sorted(glob.glob(f'{T}/osm_dock_*.json')):
    cid = f.split('_')[-1][:-5]
    if cid not in DOCKC: continue
    la0, lo0 = DOCKC[cid]
    d = json.load(open(f))
    D = {'lat': la0, 'lon': lo0, 'pier': [], 'pierp': [], 'bw': [], 'quay': [], 'port': [], 'marina': [], 'crane': [], 'wh': []}
    whs = []
    for el in d.get('elements', []):
        tg = el.get('tags', {}); t = el['type']; mm = tg.get('man_made')
        if t == 'node':
            if mm == 'crane': D['crane'].append([round((el['lon'] - lo0) * KX(la0)), round((el['lat'] - la0) * KY), 0])
            continue
        geoms = [ring(el['geometry'], la0, lo0)] if t == 'way' and el.get('geometry') else stitch_outer(el, la0, lo0) if t == 'relation' else []
        for g in geoms:
            closed = t == 'relation' or el['geometry'][0] == el['geometry'][-1]
            g2 = simplify(g, 2)
            if len(g2) < 2: continue
            if mm == 'pier': (D['pierp'] if closed and len(g2) > 2 else D['pier']).append(enc(g2) if closed and len(g2) > 2 else [round(num(tg.get('width'), 8) or 8), enc(g2)])
            elif mm in ('breakwater', 'groyne'): D['bw'].append(enc(g2))
            elif mm == 'quay': D['quay'].append(enc(g2))
            elif mm == 'crane' and t == 'way':
                cx = sum(p[0] for p in g) / len(g); cy = sum(p[1] for p in g) / len(g)
                ang = math.atan2(g[-1][1] - g[0][1], g[-1][0] - g[0][0]) if len(g) > 1 else 0
                D['crane'].append([round(cx), round(cy), round(-ang, 2)])
            elif tg.get('landuse') in ('port', 'harbour') and closed and len(g2) > 2:
                D['port'].append(enc(g2)); hide_polys.append([la0, lo0, enc(g2)])
            elif tg.get('leisure') == 'marina' and closed and len(g2) > 2: D['marina'].append(enc(g2))
            elif tg.get('building') == 'warehouse' and closed and len(g2) > 2: whs.append((g2, num(tg.get('height')) or 12))
    D['crane'] = D['crane'][:160]
    D['wh'] = [[round(min(h, 25)), enc(g)] for g, h in whs][:400]
    docks[cid] = D
    print('dock', cid, {k: len(v) for k, v in D.items() if isinstance(v, list)})

# ---------------- ports & lanes ----------------
P = json.load(open(f'{T}/ports.json'))
L = json.load(open(f'{T}/lanes.json'))
hubs = set(h[0] for h in L['hubs'])
ports = []
seen = []
for code, p in P.items():
    c = p.get('coordinates')
    if not c or len(c) < 2: continue
    lo, la = c[0], c[1]
    if any(abs(la - a) < .03 and abs(lo - b) < .04 for a, b in seen): continue
    seen.append((la, lo))
    ports.append([p.get('name', code)[:40], round(la, 4), round(lo, 4), 1 if code in hubs else 0])
print('ports', len(ports), 'lanes', len(L['routes']))

out = {'ap': ap, 'osm': osm, 'docks': docks, 'ports': ports, 'lanes': [{'a': r['a'], 'b': r['b'], 'p': r['p']} for r in L['routes']],
       'attribution': 'Airports: OurAirports (public domain). Ports: sea-ports (MIT). Airport and dock detail: © OpenStreetMap contributors (ODbL).'}
json.dump(out, open('data/transport.json', 'w'), separators=(',', ':'))
print('transport.json', os.path.getsize('data/transport.json'))

# ---------------- hide zones (runway strips + OSM aerodrome/port polygons) ----------------
rects = []
for a in ap:
    for r in a[6]:
        la1, lo1, la2, lo2, w = r[:5]
        L_ = gdist(la1, lo1, la2, lo2)
        if L_ < 300: continue
        h = math.atan2((lo2 - lo1) * KX(la1), (la2 - la1) * KY)
        rects.append([round((la1 + la2) / 2, 5), round((lo1 + lo2) / 2, 5), round(L_ + 500), round(w + (260 if a[5] != 'S' else 80)), round(h, 3)])
js = 'const AIRHIDE=' + json.dumps({'r': rects, 'p': hide_polys}, separators=(',', ':')) + ';'
open('data/airhide.js', 'w').write(js)
print('airhide', len(rects), len(hide_polys), len(js))
