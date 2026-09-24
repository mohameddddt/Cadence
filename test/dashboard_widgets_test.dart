import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicplayer/app/brand.dart';
import 'package:musicplayer/ui/screens/dashboard/dashboard_widgets.dart';

Widget host(Widget child, {double width = 200}) => MaterialApp(
      theme: ThemeData(colorScheme: Brand.lightScheme),
      home: Scaffold(body: Align(alignment: Alignment.topLeft, child: SizedBox(width: width, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [child])))),
    );

void main() {
  Future<({Size track, Size fill})> measure(WidgetTester tester, double value) async {
    await tester.pumpWidget(host(MeterBar(value: value, height: 8)));
    final boxes = find.descendant(of: find.byType(MeterBar), matching: find.byType(ColoredBox)).evaluate().map((e) => e.renderObject! as RenderBox).toList();
    return (track: boxes.first.size, fill: boxes.last.size);
  }

  testWidgets('MeterBar draws the track at full width and the fill at value * width, left-aligned', (tester) async {
    final m = await measure(tester, 0.5);
    expect(m.track, const Size(200, 8));
    expect(m.fill, const Size(100, 8));
    final fillLeft = tester.getTopLeft(find.descendant(of: find.byType(MeterBar), matching: find.byType(ColoredBox)).last).dx;
    expect(fillLeft, 0);
  });

  testWidgets('MeterBar still shows its track when the value is 0', (tester) async {
    final m = await measure(tester, 0);
    expect(m.track, const Size(200, 8));
    expect(m.fill.width, 0);
  });

  testWidgets('MeterBar clamps values outside 0..1', (tester) async {
    expect((await measure(tester, 1.7)).fill.width, 200);
    expect((await measure(tester, -1)).fill.width, 0);
  });

  test('plural picks the singular only for exactly one', () {
    expect(plural(1, 'song'), '1 song');
    expect(plural(0, 'song'), '0 songs');
    expect(plural(1234, 'album'), '1,234 albums');
  });
}
