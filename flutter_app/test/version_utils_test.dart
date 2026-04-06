import 'package:flutter_test/flutter_test.dart';
import 'package:hztech_quant/version_utils.dart';

void main() {
  test('compareSemanticVersion orders major.minor.patch', () {
    expect(compareSemanticVersion('1.0.0', '1.0.1'), lessThan(0));
    expect(compareSemanticVersion('1.0.1', '1.0.0'), greaterThan(0));
    expect(compareSemanticVersion('2.0.0', '1.9.9'), greaterThan(0));
    expect(compareSemanticVersion('1.2.3', '1.2.3'), 0);
  });

  test('ignores +build suffix for ordering', () {
    expect(compareSemanticVersion('1.0.0+99', '1.0.1'), lessThan(0));
  });

  test('isVersionLower respects empty required', () {
    expect(isVersionLower('0.0.1', null), false);
    expect(isVersionLower('0.0.1', ''), false);
    expect(isVersionLower('1.0.0', '1.0.1'), true);
  });
}
