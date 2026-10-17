// MT Micro - tiny file manager: browse, copy/move/delete/rename, edit text, view images, run HTML.
// Single file on purpose so it is easy to read and grow. Sections: helpers, app, permission gate,
// file browser, image viewer, text editor, HTML viewer (local server).
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:permission_handler/permission_handler.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'unzipper.dart';

const rootPath = '/storage/emulated/0';
const imgExt = {'.jpg', '.jpeg', '.png', '.gif', '.webp', '.bmp', '.wbmp'};
const htmlExt = {'.html', '.htm', '.xhtml'};

// ---------------------------------------------------------------- helpers
String fmtSize(int b) {
  if (b < 1024) return '$b B';
  const u = ['KB', 'MB', 'GB', 'TB'];
  double v = b / 1024;
  int i = 0;
  while (v >= 1024 && i < u.length - 1) { v /= 1024; i++; }
  return '${v.toStringAsFixed(v < 10 ? 2 : 1)} ${u[i]}';
}

String fmtDate(DateTime t) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
}

class Item {
  final FileSystemEntity e;
  final FileStat st;
  final bool dir;
  Item(this.e, this.st) : dir = st.type == FileSystemEntityType.directory;
  String get name => p.basename(e.path);
  String get path => e.path;
  String get ext => p.extension(e.path).toLowerCase();
}

IconData iconFor(Item i) {
  if (i.dir) return Icons.folder;
  if (imgExt.contains(i.ext)) return Icons.image;
  if (htmlExt.contains(i.ext)) return Icons.html;
  if (['.mp4', '.mkv', '.webm', '.avi', '.mov'].contains(i.ext)) return Icons.movie;
  if (['.mp3', '.wav', '.ogg', '.flac', '.m4a'].contains(i.ext)) return Icons.audiotrack;
  if (['.zip', '.rar', '.7z', '.tar', '.gz', '.apk'].contains(i.ext)) return Icons.archive;
  return Icons.description;
}

void toast(BuildContext c, String m) =>
    ScaffoldMessenger.of(c).showSnackBar(SnackBar(content: Text(m), duration: const Duration(seconds: 2)));

Future<String?> askText(BuildContext c, String title, {String initial = ''}) {
  final ctl = TextEditingController(text: initial);
  return showDialog<String>(
    context: c,
    builder: (_) => AlertDialog(
      title: Text(title),
      content: TextField(controller: ctl, autofocus: true),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
        TextButton(onPressed: () => Navigator.pop(c, ctl.text.trim()), child: const Text('OK')),
      ],
    ),
  );
}

Future<bool> confirm(BuildContext c, String msg) async {
  final r = await showDialog<bool>(
    context: c,
    builder: (_) => AlertDialog(
      content: Text(msg),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('No')),
        TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Yes')),
      ],
    ),
  );
  return r ?? false;
}

String uniq(String dir, String name) {
  var t = p.join(dir, name);
  if (!File(t).existsSync() && !Directory(t).existsSync()) return t;
  final b = p.basenameWithoutExtension(name), x = p.extension(name);
  for (var i = 1;; i++) {
    t = p.join(dir, '$b ($i)$x');
    if (!File(t).existsSync() && !Directory(t).existsSync()) return t;
  }
}

Future<void> copyEntity(String src, String dst, bool isDir) async {
  if (!isDir) { await File(src).copy(dst); return; }
  if (p.isWithin(src, dst)) throw 'Cannot copy a folder into itself';
  await Directory(dst).create(recursive: true);
  await for (final e in Directory(src).list(followLinks: false)) {
    await copyEntity(e.path, p.join(dst, p.basename(e.path)), e is Directory);
  }
}

Future<void> moveEntity(String src, String dst, bool isDir) async {
  try {
    if (isDir) { await Directory(src).rename(dst); } else { await File(src).rename(dst); }
  } on FileSystemException {
    await copyEntity(src, dst, isDir); // rename fails across volumes: copy, then delete
    if (isDir) { await Directory(src).delete(recursive: true); } else { await File(src).delete(); }
  }
}

// ---------------------------------------------------------------- app + permission gate
void main() => runApp(const MTMicroApp());

