# SADIE II derived warning audio

Copyright 2018, University of York. Apache License 2.0; see LICENSE.txt.

Source: SADIE II v2-1 D2 KEMAR, AudioLab, University of York.
https://zenodo.org/records/10886409
https://www.york.ac.uk/sadie-project/database.html

Reference: Thresh, Armstrong and Kearney, A Perceptual Evaluation of Individual and Non-Individual HRTFs: A Case Study of the SADIE II Database, Applied Sciences 2018, 8(11), 2029. https://doi.org/10.3390/app8112029

Modified for MOBI: horizontal 5-degree subset; right-positive azimuth conversion; averaged ears at 0/180 degrees; convolution with deterministic broadband double pulses; common peak normalization; PCM16 packing. See manifest.json for source checksums and indices. Regeneration: tools/build_spatial_warning_bank.py and upstream D2_HRIR_SOFA.zip (numpy/scipy/h5py required only when regenerating).

This generic air-conduction KEMAR HRTF is not personalized or measured for bone conduction. Stereo PCM differences do not prove perceived rear localization: evaluate the actual listener and headset. No elevation or distance rendering claim.

Listening adjustment after initial field check: front/side gain x2 (about +6 dB), tapered to x1 at the rear, applied identically to both ears. Rear PCM unchanged. Global peak capped at 0.24 full scale.
