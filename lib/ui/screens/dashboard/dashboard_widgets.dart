import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../../app/app_services.dart';
import '../../../core/models/library_models.dart';
import '../../widgets/cover_art.dart';

final NumberFormat _number = NumberFormat.decimalPattern();

/// 12345 -> "12,345" (locale aware).
String formatCount(int n) => _number.format(n);

const List<FontFeature> tabularFigures = [FontFeature.tabularFigures()];

/// 1 -> "1 song", 2 -> "2 songs".
String plural(int n, String noun) => '${formatCount(n)} $noun${n == 1 ? '' : 's'}';

/// Card-sized label + big value, used in the overview grid.
class StatTile extends StatelessWidget {
  const StatTile({super.key, required this.icon, required this.label, required this.value, this.onTap});

  final IconData icon;
  final String label;
  final String value;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Card(
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 20, color: t.colorScheme.primary),
              const SizedBox(height: 12),
              Text(value, style: t.textTheme.headlineSmall?.copyWith(fontFeatures: tabularFigures)),
              const SizedBox(height: 2),
              Text(label, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
            ],
          ),
        ),
      ),
    );
  }
}

/// A single-hue horizontal meter with its value written out (never colour alone).
class MeterBar extends StatelessWidget {
  const MeterBar({super.key, required this.value, this.height = 8, this.semanticsLabel});

