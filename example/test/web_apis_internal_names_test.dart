// Static checks on how Web API modules share private helpers through
// `internal` (conventions documented at the top of lib/web/src/js_core.dart).
//
// A module may only read names exported by core or by a module it declares in
// `requires` / `optional`, and names from an optional module only behind
// `has('<module>')`. This keeps the Dart-side dependency declaration and the
// JS-side use of `internal` from drifting apart.
import 'package:flutter_qjs_next/flutter_qjs.dart';
import 'package:flutter_test/flutter_test.dart';

/// Core defaults that the owning module replaces with the real brand check.
const _coreOverrides = {
  'isAbortSignal': 'events',
  'isBlob': 'blob',
  'isFormData': 'blob',
};

final _all = [...JsWebModule.standard, JsWebModule.fetch];

final _destructure = RegExp(r'const\s*\{([^}]*)\}\s*=\s*internal\s*;');
final _assign = RegExp(r'Object\.assign\(\s*internal\s*,\s*\{([^}]*)\}\s*\)');

List<String> _names(String list) => [
      for (final entry in list.split(','))
        if (entry.trim().isNotEmpty) entry.split(':').first.trim(),
    ];

List<String> _reads(JsWebModule module) =>
    [for (final m in _destructure.allMatches(module.source)) ..._names(m[1]!)];

List<String> _exports(JsWebModule module) =>
    [for (final m in _assign.allMatches(module.source)) ..._names(m[1]!)];

void main() {
  final exports = {for (final m in _all) m.name: _exports(m)};

  test('internal is read once, by destructuring, and written by assign', () {
    for (final module in _all) {
      final source = module.source;
      final reads = _destructure.allMatches(source).length;
      expect(
        reads,
        module.name == 'core' ? 0 : 1,
        reason: '${module.name}: one leading `const {...} = internal;`',
      );
      expect(
        _assign.allMatches(source).length,
        lessThanOrEqualTo(1),
        reason: '${module.name}: one Object.assign(internal, ...)',
      );
      final stray = RegExp(r'\binternal\s*[.\[]').allMatches(source);
      expect(
        stray,
        isEmpty,
        reason: '${module.name}: direct internal.X access; add the name to the '
            'destructuring instead',
      );
    }
  });

  test('every name a module reads comes from a declared dependency', () {
    for (final module in _all.where((m) => m.name != 'core')) {
      final hard = {
        'core',
        for (final d in module.requires) d.name,
      };
      final optional = {for (final d in module.optional) d.name};
      for (final name in _reads(module)) {
        final providers = [
          for (final entry in exports.entries)
            if (entry.value.contains(name)) entry.key,
        ];
        expect(
          providers,
          isNotEmpty,
          reason: '${module.name} reads `$name`, which no module exports',
        );
        final fromHard = providers.any(hard.contains);
        final fromOptional = providers.where(optional.contains).toList();
        expect(
          fromHard || fromOptional.isNotEmpty,
          isTrue,
          reason: '${module.name} reads `$name` from ${providers.join('/')}, '
              'which it does not declare in requires or optional',
        );
        if (!fromHard) {
          for (final dependency in fromOptional) {
            expect(
              module.source.contains("has('$dependency')"),
              isTrue,
              reason: '${module.name} reads `$name` from optional $dependency '
                  "without checking has('$dependency')",
            );
          }
        }
      }
    }
  });

  test('every optional dependency is actually checked', () {
    for (final module in _all) {
      for (final dependency in module.optional) {
        expect(
          module.source.contains("has('${dependency.name}')"),
          isTrue,
          reason:
              '${module.name} lists ${dependency.name} as optional but never '
              "checks has('${dependency.name}')",
        );
      }
    }
  });

  test('a name is exported by one module, except core defaults', () {
    final owners = <String, List<String>>{};
    exports.forEach((module, names) {
      for (final name in names) {
        (owners[name] ??= []).add(module);
      }
    });
    owners.forEach((name, modules) {
      if (modules.length == 1) return;
      final owner = _coreOverrides[name];
      expect(
        owner != null &&
            modules.length == 2 &&
            modules.contains('core') &&
            modules.contains(owner),
        isTrue,
        reason: '`$name` is exported by ${modules.join(', ')}',
      );
    });
    _coreOverrides.forEach((name, owner) {
      expect(exports['core'], contains(name));
      expect(exports[owner], contains(name),
          reason: '$owner must replace $name');
    });
  });
}
