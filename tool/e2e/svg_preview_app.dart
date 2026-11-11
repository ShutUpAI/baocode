// Run as a desktop app, not with flutter test. See svg_preview.md.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:baocode/ide/ide_tab_bar.dart';
import 'package:baocode/ide/ide_workbench.dart';
import 'package:baocode/ide/markdown/markdown_preview.dart';
import 'package:baocode/main.dart' show BaoCodeApp;
import 'package:baocode/platform/data_dir.dart';
import 'package:baocode/settings/app_locale.dart';
import 'package:baocode/theme/workbench_theme.dart';
import 'package:baocode/workspace/workspace.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:path/path.dart' as p;

import '../perf/perf_input.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final directory = Platform.environment['BAOCODE_E2E_OUT'];
  final fixture = Platform.environment['BAOCODE_E2E_SVG'];
  if (directory == null || fixture == null || !File(fixture).existsSync()) {
    stderr.writeln('Set BAOCODE_E2E_OUT and BAOCODE_E2E_SVG (issue_858.svg).');
    exit(2);
  }
  final out = Directory(directory)..createSync(recursive: true);
  final root = p.join(out.resolveSymbolicLinksSync(), 'project');
  Directory(root).createSync(recursive: true);
  DataDirectory.current = DataDirectory(p.join(out.path, 'data'));
  File(fixture).copySync(p.join(root, 'issue_858.svg'));
  final requests = <String>[];
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) {
    if (request.uri.path == '/probe.css' || request.uri.path == '/probe.png') {
      requests.add(request.uri.path);
    }
    request.response.statusCode = HttpStatus.notFound;
    request.response.close();
  });
  final base = 'http://127.0.0.1:${server.port}';
  File(p.join(root, 'safe.svg')).writeAsStringSync('''
<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="200" height="100" viewBox="0 0 200 100">
<style>@import url("$base/probe.css"); .blue { fill: #2563eb; } .external { fill: url("$base/probe.png"); }</style>
<rect width="200" height="100" fill="#ffffff"/>
<rect class="blue" x="20" y="20" width="160" height="60"/>
<rect class="external" x="0" y="0" width="1" height="1"/>
</svg>
''');
  for (final name in ['issue_858', 'safe']) {
    File(p.join(root, '$name.md')).writeAsStringSync('![$name]($name.svg)\n');
  }
  final errors = <String>[];
  final presentError = FlutterError.onError;
  FlutterError.onError = (details) {
    errors.add(details.exceptionAsString());
    presentError?.call(details);
  };
  final boundary = GlobalKey();
  final input = PerfInput();
  final results = <Map<String, Object?>>[];
  var failed = false;
  final workspace = Workspace(projects: [Project('svg-preview-e2e', root)])
    ..keepIdeView(root, {'chat': false})
    ..openIdeFolder(root)
    ..layout = WorkspaceLayout.ide;
  try {
    await () async {
      WorkbenchThemeService.instance.restore();
      await WorkbenchThemeService.instance.initialize();
      runApp(
        RepaintBoundary(
          key: boundary,
          child: BaoCodeApp(
            workspace: workspace,
            appLocale: AppLocale(
              storage: MemoryLocaleStorage(AppLocale.english),
            ),
          ),
        ),
      );
      await _until(() => _find<IdeWorkbench>() != null, 'workbench');
      await const MethodChannel('baocode/windows').invokeMethod(
        'focus',
        WidgetsBinding.instance.platformDispatcher.implicitView!.viewId,
      );
      final state =
          (_find<IdeWorkbench>()! as StatefulElement).state
              as IdeWorkbenchState;
      for (final name in ['issue_858', 'safe']) {
        await state.openFile(p.join(root, '$name.md'));
        await _until(() => _find<MarkdownSwitch>() != null, '$name switch');
        // Markdown opens in preview by default. Exercise the actual switch in
        // both directions so the tested preview is opened by pointer input.
        if ((_find<MarkdownSwitch>()!.widget as MarkdownSwitch).preview) {
          await _clickOption(input, 'Markdown');
          await _until(
            () => !(_find<MarkdownSwitch>()!.widget as MarkdownSwitch).preview,
            'source',
          );
        }
        await _clickOption(input, 'Preview');
        await _until(
          () => _find<IdeMarkdownPreview>() != null,
          '$name preview',
        );
        await _until(() => _imageElement() != null, '$name SVG');
        await _settle();
        // Allow asynchronous SVG decoding and any resulting network activity.
        await Future<void>.delayed(const Duration(seconds: 2));
        await _settle();
        final imageBox = _imageElement()!.findRenderObject()! as RenderBox;
        final origin = imageBox.localToGlobal(Offset.zero);
        final size = imageBox.size;
        final intrinsic = name == 'safe'
            ? const Size(200, 100)
            : const Size(1280, 430);
        final fitted = applyBoxFit(BoxFit.contain, intrinsic, size).destination;
        final rect = Alignment.center.inscribe(fitted, origin & size);
        _check(
          rect.width >= 100 && rect.height >= 40,
          '$name image is too small: $rect',
        );
        final pixels = await _capture(boundary, p.join(out.path, '$name.png'));
        int sample(double x, double y) => pixels.colorAt(
          rect.left + rect.width * x / intrinsic.width,
          rect.top + rect.height * y / intrinsic.height,
        );
        if (name == 'issue_858') {
          _check(_white(sample(38, 40)), 'issue 858 button is not white');
          _check(_blue(sample(1100, 38)), 'issue 858 blue button is missing');
        } else {
          _check(_blue(sample(100, 50)), 'safe blue rectangle is missing');
          _check(_white(sample(190, 90)), 'safe white background is missing');
        }
        _check(errors.isEmpty, 'Flutter errors: ${errors.join('; ')}');
        results.add({'scenario': name, 'passed': true, 'imageRect': '$rect'});
      }
      await Future<void>.delayed(const Duration(seconds: 2));
      _check(requests.isEmpty, 'Unexpected probe requests: $requests');
      _check(errors.isEmpty, 'Flutter errors: ${errors.join('; ')}');
    }().timeout(const Duration(minutes: 3));
  } catch (error, stack) {
    failed = true;
    stderr.writeln('$error\n$stack');
    results.add({'passed': false, 'error': '$error', 'stack': '$stack'});
    try {
      await _capture(boundary, p.join(out.path, 'failure.png'));
    } catch (_) {}
  } finally {
    await server.close(force: true);
    File(p.join(out.path, 'result.json')).writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert({
        'passed': !failed,
        'platform': Platform.operatingSystem,
        'project': root,
        'scenarios': results,
        'probeRequests': requests,
        'flutterErrors': errors,
      }),
    );
    stdout.writeln('BAOCODE_E2E_RESULT ${p.join(out.path, 'result.json')}');
  }
  exit(failed ? 1 : 0);
}

