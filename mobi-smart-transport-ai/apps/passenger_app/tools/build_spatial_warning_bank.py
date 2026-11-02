"""Build local binaural warning PCM from SADIE II D2, never at app runtime.
Usage: python tools/build_spatial_warning_bank.py PATH_TO_D2_HRIR_SOFA.zip
Requires numpy, scipy, h5py. Source download and license: assets/hrtf/NOTICE.md.
"""
import hashlib
import io
import json
from pathlib import Path
import struct
import sys
import zipfile

import h5py
import numpy as np
from scipy.signal import butter, sosfilt, fftconvolve

ZIP_SHA256 = '2561af2c09688c95f3909303cd2ac51cb8c15abb574903f17f635e1376cbce94'
SOFA_PATH = 'D2_HRIR_SOFA/D2_48K_24bit_256tap_FIR_SOFA.sofa'
RATE = 48000
STEP = 5


def build(archive, destination):
    blob = Path(archive).read_bytes()
    if hashlib.sha256(blob).hexdigest() != ZIP_SHA256:
        raise ValueError('Unexpected SADIE II archive version/checksum')
    with zipfile.ZipFile(io.BytesIO(blob)) as z:
        sofa = z.read(SOFA_PATH)
    with h5py.File(io.BytesIO(sofa)) as f:
        assert float(f['Data.SamplingRate'][0]) == RATE
        assert np.all(np.asarray(f['Data.Delay']) == 0)
        positions = np.asarray(f['SourcePosition'])
        ir = np.asarray(f['Data.IR'])
        receivers = np.asarray(f['ReceiverPosition'])
        # SOFA +azimuth = left; receiver 0 is the left ear (positive y).
        assert receivers[0, 1, 0] > 0 and receivers[1, 1, 0] < 0
        filters = []
        source_indices = []
        for right_angle in range(0, 360, STEP):
            matches = np.where((np.abs(positions[:, 0] - (-right_angle % 360)) < 1e-6)
                               & (np.abs(positions[:, 1]) < 1e-6))[0]
            if len(matches) != 1:
                raise ValueError('Missing unique horizontal source')
            index = int(matches[0])
            h = ir[index].copy()
            # Median-plane alerts have no left/right preference. Retain measured
            # front/rear spectral differences, but symmetrize ears at 0 and 180.
            if right_angle in (0, 180):
                h[:] = np.mean(h, axis=0)
            filters.append(h)
            source_indices.append(index)
    pulse_length = int(.08 * RATE)
    t = np.arange(pulse_length) / RATE
    noise = np.random.default_rng(901).standard_normal(pulse_length)
    noise = sosfilt(butter(4, [500, 11000], fs=RATE, btype='bandpass', output='sos'), noise)
    noise /= np.sqrt(np.mean(noise ** 2))
    edge = np.minimum(1, np.minimum(np.arange(pulse_length), np.arange(pulse_length)[::-1]) / 480)
    pulse = (.35 * np.sin(2 * np.pi * 1100 * t) + .65 * noise) * edge
    mono = np.zeros(int(.24 * RATE))
    mono[:pulse_length] = pulse
    second = int(.16 * RATE)
    mono[second:second + pulse_length] = pulse
    sounds = np.asarray([[fftconvolve(mono, h) for h in pair] for pair in filters])
    # Common gain only: preserve direction-dependent ILD/ITD, cap full-scale peak.
    gain = .12 / np.max(np.abs(sounds))
    # Listening adjustment: preserve the accepted rear sound exactly. Raise front
    # and sides by 6 dB, easing continuously to unchanged rear. Apply the SAME
    # gain to both ears to preserve measured ILD/ITD and front/rear spectra.
    angles = np.minimum(np.arange(0, 360, STEP), 360 - np.arange(0, 360, STEP))
    extra_gains = np.where(angles <= 90, 2.0,
                          1.5 + .5 * np.cos(np.pi * (angles - 90) / 90))
    sounds *= gain * extra_gains[:, None, None]
    assert np.max(np.abs(sounds)) <= .240001
    pcm = np.round(sounds * 32767).astype('<i2').transpose(0, 2, 1)
    assert np.array_equal(pcm[0, :, 0], pcm[0, :, 1])
    assert np.array_equal(pcm[36, :, 0], pcm[36, :, 1])
    assert not np.array_equal(pcm[0], pcm[36])
    assert np.sum(pcm[18, :, 1].astype(float)**2) > np.sum(pcm[18, :, 0].astype(float)**2)
    assert np.sum(pcm[54, :, 0].astype(float)**2) > np.sum(pcm[54, :, 1].astype(float)**2)
    header = b'MOBIHR01' + struct.pack('<IIII', RATE, len(pcm), pcm.shape[1], STEP)
    data = header + pcm.tobytes()
    destination = Path(destination)
    destination.mkdir(parents=True, exist_ok=True)
    (destination / 'warning_bank.bin').write_bytes(data)
    metadata = dict(dataset='SADIE II v2-1 D2 KEMAR', source_url='https://zenodo.org/records/10886409',
                    archive_sha256=ZIP_SHA256, sofa_member=SOFA_PATH,
                    sofa_sha256=hashlib.sha256(sofa).hexdigest(), source_indices=source_indices,
                    sample_rate=RATE, channels=2, step_degrees=STEP, frames_per_direction=pcm.shape[1],
                    pulse_seconds=.08, second_start_seconds=.16, common_gain=float(gain),
                    listening_gains=extra_gains.tolist(),
                    peak_fraction=float(np.max(np.abs(pcm.astype(float))) / 32767),
                    warning_bank_sha256=hashlib.sha256(data).hexdigest(),
                    changes='Horizontal 5-degree subset; right-positive conversion; symmetric median ears; broadband double pulse convolution; common peak normalization; front/side listening gain x2 tapering to unchanged rear; PCM16 quantization')
    (destination / 'manifest.json').write_text(json.dumps(metadata, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(metadata, indent=2))


if __name__ == '__main__':
    root = Path(__file__).resolve().parents[1]
    build(sys.argv[1], root / 'android/app/src/main/assets/hrtf')
