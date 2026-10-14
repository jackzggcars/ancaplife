#!/usr/bin/env python3
"""ANCAP LIFE · real-city builder.

Downloads OpenStreetMap data for a box around a city centre from the Overpass API and writes
data/city_<id>.json in the compact format the game loads (same as London, New York and Paris).

  python3 tools/build_city.py chicago 41.8817 -87.6278 3200 3400

Arguments: id, lat0, lon0, width_m, height_m  (the box is centred on lat0/lon0).
Prints the REAL_COVER_STATIC line to paste into index.html.
Map data © OpenStreetMap contributors, ODbL.
"""
import json, math, sys, time, urllib.request, urllib.parse, hashlib, re

UA = 'ancap-life-citybuilder/1.0'
ENDPOINTS = ['https://overpass-api.de/api/interpreter']

def overpass(q, tries=40):
    data = urllib.parse.urlencode({'data': q}).encode()
    last = None
    for i in range(tries):
        for ep in ENDPOINTS:
            try:
                req = urllib.request.Request(ep, data=data, headers={'User-Agent': UA, 'Accept': '*/*'})
                with urllib.request.urlopen(req, timeout=300) as r:
                    return json.loads(r.read().decode('utf-8'))
            except Exception as e:
                last = e
                time.sleep(min(30, 2 + i * 3))
    raise RuntimeError('Overpass failed: %s' % last)

