import 'package:flutter/material.dart';

import 'app/app.dart';
import 'app/app_services.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const _Boot());
}

/// Creates the services (database, audio session, yt-dlp bridge...) behind a splash screen and
/// shows a readable error - with a retry - if something fails to start.
class _Boot extends StatefulWidget {
  const _Boot();

  @override
  State<_Boot> createState() => _BootState();
}

class _BootState extends State<_Boot> {
  late Future<AppServices> _future = AppServices.create();

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<AppServices>(
      future: _future,
      builder: (context, snap) {
        if (snap.hasData) return MusicApp(services: snap.data!);
        return MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData(colorSchemeSeed: const Color(0xFF6750A4), useMaterial3: true),
          darkTheme: ThemeData(colorSchemeSeed: const Color(0xFF6750A4), useMaterial3: true, brightness: Brightness.dark),
          home: Scaffold(
            body: Center(
              child: snap.hasError
                  ? Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        const Icon(Icons.error_outline, size: 48),
                        const SizedBox(height: 12),
                        const Text('The app could not start', style: TextStyle(fontSize: 18)),
                        const SizedBox(height: 8),
                        SelectableText('${snap.error}', textAlign: TextAlign.center),
                        const SizedBox(height: 16),
                        FilledButton(onPressed: () => setState(() => _future = AppServices.create()), child: const Text('Retry')),
                      ]),
                    )
                  : const CircularProgressIndicator(),
            ),
          ),
        );
      },
    );
  }
}
