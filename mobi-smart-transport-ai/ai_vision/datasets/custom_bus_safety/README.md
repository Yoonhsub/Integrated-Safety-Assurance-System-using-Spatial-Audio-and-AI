# Local custom bus safety dataset

Place locally collected and reviewed dataset files under this directory. Dataset
images and source videos are not committed. Reviewed YOLO annotation `.txt`
files may be committed only when the corresponding source data is authorized for
sharing and contains no identifying metadata; coordinate labels alone are not a
substitute for the image data.

Expected layout:

```text
custom_bus_safety/
├── images/
│   ├── train/
│   ├── val/
│   └── test/
├── labels/
│   ├── train/
│   ├── val/
│   └── test/
└── dataset_manifest.csv   # optional source/session leakage metadata
```

Each image must have a same-stem `.txt` label file. A zero-byte label file is
the documented representation of a reviewed image with no target objects.
Dataset data is local; the checked-in training configuration points here but
does not contain or download any samples.
