// The shape of a licence check: verify the dongle, then decrypt something the
// program needs. Run from a clone of the SDK repository it finds the native
// library on its own; elsewhere set KEYNUB_LICDONGLE_LIBRARY or
// LicDongleLibrary.path first. With no dongle attached it prints so and exits.
import 'dart:io';

import 'package:keynub_licdongle/keynub_licdongle.dart';

void main() {
  final ctx = Context();
  try {
    if (ctx.enumerate().isEmpty) {
      print('No dongle attached.');
      return;
    }
    final dongle = ctx.open(); // first dongle, or ctx.open(serial: '...')
    try {
      final result = dongle.verifyGenuine(); // throws unless genuine
      print('Dongle ${result.serial} is genuine.');

      // The sealed parameters would ship with the application; the program
      // holds no other copy, so removing the check removes the data.
      final sealed = dongle.withSession((s) => s.appEncrypt('the parameters', Scope.developer));
      final parameters = dongle.withSession((s) => s.appDecrypt(sealed));
      print('Recovered ${parameters.length} bytes through the dongle.');
    } finally {
      dongle.close();
    }
  } on LicenseDongleError catch (e) {
    stderr.writeln('KeyNub error: $e');
    exitCode = 1;
  } finally {
    ctx.close();
  }
}
