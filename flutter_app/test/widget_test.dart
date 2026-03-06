import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:hztech_quant/main.dart';

void main() {
  testWidgets('App launches', (WidgetTester tester) async {
    await tester.pumpWidget(const HzQuantApp());
    await tester.pumpAndSettle();
    expect(find.byType(MaterialApp), findsOneWidget);
  });
}
