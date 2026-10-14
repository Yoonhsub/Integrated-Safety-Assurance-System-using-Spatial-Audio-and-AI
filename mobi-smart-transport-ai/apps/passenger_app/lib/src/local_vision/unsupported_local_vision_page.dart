import 'package:flutter/material.dart';

class LocalVisionPage extends StatelessWidget {
  const LocalVisionPage({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: const Text('휴대폰 로컬 Vision')),
      body: const Center(
          child: Text(
              'Android 휴대폰에서 사용할 수 있습니다. 웹 카메라와 서버 관찰 기능은 기존 경로를 이용해 주세요.')));
}
