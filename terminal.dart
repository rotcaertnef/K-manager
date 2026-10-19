// Terminal: Python (Pyodide = real CPython compiled to WebAssembly) + HTML renderer + React/JSX renderer.
// Everything runs inside one WebView page (terminalHtml below). It needs internet the first time it loads
// (Pyodide, React, Babel, lucide icons and Tailwind come from CDNs).
//   Python mode : full Python 3, imports auto-install (numpy, pandas, matplotlib...), `pip install x` works (pure-python wheels).
//   HTML mode   : whatever you type is rendered in a frame under the output.
//   JSX mode    : React component with `import React, {useState} from 'react'` and `import {Sparkles,...} from 'lucide-react'`.
// From Python you can call render_html("<h1>hi</h1>") and render_jsx("...jsx...") ; plt.show() draws charts inline.
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

class TerminalPage extends StatefulWidget {
  final String? code;
  final String mode; // 'py' | 'jsx' | 'html'
  const TerminalPage({super.key, this.code, this.mode = 'py'});
  @override
  State<TerminalPage> createState() => _TerminalPageState();
}

class _TerminalPageState extends State<TerminalPage> {
  late final WebViewController c;

  @override
  void initState() {
    super.initState();
    c = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFF0D1117))
      ..setNavigationDelegate(NavigationDelegate(onPageFinished: (_) {
        final code = widget.code;
        if (code != null) {
          c.runJavaScript('window.__init=${jsonEncode({'code': code, 'mode': widget.mode})};pending();');
        }
      }))
      ..loadHtmlString(terminalHtml, baseUrl: 'https://kterm.local/');
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: const Text('Terminal', style: TextStyle(fontSize: 16)),
          actions: [IconButton(icon: const Icon(Icons.refresh), tooltip: 'Restart', onPressed: () => c.reload())],
        ),
        body: SafeArea(child: WebViewWidget(controller: c)),
      );
}