Element? _find<T extends Widget>({Element? root, bool Function(T)? where}) {
  Element? found;
  void visit(Element element) {
    if (found != null) return;
    if (element.widget case final T widget when where?.call(widget) ?? true) {
      found = element;
    } else {
      element.visitChildren(visit);
    }
  }

  (root ?? WidgetsBinding.instance.rootElement)?.visitChildren(visit);
  return found;
}

Element? _imageElement() {
  final preview = _find<IdeMarkdownPreview>();
  return preview == null ? null : _find<SvgPicture>(root: preview);
}

Future<void> _clickOption(PerfInput input, String label) async {
  final switchElement = _find<MarkdownSwitch>()!;
  final text = _find<Text>(
    root: switchElement,
    where: (text) => text.data == label,
  );
  _check(text != null, 'Missing $label switch option');
  final box = text!.findRenderObject()! as RenderBox;
  await input.click(box.localToGlobal(box.size.center(Offset.zero)));
}

void _check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Future<void> _until(bool Function() ready, String description) async {
  final deadline = DateTime.now().add(const Duration(seconds: 45));
  while (!ready()) {
    if (DateTime.now().isAfter(deadline)) throw TimeoutException(description);
    WidgetsBinding.instance.scheduleFrame();
    await Future<void>.delayed(const Duration(milliseconds: 30));
  }
}

Future<void> _settle() async {
  for (var i = 0; i < 10; i++) {
    WidgetsBinding.instance.scheduleFrame();
    await WidgetsBinding.instance.endOfFrame;
    await Future<void>.delayed(const Duration(milliseconds: 30));
  }
}

bool _white(int color) =>
    (color >> 16 & 255) > 240 &&
    (color >> 8 & 255) > 240 &&
    (color & 255) > 240;
bool _blue(int color) =>
    (color >> 16 & 255) < 80 &&
    (color >> 8 & 255) > 70 &&
    (color >> 8 & 255) < 140 &&
    (color & 255) > 200;

class _Pixels {
  _Pixels(this.bytes, this.width, this.height);
  final ByteData bytes;
  final int width;
  final int height;
  int colorAt(double x, double y) {
    final px = x.floor(), py = y.floor();
    _check(
      px >= 0 && px < width && py >= 0 && py < height,
      'Pixel outside screenshot: $x, $y',
    );
    final index = (py * width + px) * 4;
    return bytes.getUint8(index) << 16 |
        bytes.getUint8(index + 1) << 8 |
        bytes.getUint8(index + 2);
  }
}

Future<_Pixels> _capture(GlobalKey key, String path) async {
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final image = await boundary.toImage(pixelRatio: 1);
  try {
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    final raw = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (png == null || raw == null) throw StateError('No screenshot bytes');
    File(path).writeAsBytesSync(png.buffer.asUint8List());
    return _Pixels(raw, image.width, image.height);
  } finally {
    image.dispose();
  }
}
