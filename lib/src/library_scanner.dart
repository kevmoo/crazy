// Copyright (c) 2017, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/file_system/file_system.dart' hide File;
import 'package:analyzer/file_system/physical_file_system.dart';
import 'package:analyzer/source/package_map_resolver.dart';
import 'package:analyzer/source/pub_package_map_provider.dart';
import 'package:analyzer/src/dart/sdk/sdk.dart' show FolderBasedDartSdk;
import 'package:analyzer/src/generated/engine.dart';
import 'package:analyzer/src/generated/java_io.dart';
import 'package:analyzer/src/generated/source.dart';
import 'package:analyzer/src/generated/source_io.dart';
import 'package:path/path.dart' as p;

import 'package:source_span/source_span.dart';

import 'import_element_references_visitor.dart';
import 'sdk_env.dart';
import 'utils.dart';

typedef ImportPredicate = bool Function(
    ImportElement element, Uri normalizedUri);

class LibraryScanner {
  final String packageName;
  final String _packagePath;
  final UriResolver _packageResolver;
  final AnalysisContext _context;
  final Map<String, String> _dependencyUris;
  final _cachedLibs = new HashMap<String, LibraryReferences>();

  LibraryScanner._(this.packageName, this._packagePath, this._packageResolver,
      this._context, this._dependencyUris);

  factory LibraryScanner(
      PubEnvironment pubEnv, String packagePath, bool useFlutter) {
    // TODO: fail more clearly if this...fails
    var sdkPath = pubEnv.dartSdk.sdkDir;

    var resourceProvider = PhysicalResourceProvider.INSTANCE;
    var sdk = new FolderBasedDartSdk(
        resourceProvider, resourceProvider.getFolder(sdkPath));

    var dotPackagesPath = p.join(packagePath, '.packages');
    if (!FileSystemEntity.isFileSync(dotPackagesPath)) {
      throw new StateError('A package configuration file was not found at the '
          'expectetd location.\n$dotPackagesPath');
    }

    // TODO: figure out why non-flutter pub list doesn't work the same way as the default
    RunPubList runPubList;
    if (useFlutter) {
      runPubList = (Folder folder) =>
          pubEnv.listPackageDirsSync(folder.path, useFlutter);
    }

    var pubPackageMapProvider = new PubPackageMapProvider(
        PhysicalResourceProvider.INSTANCE, sdk, runPubList);
    var packageMapInfo = pubPackageMapProvider.computePackageMap(
        PhysicalResourceProvider.INSTANCE.getResource(packagePath) as Folder);

    var packageMap = packageMapInfo.packageMap;
    if (packageMap == null) {
      throw new StateError('An error occurred getting the package map '
          'for the file at `$dotPackagesPath`.');
    }

    var dependencyUris = <String, String>{};
    var packageNames = <String>[];
    packageMap.forEach((k, v) {
      if (v.any((f) => p.isWithin(packagePath, f.path))) {
        packageNames.add(k);
      }

      dependencyUris[k] = v.single.path;
    });

    String package;
    if (packageNames.length == 1) {
      package = packageNames.single;
    } else {
      throw new StateError(
          "Could not determine package name for package at $packagePath");
    }

    UriResolver packageResolver = new PackageMapUriResolver(
        PhysicalResourceProvider.INSTANCE, packageMap);

    var resolvers = [
      new DartUriResolver(sdk),
      new ResourceUriResolver(PhysicalResourceProvider.INSTANCE),
      packageResolver,
    ];

    AnalysisEngine.instance.processRequiredPlugins();

    var context = AnalysisEngine.instance.createAnalysisContext()
      ..sourceFactory = new SourceFactory(resolvers);

    return new LibraryScanner._(
        package, packagePath, packageResolver, context, dependencyUris);
  }

  Future<Map<String, List<String>>> scanTransitiveLibs(
      ImportPredicate predicate) async {
    var results = new SplayTreeMap<String, List<String>>();
    var direct = await _scanPackage(predicate);
    for (var key in direct.keys) {
      var processed = new Set<String>();
      var todo = new Set<String>.from(direct[key].references);
      while (todo.isNotEmpty) {
        var lib = todo.first;
        todo.remove(lib);
        if (processed.contains(lib)) continue;
        processed.add(lib);
        if (lib.startsWith('dart:')) {
          // nothing to do
        } else if (_cachedLibs.containsKey(lib)) {
          todo.addAll(_cachedLibs[lib].references);
        } else if (lib.startsWith('package:')) {
          todo.addAll(await _scanUri(lib, predicate));
        }
      }

      results[key] = processed.toList()..sort();
    }
    return results;
  }

  /// [AnalysisEngine] caches analyzed fragments, and we need to clear those
  /// after we have analyzed a package.
  void clearCaches() {
    AnalysisEngine.instance.clearCaches();
  }

  Future<Map<String, LibraryReferences>> scanDependencyGraph(
      ImportPredicate predicate) async {
    var items = await scanTransitiveLibs(predicate);

    var graph = new SplayTreeMap<String, LibraryReferences>();

    var todo = new LinkedHashSet<String>.from(items.keys);
    while (todo.isNotEmpty) {
      var first = todo.first;
      todo.remove(first);

      if (first.startsWith('dart:')) {
        continue;
      }

      graph.putIfAbsent(first, () {
        var cache = _cachedLibs[first];
        todo.addAll(cache.references);
        return cache;
      });
    }

    return graph;
  }

