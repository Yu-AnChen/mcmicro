/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    IMPORT MODULES / SUBWORKFLOWS / FUNCTIONS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

include { paramsSummaryMap       } from 'plugin/nf-schema'
include { paramsSummaryMultiqc   } from '../subworkflows/nf-core/utils_nfcore_pipeline'
include { softwareVersionsToYAML } from '../subworkflows/nf-core/utils_nfcore_pipeline'
include { UPDATE_FROM_OME        } from '../subworkflows/local/update_from_ome'
include { methodsDescriptionText } from '../subworkflows/local/utils_nfcore_mcmicro_pipeline'
include { MULTIQC                } from '../modules/nf-core/multiqc/main'
include { BASICPY                } from '../modules/nf-core/basicpy/main'
include { ASHLAR                 } from '../modules/nf-core/ashlar/main'
include { BACKSUB                } from '../modules/nf-core/backsub/main'
include { CELLPOSE               } from '../modules/nf-core/cellpose/main'
include { MCCELLPOSE             } from '../modules/local/mccellpose/main'
include { COREOGRAPH             } from '../modules/nf-core/coreograph/main'
include { DEEPCELL_MESMER        } from '../modules/nf-core/deepcell/mesmer/main'
include { SCIMAP_MCMICRO         } from '../modules/nf-core/scimap/mcmicro/main'
include { MCQUANT                } from '../modules/nf-core/mcquant/main'
include { BFTOOLS_SHOWINF        } from '../modules/nf-core/bftools/showinf/main'
include { PRELUDE                } from '../subworkflows/local/prelude/main'
include { EXTRACT_MARKERS        } from '../modules/local/extract_markers/main'
include { COMPRESS_PYSED         } from '../modules/local/compress_pysed/main'
include { WORKDIR_CLEANUP as WORKDIR_CLEANUP_PYSED   } from '../modules/local/workdir_cleanup/main'
include { WORKDIR_CLEANUP as WORKDIR_CLEANUP_MCQUANT } from '../modules/local/workdir_cleanup/main'

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    RUN MAIN WORKFLOW
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

