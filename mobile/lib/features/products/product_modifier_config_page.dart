import 'package:flutter/material.dart';
import '../../core/localization/l10n.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/formatters.dart';
import '../../core/widgets/glass/glass_card.dart';
import '../../core/widgets/glass/glass_app_bar.dart';
import '../../core/widgets/app_background.dart';
import '../../data/models/modifier_group.dart';
import '../../data/models/modifier_option.dart';
import '../../data/models/product_modifier_config.dart';
import '../../data/models/enums.dart';

/// A local draft: leaving this page never writes to the product or DB.
class ProductModifierConfigPage extends StatefulWidget {
  const ProductModifierConfigPage({
    super.key,
    required this.initial,
    required this.groups,
    required this.options,
  });
  final ProductModifierConfig initial;
  final List<ModifierGroup> groups;
  final Map<String, List<ModifierOption>> options;

  @override
  State<ProductModifierConfigPage> createState() => _ConfigState();
}

class _ConfigState extends State<ProductModifierConfigPage> {
  late final _groups = {...widget.initial.groupIds};
  late final _options = {...widget.initial.optionIds};
  late final _defaults = {...widget.initial.defaultOptionIds};
  String _query = '';

  @override
  void initState() {
    super.initState();
    // A catalogue edit can deactivate an option or reduce the selection cap.
    final valid = <String>{};
    for (final group in widget.groups) {
      valid.addAll(
        resolveModifierSelection(
          group,
          (widget.options[group.id] ?? [])
              .where((o) => _options.contains(o.id))
              .toList(),
          _defaults,
        ).map((o) => o.id),
      );
    }
    _defaults.retainAll(valid);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AppBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: GlassAppBar(title: l10n.modifierConfigure),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(l10n.modifierDefaultsHint),
                const SizedBox(height: 12),
                TextField(
                  decoration: InputDecoration(
                    prefixIcon: const Icon(Icons.search),
                    hintText: l10n.modifierSearchGroups,
                  ),
                  onChanged: (v) => setState(() => _query = v.toLowerCase()),
                ),
                Expanded(
                  child: ListView(
                    children: [
                      for (final g in widget.groups.where(
                        (g) => g.name.toLowerCase().contains(_query),
                      ))
                        _group(context, g),
                    ],
                  ),
                ),
                Row(
                  children: [
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: Text(l10n.commonCancel),
                    ),
                    const SizedBox(width: 16),
                    // The app button theme has a full-width minimum size.
                    // A non-flex child of Row receives infinite width.
                    Expanded(
                      child: FilledButton(
                        onPressed: () => Navigator.of(context).pop(
                          ProductModifierConfig(
                            groupIds: _groups,
                            optionIds: _options,
                            defaultOptionIds: _defaults,
                          ),
                        ),
                        child: Text(l10n.commonSave),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _group(BuildContext context, ModifierGroup g) {
    final l10n = context.l10n;
    final options = widget.options[g.id] ?? const <ModifierOption>[];
    final ids = options.map((o) => o.id).toSet();
    final attached = _groups.contains(g.id);
    final count = ids.intersection(_options).length;
    final defaults = ids.intersection(_defaults).length;
    final limit = g.selectionType == ModifierSelectionType.single
        ? 1
        : g.maxSelect;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: GlassCard.solid(
        child: ExpansionTile(
          key: ValueKey(g.id),
          title: Text(g.name),
          subtitle: Text(
            '${l10n.modifierConfigSummary(count, defaults)} · '
            '${g.required ? l10n.modifierPickRequiredBadge : l10n.modifierPickOptionalBadge}'
            '${limit == null ? '' : ' · ${l10n.modifierPickMaxBadge(limit)}'}',
          ),
          leading: Checkbox(
            value: attached,
            onChanged: g.active || attached
                ? (value) => setState(() {
                    if (value == true) {
                      _groups.add(g.id);
                      _options.addAll(
                        options.where((o) => o.active).map((o) => o.id),
                      );
                    } else {
                      _groups.remove(g.id);
                      _options.removeAll(ids);
                      _defaults.removeAll(ids);
                    }
                  })
                : null,
          ),
          children: attached
              ? [
                  if (!g.active) Text(l10n.productUnavailable),
                  if (options
                      .where((o) => o.active && _options.contains(o.id))
                      .isEmpty)
                    Text(
                      l10n.modifierOptionScopeEmpty,
                      style: TextStyle(color: context.design.warning),
                    ),
                  for (final o in options)
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(o.name),
                      subtitle: Text(
                        o.active
                            ? '+${MoneyFormatter.format(o.priceDelta)}'
                            : l10n.productUnavailable,
                      ),
                      value: _options.contains(o.id),
                      onChanged: (v) => setState(() {
                        if (v == true) {
                          _options.add(o.id);
                        } else {
                          _options.remove(o.id);
                          _defaults.remove(o.id);
                        }
                      }),
                      secondary: IconButton(
                        tooltip: l10n.modifierDefaultOption,
                        icon: Icon(
                          _defaults.contains(o.id)
                              ? Icons.star
                              : Icons.star_border,
                        ),
                        color: _defaults.contains(o.id)
                            ? context.design.primary
                            : context.design.textMedium,
                        onPressed:
                            !_options.contains(o.id) || !o.active || !g.active
                            ? null
                            : () => setState(() {
                                if (_defaults.remove(o.id)) return;
                                if (g.selectionType ==
                                    ModifierSelectionType.single) {
                                  _defaults.removeAll(ids);
                                } else if (limit != null && defaults >= limit) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(
                                        l10n.modifierPickMaxBadge(limit),
                                      ),
                                    ),
                                  );
                                  return;
                                }
                                _defaults.add(o.id);
                              }),
                      ),
                    ),
                ]
              : const [],
        ),
      ),
    );
  }
}