class MTMicroApp extends StatelessWidget {
  const MTMicroApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'MT Micro',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.teal, brightness: Brightness.dark),
        home: const Gate(),
      );
}

class Gate extends StatefulWidget {
  const Gate({super.key});
  @override
  State<Gate> createState() => _GateState();
}

class _GateState extends State<Gate> with WidgetsBindingObserver {
  bool? ok;
  @override
  void initState() { super.initState(); WidgetsBinding.instance.addObserver(this); check(); }
  @override
  void dispose() { WidgetsBinding.instance.removeObserver(this); super.dispose(); }
  @override
  void didChangeAppLifecycleState(AppLifecycleState s) { if (s == AppLifecycleState.resumed) check(); }

  Future<void> check() async {
    var g = await Permission.manageExternalStorage.isGranted;
    if (!g) g = await Permission.storage.isGranted;
    if (mounted) setState(() => ok = g);
  }

  Future<void> ask() async {
    final s = await Permission.manageExternalStorage.request(); // opens "All files access" settings on Android 11+
    if (!s.isGranted) await Permission.storage.request();
    check();
  }

  @override
  Widget build(BuildContext context) {
    if (ok == true) return const Browser();
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.folder_open, size: 72),
            const SizedBox(height: 16),
            const Text('MT Micro needs "All files access" to manage your storage.', textAlign: TextAlign.center),
            const SizedBox(height: 20),
            FilledButton(onPressed: ask, child: const Text('Grant access')),
          ]),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- file browser
class Browser extends StatefulWidget {
  const Browser({super.key});
  @override
  State<Browser> createState() => _BrowserState();
}

class _BrowserState extends State<Browser> {
  Directory cwd = Directory(rootPath);
  List<Item> items = [];
  final sel = <String>{};
  List<String> clip = [];
  bool cut = false, hidden = false, loading = false, asc = true, autoUnzip = true;
  String sortBy = 'name';

  @override
  void initState() { super.initState(); go(cwd); }

  List<Item> get shown => hidden ? items : items.where((i) => !i.name.startsWith('.')).toList();
  bool get atTop => cwd.path == rootPath || cwd.parent.path == cwd.path;

  Future<void> go(Directory d) async {
    setState(() => loading = true);
    try {
      final raw = await d.list(followLinks: false).toList();
      final its = <Item>[];
      for (final e in raw) { try { its.add(Item(e, await e.stat())); } catch (_) {} }
      cwd = d; items = its; sel.clear(); resort();
      if (autoUnzip && d.path == autoUnzipDir) autoScan();
    } catch (_) {
      if (mounted) toast(context, 'Cannot open ${p.basename(d.path)} (restricted by Android)');
    }
    if (mounted) setState(() => loading = false);
  }

  void resort() {
    items.sort((a, b) {
      if (a.dir != b.dir) return a.dir ? -1 : 1;
      int r;
      if (sortBy == 'size') { r = a.st.size.compareTo(b.st.size); }
      else if (sortBy == 'date') { r = a.st.modified.compareTo(b.st.modified); }
      else { r = a.name.toLowerCase().compareTo(b.name.toLowerCase()); }
      return asc ? r : -r;
    });
  }

  Future<void> open(Item i) async {
    if (i.dir) return go(Directory(i.path));
    if (i.ext == '.zip') {
      final made = p.join(p.dirname(i.path), p.basenameWithoutExtension(i.path));
      if (autoUnzip && Directory(made).existsSync()) return go(Directory(made)); // already extracted
      if (autoUnzip || await confirm(context, 'Extract ${i.name}?')) await unzip(i.path);
      return;
    }
    Widget? page;
    if (imgExt.contains(i.ext)) {
      final imgs = shown.where((x) => !x.dir && imgExt.contains(x.ext)).map((x) => x.path).toList();
      page = ImageViewer(paths: imgs, index: imgs.indexOf(i.path));
    } else if (htmlExt.contains(i.ext)) {
      page = HtmlViewer(path: i.path);
    } else {
      page = Editor(path: i.path);
    }
    await Navigator.push(context, MaterialPageRoute(builder: (_) => page!));
    refresh();
  }

  Future<void> refresh() => go(cwd);

