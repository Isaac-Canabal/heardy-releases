import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'app_log.dart';
import 'lan_sync_protocol.dart' show sanitizeLanLabel;

const lanDefaultTcpPort = 53418;
const lanDefaultDiscoveryPort = 53419;
const lanMulticastGroup = '239.255.53.19';
const lanMaxAnnouncementBytes = 400;
const lanAnnounceEvery = Duration(seconds: 2);
const lanDeviceExpiry = Duration(seconds: 8);
const lanMaxNearbyDevices = 64;

final _idPattern = RegExp(r'^[A-Za-z0-9\-]{1,64}$');

/// Paquete de descubrimiento: solo id aleatorio, etiqueta, versión y puerto TCP.
/// Nunca contenido de la biblioteca.
class LanAnnouncement {
  final String deviceId;
  final String label;
  final int port;
  final int version;

  const LanAnnouncement({required this.deviceId, required this.label, required this.port, this.version = 1});

  Uint8List encode() => Uint8List.fromList(utf8.encode(jsonEncode({
        'a': 'heardy-lan',
        'v': version,
        'id': deviceId,
        'l': label,
        'p': port,
      })));

  /// `null` ante cualquier paquete que no sea exactamente el esperado.
  static LanAnnouncement? decode(List<int> bytes) {
    if (bytes.isEmpty || bytes.length > lanMaxAnnouncementBytes) return null;
    try {
      final json = jsonDecode(utf8.decode(bytes));
      if (json is! Map || json['a'] != 'heardy-lan') return null;
      final version = json['v'], id = json['id'], label = json['l'], port = json['p'];
      if (version is! int || version != 1) return null;
      if (id is! String || !_idPattern.hasMatch(id)) return null;
      if (label is! String || port is! int || port < 1 || port > 65535) return null;
      return LanAnnouncement(deviceId: id, label: sanitizeLanLabel(label), port: port, version: version);
    } catch (_) {
      return null;
    }
  }
}

class LanNearbyDevice {
  final LanAnnouncement announcement;
  final InternetAddress address;
  final DateTime lastSeen;
  const LanNearbyDevice(this.announcement, this.address, this.lastSeen);

  String get deviceId => announcement.deviceId;
  String get label => announcement.label;
  int get port => announcement.port;
}

class LanDatagram {
  final Uint8List data;
  final InternetAddress address;
  const LanDatagram(this.data, this.address);
}

abstract class LanDiscoveryTransport {
  Stream<LanDatagram> get datagrams;
  Future<void> start();
  Future<void> broadcast(Uint8List data);
  Future<void> stop();
}

/// IPv4 privada (RFC 1918), link-local o loopback; IPv6 loopback, fe80::/10 o
/// fc00::/7 (también las IPv4 mapeadas).
bool isLocalNetworkAddress(InternetAddress address) {
  final b = address.rawAddress;
  if (address.type == InternetAddressType.IPv4 && b.length == 4) return _isLocalV4(b[0], b[1]);
  if (b.length != 16) return false;
  final mapped = b.sublist(0, 10).every((x) => x == 0) && b[10] == 0xFF && b[11] == 0xFF;
  if (mapped) return _isLocalV4(b[12], b[13]);
  if (b.sublist(0, 15).every((x) => x == 0) && b[15] == 1) return true;
  if (b[0] == 0xFE && (b[1] & 0xC0) == 0x80) return true;
  return (b[0] & 0xFE) == 0xFC;
}

bool _isLocalV4(int a, int b) =>
    a == 10 || a == 127 || (a == 172 && b >= 16 && b <= 31) || (a == 192 && b == 168) || (a == 169 && b == 254);

/// Direcciones IPv4 privadas (RFC 1918) de las interfaces activas.
Future<List<InternetAddress>> privateIPv4Addresses() async {
  try {
    final out = <InternetAddress>[];
    for (final iface in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
      for (final addr in iface.addresses) {
        final b = addr.rawAddress;
        if (b.length == 4 && (b[0] == 10 || (b[0] == 172 && b[1] >= 16 && b[1] <= 31) || (b[0] == 192 && b[1] == 168))) {
          out.add(addr);
        }
      }
    }
    return out;
  } catch (e) {
    appLog('LanSyncDiscovery: no se pudieron listar las interfaces (${e.runtimeType})');
    return const [];
  }
}

class LanSyncDiscovery {
  final LanDiscoveryTransport _transport;
  final DateTime Function() _clock;
  final Duration announceEvery;
  final Duration expiry;
  final void Function() onChanged;

  LanAnnouncement? _announcement;
  StreamSubscription<LanDatagram>? _sub;
  Timer? _timer;
  final Map<String, LanNearbyDevice> _devices = {};

  LanSyncDiscovery({
    required LanDiscoveryTransport transport,
    required this.onChanged,
    DateTime Function()? clock,
    this.announceEvery = lanAnnounceEvery,
    this.expiry = lanDeviceExpiry,
  })  : _transport = transport,
        _clock = clock ?? DateTime.now;

