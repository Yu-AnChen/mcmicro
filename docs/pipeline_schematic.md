# Pipeline Execution Schematic

```
══════════════════════════════════════════════════════════════════════════════
  ENTRY POINTS (exactly one must be set)
══════════════════════════════════════════════════════════════════════════════

  --input_cycle / --input_sample          --input_registered    --input_segmented
         │                                       │                      │
         ▼                                       │                      │
  BFTOOLS_SHOWINF                                │                      │
  (per-cycle OME-XML)                            │                      │
         │                                       │                      │
         │  if !marker_sheet:                    │  if !marker_sheet:   │  if !marker_sheet:
         ├─► EXTRACT_MARKERS (xml mode)          ├─► EXTRACT_MARKERS    ├─► EXTRACT_MARKERS
         │   grouped by sample id,               │   (tiff mode)        │   (tiff mode)
         │   sorted by cycle_number              │                      │
         │   → ch_per_sample_markers             │   → ch_per_sample_   │   → ch_per_sample_
         │                                       │     markers          │     markers
         ▼                                       │                      │
  PRELUDE ──────────────────────────────────────►│◄─────────────────────│
  (MultiQC metadata tables)                      │                      │
  [marker summary skipped if !marker_sheet]      │                      │
  [exits here if --prelude]                      │                      │
         │                                       │                      │
         │  if marker_sheet:                     │                      │
         ▼                                       │                      │
  UPDATE_FROM_OME                                │                      │
  (enrich ch_markersheet + ch_samplesheet        │                      │
   from OME-XML; validates channel/cycle nums)   │                      │
  [skipped if !marker_sheet]                     │                      │
         │                                       │                      │
         │  if --illumination basicpy:           │                      │
         ├─► BASICPY                             │                      │
         │   (illumination correction)           │                      │
         │                                       │                      │
         ▼                                       ▼                      │
        ASHLAR                           post_registration ◄────────────┘
  (stitch + register → .ome.tif)         (registered image)
         │                                       │
         │  if --backsub:                        │
         ├─► BACKSUB                             │
         │   (background subtraction)            │
         │                                       │
         ▼                                       ▼
    post_registration ──────────────────► post_registration
         │
         │  [generates samplesheet_registered.csv]
         │
         │  [exits here if --stop_after registration]
         │
══════════════════════════════════════════════════════════════════════════════
  if marker_sheet:  ch_mcquant_markers built here (from ch_markersheet,
                    minus --backsub removes) — one global file for all samples
  if !marker_sheet: ch_per_sample_markers used — one file per sample,
                    joined by id at MCQUANT input
══════════════════════════════════════════════════════════════════════════════
         │
         ▼                                                     --input_segmented
  if !input_segmented:                                                │
         │                                                            │
         │  if --tma_dearray:                                         │
         ├─► COREOGRAPH                                               │
         │   (TMA core splitting)                                     │
         │                                                            │
         ▼                                                            │
  ch_segmentation_input                                               │
  ┌──────┴──────────────────────────────┐                             │
  │             │                       │                             │
  ▼             ▼                       ▼                             │
MCCELLPOSE   CELLPOSE           DEEPCELL_MESMER                       │
(if selected) (if selected)     (if selected)                         │
  │             │                       │                             │
  └──────┬──────┴───────────────────────┘                             │
         ▼                                                            │
      ch_masks  (merged from all selected segmenters)                 │
         │                                                            │
         │  [generates samplesheet_segmented.csv]                     │
         │                                                            │
         │  [exits here if --stop_after segmentation]                 │
         │                                                            │
         └────────────────────────────► ch_seg_masks ◄────────────────┘
                                               │
                                               ▼
                                           MCQUANT
                                  (single-cell quantification;
                                   one call per segmenter per sample)
                                               │
══════════════════════════════════════════════════════════════════════════════
         │  (all paths converge)
         ▼
      MULTIQC
  (aggregate report)
```

## Key channel relationships

```
ch_markersheet ──────────────────────────────────────────────────────────────
  source: --marker_sheet CSV (only when --marker_sheet provided)
  format: channel emitting one List<Map> with keys:
          channel_number, cycle_number, marker_name, exposure, background, remove
  used by:
    • PRELUDE (summary table)
    • UPDATE_FROM_OME (enriches with OME metadata, validates numbering)
    • ch_mcquant_markers (filtered to just marker_name for MCQUANT input)
    • BACKSUB (full CSV with exposure/background/remove columns)

ch_per_sample_markers ───────────────────────────────────────────────────────
  source: EXTRACT_MARKERS output (only when !marker_sheet)
  format: channel of [meta_id_only, markers_file]
          markers_file has one column: marker_name (no header row context needed)
  used by: MCQUANT (joined by meta.id to match each sample's image+mask)
  note: for cycle/sample input, per-cycle CSVs are grouped by sample id and
        sorted by cycle_number before concatenation

ch_samplesheet ──────────────────────────────────────────────────────────────
  source: --input_cycle / --input_sample
  mutated by: UPDATE_FROM_OME → adds pixel_size, channel_count from OME-XML
              (only when --marker_sheet is provided)
  mutated by: BASICPY → replaces image_tiles with corrected tiles

post_registration ───────────────────────────────────────────────────────────
  source (cycle/sample): ASHLAR.out.tif  OR  BACKSUB.out.backsub_tif
  source (registered):   ch_registered (passthrough)
  flows into: COREOGRAPH or directly to segmenters
```

## Stop points

| `--stop_after` | Exits after | Skips |
|---|---|---|
| *(not set)* | MCQUANT | — |
| `registration` | ASHLAR/BACKSUB | segmentation, MCQUANT |
| `segmentation` | segmenters | MCQUANT |
| `--prelude` | PRELUDE | everything after |

## Constraints when --marker_sheet is omitted

| Feature | Requires --marker_sheet | Reason |
|---|---|---|
| `--backsub` | yes | needs exposure/background/remove columns |
| `--tma_dearray` | yes | needs pixel_size from UPDATE_FROM_OME |
| `--segmentation mesmer` | yes | needs pixel_size from UPDATE_FROM_OME |

UPDATE_FROM_OME is skipped entirely when `!marker_sheet`. This means pixel_size
is not available for TMA de-arraying or Mesmer segmentation — hence the hard
validation errors above. For all other segmenters (mccellpose, cellpose),
skipping UPDATE_FROM_OME is safe.
