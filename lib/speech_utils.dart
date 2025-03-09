import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

class PermissionsUtils {
  Future<bool?> showPermissionDeniedDialog(
    BuildContext context, {
    String title = 'Enable microphone and speech recognition access',
    String subtitle =
        'To keep going please allow microphone and speech recognition access in settings',
  }) async {
    if (!Platform.isIOS) {
      return showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(
            subtitle,
          ),
          actions: <Widget>[
            CupertinoDialogAction(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text(
                'Cancel',
                style: TextStyle(
                  color: Color(0xFF007AFF),
                  height: 22 / 17,
                  fontWeight: FontWeight.w400,
                ),
              ),
            ),
            CupertinoDialogAction(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text(
                'Go to settings',
                style: TextStyle(
                  color: Color(0xFF007AFF),
                  height: 22 / 17,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      );
    }

    // todo : showDialog for ios
    return showCupertinoDialog<bool>(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        title: Text(title),
        content: Text(subtitle),
        actions: <Widget>[
          CupertinoDialogAction(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text(
              'Cancel',
              style: TextStyle(
                color: Color(0xFF007AFF),
                height: 22 / 17,
                fontWeight: FontWeight.w400,
              ),
            ),
          ),
          CupertinoDialogAction(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text(
              'Go to settings',
              style: TextStyle(
                color: Color(0xFF007AFF),
                height: 22 / 17,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
