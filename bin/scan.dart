import 'dart:io' as io;

import 'package:crazy/src/library_scanner.dart';
import 'package:crazy/src/sdk_env.dart';

import 'package:gviz/gviz.dart';

import 'package:path/path.dart' as p;

main(List<String> args) async {
  var pubEnv = new PubEnvironment();

  var scanner = new LibraryScanner(pubEnv, args.single, false);

  var result = await scanner.scanDependencyGraph((ie, uri) {
    return uri.toString().startsWith('package:source_span');
  });

  print(result.length);

  var graph = new Graph();

  for (var entry in result.entries) {
    var lib = entry.key;
    var references = entry.value;

    for (var thing in references.references) {
      graph.addEdge(lib, thing);
    }

    if (references.details.isNotEmpty) {
      references.details.forEach((k, usages) {
        var allUsages = usages.map((u) => u.content).toSet();

        for (var usage in allUsages) {
          graph.addEdge(lib, usage);
        }
      });
    }
  }

  var things = graph.flagConnectedComponents();
  io.stderr.writeln(things.length);

  print(graph.createGviz(graphStyle: new ScanStyle()));
}

class ScanStyle extends GraphStyle {
  @override
  Map<String, String> styleForNode(Object node) {
    var map = super.styleForNode(node);

    if (node is String) {
      try {
        var uri = Uri.parse(node);
        if (uri.scheme == 'package') {
          map['label'] =
              "${uri.pathSegments.first}\n${p.joinAll(uri.pathSegments.skip(1))}";
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
