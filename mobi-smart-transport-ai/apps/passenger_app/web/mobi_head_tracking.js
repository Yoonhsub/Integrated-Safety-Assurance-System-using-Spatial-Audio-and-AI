(function () {
  'use strict';

  var SERVICE_UUID = '0000ffe5-0000-1000-8000-00805f9a34fb';
  var PREFERRED_NOTIFY_UUID = '0000ffe4-0000-1000-8000-00805f9a34fb';

  var device = null;
  var server = null;
  var characteristic = null;
  var buffer = [];
  var zeroYaw = null;
  var snapshot = disabledSnapshot('idle');

  function disabledSnapshot(status) {
    return {
      statusLabel: status || 'disconnected',
      isAvailable: false,
      yaw: null,
      pitch: null,
      roll: null,
      updatedAt: null,
      sourceLabel: 'WT901BLE Web Bluetooth',
      deviceName: device && device.name ? device.name : null,
      packetType: null,
      rawHex: null
    };
  }

  function supported() {
    return !!(navigator.bluetooth && navigator.bluetooth.requestDevice);
  }

  function nowIso() {
    return new Date().toISOString();
  }

  function toHex(bytes) {
    return Array.from(bytes)
      .map(function (b) { return b.toString(16).padStart(2, '0'); })
      .join(' ');
  }

  function signedInt16LE(bytes, offset) {
    var value = bytes[offset] | (bytes[offset + 1] << 8);
    return value & 0x8000 ? value - 0x10000 : value;
  }

  function angleFromInt16(value) {
    return value / 32768.0 * 180.0;
  }

  function normalize180(value) {
    var out = Number(value);
    if (!Number.isFinite(out)) return 0;
    out = ((out + 180) % 360 + 360) % 360 - 180;
    return out === -180 ? 180 : out;
  }

  function checksumOk(frame) {
    var sum = 0;
    for (var i = 0; i < frame.length - 1; i += 1) {
      sum = (sum + frame[i]) & 0xff;
    }
    return sum === frame[frame.length - 1];
  }

  function updateAngles(packetType, roll, pitch, rawYaw, rawFrame) {
    if (zeroYaw === null || !Number.isFinite(zeroYaw)) {
      zeroYaw = rawYaw;
    }

    snapshot = {
      statusLabel: 'connected',
      isAvailable: true,
      yaw: normalize180(rawYaw - zeroYaw),
      pitch: pitch,
      roll: roll,
      updatedAt: nowIso(),
      sourceLabel: 'WT901BLE Web Bluetooth',
      deviceName: device && device.name ? device.name : null,
      packetType: packetType,
      rawHex: toHex(rawFrame)
    };
  }

  function decodePacket61(frame) {
    // WT901BLE default BLE packet:
    // 55 61 ax ay az wx wy wz roll pitch yaw, little-endian int16 pairs.
    var roll = angleFromInt16(signedInt16LE(frame, 14));
    var pitch = angleFromInt16(signedInt16LE(frame, 16));
    var yaw = angleFromInt16(signedInt16LE(frame, 18));
    updateAngles('0x61', roll, pitch, yaw, frame);
  }

  function decodePacket53(frame) {
    // Standard WIT angle packet:
    // 55 53 RollL RollH PitchL PitchH YawL YawH VL VH SUM.
    var roll = angleFromInt16(signedInt16LE(frame, 2));
    var pitch = angleFromInt16(signedInt16LE(frame, 4));
    var yaw = angleFromInt16(signedInt16LE(frame, 6));
    updateAngles('0x53', roll, pitch, yaw, frame);
  }

  function consumeBuffer() {
    while (buffer.length >= 2) {
      if (buffer[0] !== 0x55) {
        buffer.shift();
        continue;
      }

      var type = buffer[1];
      if (type === 0x61) {
        if (buffer.length < 20) return;
        decodePacket61(buffer.splice(0, 20));
        continue;
      }

      if (type === 0x53) {
        if (buffer.length < 11) return;
        var angleFrame = buffer.slice(0, 11);
        if (!checksumOk(angleFrame)) {
          buffer.shift();
          continue;
        }
        buffer.splice(0, 11);
        decodePacket53(angleFrame);
        continue;
      }

      // Other standard WIT frames are fixed 11-byte packets. Skip them so the
      // parser can reach the next angle frame.
      if (type >= 0x50 && type <= 0x5f) {
        if (buffer.length < 11) return;
        buffer.splice(0, 11);
        continue;
      }

      buffer.shift();
    }
  }

  function handleCharacteristicValue(event) {
    var value = event && event.target ? event.target.value : null;
    if (!value) return;
    var bytes = new Uint8Array(value.buffer, value.byteOffset, value.byteLength);
    for (var i = 0; i < bytes.length; i += 1) buffer.push(bytes[i]);
    if (buffer.length > 256) buffer = buffer.slice(buffer.length - 256);
    consumeBuffer();
  }

  async function connect() {
    if (!supported()) {
      snapshot = disabledSnapshot('Web Bluetooth unsupported');
      return snapshot;
    }

    snapshot = disabledSnapshot('selecting device');
    device = await navigator.bluetooth.requestDevice({
      acceptAllDevices: true,
      optionalServices: [SERVICE_UUID]
    });
    snapshot = disabledSnapshot('connecting');
    device.addEventListener('gattserverdisconnected', function () {
      characteristic = null;
      server = null;
      snapshot = disabledSnapshot('disconnected');
    });

    server = await device.gatt.connect();
    var service = await server.getPrimaryService(SERVICE_UUID);
    var characteristics = await service.getCharacteristics();
    characteristic = characteristics.find(function (item) {
      return item.uuid.toLowerCase() === PREFERRED_NOTIFY_UUID &&
        (item.properties.notify || item.properties.indicate);
    }) || characteristics.find(function (item) {
      return item.properties.notify || item.properties.indicate;
    });

    if (!characteristic) {
      snapshot = disabledSnapshot('notify characteristic not found');
      return snapshot;
    }

    buffer = [];
    zeroYaw = null;
    characteristic.addEventListener(
      'characteristicvaluechanged',
      handleCharacteristicValue
    );
    await characteristic.startNotifications();
    snapshot = disabledSnapshot('connected, waiting for angle packet');
    return snapshot;
  }

  async function disconnect() {
    try {
      if (characteristic) {
        characteristic.removeEventListener(
          'characteristicvaluechanged',
          handleCharacteristicValue
        );
        await characteristic.stopNotifications().catch(function () {});
      }
    } catch (_) {}
    try {
      if (device && device.gatt && device.gatt.connected) {
        device.gatt.disconnect();
      }
    } catch (_) {}
    characteristic = null;
    server = null;
    buffer = [];
    zeroYaw = null;
    snapshot = disabledSnapshot('disconnected');
    return snapshot;
  }

  function resetZero() {
    if (snapshot && snapshot.isAvailable && typeof snapshot.yaw === 'number') {
      zeroYaw = null;
      snapshot.statusLabel = 'zero reset, waiting for next packet';
      snapshot.yaw = 0;
    }
  }

  function getSnapshotJson() {
    return JSON.stringify(snapshot || disabledSnapshot('idle'));
  }

  window.MobiHeadTracking = {
    supported: supported,
    connect: connect,
    disconnect: disconnect,
    resetZero: resetZero,
    getSnapshotJson: getSnapshotJson
  };
})();