  final double value; // 0..1
  final double height;
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Semantics(
      label: semanticsLabel,
      value: '${(value * 100).round()}%',
      child: ClipRRect(
        borderRadius: BorderRadius.circular(height / 2),
        child: SizedBox(
          height: height,
          // StackFit.expand: children get tight constraints, so a child-less ColoredBox is not collapsed to zero size
          child: Stack(
            fit: StackFit.expand,
            children: [
              ColoredBox(color: t.colorScheme.outlineVariant),
              FractionallySizedBox(
                widthFactor: value.clamp(0.0, 1.0),
                alignment: Alignment.centerLeft,
                child: ColoredBox(color: t.colorScheme.primary),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Ranked, directly-labelled bars (one hue - rank is position, not colour).
class RankedBars extends StatelessWidget {
  const RankedBars({super.key, required this.rows, this.onTap});

  final List<({int id, String name, int count})> rows;
  final ValueChanged<int>? onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final max = rows.fold<int>(1, (m, r) => r.count > m ? r.count : m);
    return Column(
      children: [
        for (final r in rows)
          InkWell(
            onTap: onTap == null ? null : () => onTap!(r.id),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
              child: Row(
                children: [
                  CoverArt(artistId: r.id, seed: r.name, size: 36, circle: true),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          r.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: t.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 5),
                        MeterBar(value: r.count / max, height: 6),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  SizedBox(
                    width: 44,
                    child: Text(
                      formatCount(r.count),
                      textAlign: TextAlign.end,
                      style: t.textTheme.labelLarge?.copyWith(color: t.colorScheme.onSurfaceVariant, fontFeatures: tabularFigures),
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// A row in "Needs attention": count badge, what is wrong, and where tapping goes.
class AttentionTile extends StatelessWidget {
  const AttentionTile({super.key, required this.icon, required this.title, required this.subtitle, required this.count, required this.onTap});

  final IconData icon;
  final String title;
  final String subtitle;
  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final clean = count == 0;
    return ListTile(
      enabled: !clean,
      leading: CircleAvatar(
        backgroundColor: clean ? t.colorScheme.surfaceContainerHighest : t.colorScheme.tertiaryContainer,
        foregroundColor: clean ? t.colorScheme.onSurfaceVariant : t.colorScheme.onTertiaryContainer,
        child: Icon(clean ? Icons.check : icon, size: 20),
      ),
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Text(clean ? 'All good' : subtitle),
      trailing: clean
          ? null
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(formatCount(count), style: t.textTheme.titleMedium?.copyWith(fontFeatures: tabularFigures)),
                const Icon(Icons.chevron_right),
              ],
            ),
      onTap: clean ? null : onTap,
    );
  }
}

/// Horizontally scrolling single-select filter chips.
class FilterChipsRow<T> extends StatelessWidget {
  const FilterChipsRow({super.key, required this.values, required this.selected, required this.label, required this.onSelected, this.counts});

  final List<T> values;
  final T selected;
  final String Function(T) label;
  final ValueChanged<T> onSelected;
  final Map<T, int>? counts;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 44,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: values.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final v = values[i];
          final n = counts?[v];
          return ChoiceChip(
            label: Text(n == null || v == values.first ? label(v) : '${label(v)} · ${formatCount(n)}'),
            selected: v == selected,
            showCheckmark: false,
            onSelected: (_) => onSelected(v),
          );
        },
      ),
    );
  }
}

/// Search box used at the top of the manager lists.
class ManagerSearchField extends StatelessWidget {
  const ManagerSearchField({super.key, required this.hint, required this.onChanged});

  final String hint;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: TextField(
        onChanged: onChanged,
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(hintText: hint, prefixIcon: const Icon(Icons.search), isDense: true),
      ),
    );
  }
}

/// Small pill flagging a problem on a row ("No cover", "No year"…).
class IssuePill extends StatelessWidget {
  const IssuePill(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(color: t.colorScheme.tertiaryContainer, borderRadius: BorderRadius.circular(20)),
      child: Text(
        text,
        style: t.textTheme.labelSmall?.copyWith(color: t.colorScheme.onTertiaryContainer, fontWeight: FontWeight.w700),
      ),
    );
  }
}

// ----------------------------------------------------------------------------
// pickers
// ----------------------------------------------------------------------------

Future<T?> _pickEntity<T>(
  BuildContext context, {
  required String title,
  required Future<List<T>> Function() load,
  required String Function(T) name,
  required String Function(T) sub,
  required Widget Function(T) leading,
}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    useSafeArea: true,
    builder: (c) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.8,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      builder: (context, scroll) => _EntityPicker<T>(title: title, load: load, name: name, sub: sub, leading: leading, controller: scroll),
    ),
  );
}

class _EntityPicker<T> extends StatefulWidget {
  const _EntityPicker({required this.title, required this.load, required this.name, required this.sub, required this.leading, required this.controller});

  final String title;
  final Future<List<T>> Function() load;
  final String Function(T) name;
  final String Function(T) sub;
  final Widget Function(T) leading;
  final ScrollController controller;

  @override
  State<_EntityPicker<T>> createState() => _EntityPickerState<T>();
}

class _EntityPickerState<T> extends State<_EntityPicker<T>> {
  late final Future<List<T>> _items = widget.load();
  String _q = '';

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(widget.title, style: t.textTheme.titleLarge),
          ),
        ),
        ManagerSearchField(hint: 'Search', onChanged: (v) => setState(() => _q = v.trim().toLowerCase())),
        Expanded(
          child: FutureBuilder<List<T>>(
            future: _items,
            builder: (context, snap) {
              final all = snap.data;
              if (all == null) return const Center(child: CircularProgressIndicator());
              final list = _q.isEmpty ? all : all.where((e) => widget.name(e).toLowerCase().contains(_q)).toList();
              if (list.isEmpty) return Center(child: Text('Nothing matches', style: t.textTheme.bodyMedium));
              return ListView.builder(
                controller: widget.controller,
                itemCount: list.length,
                itemBuilder: (context, i) => ListTile(
                  leading: widget.leading(list[i]),
                  title: Text(widget.name(list[i]), maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(widget.sub(list[i]), maxLines: 1, overflow: TextOverflow.ellipsis),
                  onTap: () => Navigator.pop(context, list[i]),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

Future<Artist?> pickArtist(BuildContext context, {int? exclude, String title = 'Choose an artist'}) {
  final s = context.read<AppServices>();
  return _pickEntity<Artist>(
    context,
    title: title,
    load: () async => (await s.repo.artists()).where((a) => a.id != exclude).toList(),
    name: (a) => a.name,
    sub: (a) => '${plural(a.albumCount, 'album')} · ${plural(a.trackCount, 'song')}',
    leading: (a) => CoverArt(artistId: a.id, seed: a.name, size: 44, circle: true),
  );
}

Future<Album?> pickAlbum(BuildContext context, {int? exclude, String title = 'Choose an album'}) {
  final s = context.read<AppServices>();
  return _pickEntity<Album>(
    context,
    title: title,
    load: () async => (await s.repo.albums()).where((a) => a.id != exclude).toList(),
    name: (a) => a.title,
    sub: (a) => '${a.displayArtist} · ${plural(a.trackCount, 'song')}',
    leading: (a) => CoverArt(albumId: a.id, seed: a.title, size: 44),
  );
}

/// Asks which of [names] should survive a merge. Returns the index, or null when cancelled.
Future<int?> chooseMergeSurvivor(BuildContext context, {required String noun, required List<String> names}) {
  var picked = 0;
  return showDialog<int>(
    context: context,
    builder: (d) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: Text('Merge ${names.length} $noun'),
        content: SizedBox(
          width: 360,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Keep this one. The others are folded into it and disappear.'),
              const SizedBox(height: 8),
              Flexible(
                child: RadioGroup<int>(
                  groupValue: picked,
                  onChanged: (v) => setState(() => picked = v ?? picked),
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      for (var i = 0; i < names.length; i++)
                        RadioListTile<int>(
                          value: i,
                          contentPadding: EdgeInsets.zero,
                          title: Text(names[i], maxLines: 2, overflow: TextOverflow.ellipsis),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(d, picked), child: const Text('Merge')),
        ],
      ),
    ),
  );
}

Future<bool> confirm(BuildContext context, {required String title, required String message, String action = 'Continue'}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (d) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(d, true), child: Text(action)),
      ],
    ),
  );
  return ok ?? false;
}