const terminalHtml = r'''<!DOCTYPE html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1">
<style>
*{box-sizing:border-box}
html,body{margin:0;height:100%;background:#0d1117;color:#c9d1d9;font:13px/1.45 ui-monospace,Menlo,Consolas,monospace}
body{display:flex;flex-direction:column}
#out{flex:1;overflow:auto;padding:8px 10px}
#out div{white-space:pre-wrap;word-break:break-word}
.err{color:#ff7b72}.in{color:#7ee787}.sys{color:#8b949e}
iframe{display:block;width:100%;height:320px;border:1px solid #30363d;border-radius:8px;background:#fff;margin:6px 0}
img.fig{display:block;max-width:100%;background:#fff;border-radius:8px;margin:6px 0}
.row{display:flex;gap:6px;padding:6px 6px 0;background:#161b22;flex-wrap:wrap}
#bar{display:flex;gap:6px;padding:6px;background:#161b22;align-items:flex-end}
button{background:#30363d;color:#c9d1d9;border:0;border-radius:6px;padding:8px 12px;font:inherit}
button.run{background:#238636;color:#fff}
button.on{background:#1f6feb;color:#fff}
textarea{flex:1;min-height:46px;max-height:150px;background:#0d1117;color:#c9d1d9;border:1px solid #30363d;border-radius:6px;padding:8px;font:inherit}
</style>
<script src="https://cdn.jsdelivr.net/pyodide/v0.26.4/full/pyodide.js"></script>
</head><body>
<div id="out"></div>
<div class="row">
  <button id="m-py" class="on" onclick="setMode('py')">Python</button>
  <button id="m-jsx" onclick="setMode('jsx')">JSX</button>
  <button id="m-html" onclick="setMode('html')">HTML</button>
  <button onclick="hist(-1)">&#9650;</button><button onclick="hist(1)">&#9660;</button>
  <button onclick="document.getElementById('out').innerHTML=''">Clear</button>
</div>
<div id="bar"><textarea id="in" autocapitalize="off" autocomplete="off" autocorrect="off" spellcheck="false" placeholder="print('hello')"></textarea>
<button class="run" onclick="runInput()">Run</button></div>
<script>
let py=null,MODE='py',H=[],hi=0,mplDone=false;
const out=document.getElementById('out'),inp=document.getElementById('in');
const HOLD={py:"print('hello')",jsx:"export default function App(){ return <h1 className='text-2xl p-4'>Hello</h1> }",html:'<h1>Hello</h1>'};
function log(t,c){const d=document.createElement('div');if(c)d.className=c;d.textContent=t;out.appendChild(d);out.scrollTop=out.scrollHeight}
function setMode(m){MODE=m;for(const k of['py','jsx','html'])document.getElementById('m-'+k).className=k===m?'on':'';inp.placeholder=HOLD[m]}
function hist(d){if(!H.length)return;hi=Math.max(0,Math.min(H.length-1,hi+d));inp.value=H[hi].code;setMode(H[hi].mode)}
function runInput(){const code=inp.value;if(!code.trim())return;H.push({code,mode:MODE});hi=H.length;inp.value='';run(code,MODE)}
function addFrame(doc){
  const f=document.createElement('iframe');f.setAttribute('sandbox','allow-scripts allow-modals');f.srcdoc=doc;out.appendChild(f);
  const b=document.createElement('button');b.textContent='Expand / collapse';b.onclick=()=>{f.style.height=f.style.height==='75vh'?'320px':'75vh'};
  const w=document.createElement('div');w.appendChild(b);out.appendChild(w);out.scrollTop=out.scrollHeight}
function renderHTML(s){addFrame(String(s))}
function renderImage(b64){const i=document.createElement('img');i.className='fig';i.src='data:image/png;base64,'+b64;out.appendChild(i);out.scrollTop=out.scrollHeight}

// ---- JSX: rewrite imports of react / react-dom / lucide-react to globals, then run inside a sandboxed frame
const LIBS={'react':'__R','react-dom':'__RD','react-dom/client':'__RD','lucide-react':'__L'};
function decl(spec,lib){
  spec=spec.trim();let o='';
  const st=spec.match(/^\*\s+as\s+([\w$]+)$/);if(st)return 'const '+st[1]+'='+lib+';';
  const m=spec.match(/^([\w$]+)?\s*,?\s*(\{[\s\S]*\})?$/);
  if(m&&m[1])o+='const '+m[1]+'=('+lib+'.default||'+lib+');';
  if(m&&m[2])o+='const '+m[2].replace(/\s+as\s+/g,': ')+'='+lib+';';
  return o}
function rewrite(src){
  let def=null;
  let code=src.replace(/^\s*import\s+['"][^'"]+['"]\s*;?\s*$/gm,'')
    .replace(/import\s+([\s\S]*?)\s+from\s+['"]([^'"]+)['"]\s*;?/g,(m,spec,mod)=>{
      const lib=LIBS[mod];if(!lib)throw new Error('Unsupported import "'+mod+'" (available: react, react-dom, lucide-react)');return decl(spec,lib)});
  code=code.replace(/export\s+default\s+function\s+([\w$]+)/,(m,n)=>{def=n;return 'function '+n})
           .replace(/export\s+default\s+class\s+([\w$]+)/,(m,n)=>{def=n;return 'class '+n});
  if(!def)code=code.replace(/export\s+default\s+([\w$]+)\s*;?\s*$/m,(m,n)=>{def=n;return ''});
  if(!def)code=code.replace(/export\s+default\s+/,()=>{def='__Default';return 'const __Default = '});
  code=code.replace(/\bexport\s+(?=(?:const|let|var|function|class)\b)/g,'');
  return{code,def}}
function jsxDoc(code,def){
  const J=JSON.stringify(code).replace(/</g,'\\u003c'),D=JSON.stringify(def);
  return `<!DOCTYPE html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<script src="https://cdn.tailwindcss.com/3.4.17"><\/script>
<script src="https://cdnjs.cloudflare.com/ajax/libs/react/18.3.1/umd/react.production.min.js"><\/script>
<script src="https://cdnjs.cloudflare.com/ajax/libs/react-dom/18.3.1/umd/react-dom.production.min.js"><\/script>
<script src="https://cdn.jsdelivr.net/npm/@babel/standalone@7.26.4/babel.min.js"><\/script>
<script src="https://cdn.jsdelivr.net/npm/lucide-react@0.460.0/dist/umd/lucide-react.min.js"><\/script>
<style>body{margin:0;font-family:system-ui,sans-serif}pre.e{color:#b00020;white-space:pre-wrap;padding:12px}</style></head>
<body><div id="root"></div><script>
const root=document.getElementById('root');
function fail(e){root.innerHTML='';const p=document.createElement('pre');p.className='e';p.textContent=String(e&&e.message||e);root.appendChild(p)}
window.onerror=(m)=>{fail(m)};
try{
  const L=window.lucideReact||window.LucideReact||{};
  const js=Babel.transform(${J},{presets:['react']}).code;
  const DEF=${D};
  const fn=new Function('__R','__RD','__L',js+'\\nreturn '+(DEF||'(typeof App!=="undefined"?App:null)')+';');
  const Comp=fn(React,ReactDOM,L);
  if(!Comp)throw new Error('No default export or App component found');
  class EB extends React.Component{constructor(p){super(p);this.state={e:null}}static getDerivedStateFromError(e){return{e}}
    render(){return this.state.e?React.createElement('pre',{className:'e'},String(this.state.e)):this.props.children}}
  ReactDOM.createRoot(root).render(React.createElement(EB,null,React.createElement(Comp)));
}catch(e){fail(e)}
<\/script></body></html>`}
function renderJSX(src){let r;try{r=rewrite(String(src))}catch(e){log(String(e.message),'err');return}addFrame(jsxDoc(r.code,r.def))}

// ---- Python
const MPL=`
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt, io, base64, js
def _show(*a, **k):
    for n in plt.get_fignums():
        b = io.BytesIO(); plt.figure(n).savefig(b, format='png', dpi=110, bbox_inches='tight')
        js.renderImage(base64.b64encode(b.getvalue()).decode())
    plt.close('all')
plt.show = _show
`;
async function run(code,mode){
  log((mode==='py'?'>>> ':mode+'> ')+code.split('\n').join('\n... '),'in');
  if(mode==='html'){renderHTML(code);return}
  if(mode==='jsx'){renderJSX(code);return}
  if(!py){log('Python is still loading, try again in a moment...','sys');return}
  try{
    const t=code.trim();
    if(/^!?pip install /.test(t)){
      const pk=t.replace(/^!?pip install /,'').split(/\s+/).filter(x=>x&&!x.startsWith('-'));
      await py.loadPackage('micropip');await py.pyimport('micropip').install(py.toPy(pk));log('Installed '+pk.join(', '),'sys');return}
    await py.loadPackagesFromImports(code);
    if(/matplotlib/.test(code)&&!mplDone){await py.runPythonAsync(MPL);mplDone=true}
    const r=await py.runPythonAsync(code);
    if(r!==undefined&&r!==null){log(String(r));if(r.destroy){try{r.destroy()}catch(e){}}}
  }catch(e){log(String(e.message||e).trim(),'err')}}
function pending(){const i=window.__init;if(!i)return;if(i.mode==='py'&&!py)return;window.__init=null;setMode(i.mode);run(i.code,i.mode)}
async function boot(){
  log('Loading Python (first start downloads about 10 MB)...','sys');
  try{
    py=await loadPyodide({stdout:t=>log(t),stderr:t=>log(t,'err')});
    await py.runPythonAsync("import js\ndef render_html(s): js.renderHTML(str(s))\ndef render_jsx(s): js.renderJSX(str(s))\nhtml = render_html");
    log('Python '+py.runPython('import sys; sys.version.split()[0]')+' ready.','sys');
    log('Helpers: render_html("<h1>hi</h1>"), render_jsx(code), plt.show(), pip install <pkg>. Modes: Python / JSX / HTML.','sys');
    pending();
  }catch(e){log('Could not load Python: '+(e.message||e)+' (needs internet)','err')}}
boot();
</script></body></html>''';
