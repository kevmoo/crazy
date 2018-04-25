import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/visitor.dart';
import 'package:analyzer/src/dart/element/element.dart';
import 'package:analyzer/src/dart/resolver/scope.dart' show NamespaceBuilder;

import 'package:source_span/source_span.dart';

/// The kind of reference in a [SearchResult].
enum SearchResultKind { READ, READ_WRITE, WRITE, INVOCATION, REFERENCE }

/// A visitor that finds the deep-most [Element] that contains the [offset].
class _ContainingElementFinder extends GeneralizingElementVisitor {
  final int offset;
  Element containingElement;

  _ContainingElementFinder(this.offset);

  visitElement(Element element) {
    if (element is ElementImpl) {
      if (element.codeOffset != null &&
          element.codeOffset <= offset &&
          offset <= element.codeOffset + element.codeLength) {
        containingElement = element;
        super.visitElement(element);
      }
    }
  }
}

Element _getEnclosingElement(CompilationUnitElement unitElement, int offset) {
  var finder = new _ContainingElementFinder(offset);
  unitElement.accept(finder);
  return finder.containingElement;
}

/// A single search result.
class SearchResult {
  /// The deep most element that contains this result.
  final Element enclosingElement;

  /// Defines the URI where this referenced item is defined.
  final Uri sourceUri;

  /// The kind of the [enclosingElement] usage.
  final SearchResultKind kind;

  /// Is `true` if a field or a method is using with a qualifier.
  final bool isResolved;

  final SourceSpan span;

  SearchResult._(this.enclosingElement, this.kind, int offset, int length,
      this.isResolved, this.sourceUri)
      : span = new SourceFile.fromString(enclosingElement.source.contents.data,
                url: enclosingElement.source.uri)
            .span(offset, offset + length) {
    if (!isResolved) {
      throw new UnsupportedError('must be resolved!');
    }
  }

  @override
  String toString() {
    var buffer = new StringBuffer();
    buffer.write("SearchResult(kind=");
    buffer.write(kind);
    buffer.write(", enclosingElement=");
    buffer.write(enclosingElement);
    buffer.write(", offset=");
    buffer.write(span.start);
    buffer.write(", length=");
    buffer.write(span.length);
    buffer.write(", isResolved=");
    buffer.write(isResolved);
    buffer.write(")");
    return buffer.toString();
  }
}

/// Visitor that adds [SearchResult]s for references to the [_importElement].
class ImportElementReferencesVisitor extends RecursiveAstVisitor {
  final List<SearchResult> results = <SearchResult>[];

  final ImportElement _importElement;
  final CompilationUnitElement _enclosingUnitElement;

  Set<Element> importedElements;

  ImportElementReferencesVisitor(
      ImportElement element, this._enclosingUnitElement)
      : _importElement = element {
    importedElements = new NamespaceBuilder()
        .createImportNamespaceForDirective(element)
        .definedNames
        .values
        .toSet();
  }

  @override
  visitExportDirective(ExportDirective node) {}

  @override
  visitImportDirective(ImportDirective node) {}

  @override
  visitSimpleIdentifier(SimpleIdentifier node) {
    if (node.inDeclarationContext()) {
      return;
    }
    if (_importElement.prefix != null) {
      if (node.staticElement == _importElement.prefix) {
        var parent = node.parent;
        if (parent is PrefixedIdentifier && parent.prefix == node) {
          if (importedElements.contains(parent.staticElement)) {
            _addResultForPrefix(node, parent.identifier, parent.staticElement);
            return;
          }
        }
        if (parent is MethodInvocation && parent.target == node) {
          if (importedElements.contains(parent.methodName.staticElement)) {
            _addResultForPrefix(
                node, parent.methodName, parent.methodName.staticElement);
            return;
          }
        }
      }
    } else {
      if (importedElements.contains(node.staticElement)) {
        _addResult(node.offset, node.length, node.staticElement);
        return;
      }
    }
  }

  void _addResult(int offset, int length, Element staticElement) {
    var enclosingElement = _getEnclosingElement(_enclosingUnitElement, offset);

    results.add(new SearchResult._(enclosingElement, SearchResultKind.REFERENCE,
        offset, length, true, staticElement.source.uri));
  }

  void _addResultForPrefix(
      SimpleIdentifier prefixNode, AstNode nextNode, Element staticElement) {
    _addResult(nextNode.offset, nextNode.length, staticElement);
  }
}
