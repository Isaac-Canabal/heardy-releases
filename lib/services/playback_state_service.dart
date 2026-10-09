import 'package:shared_preferences/shared_preferences.dart';
import 'package:audio_service/audio_service.dart';

/// Servicio para persistir y restaurar el estado de reproducción
/// Soluciona el problema de pérdida de estado al cerrar completamente la app
class PlaybackStateService {
  static const _playingStateKey = 'playing_state';
  static const _currentMediaIdKey = 'current_media_id';
  static const _currentPositionKey = 'current_position';
  static const _queueDataKey = 'queue_data';
  static const _shuffleModeKey = 'shuffle_mode';
  static const _speedKey = 'playback_speed';
  static const _playlistIdKey = 'playlist_id';
  static const _volumeKey = 'player_volume';

  static final PlaybackStateService _instance = PlaybackStateService._internal();
  factory PlaybackStateService() => _instance;
  PlaybackStateService._internal();

  /// Guarda el estado actual de reproducción
  static Future<void> saveState({
    required bool isPlaying,
    required String? currentMediaId,
    required Duration position,
    required List<MediaItem> queue,
    required AudioServiceShuffleMode shuffleMode,
    required double speed,
    String? playlistId,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      
      await prefs.setBool(_playingStateKey, isPlaying);
      await prefs.setString(_currentMediaIdKey, currentMediaId ?? '');
      await prefs.setInt(_currentPositionKey, position.inMilliseconds);
      
      // Guardar datos básicos de la queue
      final queueIds = queue.map((item) => item.id).toList();
      await prefs.setStringList(_queueDataKey, queueIds);
      await prefs.setString(_shuffleModeKey, shuffleMode.name);
      await prefs.setDouble(_speedKey, speed);
      await prefs.setString(_playlistIdKey, playlistId ?? '');
      
      print('Estado de reproducción guardado: ${isPlaying ? "PLAYING" : "PAUSED"}, position: ${position.inSeconds}s');
    } catch (e) {
      print('Error guardando estado de reproducción: $e');
    }
  }

  /// Restaura el estado de reproducción guardado
  static Future<Map<String, dynamic>?> restoreState() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      
      final playingState = prefs.getBool(_playingStateKey);
      final currentMediaId = prefs.getString(_currentMediaIdKey);
      final positionMs = prefs.getInt(_currentPositionKey);
      final queueIds = prefs.getStringList(_queueDataKey);
      final shuffleModeStr = prefs.getString(_shuffleModeKey);
      final speed = prefs.getDouble(_speedKey);
      final playlistId = prefs.getString(_playlistIdKey);
      
      if (playingState == null || currentMediaId == null) {
        print('No hay estado de reproducción guardado');
        return null;
      }
      
      if (currentMediaId.isEmpty || queueIds == null || queueIds.isEmpty) {
        print('Estado de reproducción inválido o incompleto');
        await clearState();
        return null;
      }
      
      print('Estado de reproducción restaurado: ${playingState ? "PLAYING" : "PAUSED"}, position: ${positionMs}ms');
      
      return {
        'isPlaying': playingState,
        'currentMediaId': currentMediaId,
        'position': Duration(milliseconds: positionMs ?? 0),
        'queueIds': queueIds,
        'shuffleModeStr': shuffleModeStr,
        'speed': speed,
        'playlistId': playlistId,
      };
    } catch (e) {
      print('Error restaurando estado de reproducción: $e');
      return null;
    }
  }

  /// El volumen es independiente del resto del estado: no se borra con
  /// `clearState` (que la cola quede inválida no es motivo para subir el
  /// volumen de golpe la próxima vez).
  static Future<void> saveVolume(double volume) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_volumeKey, volume);
    } catch (e) {
      print('Error guardando el volumen: $e');
    }
  }

  static Future<double?> restoreVolume() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getDouble(_volumeKey);
    } catch (e) {
      print('Error restaurando el volumen: $e');
      return null;
    }
  }

  /// Limpia el estado guardado (cuando no es relevante)
  static Future<void> clearState() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_playingStateKey);
      await prefs.remove(_currentMediaIdKey);
      await prefs.remove(_currentPositionKey);
      await prefs.remove(_queueDataKey);
      await prefs.remove(_shuffleModeKey);
      await prefs.remove(_speedKey);
      await prefs.remove(_playlistIdKey);
      print('Estado de reproducción limpiado');
    } catch (e) {
      print('Error limpiando estado de reproducción: $e');
    }
  }

  /// Verifica si hay un estado guardado válido
  static Future<bool> hasValidState() async {
    final state = await restoreState();
    return state != null;
  }
}