import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:get/get.dart';
import 'package:http/http.dart' as http;
import 'package:daily_flutter/daily_flutter.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:vapi/speech_utils.dart';

class VapiEvent {
  VapiEvent(this.label, [this.value]);

  final String label;
  final dynamic value;
}

enum VapiAudioDevice {
  speakerphone,
  wired,
  earpiece,
  bluetooth,
}

class Vapi {
  Vapi(this.publicKey, [this.apiBaseUrl]);
  final String publicKey;
  final String? apiBaseUrl;
  final _streamController = StreamController<VapiEvent>();

  Stream<VapiEvent> get onEvent => _streamController.stream;

  CallClient? _client;

  Future<void> _checkPermissions() async {
    final goToSettings = await PermissionsUtils().showPermissionDeniedDialog(
      Get.context!,
      title: 'Enable microphone access',
      subtitle: 'To keep going please allow microphone access in settings',
    );
    if (goToSettings ?? false) {
      await openAppSettings();
    }
  }

  Future<void> start({
    String? assistantId,
    dynamic assistant,
    dynamic assistantOverrides = const {},
    Duration clientCreationTimeoutDuration = const Duration(seconds: 10),
  }) async {
    if (_client != null) {
      throw Exception('Call already in progress');
    }

    debugPrint('🔄 ${DateTime.now()}: Vapi - Requesting Mic Permission...');
    var microphoneStatus = await Permission.microphone.request();
    if (microphoneStatus.isDenied || microphoneStatus.isPermanentlyDenied) {
      await _checkPermissions();
      return;
    }
    debugPrint('🆗 ${DateTime.now()}: Vapi - Mic Permission Granted');

    if (assistantId == null && assistant == null) {
      throw ArgumentError('Either assistantId or assistant must be provided');
    }

    final baseUrl = '${apiBaseUrl ?? 'https://api.vapi.ai'}/call/web';
    final url = Uri.parse(baseUrl);
    final headers = {
      'Authorization': 'Bearer $publicKey',
      'Content-Type': 'application/json',
    };
    final body = assistantId != null
        ? jsonEncode({'assistantId': assistantId, 'assistantOverrides': assistantOverrides})
        : jsonEncode({'assistant': assistant, 'assistantOverrides': assistantOverrides});

    debugPrint('🔄 ${DateTime.now()}: Vapi - Preparing Call & Client...');
    debugPrint('🔄 ${DateTime.now()}: Vapi - Sending POST request to $url with body: $body');

    final vapiCallFuture = http.post(url, headers: headers, body: body);
    final clientCreationFuture = _createClientWithRetries(clientCreationTimeoutDuration);

    final results = await Future.wait([vapiCallFuture, clientCreationFuture]);

    final response = results[0] as http.Response;
    final client = results[1] as CallClient;

    _client = client;

    if (response.statusCode == 201) {
      debugPrint('🆗 ${DateTime.now()}: Vapi - Vapi Call Ready');
      debugPrint('🔄 ${DateTime.now()}: Vapi - Received response: ${response.body}');
      final data = jsonDecode(response.body);
      final webCallUrl = data['webCallUrl'];
      if (webCallUrl == null) {
        debugPrint(
            '🆘 ${DateTime.now()}: Vapi - Vapi Call URL not found in response: ${response.body}');
        emit(VapiEvent('call-error', 'Web call URL missing'));
        return;
      }
      debugPrint('🔄 ${DateTime.now()}: Vapi - Joining Call at URL: $webCallUrl');
      unawaited(
        client
            .join(
          url: Uri.parse(webCallUrl),
          clientSettings: const ClientSettingsUpdate.set(
            inputs: InputSettingsUpdate.set(
              microphone: MicrophoneInputSettingsUpdate.set(isEnabled: BoolUpdate.set(true)),
              camera: CameraInputSettingsUpdate.set(isEnabled: BoolUpdate.set(false)),
            ),
          ),
        )
            .catchError((e) {
          debugPrint('🆘 ${DateTime.now()}: Vapi - Failed to join call: $e');
          throw Exception('Vapi - Failed to join call: $e');
        }),
      );
    } else {
      client.dispose();
      _client = null;
      debugPrint(
          '🆘 ${DateTime.now()}: Vapi - Failed to create Vapi Call. Status: ${response.statusCode}, Body: ${response.body}');
      emit(VapiEvent('call-error', 'Status: ${response.statusCode}'));
      return;
    }

    client.events.listen((event) {
      event.whenOrNull(
        callStateUpdated: (stateData) {
          switch (stateData.state) {
            case CallState.leaving:
            case CallState.left:
              _client = null;
              debugPrint('⏹️ ${DateTime.now()}: Vapi - Call Ended.');
              emit(VapiEvent('call-end'));
              break;
            case CallState.joined:
              debugPrint('🆗 ${DateTime.now()}: Vapi - Joined Call');
              break;
            default:
              break;
          }
        },
        participantLeft: (participantData) {
          if (participantData.info.isLocal) return;
          _client?.leave();
        },
        appMessageReceived: (messageData, id) {
          _onAppMessage(messageData);
        },
        participantUpdated: (participantData) {
          if (participantData.info.username == 'Vapi Speaker' &&
              participantData.media?.microphone.state == MediaState.playable) {
            debugPrint('📤 ${DateTime.now()}: Vapi - Sending Ready from participantUpdated...');
            client.sendAppMessage(jsonEncode({'message': 'playable'}), null);
          }
        },
        participantJoined: (participantData) {
          if (participantData.info.username == 'Vapi Speaker' &&
              participantData.media?.microphone.state == MediaState.playable) {
            debugPrint('📤 ${DateTime.now()}: Vapi - Sending Ready from participantJoined...');
            client.sendAppMessage(jsonEncode({'message': 'playable'}), null);
          }
        },
      );
    });
  }

