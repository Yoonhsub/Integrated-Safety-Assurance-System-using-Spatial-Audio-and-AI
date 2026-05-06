import 'package:flutter/material.dart';
import 'pages/home_page.dart';

class MobiApp extends StatelessWidget {
  const MobiApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MOBI Driver App',
      theme: ThemeData(useMaterial3: true),
      home: const HomePage(),
    );
  }
}
