import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heardy/widgets/desktop_horizontal_scroller.dart';

Widget _host(double width) => MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(size: Size(width, 700)),
        child: Scaffold(
          body: Center(
            child: SizedBox(
              width: width,
              child: DesktopHorizontalScroller(
                height: 100,
                builder: (context, controller, extra) => ListView.builder(
                  controller: controller,
                  scrollDirection: Axis.horizontal,
                  padding: extra,
                  itemCount: 30,
                  itemBuilder: (_, i) => SizedBox(width: 120, child: Text('item $i')),
                ),
              ),
            ),
          ),
        ),
      ),
    );

void main() {
  test('desktopScrollTarget avanza ~80% del viewport y se acota', () {
    expect(desktopScrollTarget(offset: 0, viewport: 1000, maxExtent: 5000, forward: true), 800);
    expect(desktopScrollTarget(offset: 4900, viewport: 1000, maxExtent: 5000, forward: true), 5000);
    expect(desktopScrollTarget(offset: 300, viewport: 1000, maxExtent: 5000, forward: false), 0);
    expect(desktopScrollTarget(offset: 0, viewport: 1000, maxExtent: -1, forward: true), 0);
  });

  testWidgets('en escritorio con desbordamiento aparece › y al avanzar también ‹', (tester) async {
    await tester.pumpWidget(_host(1000));
    await tester.pump();
    expect(find.byKey(const Key('desktop_scroll_forward')), findsOneWidget);
    expect(find.byKey(const Key('desktop_scroll_back')), findsNothing);
    expect(find.byType(Scrollbar), findsOneWidget);

    await tester.tap(find.byKey(const Key('desktop_scroll_forward')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('desktop_scroll_back')), findsOneWidget);
  });

  testWidgets('en teléfono no hay flechas ni barra', (tester) async {
    await tester.pumpWidget(_host(400));
    await tester.pump();
    expect(find.byKey(const Key('desktop_scroll_forward')), findsNothing);
    expect(find.byType(Scrollbar), findsNothing);
  });
}
