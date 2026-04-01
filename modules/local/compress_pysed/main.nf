process COMPRESS_PYSED {
    tag "${meta.id}_${meta.cycle_number}"
    label 'process_single'


    container "${ workflow.containerEngine == 'singularity' && !task.ext.singularity_pull_docker_container ?
        'https://depot.galaxyproject.org/singularity/ashlar:1.18.0--pyhdfd78af_0' :
        'yuanchen12/rcashlar:latest' }"

    input:
    tuple val(meta), path(image_file)

    output:
    tuple val(meta), path("${image_file.name}"), emit: tif
    path "versions.yml"                         , emit: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    """
    python3 << 'PYEOF'

    '''
    Write a compressed BigTIFF OME-TIFF whose IFDs are clustered at the end of the
    file, so Bio-Formats (showinf -nopix) can read the IFD chain with a single seek
    rather than seeking through all pixel data.

    Two-step approach:
    1. Write with tifffile (handles compression, predictor, OME-XML) → IFDs interleaved
    2. cluster_bigtiff_ifds() appends IFDs at EOF and patches next-IFD pointers in-place
        (no pixel data is read or written in step 2)
    '''

    import logging
    import shutil
    import struct
    import sys
    import tempfile
    import time
    from pathlib import Path

    import tifffile
    import tqdm


    class MessageFilter(logging.Filter):
        def __init__(self, *substrings):
            self.substrings = substrings

        def filter(self, record):
            return not any(s in record.getMessage() for s in self.substrings)


    logging.getLogger('tifffile').addFilter(
        MessageFilter('OME series contains invalid TiffData index')
    )


    def cluster_bigtiff_ifds(path):
        '''Redirect IFD chain to IFDs appended at EOF so Bio-Formats reads them with one seek.

        Modifies the file in-place:
        - Appends IFDs 1..N at EOF (StripOffsets already correct; only next-IFD patched)
        - Patches IFD0's next-IFD pointer to the first appended IFD
        No pixel data is read or written.

        Layout after (IFDs 1..N are dead-space in the data region, harmless to readers):
        before: IFD0  data0  IFD1  data1  IFD2  …  IFDN  dataN
        after:  IFD0* data0 [dead] data1 [dead] … [dead] dataN IFD1 IFD2 … IFDN
        '''
        path = Path(path)

        with tifffile.TiffFile(path) as tif:
            endian = tif.byteorder  # '<' (little) or '>' (big)
            ifd_offsets = [p.offset for p in tif.pages]
            data_offsets = [p.dataoffsets[0] for p in tif.pages]

        n = len(ifd_offsets)
        ifd_sizes = [data_offsets[i] - ifd_offsets[i] for i in range(n)]

        # Load all raw IFD bytes into memory (total << 1 MB)
        with path.open('rb') as f:
            raw_ifds = []
            for i in range(n):
                f.seek(ifd_offsets[i])
                raw_ifds.append(bytearray(f.read(ifd_sizes[i])))

        def _set_next_ifd(ifd_ba, next_ifd):
            n_ent = struct.unpack_from(endian + 'Q', ifd_ba, 0)[0]
            struct.pack_into(endian + 'Q', ifd_ba, 8 + n_ent * 20, next_ifd)

        file_size = path.stat().st_size  # IFD1 will land here

        with path.open('r+b') as f:
            # Patch IFD0's next-IFD pointer to point to the appended IFD1
            _set_next_ifd(raw_ifds[0], file_size if n > 1 else 0)
            f.seek(ifd_offsets[0])
            f.write(bytes(raw_ifds[0]))

            # Append IFDs 1..N at EOF; compute next-IFD offset on the fly
            f.seek(0, 2)
            for i in range(1, n):
                next_off = f.tell() + ifd_sizes[i] if i < n - 1 else 0
                _set_next_ifd(raw_ifds[i], next_off)
                f.write(bytes(raw_ifds[i]))


    # ── Main ──────────────────────────────────────────────────────────────────────

    # pysed_path = '${image_file}'
    # out_path   = '${image_file.name}'

    pysed_path, out_path = Path(pysed_path), Path(out_path)

    with tifffile.TiffFile(pysed_path) as tif:
        already_compressed = tif.pages[0].compression != tifffile.COMPRESSION.NONE

    if already_compressed:
        if pysed_path.samefile(out_path):
            print(f'Already compressed, in-place (no-op): {pysed_path}', file=sys.stderr)
        else:
            print(f'Already compressed, hardlinking: {pysed_path}', file=sys.stderr)
            try:
                out_path.hardlink_to(pysed_path)
            except OSError:
                shutil.copy2(pysed_path, out_path)
    else:
        print(f'Compressing: {pysed_path}', file=sys.stderr)

        with tempfile.NamedTemporaryFile(
            delete=False, suffix='.tif', dir=out_path.parent
        ) as f:
            tmp_path = Path(f.name)
        try:
            # Step 1: write compressed with tifffile (IFDs interleaved — tifffile default)
            with tifffile.TiffFile(pysed_path) as src_tif:
                ome_xml = src_tif.ome_metadata.encode()
                n_pages = len(src_tif.pages)
                with tifffile.TiffWriter(tmp_path, bigtiff=True) as tif_w:
                    for ii in tqdm.trange(n_pages, file=sys.stderr):
                        tif_w.write(
                            src_tif.pages[ii].asarray(),
                            # zstd avoided: Bio-Formats v8.5.0 (airlift pure-Java zstd) fails
                            # with "Output buffer too small" when predictor=True because
                            # airlift ignores/misreads the content_size field in the zstd
                            # frame header, then underestimates the output buffer size from
                            # the compressed size — which is very small when predictor makes
                            # zstd achieve high compression ratios (~10:1). zlib is immune
                            # because Bio-Formats always allocates output from image dimensions.
                            # ^ MAYBE - need further verification
                            compression='zlib',
                            predictor=True,
                            metadata=None,
                            description=ome_xml if ii == 0 else None,
                        )

            # Step 2: append IFDs at EOF and patch next-IFD pointers (no pixel I/O)
            print('Clustering IFDs …', file=sys.stderr)
            t0 = time.perf_counter()
            cluster_bigtiff_ifds(tmp_path)
            print(
                f'Clustering IFDs done in {time.perf_counter() - t0:.2f}s', file=sys.stderr
            )
            tmp_path.replace(out_path)
        except Exception:
            tmp_path.unlink(missing_ok=True)
            raise

    PYEOF

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        python: \$(python3 --version | sed 's/Python //')
        tifffile: \$(python3 -c "import tifffile; print(tifffile.__version__)")
    END_VERSIONS
    """
}
