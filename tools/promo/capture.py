"""
ANCAP LIFE promo capture: plays a scripted session in the real game and saves every frame.

The page runs on a virtual clock (vclock.js), so each frame is rendered completely before it is saved and the
footage is smooth however slow the machine is. A demo empire is set up through the game's own functions
(shops leased with createSite, kit placed with autoPlace, staff hired from the real candidates, a building under
construction), then each shot moves the camera and saves frames to frames/<shot>/0001.jpg ...

Usage:
  python3 -m http.server 8770            # from the repo root, in another terminal
  python3 tools/promo/capture.py          # all shots
  python3 tools/promo/capture.py hook cta # only some shots
Options via env: PROMO_URL (default http://localhost:8770/), PROMO_W/PROMO_H (default 720x1280), PROMO_FPS (15)
"""
import asyncio, base64, json, math, os, sys, time
from pathlib import Path
from playwright.async_api import async_playwright

HERE = Path(__file__).resolve().parent
OUT = HERE / 'frames'
URL = os.environ.get('PROMO_URL', 'http://localhost:8770/')
W, H = int(os.environ.get('PROMO_W', 720)), int(os.environ.get('PROMO_H', 1280))
FPS = int(os.environ.get('PROMO_FPS', 15))
THREE_LOCAL = os.environ.get('PROMO_THREE')   # optional local three.min.js if the CDN is blocked

# what the HUD counter shows during each shot: (start, end) cash, eased
SHOTS = [
 # name,       seconds, cash from, cash to
 ('hook',      3.0, 41_800_000, 48_212_930),
 ('first',     2.2, 12_400, 18_950),
 ('timessq',   3.0, 61_000, 64_500),
 ('interior',  2.6, 180_000, 262_000),
 ('build',     2.6, 2_400_000, 3_150_000),
 ('tokyo',     2.4, 9_800_000, 14_600_000),
 ('payoff',    4.2, 22_000_000, 1_204_000_000),
 ('cta',       3.0, 1_204_000_000, 1_250_000_000),
]

HIDE_CSS = """
html body #bar,html body #left,html body #right,html body #legend,html body #ticker,html body #crdock,html body #crlayers,html body #mapctl,html body #crfps,html body #toasts,html body #tut,html body #flhud,html body #hint,html body #ibar,html body #care-intro,html body #vtp,html body #cartp,html body #crlist,html body #modal,html body #shopsmenu,html body #elp,html body #invp,html body #mppanel,html body #landtip,html body .fl-obj,html body .fl-lvl,html body .fl-event,html body .fl-week,html body .fl-day,html body #goalchip,html body #skipov,html body #crgame,html body #crpick,html body .hb-icons{display:none!important;visibility:hidden!important}
html body .clabel.feat button{font-size:25px!important;text-shadow:0 2px 0 #000,0 0 8px #000!important}
html body .clabel.feat button::before{width:11px!important;height:11px!important}
html body .clabel i{display:none!important}
html body .clabel b{display:inline-block;margin-left:8px;min-width:30px;height:30px;line-height:30px;border-radius:15px;background:#ffde00;color:#000;font:900 18px/30px Inter,Arial,sans-serif;text-align:center;box-shadow:0 0 0 3px #000,0 0 18px 4px rgba(255,222,0,.75);vertical-align:2px}
#promohud{position:fixed;left:0;right:0;top:15.5%;display:flex;flex-direction:column;align-items:center;gap:2px;pointer-events:none;z-index:99;font-family:Inter,'Helvetica Neue',Arial,sans-serif}
#promohud small{font:800 15px/1 Inter,Arial,sans-serif;letter-spacing:.28em;color:#fff;text-shadow:0 2px 0 #000,0 0 10px rgba(0,0,0,.8)}
#promohud b{font:900 58px/1.05 Inter,Arial,sans-serif;color:#ffde00;-webkit-text-stroke:3px #000;paint-order:stroke fill;text-shadow:0 5px 0 #000,0 0 26px rgba(0,0,0,.55);font-variant-numeric:tabular-nums;letter-spacing:-.01em}
#promohud i{font:800 20px/1 Inter,Arial,sans-serif;font-style:normal;color:#7cf59a;-webkit-text-stroke:1.5px #000;paint-order:stroke fill;text-shadow:0 3px 0 #000}
.clabel{transform-origin:center;}
"""

HUD_JS = """
(()=>{if(document.getElementById('promohud'))return;const d=document.createElement('div');d.id='promohud';d.innerHTML='<small>NET WORTH</small><b id="ph-v">$0</b><i id="ph-r"></i>';document.body.appendChild(d);
 window.__hud=(v,rate,show)=>{d.style.display=show?'flex':'none';document.getElementById('ph-v').textContent='$'+Math.round(v).toLocaleString('en-US');document.getElementById('ph-r').textContent=rate?('+$'+Math.round(rate).toLocaleString('en-US')+' / day'):''}})();
"""