def main():
    cid, lat0, lon0, W, H = sys.argv[1], float(sys.argv[2]), float(sys.argv[3]), float(sys.argv[4]), float(sys.argv[5])
    kx, ky = 111320 * math.cos(math.radians(lat0)), 110540
    x0, x1, y0, y1 = -W / 2, W / 2, -H / 2, H / 2
    pad = 150
    s, n = lat0 + (y0 - pad) / ky, lat0 + (y1 + pad) / ky
    w, e = lon0 + (x0 - pad) / kx, lon0 + (x1 + pad) / kx
    XY = lambda lat, lon: ((lon - lon0) * kx, (lat - lat0) * ky)

    # fetch in tiles so the server never times out on dense cities
    els = {}
    TX = max(1, math.ceil(W / 1100)); TY = max(1, math.ceil(H / 1100))
    for ti in range(TX):
        for tj in range(TY):
            ts, tn = s + (n - s) * tj / TY, s + (n - s) * (tj + 1) / TY
            tw, te = w + (e - w) * ti / TX, w + (e - w) * (ti + 1) / TX
            bb = '%f,%f,%f,%f' % (ts, tw, tn, te)
            q = f"""[out:json][timeout:240];(
way["building"]({bb});relation["building"]["type"="multipolygon"]({bb});way["building:part"]({bb});
way["highway"]({bb});
way["natural"="water"]({bb});relation["natural"="water"]({bb});way["waterway"="riverbank"]({bb});
way["leisure"~"^(park|garden)$"]({bb});relation["leisure"~"^(park|garden)$"]({bb});way["landuse"~"^(grass|recreation_ground|village_green)$"]({bb});
node["natural"="tree"]({bb});
node["amenity"~"^(cafe|restaurant|fast_food|bar|pub)$"]({bb});node["shop"]({bb});
);out geom;"""
            print('tile', ti, tj, file=sys.stderr)
            import os
            cache = '/tmp/osmcache_%s_%d_%d.json' % (cid, ti, tj)
            if os.path.exists(cache):
                d = json.load(open(cache))
            else:
                d = overpass(q)
                json.dump(d, open(cache, 'w'))
            for el in d.get('elements', []):
                els[(el['type'], el['id'])] = el
            time.sleep(2)
    print('elements', len(els), file=sys.stderr)

    def ring_of(geom):
        pts = [XY(p['lat'], p['lon']) for p in geom if p]
        return pts

    def clean(pts, closed=True, tol=0.6):
        out = []
        for x, y in pts:
            q = (int(round(x)), int(round(y)))
            if out and abs(q[0] - out[-1][0]) + abs(q[1] - out[-1][1]) < tol:
                continue
            out.append(q)
        if closed and len(out) > 2 and out[0] == out[-1]:
            out.pop()
        if closed:
            # drop collinear points
            changed = True
            while changed and len(out) > 3:
                changed = False
                for i in range(len(out)):
                    a, b, c = out[i - 1], out[i], out[(i + 1) % len(out)]
                    if abs((b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0])) < 0.5:
                        out.pop(i); changed = True; break
        return out

    def enc(pts):
        o = []; px = py = 0
        for x, y in pts:
            o += [x - px, y - py]; px, py = x, y
        return o

    def area(p):
        a = 0
        for i in range(len(p)):
            x1_, y1_ = p[i]; x2_, y2_ = p[(i + 1) % len(p)]
            a += x1_ * y2_ - x2_ * y1_
        return a / 2

    def centroid(p):
        return sum(q[0] for q in p) / len(p), sum(q[1] for q in p) / len(p)

    def inside(p, x, y):
        c = False; j = len(p) - 1
        for i in range(len(p)):
            xi, yi = p[i]; xj, yj = p[j]
            if (yi > y) != (yj > y) and x < (xj - xi) * (y - yi) / ((yj - yi) or 1e-9) + xi:
                c = not c
            j = i
        return c

    def stitch(ways):
        """join member way geometries into closed rings"""
        segs = [list(wg) for wg in ways if len(wg) >= 2]
        rings = []
        while segs:
            cur = segs.pop(0)
            changed = True
            while changed and cur[0] != cur[-1]:
                changed = False
                for i, sg in enumerate(segs):
                    if sg[0] == cur[-1]: cur += sg[1:]
                    elif sg[-1] == cur[-1]: cur += sg[::-1][1:]
                    elif sg[-1] == cur[0]: cur = sg[:-1] + cur
                    elif sg[0] == cur[0]: cur = sg[::-1][:-1] + cur
                    else: continue
                    segs.pop(i); changed = True; break
            if len(cur) >= 4: rings.append(cur)
        return rings

    def geomkey(g):
        return [(round(p['lat'], 7), round(p['lon'], 7)) for p in g if p]

    def rel_rings(el, role='outer'):
        ws = [geomkey(m['geometry']) for m in el.get('members', []) if m.get('type') == 'way' and m.get('role', 'outer') in (role, '' if role == 'outer' else role) and m.get('geometry')]
        return [[XY(a, b) for a, b in r] for r in stitch(ws)]

    num = lambda v: (lambda m: float(m.group(0)) if m else None)(re.search(r'-?\d+(\.\d+)?', str(v))) if v is not None else None
    in_box = lambda x, y: x0 <= x <= x1 and y0 <= y <= y1
    hh = lambda k: int(hashlib.md5(str(k).encode()).hexdigest()[:8], 16) / 0xffffffff

    # ---------- buildings ----------
    parts, outlines = [], []
    for (t, i), el in els.items():
        tg = el.get('tags', {})
        if 'building:part' in tg and t == 'way' and el.get('geometry'):
            parts.append((el, [ring_of(el['geometry'])]))
        elif 'building' in tg and tg.get('building') not in ('no', 'construction', 'roof') and not tg.get('location') == 'underground':
            if t == 'way' and el.get('geometry'):
                outlines.append((el, [ring_of(el['geometry'])]))
            elif t == 'relation':
                outlines.append((el, rel_rings(el)))
    grid = {}
    def gk(x, y): return (int(x // 60), int(y // 60))
    part_polys = []
    for el, rings in parts:
        for r in rings:
            p = clean(r)
            if len(p) >= 3 and abs(area(p)) > 4:
                cx, cy = centroid(p); part_polys.append((el, p)); grid.setdefault(gk(cx, cy), []).append(p)

    def has_parts(p):
        xs = [q[0] for q in p]; ys = [q[1] for q in p]
        for gx in range(int(min(xs) // 60), int(max(xs) // 60) + 1):
            for gy in range(int(min(ys) // 60), int(max(ys) // 60) + 1):
                for pp in grid.get((gx, gy), []):
                    cx, cy = centroid(pp)
                    if inside(p, cx, cy): return True
        return False

    def heights(tg, key, foot):
        h = num(tg.get('height')); lv = num(tg.get('building:levels'))
        mh = num(tg.get('min_height')); ml = num(tg.get('building:min_level'))
        gen = 0
        if h is None and lv is not None: h = lv * 3.4 + (1.2 if lv > 2 else 0.6)
        if h is None:
            gen = 1
            b = tg.get('building', 'yes')
            if b in ('house', 'detached', 'semidetached_house', 'terrace', 'garage', 'shed', 'hut', 'kiosk'):
                h = 5 + hh(key) * 4
            else:
                h = [11, 14, 14, 17, 17, 21, 24][int(hh(key) * 7)]
                if foot < 60: h = min(h, 8)
        if mh is None and ml is not None: mh = ml * 3.4
        return max(3, min(h, 560)), max(0, mh or 0), gen

    B = []
    for el, p in part_polys:
        tg = el.get('tags', {})
        cx, cy = centroid(p)
        if not in_box(cx, cy): continue
        h, mh, gen = heights(tg, el['id'], abs(area(p)))
        if mh >= h: continue
        B.append((p, h, mh, gen, tg))
    for el, rings in outlines:
        tg = el.get('tags', {})
        for r in rings:
            p = clean(r)
            if len(p) < 3 or abs(area(p)) < 6: continue
            cx, cy = centroid(p)
            if not in_box(cx, cy): continue
            if part_polys and has_parts(p): continue
            h, mh, gen = heights(tg, el['id'], abs(area(p)))
            if mh >= h: mh = 0
            B.append((p, h, mh, gen, tg))
    # ground-up first so raised parts find their bases
    B.sort(key=lambda b: (b[2], -abs(area(b[0]))))
    b_out = [[int(round(h * 10)), int(round(mh * 10)), gen] + enc(p) for p, h, mh, gen, tg in B]
    print('buildings', len(b_out), file=sys.stderr)

    # ---------- POIs: the building each business sits in ----------
    cat_of = lambda tg: ('cafe' if tg.get('amenity') == 'cafe' else 'burger' if tg.get('amenity') in ('fast_food', 'restaurant', 'bar', 'pub') else
                         'bakery' if tg.get('shop') in ('bakery', 'pastry') else 'boutique' if tg.get('shop') in ('clothes', 'boutique', 'fashion', 'shoes', 'fashion_accessories') else
                         'tech' if tg.get('shop') in ('electronics', 'computer', 'mobile_phone') else 'shop' if tg.get('shop') in ('convenience', 'supermarket', 'kiosk') else '')
    bgrid = {}
    for i, (p, h, mh, gen, tg) in enumerate(B):
        if mh > 0: continue
        cx, cy = centroid(p); bgrid.setdefault(gk(cx, cy), []).append(i)
    poi = {}
    for (t, i), el in els.items():
        if t != 'node': continue
        tg = el.get('tags', {})
        if not ('amenity' in tg or 'shop' in tg) or not tg.get('name'): continue
        x, y = XY(el['lat'], el['lon'])
        if not in_box(x, y): continue
        g = gk(x, y); hit = None
        for dx in (-1, 0, 1):
            for dy in (-1, 0, 1):
                for bi in bgrid.get((g[0] + dx, g[1] + dy), []):
                    if inside(B[bi][0], x, y): hit = bi; break
                if hit is not None: break
            if hit is not None: break
        if hit is not None and hit not in poi:
            poi[hit] = [hit, tg['name'][:40], cat_of(tg)]
    poi_out = sorted(poi.values())

    # ---------- roads ----------
    WID = {'motorway': 20, 'trunk': 20, 'primary': 16, 'secondary': 14, 'tertiary': 12, 'motorway_link': 10, 'trunk_link': 10, 'primary_link': 10, 'secondary_link': 10, 'tertiary_link': 10,
           'residential': 10, 'unclassified': 10, 'living_street': 8, 'pedestrian': 8, 'service': 5, 'track': 5, 'footway': 3, 'path': 3, 'cycleway': 3, 'steps': 3, 'bridleway': 3}
    names, nidx, roads = [], {}, []
    for (t, i), el in els.items():
        tg = el.get('tags', {})
        if t != 'way' or 'highway' not in tg or not el.get('geometry'): continue
        wv = WID.get(tg['highway'])
        if not wv or tg.get('tunnel') in ('yes', 'building_passage') or (num(tg.get('layer')) or 0) < 0 or tg.get('area') == 'yes': continue
        if tg['highway'] == 'footway' and tg.get('footway') in ('sidewalk', 'crossing'): continue
        pts = clean(ring_of(el['geometry']), closed=False, tol=1.5)
        pts = [q for q in pts if x0 - 120 <= q[0] <= x1 + 120 and y0 - 120 <= q[1] <= y1 + 120]
        if len(pts) < 2: continue
        nm = tg.get('name', '')
        ni = -1
        if nm:
            if nm not in nidx: nidx[nm] = len(names); names.append(nm[:48])
            ni = nidx[nm]
        roads.append([wv, 1 if tg.get('bridge') and tg.get('bridge') != 'no' else 0, ni] + enc(pts))

    # ---------- water & parks ----------
    def polys(pred, kind):
        out = []
        for (t, i), el in els.items():
            tg = el.get('tags', {})
            if not pred(tg): continue
            if t == 'way' and el.get('geometry'):
                rings = [ring_of(el['geometry'])]; holes = []
            elif t == 'relation':
                rings = rel_rings(el); holes = rel_rings(el, 'inner')
            else: continue
            for r in rings:
                p = clean(r, tol=2)
                if len(p) < 3 or abs(area(p)) < 60: continue
                xs = [q[0] for q in p]; ys = [q[1] for q in p]
                if max(xs) < x0 - 300 or min(xs) > x1 + 300 or max(ys) < y0 - 300 or min(ys) > y1 + 300: continue
                hs = []
                for hr in holes:
                    hp = clean(hr, tol=2)
                    if len(hp) >= 3 and inside(p, *centroid(hp)): hs.append(enc(hp))
                out.append([enc(p)] + hs)
        print(kind, len(out), file=sys.stderr)
        return out
    water = polys(lambda tg: tg.get('natural') == 'water' or tg.get('waterway') == 'riverbank', 'water')
    parks = polys(lambda tg: tg.get('leisure') in ('park', 'garden') or tg.get('landuse') in ('grass', 'recreation_ground', 'village_green'), 'parks')

    # ---------- street trees ----------
    tr = []
    for (t, i), el in els.items():
        if t == 'node' and el.get('tags', {}).get('natural') == 'tree':
            x, y = XY(el['lat'], el['lon'])
            if in_box(x, y): tr.append((int(round(x)), int(round(y))))
    tr = tr[:6000]

    out = {'name': cid, 'lat0': lat0, 'lon0': lon0, 'cover': [[int(x0), int(y0), int(x1), int(y1)]], 'b': b_out, 'poi': poi_out, 'roads': roads,
           'names': names, 'water': water, 'parks': parks, 'trees': enc(tr), 'attribution': '© OpenStreetMap contributors (ODbL)'}
    path = 'data/city_%s.json' % cid
    with open(path, 'w') as f: json.dump(out, f, separators=(',', ':'))
    print('wrote', path, file=sys.stderr)
    print(" %s:{lat0:%s,lon0:%s,box:[[%d,%d,%d,%d]]}," % (cid, lat0, lon0, x0, y0, x1, y1))

if __name__ == '__main__':
    main()
