import 'dart:convert';
import 'dart:io' as io;

import 'package:crazy/src/library_scanner.dart';
import 'package:crazy/src/sdk_env.dart';

import 'package:gviz/gviz.dart';

import 'package:path/path.dart' as p;

bool _cool(String thing) {
  var uri = Uri.parse(thing);

  if (uri.isScheme('package') &&
      (const ['build'].any((pkg) => uri.pathSegments.first.startsWith(pkg)))) {
    return true;
  }
  //io.stderr.writeln([false, thing]);
  return false;
}

main(List<String> args) async {
  var pubEnv = new PubEnvironment();

  var scanner = new LibraryScanner(pubEnv, args.single, false);

  var result = await scanner.scanDependencyGraph((uri) {
    return uri.scheme == 'package' &&
        uri.pathSegments.first == scanner.packageName;
  });

  io.stderr.writeln(result.length);

  var allThings = <String, Map<String, int>>{};

  var graph = new Graph();

  for (var entry in result.entries) {
    var lib = entry.key;
    var references = entry.value;

    for (var thing in references.references) {
      if (_cool(thing)) {
        graph.addEdge(lib, thing);
      }
    }

    for (var u in references.details.values.expand((u) => u)) {
      var childMap =
          allThings.putIfAbsent(u.source.toString(), () => <String, int>{});

      childMap[u.content] = (childMap[u.content] ?? 0) + 1;
    }
  }

  //var things = graph.flagConnectedComponents();
  //io.stderr.writeln(things.length);

  //print(const JsonEncoder.withIndent(' ').convert(allThings));
  //print(graph.createGviz(graphStyle: new ScanStyle()));

  var unused = <String, List<String>>{};

  for (var entry in scanner.foundMembers.entries) {
    var usedMap = allThings[entry.key];

    if (usedMap == null) {
      unused[entry.key] = null;
      continue;
    }

    var unusedMembers = entry.value.toList()
      ..removeWhere(usedMap.keys.contains)
      ..sort();

    if (unusedMembers.isNotEmpty) {
      unused[entry.key] = unusedMembers;
    }
  }

  print(const JsonEncoder.withIndent(' ').convert(unused));
}

class ScanStyle extends GraphStyle {
  @override
  Map<String, String> styleForEdge(Edge edge) {
    var style = <String, String>{};
    if (edge.flags.isNotEmpty) {
      //io.stderr.writeln([edge.from, edge.to, edge.flags]);
      style['color'] = 'green';
    }

    return style;
  }

  @override
  Map<String, String> styleForNode(Object node) {
    var map = super.styleForNode(node);

    if (node is String) {
      try {
        var uri = Uri.parse(node);
        if (uri.scheme == 'package') {
          map['label'] =
              "pkg:${uri.pathSegments.first}\n${p.joinAll(uri.pathSegments.skip(1))}";
        } else if (!uri.hasScheme) {
          // Then this should be a member of `dart:io`
          map['shape'] = 'polygon';
          map['color'] = 'red';
        }
      } catch (_) {
        io.stderr.writeln('Or $node');
        // nevermind
      }
    }

    return map;
  }
}