  // Auto-unzip: every .zip in autoUnzipDir (see unzipper.dart) gets extracted once into a same-named folder.
  Future<void> autoScan() async {
    final made = await autoUnzipAll(autoUnzipDir);
    if (made.isNotEmpty && mounted) {
      toast(context, 'Auto-unzipped ${made.length} zip file(s)');
      if (cwd.path == autoUnzipDir) refresh();
    }
  }

  // Extracts <name>.zip into a new folder named <name> next to it, then opens that folder.
  Future<void> unzip(String zipPath) async {
    final dest = uniq(p.dirname(zipPath), p.basenameWithoutExtension(zipPath));
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(content: Row(children: [CircularProgressIndicator(), SizedBox(width: 16), Text('Extracting...')])),
    );
    var n = 0;
    String? err;
    try { n = await unzipTo(zipPath, dest); } catch (e) { err = '$e'; }
    if (!mounted) return;
    Navigator.pop(context);
    if (err != null) { toast(context, 'Unzip failed: $err'); refresh(); return; }
    toast(context, 'Extracted $n files');
    go(Directory(dest));
  }

  void tap(Item i) {
    if (sel.isNotEmpty) { setState(() => sel.contains(i.path) ? sel.remove(i.path) : sel.add(i.path)); }
    else { open(i); }
  }

  Future<void> doDelete() async {
    if (!await confirm(context, 'Delete ${sel.length} item(s)? This cannot be undone.')) return;
    for (final s in sel.toList()) {
      try {
        if (FileSystemEntity.isDirectorySync(s)) { await Directory(s).delete(recursive: true); } else { await File(s).delete(); }
      } catch (_) { if (mounted) toast(context, 'Failed: ${p.basename(s)}'); }
    }
    refresh();
  }

  Future<void> doRename() async {
    final old = sel.first;
    final n = await askText(context, 'Rename', initial: p.basename(old));
    if (n == null || n.isEmpty || n == p.basename(old)) return;
    try {
      await moveEntity(old, p.join(p.dirname(old), n), FileSystemEntity.isDirectorySync(old));
    } catch (_) { if (mounted) toast(context, 'Rename failed'); }
    refresh();
  }

  Future<void> doPaste() async {
    for (final s in clip) {
      final isDir = FileSystemEntity.isDirectorySync(s);
      if (cut && p.dirname(s) == cwd.path) continue;
      final dest = uniq(cwd.path, p.basename(s));
      try {
        if (cut) { await moveEntity(s, dest, isDir); } else { await copyEntity(s, dest, isDir); }
      } catch (e) { if (mounted) toast(context, 'Failed: ${p.basename(s)} ($e)'); }
    }
    if (cut) clip = [];
    refresh();
  }

  Future<void> create(bool folder) async {
    final n = await askText(context, folder ? 'New folder' : 'New file');
    if (n == null || n.isEmpty) return;
    try {
      final t = p.join(cwd.path, n);
      if (folder) { await Directory(t).create(); } else { await File(t).create(); }
    } catch (_) { if (mounted) toast(context, 'Could not create'); }
    refresh();
  }

  @override
  Widget build(BuildContext context) {
    final list = shown;
    final selecting = sel.isNotEmpty;
    return PopScope(
      canPop: !selecting && atTop,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (selecting) { setState(sel.clear); } else { go(cwd.parent); }
      },
      child: Scaffold(
        drawer: Drawer(
          child: SafeArea(
            child: ListView(children: [
              const ListTile(title: Text('MT Micro', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold))),
              for (final e in {
                'Internal storage': rootPath,
                'Download': '$rootPath/Download',
                'DCIM': '$rootPath/DCIM',
                'Pictures': '$rootPath/Pictures',
                'Documents': '$rootPath/Documents',
                'All volumes (/storage)': '/storage',
              }.entries)
                ListTile(
                  leading: const Icon(Icons.folder_outlined),
                  title: Text(e.key),
                  onTap: () { Navigator.pop(context); go(Directory(e.value)); },
                ),
            ]),
          ),
        ),
        appBar: AppBar(
          leading: selecting ? IconButton(icon: const Icon(Icons.close), onPressed: () => setState(sel.clear)) : null,
          title: selecting
              ? Text('${sel.length} selected')
              : Text(cwd.path, style: const TextStyle(fontSize: 14), maxLines: 2, overflow: TextOverflow.ellipsis),
          actions: selecting
              ? [
                  IconButton(icon: const Icon(Icons.select_all), onPressed: () => setState(() => sel.addAll(list.map((i) => i.path)))),
                  IconButton(icon: const Icon(Icons.copy), onPressed: () => setState(() { clip = sel.toList(); cut = false; sel.clear(); })),
                  IconButton(icon: const Icon(Icons.content_cut), onPressed: () => setState(() { clip = sel.toList(); cut = true; sel.clear(); })),
                  if (sel.length == 1 && sel.first.toLowerCase().endsWith('.zip'))
                    IconButton(icon: const Icon(Icons.unarchive), onPressed: () { final z = sel.first; setState(sel.clear); unzip(z); }),
                  if (sel.length == 1) IconButton(icon: const Icon(Icons.drive_file_rename_outline), onPressed: doRename),
                  IconButton(icon: const Icon(Icons.delete), onPressed: doDelete),
                ]
              : [
                  IconButton(icon: const Icon(Icons.arrow_upward), onPressed: atTop ? null : () => go(cwd.parent)),
                  PopupMenuButton<String>(
                    icon: const Icon(Icons.more_vert),
                    onSelected: (v) {
                      if (v == 'folder') { create(true); }
                      else if (v == 'file') { create(false); }
                      else if (v == 'hidden') { setState(() => hidden = !hidden); }
                      else if (v == 'asc') { setState(() { asc = !asc; resort(); }); }
                      else if (v == 'refresh') { refresh(); }
                      else if (v == 'unzip') { setState(() => autoUnzip = !autoUnzip); refresh(); }
                      else { setState(() { sortBy = v; resort(); }); }
                    },
                    itemBuilder: (_) => [
                      const PopupMenuItem(value: 'folder', child: Text('New folder')),
                      const PopupMenuItem(value: 'file', child: Text('New file')),
                      const PopupMenuDivider(),
                      const PopupMenuItem(value: 'name', child: Text('Sort by name')),
                      const PopupMenuItem(value: 'size', child: Text('Sort by size')),
                      const PopupMenuItem(value: 'date', child: Text('Sort by date')),
                      PopupMenuItem(value: 'asc', child: Text(asc ? 'Order: ascending' : 'Order: descending')),
                      PopupMenuItem(value: 'hidden', child: Text(hidden ? 'Hide hidden files' : 'Show hidden files')),
                      PopupMenuItem(value: 'unzip', child: Text(autoUnzip ? 'Auto-unzip on tap: ON' : 'Auto-unzip on tap: OFF')),
                      const PopupMenuItem(value: 'refresh', child: Text('Refresh')),
                    ],
                  ),
                ],
        ),
        bottomNavigationBar: clip.isEmpty
            ? null
            : Material(
                color: Theme.of(context).colorScheme.surfaceContainerHigh,
                child: SafeArea(
                  child: Row(children: [
                    Padding(padding: const EdgeInsets.all(12), child: Text('${clip.length} to ${cut ? 'move' : 'copy'}')),
                    const Spacer(),
                    TextButton(onPressed: () => setState(() => clip = []), child: const Text('Cancel')),
                    FilledButton(onPressed: doPaste, child: const Text('Paste here')),
                    const SizedBox(width: 12),
                  ]),
                ),
              ),
        body: Column(children: [
          if (loading) const LinearProgressIndicator(),
          Expanded(
            child: RefreshIndicator(
              onRefresh: refresh,
              child: list.isEmpty && !loading
                  ? ListView(children: const [SizedBox(height: 120), Center(child: Text('Empty folder'))])
                  : ListView.builder(
                      itemCount: list.length,
                      itemBuilder: (_, k) {
                        final i = list[k];
                        final isImg = !i.dir && imgExt.contains(i.ext);
                        return ListTile(
                          selected: sel.contains(i.path),
                          leading: SizedBox(
                            width: 44, height: 44,
                            child: isImg
                                ? ClipRRect(
                                    borderRadius: BorderRadius.circular(6),
                                    child: Image.file(File(i.path), cacheWidth: 96, fit: BoxFit.cover,
                                        errorBuilder: (_, __, ___) => Icon(iconFor(i), size: 36)))
                                : Icon(iconFor(i), size: 36, color: i.dir ? Colors.amber : null),
                          ),
                          title: Text(i.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: Text('${i.dir ? 'Folder' : fmtSize(i.st.size)}  •  ${fmtDate(i.st.modified)}'),
                          trailing: selecting ? Checkbox(value: sel.contains(i.path), onChanged: (_) => tap(i)) : null,
                          onTap: () => tap(i),
                          onLongPress: () => setState(() => sel.contains(i.path) ? sel.remove(i.path) : sel.add(i.path)),
                        );
                      },
                    ),
            ),
          ),
        ]),
      ),
    );
  }
}