def ease(t): return t*t*(3-2*t)
def lerp(a, b, t): return a + (b - a) * t
def loglerp(a, b, t): return math.exp(lerp(math.log(a), math.log(b), t))

class Rec:
    def __init__(self, pg, cdp): self.pg, self.cdp = pg, cdp
    async def js(self, s, *a): return await self.pg.evaluate(s, *a)
    async def warm(self, lat, lon, dist, tilt=-.62, heading=0., need=1, timeout=600):
        """put the camera somewhere and let the city around it build before recording"""
        await self.js(f"__auto(true);Object.assign(CAM,{{lat:{lat},lon:{lon},dist:{dist},tiltU:{tilt},heading:{heading}}});ROT.h=null;FLIGHT=null;ui.busy=false;updateCamera()")
        t0 = time.time()
        while time.time() - t0 < timeout:
            n = await self.js("[...LIVE.values()].filter(L=>L.kind!=='empty'&&L.meshes&&L.meshes.length&&!L.job).length")
            busy = await self.js("[...LIVE.values()].some(L=>L.job)")
            if n >= need and not busy: break
            await asyncio.sleep(2)
        await asyncio.sleep(3)
        await self.js("__auto(false)")
    async def shot(self, name, secs, cam, cash=(0, 0), hud=True, each=None):
        d = OUT / name; d.mkdir(parents=True, exist_ok=True)
        for f in d.glob('*.jpg'): f.unlink()
        n = max(1, round(secs * FPS)); meta = []
        print(f'[{name}] {n} frames', flush=True); t0 = time.time()
        c = cam(0); await self.js(f"Object.assign(CAM,{json.dumps(c)});ROT.h=null;FLIGHT=null")
        for _ in range(3): await self.js(f"__step({1000/FPS})")   # settle the first frame
        for i in range(n):
            t = i / max(1, n - 1)
            c = cam(t)
            v = loglerp(max(1, cash[0]), max(1, cash[1]), ease(t)) if cash[1] > cash[0] * 50 else lerp(cash[0], cash[1], ease(t))
            await self.js(f"Object.assign(CAM,{json.dumps(c)});ROT.h=null;FLIGHT=null;G.cash={v};__hud({v},{max(0,(cash[1]-cash[0])/ (secs*4))},{str(hud).lower()})")
            if each: await each(i, t)
            await self.js(f"__step({1000/FPS})")
            r = await self.cdp.send('Page.captureScreenshot', {'format': 'jpeg', 'quality': 93, 'optimizeForSpeed': True})
            (d / f'{i+1:04d}.jpg').write_bytes(base64.b64decode(r['data']))
            meta.append({'i': i, 'cash': v})
            if i % 10 == 0: print(f'  {i}/{n}  {(time.time()-t0)/(i+1):.1f}s/frame', flush=True)
        (d / 'meta.json').write_text(json.dumps({'fps': FPS, 'frames': n, 'meta': meta}))

PREP_JS = r"""
async()=>{
 const pickLease=(C,lat,lon,minSqm,skip)=>{let best=null,bd=1e18;for(const l of C.lots){if(l.landmark||l.kind||l.hidden)continue;if((l.sqm||0)<minSqm)continue;const st=lotState(l);if(!st||st.st!=='lease')continue;if(skip.has(l.key))continue;const d=distM(l.lat,l.lon,lat,lon);if(d<bd){bd=d;best=l}}return best};
 const used=new Set(),made=[];
 const plan=[['london',51.5135,-0.1340,'cafe',3],['nyc',40.7580,-73.9855,'cafe',2],['paris',48.8698,2.3412,'bakery',2],['tokyo',35.6595,139.7005,'cafe',2],['berlin',52.5163,13.3889,'cafe',1],['chicago',41.8826,-87.6278,'cafe',1]];
 for(const[id,lat,lon,type,n]of plan){await loadCity(id);const C=CITYDATA[id];if(!C||!C.lots)continue;const b=BIZ[type]||BIZ.cafe;
  for(let k=0;k<n;k++){const lot=pickLease(C,lat+k*.0012,lon+k*.0009,b.minSqm,used);if(!lot)continue;used.add(lot.key);const E=econAt(lot.lat,lot.lon);setLotState(lot,{st:'player'});
   const s=createSite({lot,type:BIZ[type]?type:'cafe',tenure:'lease',rent:groundRent(E,lot),deposit:0,name:`${lot.street} ${b.n}`});
   for(const e of b.equip)if(e.req)s.equip[e.id]=1;for(const r of b.roles){const c=s.cands[r.id];if(c&&c.length)s.staff.push(c.shift())}
   for(const k2 of bizSupplies(b))s.inv[k2]={q:400,c:1};s.status='open';s.openDay=G.day;s.rep=70;made.push({id:s.id,city:id,key:lot.key,lat:lot.lat,lon:lot.lon})}}
 return made}
"""