  Future<List<String>> _scanUri(
      String libUri, ImportPredicate predicate) async {
    var uri = Uri.parse(libUri);
    var package = uri.pathSegments.first;

    var source = _packageResolver.resolveAbsolute(uri);
    if (source == null) {
      throw "Could not resolve package URI for $uri";
    }

    var fullPath = source.fullName;
    var relativePath = p.join('lib', libUri.substring(libUri.indexOf('/') + 1));
    if (fullPath.endsWith('/$relativePath')) {
      var packageDir =
          fullPath.substring(0, fullPath.length - relativePath.length - 1);
      var libs = _parseLibs(package, packageDir, relativePath, predicate);
      _cachedLibs[libUri] = libs;
      return libs.references;
    } else {
      return [];
    }
  }

  Future<Map<String, LibraryReferences>> _scanPackage(
      ImportPredicate predicate) async {
    var results = new SplayTreeMap<String, LibraryReferences>();
    var dartFiles = await listFiles(_packagePath, endsWith: '.dart');
    var mainFiles = dartFiles.where((path) {
      if (p.isWithin('bin', path)) {
        return true;
      }

      // Include all Dart files in lib – except for implementation files.
      if (p.isWithin('lib', path) && !p.isWithin('lib/src', path)) {
        return true;
      }

      return false;
    }).toList();
    for (var relativePath in mainFiles) {
      var uri = toPackageUri(packageName, relativePath);
      results[uri] = _cachedLibs.putIfAbsent(uri,
          () => _parseLibs(packageName, _packagePath, relativePath, predicate));
    }
    return results;
  }

  LibraryReferences _parseLibs(String package, String packageDir,
      String relativePath, ImportPredicate predicate) {
    var fullPath = p.join(packageDir, relativePath);
    var lib = _getLibraryElement(fullPath);
    if (lib == null) return LibraryReferences.empty;
    var refs = new SplayTreeSet<String>();

    lib.importedLibraries.forEach((le) {
      refs.add(_normalizeLibRef(le.librarySource.uri, package, packageDir));
    });
    lib.exportedLibraries.forEach((le) {
      refs.add(_normalizeLibRef(le.librarySource.uri, package, packageDir));
    });
    refs.remove('dart:core');

    var details = <String, List<Usage>>{};
    var items = searchLib(lib, predicate);
    items.forEach((k, v) {
      var usages = details[k.uri] = <Usage>[];

      for (var result in v) {
        stderr.writeln([
          result.enclosingElement.runtimeType.toString().padRight(30),
          result.enclosingElement
        ].join('\t'));
        usages.add(new Usage.fromSpan(result.span));
      }
    });

    return new LibraryReferences(new List<String>.unmodifiable(refs), details);
  }

  LibraryElement _getLibraryElement(String path) {
    Source source = new FileBasedSource(new JavaFile(path));
    if (_context.computeKindOf(source) == SourceKind.LIBRARY) {
      return _context.computeLibraryElement(source);
    }
    return null;
  }

  Uri _coolThing(ImportElement ie) {
    var uri = ie.importedLibrary.source.uri;

    if (uri.isScheme('file')) {
      var filePath = p.fromUri(uri);

      for (var entry in _dependencyUris.entries) {
        if (p.isWithin(entry.value, filePath)) {
          uri = new Uri(
              scheme: 'package',
              host: entry.key,
              path: p.relative(filePath, from: entry.value));
          break;
        }
      }
    }

    if (!(uri.isScheme('dart') || uri.isScheme('package'))) {
      throw new UnsupportedError(
          'Should only ever get package: and dart: uris here: $uri');
    }

    return uri;
  }

  Map<ImportElement, List<SearchResult>> searchLib(
      LibraryElement lib, ImportPredicate predicate) {
    var results = <ImportElement, List<SearchResult>>{};

    for (var importElement
        in lib.imports.where((ie) => predicate(ie, _coolThing(ie)))) {
      var items = results[importElement] = <SearchResult>[];

      var compUnit = _context.resolveCompilationUnit(lib.source, lib);
      assert(compUnit != null);

      items
          .addAll(search(importElement, lib.definingCompilationUnit, compUnit));

      for (var part in lib.parts) {
        compUnit = _context.resolveCompilationUnit(part.source, lib);

        items.addAll(search(importElement, part, compUnit));
      }
    }

    return results;
  }

  List<SearchResult> search(
      ImportElement element,
      CompilationUnitElement enclosingUnitElement,
      CompilationUnit libCompUnit) {
    assert(enclosingUnitElement != null);

    var visitor =
        new ImportElementReferencesVisitor(element, enclosingUnitElement);

    libCompUnit.accept(visitor);

    return visitor.results;
  }
}

String _normalizeLibRef(Uri uri, String package, String packageDir) {
  if (uri.isScheme('file')) {
    var relativePath = p.relative(p.fromUri(uri), from: packageDir);
    return toPackageUri(package, relativePath);
  } else if (uri.isScheme('package') || uri.isScheme('dart')) {
    return uri.toString();
  }

  throw "not supported - $uri";
}

class LibraryReferences {
  final List<String> references;
  final Map<String, List<Usage>> details;

  static const LibraryReferences empty =
      const LibraryReferences(const [], const {});

  const LibraryReferences(this.references, this.details);
}

class Usage {
  final String content;
  final int offset, column, line;

  Usage(this.content, this.offset, this.line, this.column);

  factory Usage.fromSpan(FileSpan span) => new Usage(
      span.text, span.start.offset, span.start.line, span.start.column);

  String toString() => "$content @ $line,$column";
}
