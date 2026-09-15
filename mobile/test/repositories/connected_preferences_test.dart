import 'package:flutter_test/flutter_test.dart';
import 'package:nti_pos/data/preferences/app_preferences.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(AppPreferences.resetForTest);

  test(
    'connected scopes never inherit demo login or another merchants preferences',
    () async {
      SharedPreferences.setMockInitialValues({
        'logged_in': true,
        'store_name': 'Demo',
        'employee_id': 'demo-owner',
      });
      AppPreferences.resetForTest();
      final demo = await AppPreferences.instance();
      expect(demo.isLoggedIn, isTrue);
      AppPreferences.configureScope('tenant-a');
      final a = await AppPreferences.instance();
      expect(a.isLoggedIn, isFalse);
      expect(a.employeeId, isEmpty);
      await a.setStoreName('A');
      await a.setLoggedIn(true);
      AppPreferences.configureScope('tenant-b');
      final b = await AppPreferences.instance();
      expect(b.isLoggedIn, isFalse);
      expect(b.storeName, isNot('A'));
      AppPreferences.configureScope('tenant-a');
      expect((await AppPreferences.instance()).storeName, 'A');
      AppPreferences.resetForTest();
      expect((await AppPreferences.instance()).storeName, 'Demo');
      expect((await AppPreferences.instance()).isLoggedIn, isTrue);
    },
  );
}