  List<LanNearbyDevice> get devices {
    pruneNow();
    final list = _devices.values.toList()..sort((a, b) => a.label.compareTo(b.label));
    return list;
  }

  bool get isRunning => _timer != null;

  Future<void> start(LanAnnouncement announcement) async {
    if (isRunning) return;
    _announcement = announcement;
    await _transport.start();
    _sub = _transport.datagrams.listen(_onDatagram, onError: (_) {});
    _timer = Timer.periodic(announceEvery, (_) {
      pruneNow();
      unawaited(announceNow());
    });
    unawaited(announceNow());
  }

  Future<void> announceNow() async {
    final a = _announcement;
    if (a == null) return;
    try {
      await _transport.broadcast(a.encode());
    } catch (e) {
      appLog('LanSyncDiscovery: no se pudo anunciar (${e.runtimeType})');
    }
  }

  void _onDatagram(LanDatagram d) {
    if (!isLocalNetworkAddress(d.address)) return;
    final announcement = LanAnnouncement.decode(d.data);
    if (announcement == null || announcement.deviceId == _announcement?.deviceId) return;
    final known = _devices.containsKey(announcement.deviceId);
    if (!known && _devices.length >= lanMaxNearbyDevices) return;
    final previous = _devices[announcement.deviceId];
    _devices[announcement.deviceId] = LanNearbyDevice(announcement, d.address, _clock());
    if (previous == null ||
        previous.label != announcement.label ||
        previous.port != announcement.port ||
        previous.address != d.address) {
      onChanged();
    }
  }

  void pruneNow() {
    final limit = _clock().subtract(expiry);
    final before = _devices.length;
    _devices.removeWhere((_, d) => d.lastSeen.isBefore(limit));
    if (_devices.length != before) onChanged();
  }

  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    await _sub?.cancel();
    _sub = null;
    _devices.clear();
    await _transport.stop();
  }
}

/// UDP real: difusión limitada, difusión dirigida (/24 de cada interfaz
/// privada) y un grupo multicast administrativo. Cada paso es opcional: en una
/// red con aislamiento de clientes ninguno llega y queda "Conectar por
/// dirección".
class UdpDiscoveryTransport implements LanDiscoveryTransport {
  final int port;
  final Future<void> Function()? acquireMulticastLock;
  final Future<void> Function()? releaseMulticastLock;
  final Future<List<InternetAddress>> Function() interfaces;
  final InternetAddress bindAddress;

  RawDatagramSocket? _socket;
  final _controller = StreamController<LanDatagram>.broadcast();
  StreamSubscription<RawSocketEvent>? _sub;
  var _lockHeld = false;

  UdpDiscoveryTransport({
    this.port = lanDefaultDiscoveryPort,
    this.acquireMulticastLock,
    this.releaseMulticastLock,
    Future<List<InternetAddress>> Function()? interfaces,
    InternetAddress? bindAddress,
  })  : interfaces = interfaces ?? privateIPv4Addresses,
        bindAddress = bindAddress ?? InternetAddress.anyIPv4;

  @override
  Stream<LanDatagram> get datagrams => _controller.stream;

  @override
  Future<void> start() async {
    try {
      await acquireMulticastLock?.call();
      _lockHeld = acquireMulticastLock != null;
    } catch (e) {
      appLog('UdpDiscoveryTransport: sin multicast lock (${e.runtimeType})');
    }
    final socket = await RawDatagramSocket.bind(bindAddress, port, reuseAddress: true);
    socket.broadcastEnabled = true;
    _socket = socket;
    try {
      final local = {for (final a in await interfaces()) a.address};
      for (final iface in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
        if (!iface.addresses.any((a) => local.contains(a.address))) continue;
        try {
          socket.joinMulticast(InternetAddress(lanMulticastGroup), iface);
        } catch (_) {}
      }
    } catch (_) {}
    _sub = socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      final d = socket.receive();
      if (d == null) return;
      _controller.add(LanDatagram(d.data, d.address));
    });
  }

  @override
  Future<void> broadcast(Uint8List data) async {
    final socket = _socket;
    if (socket == null) return;
    final targets = <InternetAddress>{
      InternetAddress('255.255.255.255'),
      InternetAddress(lanMulticastGroup),
    };
    for (final addr in await interfaces()) {
      final b = addr.rawAddress;
      targets.add(InternetAddress('${b[0]}.${b[1]}.${b[2]}.255'));
    }
    for (final target in targets) {
      try {
        socket.send(data, target, port);
      } catch (_) {}
    }
  }

  @override
  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
    _socket?.close();
    _socket = null;
    if (_lockHeld) {
      _lockHeld = false;
      try {
        await releaseMulticastLock?.call();
      } catch (e) {
        appLog('UdpDiscoveryTransport: no se pudo liberar el multicast lock (${e.runtimeType})');
      }
    }
  }
}