  Future<CallClient> _createClientWithRetries(
    Duration clientCreationTimeoutDuration,
  ) async {
    var retries = 0;
    const maxRetries = 5;

    Future<CallClient> attemptCreation() async {
      debugPrint('🔄 ${DateTime.now()}: Vapi - Attempting to create client.');
      return CallClient.create();
    }

    Future<CallClient> createWithTimeout() async {
      final completer = Completer<CallClient>();

      // Start a timer for timeout
      Timer(clientCreationTimeoutDuration, () {
        if (!completer.isCompleted) {
          debugPrint(
              '⏳ ${DateTime.now()}: Vapi - Client creation timed out after ${clientCreationTimeoutDuration.inSeconds} seconds.');
          completer.completeError(TimeoutException('Client creation timed out'));
        }
      });

      attemptCreation().then((client) {
        if (!completer.isCompleted) {
          debugPrint('🆗 ${DateTime.now()}: Vapi - Client created successfully.');
          completer.complete(client);
        }
      }).catchError((error) {
        if (!completer.isCompleted) {
          debugPrint('🆘 ${DateTime.now()}: Vapi - Client creation error: $error');
          completer.completeError(error);
        }
      });

      return completer.future;
    }

    while (retries < maxRetries) {
      try {
        debugPrint(
            '🔄 ${DateTime.now()}: Vapi - Creating client (Attempt ${retries + 1}/$maxRetries)...');
        final client = await createWithTimeout();
        debugPrint('🆗 ${DateTime.now()}: Vapi - Client Created on attempt ${retries + 1}');
        return client;
      } catch (e) {
        retries++;
        debugPrint(
            '🆘 ${DateTime.now()}: Vapi - Client creation failed on attempt $retries with error: $e');
        if (retries >= maxRetries) {
          debugPrint(
              '🆘 ${DateTime.now()}: Vapi - Failed to create client after $maxRetries attempts.');
          rethrow;
        }
      }
    }
    throw Exception('Client creation failed after $maxRetries retries');
  }

  Future<void> send(dynamic message) async {
    await _client!.sendAppMessage(jsonEncode(message), null);
  }

  void _onAppMessage(String msg) {
    try {
      final parsedMessage = jsonDecode(msg);
      if (parsedMessage == 'listening') {
        debugPrint('✅ ${DateTime.now()}: Vapi - Assistant Connected.');
        emit(VapiEvent('call-start'));
      }
      emit(VapiEvent('message', parsedMessage));
    } catch (parseError) {
      debugPrint('🆘 ${DateTime.now()}: Vapi - Error parsing message data: $parseError');
    }
  }

  Future<void> stop() async {
    if (_client == null) {
      throw Exception('No call in progress');
    }
    debugPrint('🔄 ${DateTime.now()}: Vapi - Stopping call...');
    await _client!.leave();
  }

  void setMuted(bool muted) {
    _client!.updateInputs(
      inputs: InputSettingsUpdate.set(
        microphone: MicrophoneInputSettingsUpdate.set(isEnabled: BoolUpdate.set(!muted)),
      ),
    );
    debugPrint('🔄 ${DateTime.now()}: Vapi - setMuted called. Muted: $muted');
  }

  bool isMuted() {
    final muted = _client!.inputs.microphone.isEnabled == false;
    debugPrint('🔄 ${DateTime.now()}: Vapi - isMuted called. Result: $muted');
    return muted;
  }

  @Deprecated(
    'Use [setVapiAudioDevice] instead. Deprecated because unusable if user does not depend of daily_flutter',
  )
  void setAudioDevice({required DeviceId deviceId}) {
    _client!.setAudioDevice(deviceId: deviceId);
    debugPrint('🔄 ${DateTime.now()}: Vapi - setAudioDevice called with DeviceId: $deviceId');
  }

  void setVapiAudioDevice({required VapiAudioDevice device}) {
    _client!.setAudioDevice(
      deviceId: switch (device) {
        VapiAudioDevice.speakerphone => DeviceId.speakerPhone,
        VapiAudioDevice.wired => DeviceId.wired,
        VapiAudioDevice.earpiece => DeviceId.earpiece,
        VapiAudioDevice.bluetooth => DeviceId.bluetooth,
      },
    );
    debugPrint('🔄 ${DateTime.now()}: Vapi - setVapiAudioDevice called with device: $device');
  }

  void emit(VapiEvent event) {
    _streamController.add(event);
    debugPrint(
        '🔄 ${DateTime.now()}: Vapi - Emitting event: ${event.label}, Value: ${event.value}');
  }

  void dispose() {
    _streamController.close();
    debugPrint('🔄 ${DateTime.now()}: Vapi - Disposed stream controller.');
  }
}
