# Custom bus safety detection annotation guidelines

This first YOLO detection subset uses the four classes in
`class_mapping.json`. YOLO label IDs are local, contiguous indices (0–3), not
the project taxonomy IDs. The mapping file is the source for that relationship;
the dataset YAML repeats the required Ultralytics names and is checked against
the mapping by the dataset validator.

Use one YOLO row per object:

```text
<class_id> <x_center> <y_center> <width> <height>
```

All coordinates and sizes are normalized to `[0, 1]` relative to the image.
Draw a tight, axis-aligned box around visible object pixels, excluding shadows
and reflections. Do not infer user movement, distance, danger, or intent from a
single image. Do not add risk labels to detection annotations.

## Common visibility rules

- If at least half of an object is visible and its class is unambiguous, label
  the visible extent. Otherwise omit it and record the ambiguity for review.
- For an object cut by the image boundary, box only the visible portion.
- Omit objects smaller than 16 pixels in either dimension, following the
  existing labeling standard.
- Label separate physical objects separately, including adjacent instances.
- Do not duplicate one object under multiple labels except the explicit
  `bus`/`bus_door` overlap described below.
- Empty `.txt` files are valid for reviewed negative images. Missing label files
  are invalid because they cannot distinguish a reviewed negative from an
  annotation omission.
- Blur faces and license plates and remove/strip EXIF GPS before sharing data.

## Classes

### `bus`

- Label: the visible bus body, including school buses. Include a partial bus
  only when the remaining body is identifiable as a bus.
- Exclude: trucks, cars, taxis, vans, and ambiguous vehicle fragments.
- Boundary: tight box around the visible body; do not add the road, shadow, or
  reflection.
- When both body and door are visible, label the bus and the passenger door as
  separate overlapping boxes.

### `bus_door`

- Label: front or middle passenger boarding/alighting door on a bus, whether
  open or closed; include its visible steps/handrail only when they are part of
  the doorway assembly.
- Exclude: rear emergency doors, unrelated vehicle doors, and a doorway too
  occluded to identify.
- Boundary: tight box around the passenger-door assembly. Overlap with the
  enclosing `bus` box is expected and is not a duplicate annotation.

### `bus_stop`

- Label: a clearly identifiable bus-stop sign and its adjacent, visually
  connected passenger-stop structure as one instance. Label separate adjacent
  stops separately.
- Exclude: generic traffic signs, benches with no clearly identifiable stop
  sign, and structures whose bus-stop identity is uncertain or whose sign is
  occluded.
- Boundary: box the sign and adjacent shelter/platform structure described by
  the taxonomy. Do not include unrelated street scenery to enlarge it.

### `obstacle`

- Label: a clearly visible fixed or semi-fixed physical object that occupies a
  pedestrian-access area, such as a pole, tree guard, or an illegally parked
  vehicle visibly on the pedestrian area.
- Exclude: people, bicycles, ordinary moving traffic, background objects not
  visibly occupying a pedestrian area, and any object called an obstacle only
  because of assumed user route or danger.
- Boundary: tight box around the individual object. If it is unclear from the
  image whether the object occupies the pedestrian area, omit and flag it for
  review rather than infer context.

## Ambiguity and review

Do not invent labels or resolve class ambiguity by annotator preference. Leave
the object unlabeled and add it to a review list when bus vs. other vehicle,
bus-stop vs. generic sign, or obstacle-vs-background cannot be resolved from
the image. Resolve taxonomy questions through the project taxonomy owner; this
document does not change the seven-class project taxonomy.
