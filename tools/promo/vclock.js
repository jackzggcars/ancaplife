// Virtual clock for frame-by-frame capture: the page only advances when the recorder calls __step(ms).
(()=>{window.__PROMO=true;let fake=1000;const q=[];const realRAF=window.requestAnimationFrame.bind(window);
 performance.now=()=>fake;
 window.requestAnimationFrame=cb=>{q.push(cb);return q.length};window.cancelAnimationFrame=()=>{};
 window.__step=ms=>{fake+=ms;const c=q.splice(0);for(const f of c){try{f(fake)}catch(e){console.error(e)}}};
 let auto=null;window.__auto=on=>{clearInterval(auto);auto=null;if(on)auto=setInterval(()=>window.__step(16.7),4)};
 window.__auto(true);
 try{localStorage.setItem('ancap.gfx',window.__GFX||'balanced');localStorage.setItem('ancap.vivid','1');localStorage.setItem('groundfloor.shadows','1');localStorage.setItem('ancap.prefs',JSON.stringify({intros:false}))}catch(e){}
})();
