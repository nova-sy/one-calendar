import 'package:flutter_test/flutter_test.dart';
import 'package:neo_toolbox/core/update/update_checker.dart';

void main() {
  test('isNewer compares semantic versions', () {
    expect(UpdateChecker.isNewer('1.2.0', '1.1.0'), isTrue);
    expect(UpdateChecker.isNewer('1.1.1', '1.1.0'), isTrue);
    expect(UpdateChecker.isNewer('2.0.0', '1.9.9'), isTrue);
    expect(UpdateChecker.isNewer('1.1.0', '1.1.0'), isFalse);
    expect(UpdateChecker.isNewer('1.0.0', '1.1.0'), isFalse);
    expect(UpdateChecker.isNewer('1.1.0', '1.1.0+2'), isFalse);
  });
}
