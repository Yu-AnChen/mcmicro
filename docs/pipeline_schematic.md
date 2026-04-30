# Pipeline Execution Schematic

```txt
══════════════════════════════════════════════════════════════════════════════
  ENTRY POINTS (exactly one must be set)
══════════════════════════════════════════════════════════════════════════════

  --input_cycle / --input_sample          --input_registered    --input_segmented
         │                                       │                      │
         ▼                                       │                      │
  BFTOOLS_SHOWINF                                │                      │
  (per-cycle OME-XML)                            │                      │
         │                                       │                      │
         ├─► COMPRESS_PYSED                      │                      │
         │   (.pysed.ome.tif files only;         │                      │
         │    fire-and-forget, no downstream     │                      │
         │    output)                            │                      │
         │                                       │                      │
         │  if !marker_sheet:                    │  if !marker_sheet:   │  if !marker_sheet:
         ├─► EXTRACT_MARKERS (xml mode)          ├─► EXTRACT_MARKERS    ├─► EXTRACT_MARKERS
         │   grouped by sample id,               │   (tiff mode)        │   (tiff mode, unique
         │   sorted by cycle_number              │                      │    image per sample)
         │   → ch_per_sample_markers             │   → ch_per_sample_   │   → ch_per_sample_
         │                                       │     markers          │     markers
         ▼                                       │                      │
  PRELUDE                                        │                      │
  (MultiQC metadata tables)                      │                      │
  [marker summary skipped if !marker_sheet]      │                      │
  [exits here if --prelude]                      │                      │
         │                                       │                      │
         │  if marker_sheet:                     │                      │
         ▼                                       │                      │
  UPDATE_FROM_OME                                │                      │
  (enrich ch_markersheet + ch_samplesheet from   │                      │
   OME-XML; validates image-channel/cycle nums)  │                      │
  [skipped if !marker_sheet]                     │                      │
         │                                       │                      │
         │  if --illumination basicpy:           │                      │
         ├─► BASICPY                             │                      │
         │   (illumination correction)           │                      │
         │                                       │                      │
         │  [waits for PRELUDE + EXTRACT_MARKERS │                      │
         │   to finish before ASHLAR launches]   │                      │
         ▼                                       ▼                      │
        ASHLAR                           post_registration ◄────────────┘
  (stitch + register → .ome.tif)         (registered image)
         │
         │  [generates samplesheet_registered.csv]
         │
         │  if --backsub:
         ├─► BACKSUB
         │   (background subtraction)
         │
         ▼
    post_registration
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
  [if !tma_dearray and !no_cleanup_slide:                             │
   WORKDIR_CLEANUP_ASHLAR fires here (fire-and-forget)]              │
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
                                   one call per segmenter per sample;
                                   accepts multiple masks per call)
                                               │
                                  [if !input_segmented and !no_cleanup_slide:
                                   WORKDIR_CLEANUP_MCQUANT frees
                                   slide + mask work dirs]
══════════════════════════════════════════════════════════════════════════════
         │  (all paths converge)
         ▼
      MULTIQC
  (aggregate report)
```

## Key data flows

```
ch_markersheet ──────────────────────────────────────────────────────────────
  source: --marker_sheet CSV (only when --marker_sheet provided)
  format: queue emitting one List<Map> with keys:
          channel_number, cycle_number, marker_name, exposure, background, remove
  used by:
    • PRELUDE (summary table)
    • UPDATE_FROM_OME (enriches with OME metadata, validates numbering)
    • ch_mcquant_markers (filtered to just marker_name for MCQUANT input)
    • BACKSUB (full CSV with exposure/background/remove columns)

ch_per_sample_markers ───────────────────────────────────────────────────────
  source: EXTRACT_MARKERS output (only when !marker_sheet)
  format: queue of [meta_id_only, markers_file]
          markers_file has one column: marker_name (no header row)
  used by: MCQUANT (joined by meta.id to match each sample's image+mask)
  note: for cycle/sample input, per-cycle CSVs are grouped by sample id and
        sorted by cycle_number before concatenation
  note: image channel names cleaned by --marker_name_replace regex before extraction
        (default strips leading digit prefixes and trailing dye suffixes)

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

| `--stop_after` | Exits after    | Skips                             |
| -------------- | -------------- | --------------------------------- |
| *(not set)*    | MCQUANT        | —                                 |
| `registration` | ASHLAR/BACKSUB | COREOGRAPH, segmentation, MCQUANT |
| `segmentation` | segmenters     | MCQUANT                           |
| `--prelude`    | PRELUDE        | everything after                  |

## Work directory cleanup (`--no_cleanup_slide`)

By default (`no_cleanup_slide = false`), the pipeline frees large intermediate
work directories at three points:

| Trigger                               | What is cleaned        |
| ------------------------------------- | ---------------------- |
| After COMPRESS_PYSED                  | pysed slide work dir   |
| After ASHLAR (when !tma_dearray)      | slide work dir         |
| After MCQUANT (when !input_segmented) | slide + mask work dirs |

Pass `--no_cleanup_slide` to disable all three cleanups (useful for debugging).

## Constraints when --marker_sheet is omitted

| Feature                 | Requires --marker_sheet | Reason                                   |
| ----------------------- | ----------------------- | ---------------------------------------- |
| `--backsub`             | yes                     | needs exposure/background/remove columns |
| `--tma_dearray`         | yes                     | needs pixel_size from UPDATE_FROM_OME    |
| `--segmentation mesmer` | yes                     | needs pixel_size from UPDATE_FROM_OME    |

UPDATE_FROM_OME is skipped entirely when `!marker_sheet`. This means pixel_size
is not available for TMA de-arraying or Mesmer segmentation — hence the hard
validation errors above. For all other segmenters (mccellpose, cellpose),
skipping UPDATE_FROM_OME is safe.
