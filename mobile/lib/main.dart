import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:media_kit/media_kit.dart';
import 'services/app_state.dart';
import 'screens/search_screen.dart';
import 'screens/shorts_screen.dart';
import 'screens/library_screen.dart';
import 'screens/settings_screen.dart';
import 'theme/app_theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  runApp(const VideoGetApp());
}

class VideoGetApp extends StatefulWidget {
  const VideoGetApp({super.key});

  @override
  State<VideoGetApp> createState() => _VideoGetAppState();
}

class _VideoGetAppState extends State<VideoGetApp> {
  final AppState _appState = AppState();
  late final Future<void> _initialize;

  @override
  void initState() {
    super.initState();
    _initialize = _appState.initialize();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'VideoGET',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark(),
      themeMode: ThemeMode.dark,
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [Locale('zh', 'CN')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      home: FutureBuilder<void>(
        future: _initialize,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return Scaffold(
              backgroundColor: Colors.black,
              body: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SvgPicture.asset(
                      'assets/videoget-icon.svg',
                      width: 88,
                      height: 66,
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'VideoGET',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 20),
                    const CircularProgressIndicator(),
                  ],
                ),
              ),
            );
          }
          if (snapshot.hasError) {
            return Scaffold(
              body: Center(child: Text('初始化失败：${snapshot.error}')),
            );
          }
          return MainShell(appState: _appState);
        },
      ),
    );
  }
}

class MainShell extends StatefulWidget {
  final AppState appState;
  const MainShell({super.key, required this.appState});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _index = 0;
  late final List<Widget> _pages;

  @override
  void initState() {
    super.initState();
    _pages = [
      SearchScreen(
        appState: widget.appState,
        onOpenLibrary: () => setState(() => _index = 2),
      ),
      ShortsScreen(
        appState: widget.appState,
        onOpenSettings: () => setState(() => _index = 3),
      ),
      LibraryScreen(appState: widget.appState),
      SettingsScreen(appState: widget.appState),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBody: true,
      body: IndexedStack(index: _index, children: _pages),
      bottomNavigationBar: ClipRect(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: Border(
                top: BorderSide(
                  color: Theme.of(context).colorScheme.outlineVariant,
                ),
              ),
            ),
            child: NavigationBar(
              selectedIndex: _index,
              onDestinationSelected: (value) {
                if (value == _index) return;
                HapticFeedback.selectionClick();
                setState(() => _index = value);
              },
              destinations: const [
                NavigationDestination(
                  icon: Icon(Icons.grid_view_outlined),
                  selectedIcon: Icon(Icons.grid_view_rounded),
                  label: '片库',
                ),
                NavigationDestination(
                  icon: Icon(Icons.smart_display_outlined),
                  selectedIcon: Icon(Icons.smart_display_rounded),
                  label: '短视频',
                ),
                NavigationDestination(
                  icon: Icon(Icons.video_library_outlined),
                  selectedIcon: Icon(Icons.video_library_rounded),
                  label: '收藏',
                ),
                NavigationDestination(
                  icon: Icon(Icons.tune_outlined),
                  selectedIcon: Icon(Icons.tune_rounded),
                  label: '设置',
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
