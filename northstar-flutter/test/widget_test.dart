import 'package:flutter_test/flutter_test.dart';

import 'package:northstar/main.dart';

void main() {
  testWidgets('Relay app renders core controls', (WidgetTester tester) async {
    await tester.pumpWidget(const MyApp());

    expect(find.text('Northstar Relay'), findsOneWidget);
    expect(find.text('Server endpoint'), findsOneWidget);
    expect(find.text('Request message'), findsOneWidget);
    expect(find.text('Send'), findsOneWidget);
    expect(
      find.text('No exchanges yet. Send a request to start.'),
      findsOneWidget,
    );
  });
}