// ---------------------------------------------------------------- image viewer
class ImageViewer extends StatefulWidget {
  final List<String> paths;
  final int index;
  const ImageViewer({super.key, required this.paths, required this.index});
  @override
  State<ImageViewer> createState() => _ImageViewerState();
}

class _ImageViewerState extends State<ImageViewer> {
  late final PageController pc = PageController(initialPage: widget.index < 0 ? 0 : widget.index);
  late int cur = widget.index < 0 ? 0 : widget.index;
  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black54,
          title: Text('${p.basename(widget.paths[cur])}  (${cur + 1}/${widget.paths.length})', style: const TextStyle(fontSize: 14)),
        ),
        body: PageView.builder(
          controller: pc,
          itemCount: widget.paths.length,
          onPageChanged: (v) => setState(() => cur = v),
          itemBuilder: (_, k) => InteractiveViewer(
            minScale: 1, maxScale: 8,
            child: Center(
              child: Image.file(File(widget.paths[k]), fit: BoxFit.contain,
                  errorBuilder: (_, __, ___) => const Text('Cannot decode this image')),
            ),
          ),
        ),
      );
}

// ---------------------------------------------------------------- text editor
class Editor extends StatefulWidget {
  final String path;
  const Editor({super.key, required this.path});
  @override
  State<Editor> createState() => _EditorState();
}