workflow MCMICRO {

    take:
    ch_samplesheet // channel: samplesheet read in from --input_cycle or --input_sample
    ch_markersheet // channel: markersheet read in from --marker_sheet
    ch_registered  // channel: from --input_registered (empty otherwise)
    ch_segmented   // channel: from --input_segmented (empty otherwise)

    main:
    ch_versions = channel.empty()
    ch_multiqc_files = channel.empty()

    // Initialize post_registration as empty; assigned below based on input type
    post_registration = channel.empty()
    // Per-sample markers file channel (used when --marker_sheet is not provided)
    ch_per_sample_markers = channel.empty()

    // Resolve outdir to an absolute path so generated samplesheets are portable
    def outdir_abs = file(params.outdir).toAbsolutePath().toString()

    if (!params.input_registered && !params.input_segmented) {

        ch_samplesheet.map{meta, image_tiles, dfp, ffp -> [meta, image_tiles]} | BFTOOLS_SHOWINF
        ch_versions = ch_versions.mix(BFTOOLS_SHOWINF.out.versions)

        // Archive-compress pysed files in parallel (output not used by downstream steps)
        ch_samplesheet
            .filter  { it[1].toString().endsWith('.pysed.ome.tif') }
            .map     { meta, image_tiles, dfp, ffp -> [meta, image_tiles] }
            | COMPRESS_PYSED
        ch_versions = ch_versions.mix(COMPRESS_PYSED.out.versions)
        if (params.cleanup_workdir) {
            COMPRESS_PYSED.out.tif | WORKDIR_CLEANUP_PYSED
        }

        if (!params.marker_sheet) {
            EXTRACT_MARKERS(BFTOOLS_SHOWINF.out.xml)
            ch_versions = ch_versions.mix(EXTRACT_MARKERS.out.versions)
            // Build per-sample markers file: group CSVs by id, sort by cycle_number, extract marker_name
            ch_per_sample_markers = EXTRACT_MARKERS.out.csv
                .map { meta, csv -> [meta.subMap('id'), meta.cycle_number, csv] }
                .groupTuple(by: 0)
                .map { meta, cycle_nums, csvs ->
                    def sorted = [cycle_nums, csvs].transpose()
                        .sort { a, b -> a[0] <=> b[0] }
                    def content = 'marker_name\n' + sorted.collectMany { cycle_n, f ->
                        f.readLines().drop(1).findAll { it.trim() }.collect { line ->
                            '"' + line.split(',', 3)[2].trim().replaceAll('^"|"$', '') + '"'
                        }
                    }.join('\n') + '\n'
                    [meta, content]
                }
                .collectFile { meta, content -> ["${meta.id}_markers.csv", content] }
                .map { f -> [[id: f.name.replaceFirst('_markers\\.csv$', '')], f] }
        }

        PRELUDE(params.marker_sheet ? ch_markersheet : channel.empty(), ch_samplesheet, BFTOOLS_SHOWINF.out.xml)

        ch_multiqc_files = ch_multiqc_files.mix(PRELUDE.out.output_file_samplesheet)
                            .mix(PRELUDE.out.output_file_xml)
                            .mix(PRELUDE.out.output_file_markersheet)

        if (!params.prelude) {
            if (params.marker_sheet) {
                metadata    = UPDATE_FROM_OME(ch_samplesheet, ch_markersheet, BFTOOLS_SHOWINF.out.xml)
                ch_samplesheet = metadata.samplesheet
                ch_markersheet = metadata.markersheet
            }
            // if !marker_sheet: skip UPDATE_FROM_OME; ch_samplesheet has no pixel_size
            // (mesmer + tma_dearray already guarded by validation errors)

            ch_samplesheet.dump(tag: "ch_samplesheet")
            ch_markersheet.dump(tag: "ch_markersheet")

            //
            // MODULE: BASICPY
            //
            if (params.illumination == 'basicpy') {
                ch_samplesheet
                    .map{ meta, image_tiles, dfp, ffp -> [meta, image_tiles] }
                    .dump(tag: 'BASICPY in')
                    | BASICPY
                ch_versions = ch_versions.mix(BASICPY.out.versions)
                ch_samplesheet = ch_samplesheet
                    .map{ meta, image_tiles, dfp, ffp -> [meta, image_tiles] }
                    .join(BASICPY.out.profiles)
                    .dump(tag: 'ch_samplesheet (after BASICPY)')
            }

            ch_samplesheet
                .map{ meta, image_tiles, dfp, ffp ->
                    [meta.subMap('id', 'pixel_size'), [meta.cycle_number, image_tiles, dfp, ffp]]
                }
                // FIXME: pass groupTuple size: from samplesheet cycle count
                .groupTuple(sort: { a, b -> a[0] <=> b[0] } )
                .map{ meta, cycles -> [meta, *cycles.collect{ it[1..-1] }.transpose()]}
                .dump(tag: 'ASHLAR in')
                // flatten() handles list of empty-lists, turning it into a single empty list.
                .multiMap{ meta, images, dfps, ffps ->
                    images: [meta, images]
                    dfps: dfps.flatten()
                    ffps: ffps.flatten()
                }
                | ASHLAR
            ch_versions = ch_versions.mix(ASHLAR.out.versions)

            // Run Background Correction
            if (params.backsub) {
                ch_backsub_markers = ch_markersheet
                    .map { ['channel_number,cycle_number,marker_name,exposure,background,remove',
                        it.collect{ it.channel_number + "," + it.cycle_number + "," + it.marker_name + "," + it.exposure + "," + it.background + "," + it.remove}] }
                    .flatten()
                    .map { it.replaceAll('(?<=,|^)null(?=,|$)', '') }
                    .collectFile(name: 'markers_backsub.csv', sort: false, newLine: true)

                ASHLAR.out.tif
                    .combine(ch_backsub_markers)
                    .dump(tag: 'BACKSUB IN')
                    .multiMap{ meta, image, marker ->
                        image: [meta, image]
                        markers: [meta, marker]
                    }
                    | BACKSUB

                post_registration = BACKSUB.out.backsub_tif
                ch_versions = ch_versions.mix(BACKSUB.out.versions)
            } else {
                post_registration = ASHLAR.out.tif
            }

            // Generate samplesheet_registered.csv after ASHLAR
            ASHLAR.out.tif
                .map { meta, image ->
                    "${meta.id},${outdir_abs}/registration/ashlar/${image.name}"
                }
                .collectFile(
                    name: 'samplesheet_registered.csv',
                    seed: 'sample,registered_image\n',
                    sort: true, newLine: true,
                    storeDir: "${params.outdir}/registration/ashlar"
                )

        }
    }

    if (params.input_registered) {
        post_registration = ch_registered
        if (!params.marker_sheet) {
            EXTRACT_MARKERS(ch_registered)
            ch_versions = ch_versions.mix(EXTRACT_MARKERS.out.versions)
            ch_per_sample_markers = EXTRACT_MARKERS.out.csv
                .map { meta, csv ->
                    def content = 'marker_name\n' + csv.readLines().drop(1)
                        .findAll { it.trim() }
                        .collect { line -> '"' + line.split(',', 3)[2].trim().replaceAll('^"|"$', '') + '"' }
                        .join('\n') + '\n'
                    [meta.subMap('id'), content]
                }
                .collectFile { meta, content -> ["${meta.id}_markers.csv", content] }
                .map { f -> [[id: f.name.replaceFirst('_markers\\.csv$', '')], f] }
        }
    }

    if (params.input_segmented && !params.marker_sheet) {
        ch_seg_images_for_markers = ch_segmented
            .map { meta, image, mask -> [meta.subMap('id'), image] }
            .unique { it[0] }
        EXTRACT_MARKERS(ch_seg_images_for_markers)
        ch_versions = ch_versions.mix(EXTRACT_MARKERS.out.versions)
        ch_per_sample_markers = EXTRACT_MARKERS.out.csv
            .map { meta, csv ->
                def content = 'marker_name\n' + csv.readLines().drop(1)
                    .findAll { it.trim() }
                    .collect { line -> '"' + line.split(',', 3)[2].trim().replaceAll('^"|"$', '') + '"' }
                    .join('\n') + '\n'
                [meta.subMap('id'), content]
            }
            .collectFile { meta, content -> ["${meta.id}_markers.csv", content] }
            .map { f -> [[id: f.name.replaceFirst('_markers\\.csv$', '')], f] }
    }

    // Generate markers.csv for mcquant with just the marker_name column, and
    // omitting rows removed by backsub.
    if (params.marker_sheet) {
        ch_mcquant_markers = channel.of('marker_name')
            .concat(
                ch_markersheet
                    .flatten()
                    .filter{ row -> !(params.backsub && row.remove) }
                    .map{ row -> '"' + row.marker_name + '"' }
            )
            .dump(tag: "MARKERS")
            .collectFile(name: 'markers.csv', sort: false, newLine: true)
    }
    // else: ch_per_sample_markers is used directly in MCQUANT prep below

    if (!params.input_segmented) {

        // Run Coreograph
        if (params.tma_dearray) {
            COREOGRAPH(post_registration)
            COREOGRAPH.out.cores
                .transpose()
                .map { meta, img -> [meta + [id: meta.id + '_' + img.fileName.toString().tokenize('.')[0]], img]}
                .set { ch_segmentation_input }
        } else {
            ch_segmentation_input = post_registration
        }

        // Run Segmentation

        ch_masks = channel.empty()

        ch_segmentation_input
            .multiMap{ meta, image ->
                img: [meta + [segmenter: 'mesmer'], image]
                membrane_img: [[:], []]
            }
            | DEEPCELL_MESMER
        ch_masks = ch_masks.mix(DEEPCELL_MESMER.out.mask)
        ch_versions = ch_versions.mix(DEEPCELL_MESMER.out.versions)

        ch_segmentation_input
            .multiMap{ meta, image ->
                image: [meta + [segmenter: 'cellpose'], image]
                model: params.cellpose_model
            }
            | CELLPOSE
        ch_masks = ch_masks.mix(CELLPOSE.out.mask)
        ch_versions = ch_versions.mix(CELLPOSE.out.versions)

        ch_segmentation_input
            .multiMap{ meta, image ->
                image: [meta + [segmenter: 'mccellpose'], image]
            }
            | MCCELLPOSE
        ch_masks = ch_masks.mix(MCCELLPOSE.out.mask)
        ch_versions = ch_versions.mix(MCCELLPOSE.out.versions)

        // Generate samplesheet_segmented.csv after segmentation
        def img_pubdir = params.backsub
            ? "${outdir_abs}/backsub"
            : "${outdir_abs}/registration/ashlar"
        ch_segmentation_input
            .cross(ch_masks) { it[0]['id'] }
            .flatMap { t_img, t_mask ->
                def seg_pubdir = "${outdir_abs}/segmentation/${t_mask[0].segmenter}"
                def masks = t_mask[1] instanceof List ? t_mask[1] : [t_mask[1]]
                masks.collect { mask ->
                    "${t_mask[0].id},${img_pubdir}/${t_img[1].name},${seg_pubdir}/${mask.name},${t_mask[0].segmenter}"
                }
            }
            .collectFile(
                name: 'samplesheet_segmented.csv',
                seed: 'sample,registered_image,mask,segmenter\n',
                sort: true, newLine: true,
                storeDir: "${params.outdir}/segmentation"
            )

        // Run Quantification
        def ch_for_mcquant = ch_segmentation_input
            .cross(ch_masks) { it[0]['id'] }
            .map{ t_img, t_mask -> [t_mask[0], t_img[1], t_mask[1]] }

        if (params.marker_sheet) {
            ch_for_mcquant
                .combine(ch_mcquant_markers)
                .dump(tag: 'MCQUANT IN')
                .multiMap{ meta, image, masks, marker ->
                    image:   [meta, image]
                    mask:    [meta, masks]
                    markers: [meta, marker]
                }
                | MCQUANT
        } else {
            ch_for_mcquant
                .map { meta, image, masks -> [meta.subMap('id'), meta, image, masks] }
                .join(ch_per_sample_markers)
                .map { id_meta, full_meta, image, masks, markers -> [full_meta, image, masks, markers] }
                .dump(tag: 'MCQUANT IN')
                .multiMap { meta, image, masks, markers ->
                    image:   [meta, image]
                    mask:    [meta, masks]
                    markers: [meta, markers]
                }
                | MCQUANT
        }

        ch_versions = ch_versions.mix(MCQUANT.out.versions)

        if (params.cleanup_workdir) {
            MCQUANT.out.csv
                .map { meta, csv -> [meta.id, meta] }
                .join(ch_for_mcquant.map { meta, image, masks -> [meta.id, image, masks] })
                .map { id, meta, image, masks -> [meta, [image, masks].flatten()] }
                | WORKDIR_CLEANUP_MCQUANT
        }

    }

    if (params.input_segmented) {

        // unique images per sample (drop segmenter from meta for image channel)
        ch_seg_images = ch_segmented
            .map { meta, image, mask -> [meta.subMap('id'), image] }
            .unique { it[0] }

        // masks grouped by [id, segmenter] — preserves samplesheet row order within each group
        ch_seg_masks = ch_segmented
            .map { meta, image, mask -> [meta, mask] }
            .groupTuple()

        def ch_for_mcquant_seg = ch_seg_images
            .cross(ch_seg_masks) { it[0]['id'] }
            .map { t_img, t_mask -> [t_mask[0], t_img[1], t_mask[1]] }

        if (params.marker_sheet) {
            ch_for_mcquant_seg
                .combine(ch_mcquant_markers)
                .dump(tag: 'MCQUANT IN (segmented)')
                .multiMap { meta, image, masks, marker ->
                    image:   [meta, image]
                    mask:    [meta, masks]
                    markers: [meta, marker]
                }
                | MCQUANT
        } else {
            ch_for_mcquant_seg
                .map { meta, image, masks -> [meta.subMap('id'), meta, image, masks] }
                .join(ch_per_sample_markers)
                .map { id_meta, full_meta, image, masks, markers -> [full_meta, image, masks, markers] }
                .dump(tag: 'MCQUANT IN (segmented)')
                .multiMap { meta, image, masks, markers ->
                    image:   [meta, image]
                    mask:    [meta, masks]
                    markers: [meta, markers]
                }
                | MCQUANT
        }

        ch_versions = ch_versions.mix(MCQUANT.out.versions)

    }

    //
    // Collate and save software versions
    //
    def topic_versions = channel.topic("versions")
        .distinct()
        .branch { entry ->
            versions_file: entry instanceof Path
            versions_tuple: true
        }

    def topic_versions_string = topic_versions.versions_tuple
        .map { process, tool, version ->
            [ process[process.lastIndexOf(':')+1..-1], "  ${tool}: ${version}" ]
        }
        .groupTuple(by:0)
        .map { process, tool_versions ->
            tool_versions.unique().sort()
            "${process}:\n${tool_versions.join('\n')}"
        }

    softwareVersionsToYAML(ch_versions.mix(topic_versions.versions_file))
        .mix(topic_versions_string)
        .collectFile(
            storeDir: "${params.outdir}/pipeline_info",
            name: 'nf_core_'  +  'mcmicro_software_'  + 'mqc_'  + 'versions.yml',
            sort: true,
            newLine: true
        ).set { ch_collated_versions }

    //
    // MODULE: MultiQC
    //
    ch_multiqc_config        = channel.fromPath(
        "$projectDir/assets/multiqc_config.yml", checkIfExists: true)
    ch_multiqc_custom_config = params.multiqc_config ?
        channel.fromPath(params.multiqc_config, checkIfExists: true) :
        channel.empty()
    ch_multiqc_logo          = params.multiqc_logo ?
        channel.fromPath(params.multiqc_logo, checkIfExists: true) :
        channel.empty()

    summary_params      = paramsSummaryMap(
        workflow, parameters_schema: "nextflow_schema.json")
    ch_workflow_summary = channel.value(paramsSummaryMultiqc(summary_params))
    ch_multiqc_files = ch_multiqc_files.mix(
        ch_workflow_summary.collectFile(name: 'workflow_summary_mqc.yaml'))
    ch_multiqc_custom_methods_description = params.multiqc_methods_description ?
        file(params.multiqc_methods_description, checkIfExists: true) :
        file("$projectDir/assets/methods_description_template.yml", checkIfExists: true)
    ch_methods_description                = channel.value(
        methodsDescriptionText(ch_multiqc_custom_methods_description))

    ch_multiqc_files = ch_multiqc_files.mix(ch_collated_versions)

    ch_multiqc_files = ch_multiqc_files.mix(
        ch_methods_description.collectFile(
            name: 'methods_description_mqc.yaml',
            sort: true
        )
    )

    MULTIQC (
        ch_multiqc_files.collect(),
        ch_multiqc_config.toList(),
        ch_multiqc_custom_config.toList(),
        ch_multiqc_logo.toList(),
        [],
        []
    )

    emit:
    multiqc_report = MULTIQC.out.report.toList() // channel: /path/to/multiqc_report.html
    versions       = ch_versions                 // channel: [ path(versions.yml) ]

}

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    THE END
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/
