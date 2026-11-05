import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import '../../data/models/web_dav_file.dart';
import '../../data/remote/webdav_xml_parser.dart';

/// 仅属于当前扫描任务，关闭前等待所有解析响应。
class FilmScanParserPool {
  final _workers = <Future<_ParserWorker>>[];
  final _loads = <int>[];
  final int maximum = math.max(1, Platform.numberOfProcessors - 1);

  Future<List<WebDavFile>> parse(String xml, String url) async {
    var index = _loads.indexOf(0);
    if (index < 0 && _workers.length < maximum) {
      index = _workers.length;
      _workers.add(_ParserWorker.open());
      _loads.add(0);
    }
    if (index < 0) index = _loads.indexOf(_loads.reduce(math.min));
    _loads[index]++;
    try {
      return await (await _workers[index]).parse(xml, url);
    } finally {
      _loads[index]--;
    }
  }

  Future<void> close() async {
    await Future.wait(_workers.map((worker) async => (await worker).close()));
    _workers.clear();
    _loads.clear();
  }
}

class _ParserWorker {
  _ParserWorker(this.events);
  final ReceivePort events;
  final ready = Completer<SendPort>();
  final exited = Completer<void>();
  final pending = <int, Completer<List<WebDavFile>>>{};
  late final Isolate isolate;
  late final StreamSubscription<dynamic> subscription;
  int sequence = 0;
  bool closing = false;

  static Future<_ParserWorker> open() async {
    final worker = _ParserWorker(ReceivePort());
    worker.subscription = worker.events.listen(worker.receive);
    try {
      worker.isolate = await Isolate.spawn(
        _parseMain,
        worker.events.sendPort,
        onError: worker.events.sendPort,
        onExit: worker.events.sendPort,
      );
      await worker.ready.future;
      return worker;
    } catch (_) {
      await worker.subscription.cancel();
      worker.events.close();
      rethrow;
    }
  }

  void receive(dynamic message) {
    if (message is SendPort) {
      ready.complete(message);
    } else if (message is List && message.length == 4) {
      final result = pending.remove(message[0] as int)!;
      if (message[2] != null) {
        result.completeError(
          message[2] as Object,
          StackTrace.fromString(message[3] as String),
        );
      } else {
        result.complete((message[1] as List).cast<WebDavFile>());
      }
    } else {
      final error = StateError('Catalog parser worker exited unexpectedly');
      if (!ready.isCompleted) ready.completeError(error);
      for (final result in pending.values) {
        result.completeError(error);
      }
      pending.clear();
      if (message == null && !exited.isCompleted) exited.complete();
    }
  }

  Future<List<WebDavFile>> parse(String xml, String url) async {
    final port = await ready.future;
    if (exited.isCompleted || closing) {
      throw StateError('Catalog parser worker is closed');
    }
    final id = sequence++;
    final result = Completer<List<WebDavFile>>();
    pending[id] = result;
    port.send([id, xml, url]);
    return result.future;
  }

  Future<void> close() async {
    closing = true;
    if (!exited.isCompleted) (await ready.future).send(null);
    await exited.future;
    await subscription.cancel();
    events.close();
  }
}

void _parseMain(SendPort host) {
  final commands = ReceivePort();
  host.send(commands.sendPort);
  commands.listen((dynamic message) {
    if (message == null) {
      commands.close();
      return;
    }
    final job = message as List;
    try {
      final result = const WebDavXmlParser().parse(
        job[1] as String,
        requestUrl: job[2] as String,
      );
      host.send([job[0], result, null, null]);
    } catch (error, stack) {
      host.send([job[0], null, error, stack.toString()]);
    }
  });
}