class _EditorState extends State<Editor> {
  final c = TextEditingController();
  bool dirty = false;
  String? err;
  double fs = 13;
  bool get isHtml => htmlExt.contains(p.extension(widget.path).toLowerCase());

  @override
  void initState() { super.initState(); load(); }
  @override
  void dispose() { c.dispose(); super.dispose(); }

  Future<void> load() async {
    try {
      final f = File(widget.path);
      final len = await f.length();
      if (len > 3 * 1024 * 1024) { setState(() => err = 'Too big for the micro editor (${fmtSize(len)})'); return; }
      final b = await f.readAsBytes();
      if (b.take(8000).contains(0)) { setState(() => err = 'Binary file - cannot edit as text'); return; }
      c.text = utf8.decode(b, allowMalformed: true);
      c.addListener(() { if (!dirty) setState(() => dirty = true); });
      setState(() {});
    } catch (e) { setState(() => err = 'Cannot read file: $e'); }
  }

  Future<void> save() async {
    try {
      await File(widget.path).writeAsString(c.text);
      setState(() => dirty = false);
      if (mounted) toast(context, 'Saved');
    } catch (e) { if (mounted) toast(context, 'Save failed: $e'); }
  }

  @override
  Widget build(BuildContext context) => PopScope(
        canPop: !dirty,
        onPopInvokedWithResult: (did, _) async {
          if (did) return;
          if (await confirm(context, 'Discard unsaved changes?') && mounted) Navigator.pop(context);
        },
        child: Scaffold(
          appBar: AppBar(
            title: Text('${p.basename(widget.path)}${dirty ? ' *' : ''}', style: const TextStyle(fontSize: 15)),
            actions: [
              IconButton(icon: const Icon(Icons.text_decrease), onPressed: () => setState(() => fs = (fs - 1).clamp(8, 28))),
              IconButton(icon: const Icon(Icons.text_increase), onPressed: () => setState(() => fs = (fs + 1).clamp(8, 28))),
              if (isHtml)
                IconButton(
                  icon: const Icon(Icons.play_arrow),
                  onPressed: () async {
                    if (dirty) await save();
                    if (mounted) Navigator.push(context, MaterialPageRoute(builder: (_) => HtmlViewer(path: widget.path)));
                  },
                ),
              IconButton(icon: const Icon(Icons.save), onPressed: err == null ? save : null),
            ],
          ),
          body: err != null
              ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(err!, textAlign: TextAlign.center)))
              : TextField(
                  controller: c,
                  maxLines: null, expands: true,
                  textAlignVertical: TextAlignVertical.top,
                  keyboardType: TextInputType.multiline,
                  autocorrect: false, enableSuggestions: false,
                  style: TextStyle(fontFamily: 'monospace', fontSize: fs),
                  decoration: const InputDecoration(border: InputBorder.none, contentPadding: EdgeInsets.all(10)),
                ),
        ),
      );
}

