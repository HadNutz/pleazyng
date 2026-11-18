import 'package:xml/xml.dart';

String dashSlot(int index) => 'pleazyng-dash-slot-${index}z';

final _variable = RegExp(r'\$\$|\$(RepresentationID|Bandwidth|Number|Time|SubNumber)(%0?[0-9]{0,2}[diouxX])?\$');
const _descriptors = {'SegmentTemplate', 'SegmentList', 'SegmentBase'};
const _levels = {'Period', 'AdaptationSet', 'Representation'};

/// Resolve inherited DASH addressing at each representation. Numeric template
/// substitutions remain local path components. The proxy authorizes only the
/// fixed upstream URL and those substitution positions.
String rewriteSystemDashManifest(String input, Uri manifest, String Function(Uri, List<String>) register) {
  final document = XmlDocument.parse(input);
  if (document.rootElement.localName != 'MPD' || document.doctypeElement != null) {
    throw const FormatException('Invalid DASH manifest');
  }
  void visit(XmlElement node, Uri parentBase, XmlElement? inherited) {
    final children = node.childElements.toList();
    final bases = children.where((e) => e.localName == 'BaseURL').toList();
    var base = parentBase;
    if (bases.isNotEmpty) {
      base = bases
          .map((e) => parentBase.resolve(e.innerText.trim()))
          .firstWhere(
            (uri) =>
                uri.hasAuthority && (uri.scheme == 'http' || uri.scheme == 'https') && uri.origin == manifest.origin,
            orElse: () => throw const FormatException('No same-origin DASH BaseURL'),
          );
      for (final e in bases) {
        e.remove();
      }
    }
    var descriptor = inherited;
    for (final element in children.where((e) => _descriptors.contains(e.localName))) {
      descriptor = element.copy();
      if (inherited != null && inherited.localName == element.localName) {
        for (final attribute in inherited.attributes) {
          if (descriptor.getAttribute(attribute.name.qualified) == null) descriptor.attributes.add(attribute.copy());
        }
        final ownNames = element.childElements.map((e) => e.localName).toSet();
        descriptor.children.addAll(
          inherited.childElements.where((e) => !ownNames.contains(e.localName)).map((e) => e.copy()),
        );
      }
      element.remove();
    }
    if (node.localName == 'Representation') {
      if (descriptor == null || descriptor.localName != 'SegmentTemplate') {
        final element = bases.isEmpty ? XmlElement(XmlName.parts('BaseURL', prefix: node.name.prefix)) : bases.first;
        element.innerText = register(base, const []);
        node.children.insert(0, element);
      }
      if (descriptor != null) {
        final resolved = descriptor.copy();
        for (final element in [resolved, ...resolved.descendantElements]) {
          for (final name in const ['media', 'initialization', 'index', 'sourceURL', 'bitstreamSwitching']) {
            final value = element.getAttribute(name);
            if (value == null || (name == 'bitstreamSwitching' && element.localName != 'SegmentTemplate')) continue;
            final slots = <String>[];
            if (value.contains('pleazyng-dash-slot-') || base.toString().contains('pleazyng-dash-slot-')) {
              throw const FormatException('Ambiguous DASH template');
            }
            final reference = element.localName == 'SegmentTemplate'
                ? value.replaceAllMapped(_variable, (m) {
                    if (m.group(0) == r'$$') return r'$';
                    if (m.group(1) == 'RepresentationID') {
                      final id = node.getAttribute('id');
                      if (id == null) throw const FormatException('Missing DASH representation ID');
                      return Uri.encodeComponent(id);
                    }
                    slots.add(m.group(0)!);
                    return dashSlot(slots.length - 1);
                  })
                : value;
            element.setAttribute(name, register(base.resolve(reference), slots));
          }
        }
        node.children.add(resolved);
      }
      return;
    }
    for (final child in children) {
      if (_levels.contains(child.localName)) visit(child, base, descriptor);
      if (child.localName == 'Location') child.innerText = register(manifest.resolve(child.innerText.trim()), const []);
    }
  }

  visit(document.rootElement, manifest, null);
  return document.toXmlString();
}
