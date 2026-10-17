// Unzipper: everything about zip extraction lives here so main.dart stays small.
import 'dart:io';
import 'dart:isolate';
import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;

/// The "main dir": when auto-unzip is ON and you open this folder, every .zip directly inside it
/// is extracted (once) into a folder with the same name. Change it to e.g. '/storage/emulated/0/Download'.
const autoUnzipDir = '/storage/emulated/0';

bool _scanning = false;

// Unzips zipPath into dest. Runs in a background isolate so the UI stays smooth.
// Skips any entry that tries to escape the destination folder ("zip-slip").
Future<int> extractZip(String zipPath, String dest) async {
  final input = InputFileStream(zipPath);
  try {
    final arc = ZipDecoder().decodeBuffer(input);
    await Directory(dest).create(recursive: true);
    var n = 0;
    for (final f in arc.files) {
      final target = p.normalize(p.join(dest, f.name.replaceAll('\\', '/')));
      if (!p.isWithin(dest, target)) continue;
      if (f.isFile) {
        await Directory(p.dirname(target)).create(recursive: true);
        final out = OutputFileStream(target);
        f.writeContent(out);
        await out.close();
        n++;
      } else {
        await Directory(target).create(recursive: true);
      }
    }
    return n;
  } finally {
    await input.close();
  }
}

/// Same as extractZip but off the UI thread (background isolate), so the app never freezes.
Future<int> unzipTo(String zipPath, String dest) => Isolate.run(() => extractZip(zipPath, dest));

/// Extracts every .zip in [dir] whose same-named folder does not exist yet. Returns the folders it created.
Future<List<String>> autoUnzipAll(String dir) async {
  if (_scanning) return [];
  _scanning = true;
  final made = <String>[];
  try {
    final zips = await Directory(dir)
        .list(followLinks: false)
        .where((e) => e is File && p.extension(e.path).toLowerCase() == '.zip')
        .toList();
    for (final z in zips) {
      final dest = p.join(dir, p.basenameWithoutExtension(z.path));
      if (File(dest).existsSync() || Directory(dest).existsSync()) continue; // already extracted
      try {
        await unzipTo(z.path, dest);
        made.add(dest);
      } catch (_) {
        // broken or still-downloading zip: remove the half-extracted folder so it is retried next time
        try { await Directory(dest).delete(recursive: true); } catch (_) {}
      }
    }
  } catch (_) {
  } finally {
    _scanning = false;
  }
  return made;
}