// ---------------------------------------------------------------- HTML viewer (tiny local web server so relative CSS/JS/images work)
const mimes = {
      '.html': 'text/html; charset=utf-8', '.htm': 'text/html; charset=utf-8', '.css': 'text/css; charset=utf-8',
      '.js': 'application/javascript; charset=utf-8', '.json': 'application/json; charset=utf-8',
      '.png': 'image/png', '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.gif': 'image/gif', '.webp': 'image/webp',
      '.svg': 'image/svg+xml', '.ico': 'image/x-icon', '.woff': 'font/woff', '.woff2': 'font/woff2', '.ttf': 'font/ttf',
      '.mp4': 'video/mp4', '.webm': 'video/webm', '.mp3': 'audio/mpeg', '.txt': 'text/plain; charset=utf-8',
    };
String mime(String ext) => mimes[ext.toLowerCase()] ?? 'application/octet-stream';

Future<void> serve(HttpRequest r, String root) async {
  try {
    final rel = Uri.decodeComponent(r.uri.path);
    var full = p.normalize(p.join(root, rel.startsWith('/') ? rel.substring(1) : rel));
    if (!(full == root || p.isWithin(root, full))) { r.response.statusCode = 403; await r.response.close(); return; }
    if (FileSystemEntity.isDirectorySync(full)) full = p.join(full, 'index.html');
    final f = File(full);
    if (!await f.exists()) { r.response.statusCode = 404; await r.response.close(); return; }
    r.response.headers.contentType = ContentType.parse(mime(p.extension(full)));
    r.response.headers.set('Access-Control-Allow-Origin', '*');
    r.response.contentLength = await f.length();
    await r.response.addStream(f.openRead());
    await r.response.close();
  } catch (_) {
    try { r.response.statusCode = 500; await r.response.close(); } catch (_) {}
  }
}

class HtmlViewer extends StatefulWidget {
  final String path;
  const HtmlViewer({super.key, required this.path});
  @override
  State<HtmlViewer> createState() => _HtmlViewerState();
}

class _HtmlViewerState extends State<HtmlViewer> {
  HttpServer? srv;
  WebViewController? wc;
  String? err;

  @override
  void initState() { super.initState(); boot(); }

  Future<void> boot() async {
    try {
      final root = p.dirname(widget.path);
      final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      srv = s;
      s.listen((r) => serve(r, root));
      final url = Uri.parse('http://127.0.0.1:${s.port}/${Uri.encodeComponent(p.basename(widget.path))}');
      wc = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setBackgroundColor(Colors.white)
        ..loadRequest(url);
      if (mounted) setState(() {});
    } catch (e) { if (mounted) setState(() => err = '$e'); }
  }

  @override
  void dispose() { srv?.close(force: true); super.dispose(); }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: Text(p.basename(widget.path), style: const TextStyle(fontSize: 15)),
          actions: [
            IconButton(icon: const Icon(Icons.arrow_back), onPressed: () => wc?.goBack()),
            IconButton(icon: const Icon(Icons.refresh), onPressed: () => wc?.reload()),
            IconButton(
              icon: const Icon(Icons.edit),
              onPressed: () async {
                await Navigator.push(context, MaterialPageRoute(builder: (_) => Editor(path: widget.path)));
                wc?.reload();
              },
            ),
          ],
        ),
        body: err != null
            ? Center(child: Text(err!))
            : wc == null ? const Center(child: CircularProgressIndicator()) : WebViewWidget(controller: wc!),
      );
}