FIT_JS = r"""
(sid)=>{const s=G.sites.find(x=>x.id===sid);if(!s||!IN||IN.site!==s)return 'no interior';const b=BIZ[s.type];s.layout=s.layout||[];
 for(const e of b.equip){const n=e.req?1:(Math.random()<.6?1:0);for(let i=0;i<n;i++){s.equip[e.id]=Math.max(s.equip[e.id]||0,i+1);const it=autoPlace(s,IN.rm,e.id);if(it)s.layout.push(it)}}
 for(const r of b.roles){const c=s.cands[r.id];while(c&&c.length&&s.staff.filter(x=>x.role===r.id).length<2)s.staff.push(c.shift())}
 try{rebuildItems()}catch(e){}try{interiorStaffChanged(s)}catch(e){}return s.layout.length}
"""

async def main(only):
    OUT.mkdir(exist_ok=True)
    async with async_playwright() as p:
        b = await p.chromium.launch(args=['--use-gl=angle', '--use-angle=swiftshader', '--enable-unsafe-swiftshader', '--disable-gpu-compositing', '--hide-scrollbars'])
        ctx = await b.new_context(viewport={'width': W, 'height': H}, device_scale_factor=1)
        pg = await ctx.new_page()
        pg.on('pageerror', lambda e: print('PAGEERROR', str(e)[:200]))
        await pg.add_init_script(path=str(HERE / 'vclock.js'))
        if THREE_LOCAL: await pg.route('**/three.min.js', lambda r: r.fulfill(path=THREE_LOCAL))
        await pg.route('**/supabase.js', lambda r: r.abort())
        await pg.goto(URL); await pg.wait_for_timeout(9000)
        cdp = await ctx.new_cdp_session(pg)
        R = Rec(pg, cdp)
        # sign-in bypass for a local demo session (nothing is saved to the cloud: supabase.js is blocked)
        await R.js("AUTH.user={id:'promo'};$('#front').hidden=true;G=newGame('Lion Co.');G.tutDone=true;G.cartTutDone=true;G.tut=null;G.soc={daily:{last:new Date().toISOString().slice(0,10),streak:1}};ui.started=true;VIS.cycle=false;VIS.phase=.38;renderAll();save=()=>{};")
        await pg.add_style_tag(content=HIDE_CSS); await R.js(HUD_JS)
        await R.js("setInterval(()=>{if(ui.modal)closeModal()},300)")
        made = await pg.evaluate(PREP_JS)
        print('demo empire:', len(made), 'shops', flush=True)
        await R.js("restyleAll();recolorAll&&recolorAll()")
        want = lambda n: not only or n in only
        S = {s[0]: s for s in SHOTS}

        # 1. HOOK: the planet with shops in six countries, counter racing
        def globe(lat0, lon0, d0, d1, spin):
            return lambda t: {'lat': lerp(lat0, lat0 - 4, t), 'lon': lon0 + spin * t, 'dist': loglerp(d0, d1, t), 'tiltU': -1.05, 'heading': 0}
        if want('hook'):
            await R.warm(46, -42, 1.25e7, -1.05, need=0, timeout=20)
            await R.shot('hook', S['hook'][1], globe(46, -42, 1.25e7, 1.1e7, 26), S['hook'][2:])
        # 2. one tiny shop in London: slow push-in on the first lease
        lon_sites = [m for m in made if m['city'] == 'london']
        if want('first') and lon_sites:
            s0 = lon_sites[0]
            await R.js(f"selectLot(lotByKey('{s0['key']}'))")
            await R.warm(s0['lat'], s0['lon'], 260, -.55, .4)
            await R.shot('first', S['first'][1], lambda t: {'lat': s0['lat'], 'lon': s0['lon'], 'dist': lerp(250, 150, ease(t)), 'tiltU': lerp(-.58, -.5, t), 'heading': .4 + .25 * t}, S['first'][2:])
            await R.js("selectLot(null)")
        # 3. Times Square: sweep down over Midtown
        if want('timessq'):
            nyc = [m for m in made if m['city'] == 'nyc']
            lat, lon = (nyc[0]['lat'], nyc[0]['lon']) if nyc else (40.7580, -73.9855)
            if nyc: await R.js(f"selectLot(lotByKey('{nyc[0]['key']}'))")
            await R.warm(lat, lon, 900, -.66, -.35)
            await R.shot('timessq', S['timessq'][1], lambda t: {'lat': lat - .0012 * (1 - t), 'lon': lon, 'dist': loglerp(1150, 620, ease(t)), 'tiltU': lerp(-.62, -.74, t), 'heading': -.35 + .3 * t}, S['timessq'][2:])
            await R.js("selectLot(null)")
        # 4. inside the first shop: staff at work
        if want('interior') and lon_sites:
            s0 = lon_sites[0]
            await R.warm(s0['lat'], s0['lon'], 200, -.55)
            await R.js("__auto(true)")
            for _ in range(30):
                ok = await R.js(f"(()=>{{if(IN&&IN.site&&IN.site.id==='{s0['id']}')return true;if(!FLIGHT)enterInterior(G.sites.find(x=>x.id==='{s0['id']}'));return false}})()")
                if ok: break
                await asyncio.sleep(2)
            await asyncio.sleep(4)
            print('fit:', await pg.evaluate(FIT_JS, s0['id']), flush=True)
            await asyncio.sleep(8); await R.js("__auto(false)")
            c = await R.js("({lat:IN.cLat,lon:IN.cLon})")
            await R.shot('interior', S['interior'][1], lambda t: {'lat': c['lat'], 'lon': c['lon'], 'dist': lerp(34, 24, ease(t)), 'tiltU': lerp(-.62, -.5, t), 'heading': lerp(.6, 1.3, t)}, S['interior'][2:])
            await R.js("exitInterior(true)")
        # 5. building a tower: construction rises floor by floor (game days advance between frames)
        if want('build') and lon_sites:
            plot = await R.js("""(()=>{const C=CITYDATA.london;let best=null,bd=1e18;const c=G.sites[0];for(const l of C.lots){if(l.kind||l.landmark||l.hidden)continue;const st=lotState(l);if(!st||st.st!=='plot')continue;if((l.area||0)<500)continue;const d=distM(l.lat,l.lon,c.lat,c.lon);if(d<bd){bd=d;best=l}}if(!best)return null;
              G.props.push({id:'p'+(G.seq++),key:best.key,lat:best.lat,lon:best.lon,place:'London',day:G.day,floors:0,ground:'vacant',build:{floors:16,start:G.day,end:G.day+40},built:false,price:1});setLotState(best,{st:'player'});return {key:best.key,lat:best.lat,lon:best.lon}})()""")
            if plot:
                await R.warm(plot['lat'], plot['lon'], 230, -.42, 1.0)
                await R.js("__auto(true)"); await asyncio.sleep(5); await R.js("__auto(false)")
                async def grow(i, t):
                    await R.js(f"(()=>{{const p=G.props[G.props.length-1];p.build.start=G.day-Math.round({t}*40)-2;if({i}%3===0)restyleAll()}})()")
                await R.shot('build', S['build'][1], lambda t: {'lat': plot['lat'], 'lon': plot['lon'], 'dist': lerp(230, 190, t), 'tiltU': lerp(-.40, -.36, t), 'heading': 1.0 + .5 * t}, S['build'][2:], each=grow)
        # 6. jump to another country: Tokyo
        tok = [m for m in made if m['city'] == 'tokyo']
        if want('tokyo') and tok:
            s1 = tok[0]
            await R.warm(s1['lat'], s1['lon'], 650, -.66, 2.2)
            await R.shot('tokyo', S['tokyo'][1], lambda t: {'lat': s1['lat'], 'lon': s1['lon'], 'dist': loglerp(760, 520, ease(t)), 'tiltU': lerp(-.62, -.7, t), 'heading': 2.2 - .5 * t}, S['tokyo'][2:])
        # 7. PAYOFF: from a London street all the way out to the planet
        if want('payoff') and lon_sites:
            s0 = lon_sites[0]
            await R.warm(s0['lat'], s0['lon'], 300, -.5, .3)
            def pay(t):
                # 0-40%: pull out of the street (300 m -> 4 km), 40-55%: rush to 600 km, 55-100%: out to the whole planet
                if t < .4: d = loglerp(300, 4000, ease(t / .4))
                elif t < .55: d = loglerp(4000, 6e5, (t - .4) / .15)
                else: d = loglerp(6e5, 1.25e7, ease((t - .55) / .45))
                m = max(0., (math.log(d) - math.log(6e5)) / (math.log(1.25e7) - math.log(6e5)))
                return {'lat': lerp(s0['lat'], 50, ease(m)), 'lon': lerp(s0['lon'], -16, ease(m)), 'dist': d, 'tiltU': lerp(-.5, -1.05, min(1, t / .55)), 'heading': lerp(.3, 0, min(1, t / .55))}
            await R.shot('payoff', S['payoff'][1], pay, S['payoff'][2:])
        # 8. CTA: back to the hook framing so the loop is seamless
        if want('cta'):
            await R.warm(50, -16, 1.25e7, -1.05, need=0, timeout=20)
            await R.shot('cta', S['cta'][1], globe(50, -16, 1.25e7, 1.25e7, -26), S['cta'][2:])
        await b.close()

if __name__ == '__main__':
    asyncio.run(main(set(sys.argv[1:])))
