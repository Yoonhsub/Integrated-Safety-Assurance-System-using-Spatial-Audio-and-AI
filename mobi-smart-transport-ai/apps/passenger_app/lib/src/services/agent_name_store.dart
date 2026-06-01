import 'package:shared_preferences/shared_preferences.dart';

class AgentNameStore {
  static const String _agentNameKey = 'mobi.agent_name';

  Future<String?> load() async {
    final preferences = await SharedPreferences.getInstance();
    final value = preferences.getString(_agentNameKey)?.trim();
    return value == null || value.isEmpty ? null : value;
  }

  Future<void> save(String agentName) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_agentNameKey, agentName.trim());
  }

  Future<void> clear() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.remove(_agentNameKey);
  }
}
